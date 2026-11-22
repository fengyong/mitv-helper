import Foundation

/// 上传/下载队列服务。
/// - 状态机：见 QueueStateMachine（纯函数）；所有状态变更在私有串行队列上进行
/// - 并发：maxConcurrent 个传输槽位（默认 2，电视端是小服务器不宜更多）
/// - 智能分流：上传前 engine.list("/") 决定 Movies//Pictures//根 + 重名顺延
/// - 持久化：queue.json 原子写；重启后 running/connecting 项恢复为 queued（引擎 APPE 续传接管）
/// - 断线：autoPauseForDisconnect / autoResumeAfterReconnect 由 HeartbeatService 驱动
final class QueueService {

    enum HoldReason: Equatable { case none, user, disconnected }

    // MARK: 注入

    private let engineProvider: () -> TransferEngine
    private let endpointProvider: () -> FTPEndpoint?
    private let capabilitiesProvider: () -> Capabilities?
    private let persistenceURL: URL
    var concurrency: Int
    private let resumeOnStart: Bool

    // MARK: 回调（统一主队列）

    /// 任一状态变化（已合并且节流）
    var onChanged: (() -> Void)?
    /// 一个批量内全部任务终结（completed 数 / 失败+取消数）
    var onBatchCompleted: ((_ batchId: String, _ completed: Int, _ failed: Int) -> Void)?
    /// 指定目录上传时已失效、降级回根目录后回调（主队列，每批至多一次；供 toast 告知，设计稿 v2 §6.3/D6）
    var onUploadFallback: ((_ batchId: String, _ dir: String) -> Void)?

    /// 全局指定目录（「存放位置 = 指定位置」）：nil = 智能分类（AppCoordinator 注入 TVStore 快照，设计稿 v2 §6.1）
    var targetDirProvider: (() -> String?)?

    // MARK: 状态（全部仅 stateQ 内访问）

    private let stateQ = DispatchQueue(label: "mitv.queue.state", qos: .utility)
    private var items: [QueueItem] = []
    private var handles: [String: TransferHandle] = [:]
    private var batchNotified: Set<String> = []
    private var schedulerHalted = false
    private var hold: HoldReason = .none
    /// 已发过降级告知的批次（每批至多一次，防整批降级时 toast 刷屏）
    private var fallbackNotifiedBatches: Set<String> = []
    private var lastPersistAt = Date.distantPast
    private var notifyPending = false
    private var notifyDirty = false
    private let persistInterval: TimeInterval = 0.5

    // MARK: Init / 持久化恢复

    init(engineProvider: @escaping () -> TransferEngine,
         endpointProvider: @escaping () -> FTPEndpoint?,
         capabilitiesProvider: @escaping () -> Capabilities?,
         persistenceDirectory: URL = TVStore.defaultDirectory(),
         concurrency: Int = 2,
         resumeOnStart: Bool = true) {
        self.engineProvider = engineProvider
        self.endpointProvider = endpointProvider
        self.capabilitiesProvider = capabilitiesProvider
        self.persistenceURL = persistenceDirectory.appendingPathComponent("queue.json")
        try? FileManager.default.createDirectory(at: persistenceDirectory, withIntermediateDirectories: true, attributes: nil)
        self.concurrency = max(1, concurrency)
        self.resumeOnStart = resumeOnStart
        self.schedulerHalted = !resumeOnStart

        // 恢复：running/connecting → queued（引擎侧 SIZE+APPE 从断点续传）
        if let data = try? Data(contentsOf: self.persistenceURL) {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            if let saved = try? dec.decode([QueueItem].self, from: data) {
                items = saved.map { item in
                    var it = item
                    if it.phase == .running || it.phase == .connecting {
                        it.phase = .queued
                        it.bytesPerSecond = 0
                        it.bytes = 0 // 上次会话的进度对新一轮传输无意义（防 progress max() 卡在旧值）
                    }
                    return it
                }
            }
        }
        if !items.isEmpty {
            // 重启恢复：已经是整批终态的批次视为已通知，不再重复发完成庆祝（声音/系统通知/弹跳）
            for (b, members) in Dictionary(grouping: items, by: { $0.batchId })
            where !members.isEmpty && members.allSatisfy({ $0.phase.isTerminal }) {
                batchNotified.insert(b)
            }
            // 恢复项先等连接就绪再调度（协调器连接成功后 connectionReady() 放行）：
            // 上次退出常因电视关机/断线，此刻直接跑只会对 stale endpoint 逐项判失败，
            // 也与能力探测并发争抢嵌入式服务器的有限连接（review A1）
            hold = .disconnected
            stateQ.async { [weak self] in
                self?.notifyChange()
            }
        }
    }

    /// 退出前调用：停调度 + 强制原子写（不取消进行中的回调，重启后断点续传）
    func suspendForShutdown() {
        stateQ.sync {
            schedulerHalted = true
            persistLocked(force: true)
        }
    }

    // MARK: 快照

    func snapshot() -> [QueueItem] { stateQ.sync { items } }

    // MARK: 入队

    @discardableResult
    func addUploads(_ urls: [URL], targetDir: String? = nil) -> [QueueItem] {
        let fm = FileManager.default
        let batch = UUID().uuidString
        let created: [QueueItem] = urls.compactMap { url in
            let name = url.lastPathComponent
            var size: Int64 = 0
            if let attr = try? fm.attributesOfItem(atPath: url.path),
               let n = attr[.size] as? NSNumber { size = n.int64Value }
            var it = QueueItem(direction: .upload, kind: MediaKind.of(url: url),
                               localPath: url.path, displayName: name,
                               sizeBytes: size, batchId: batch)
            // 批级目标（「上传到这里」）：入队即写入任务项，随 queue.json 持久化（设计稿 v2 §6.1）
            if let dir = targetDir { it.dirOverride = dir }
            return it
        }
        guard !created.isEmpty else { return [] }
        stateQ.sync {
            items.append(contentsOf: created)
            persistLocked(force: true)
            notifyChange()
            scheduleIfNeeded()
        }
        return created
    }

    @discardableResult
    func addDownloads(_ entries: [FTPFileEntry], toDirectory dir: URL) -> [QueueItem] {
        let batch = UUID().uuidString
        let fm = FileManager.default
        var usedNames = Set<String>()
        // 先按「本批 + 磁盘已有」预去重构造；最终唯一化在 stateQ 内并入队列级 inflight（跨批次重名，review D6）
        var created: [QueueItem] = entries.compactMap { entry in
            guard !entry.isDirectory else { return nil }
            // 大小写不敏感：本地卷（APFS 默认）与电视 U 盘（FAT）都把 IMG.jpg/img.jpg 当同一文件，
            // 批内敏感去重会让两项写同一个本地文件（截断式下载互相毁掉）
            var unique = NameCodec.uniqued(entry.name, existing: usedNames, caseInsensitive: true)
            if fm.fileExists(atPath: dir.appendingPathComponent(unique).path) {
                var i = 2
                let stem = (unique as NSString).deletingPathExtension
                let ext = (unique as NSString).pathExtension
                while true {
                    let next = ext.isEmpty ? "\(stem) (\(i))" : "\(stem) (\(i)).\(ext)"
                    if !fm.fileExists(atPath: dir.appendingPathComponent(next).path) { unique = next; break }
                    i += 1
                }
            }
            usedNames.insert(unique)
            let localPath = dir.appendingPathComponent(unique).path
            var it = QueueItem(direction: .download, kind: MediaKind.of(fileName: entry.name),
                               localPath: localPath, displayName: entry.name,
                               sizeBytes: entry.size ?? 0, batchId: batch)
            it.remotePath = entry.path
            return it
        }
        guard !created.isEmpty else { return [] }
        stateQ.sync {
            // 跨批次互斥：未终结下载项已占用的本地路径不可复用（截断式下载会互相毁掉）
            // 大小写不敏感比较：IMG.jpg 在传时，img.jpg 新批次必须顺延
            let inflight = Set(items.filter { $0.direction == .download && !$0.phase.isTerminal }.map { $0.localPath.lowercased() })
            for i in created.indices {
                if inflight.contains(created[i].localPath.lowercased()) {
                    var unique = (created[i].localPath as NSString).lastPathComponent
                    var k = 2
                    let stem = (unique as NSString).deletingPathExtension
                    let ext = (unique as NSString).pathExtension
                    while true {
                        let next = ext.isEmpty ? "\(stem) (\(k))" : "\(stem) (\(k)).\(ext)"
                        let cand = dir.appendingPathComponent(next).path
                        if !inflight.contains(cand.lowercased()) && !fm.fileExists(atPath: cand) {
                            unique = next
                            created[i].localPath = cand
                            break
                        }
                        k += 1
                    }
                }
            }
            items.append(contentsOf: created)
            persistLocked(force: true)
            notifyChange()
            scheduleIfNeeded()
        }
        return created
    }

    // MARK: 单项操作

    func pause(id: String) { applyUserEvent(.userPause, id: id, cancelHandle: true) }
    func resume(id: String) { applyUserEvent(.resume, id: id) }
    func cancel(id: String) { applyUserEvent(.userCancel, id: id, cancelHandle: true) }
    func retry(id: String) { applyUserEvent(.retry, id: id) }

    func pauseAllByUser() {
        stateQ.sync {
            hold = .user
            for i in items.indices where items[i].isBusy {
                let before = items[i].phase
                items[i] = QueueStateMachine.apply(.userPause, to: items[i])
                // 与单项暂停一致：真正取消引擎传输，否则「暂停」后传输继续跑完、下载继续写盘
                if items[i].phase != before { handles[items[i].id]?.cancel() }
            }
            persistLocked(force: true)
            notifyChange()
        }
    }

    func resumeAllByUser() {
        stateQ.sync {
            // 用户点「全部继续」= 明确意图，无论 hold 处于 .user / .disconnected / .none 都生效
            // （旧实现 guard hold == .user：断线流程覆盖 hold 后按钮永久失效，review D8）
            hold = .none
            for i in items.indices where items[i].phase == .paused {
                items[i] = QueueStateMachine.apply(.resume, to: items[i])
            }
            persistLocked(force: true)
            notifyChange()
            scheduleIfNeeded()
        }
    }

    /// 断线：整体暂停（autoPaused 标记，重连后自动恢复），不再开新任务
    func autoPauseForDisconnect() {
        stateQ.sync {
            guard hold != .disconnected else { return }
            hold = .disconnected
            for i in items.indices where items[i].isBusy {
                let before = items[i].phase
                items[i] = QueueStateMachine.apply(.autoPause, to: items[i])
                // 取消引擎句柄：死连接上的传输只会空耗到超时，取消后重连走干净的续传
                if items[i].phase != before { handles[items[i].id]?.cancel() }
            }
            persistLocked(force: true)
            notifyChange()
        }
    }

    /// 重连成功（心跳驱动）：恢复因断线暂停的任务。仅断线流程置过 hold 才生效
    func autoResumeAfterReconnect() { connectionReady(onlyIfHeld: true) }

    /// 连接就绪（首连成功/手动重连/引擎切换后重连）：放行启动恢复的等待项 +
    /// 恢复断线暂停 + 自动重试连接类失败项。只解除 .disconnected——
    /// 用户「全部暂停」（hold=.user）不得被重连悄悄解除
    func connectionReady() { connectionReady(onlyIfHeld: false) }

    private func connectionReady(onlyIfHeld: Bool) {
        stateQ.sync {
            let wasDisconnected = hold == .disconnected
            if onlyIfHeld {
                guard wasDisconnected else { return }
            }
            if wasDisconnected { hold = .none }
            for i in items.indices {
                if wasDisconnected, items[i].phase == .paused, items[i].autoPaused {
                    items[i] = QueueStateMachine.apply(.resume, to: items[i])
                } else if items[i].phase == .failed, items[i].connectionDropped == true {
                    // 连接类失败（心跳判掉线前的窗口期/启动抢跑）：重连即自动重试，
                    // 不再要求用户对着一排失败项逐个点「重试」（review A2）
                    items[i] = QueueStateMachine.apply(.retry, to: items[i])
                }
            }
            persistLocked(force: true)
            notifyChange()
            scheduleIfNeeded()
        }
    }

    /// 运行中调整并发数（设置页）
    func setConcurrency(_ n: Int) {
        stateQ.sync {
            concurrency = max(1, n)
            scheduleIfNeeded()
        }
    }

    /// 清空已完成/已取消/已失败
    func clearFinished() {
        stateQ.sync {
            items.removeAll { $0.phase.isTerminal }
            persistLocked(force: true)
            notifyChange()
        }
    }

    func remove(id: String) {
        stateQ.sync {
            guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
            if items[idx].isBusy { handles[id]?.cancel() }
            handles[id] = nil
            items.remove(at: idx)
            persistLocked(force: true)
            notifyChange()
        }
    }

    // MARK: 事件应用（stateQ 上执行）

    private func applyUserEvent(_ event: QueueEvent, id: String, cancelHandle: Bool = false) {
        stateQ.sync {
            guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
            let before = items[idx].phase
            items[idx] = QueueStateMachine.apply(event, to: items[idx])
            if items[idx].phase != before {
                if before.isTerminal && !items[idx].phase.isTerminal {
                    // 重试把批次拉回非终态后必须重新武装完成回调，
                    // 否则「删除前先下载」的批次重试成功后不会再触发删除
                    batchNotified.remove(items[idx].batchId)
                }
                if cancelHandle { handles[id]?.cancel() }
                persistLocked(force: true)
                notifyChange()
                scheduleIfNeeded()
            }
        }
    }

    // MARK: 调度

    private func scheduleIfNeeded() {
        // 仅在 stateQ 上调用
        guard !schedulerHalted, hold == .none else { return }
        let busy = items.filter { $0.phase == .connecting || $0.phase == .running }.count
        var slots = concurrency - busy
        guard slots > 0 else { return }
        for i in items.indices where items[i].phase == .queued {
            guard slots > 0 else { break }
            items[i] = QueueStateMachine.apply(.startConnecting, to: items[i])
            let id = items[i].id
            stateQ.async { [weak self] in self?.beginTransfer(id) }
            slots -= 1
        }
    }

    /// 连接标记后的真正起传（仍在 stateQ；远端操作全部异步回调回 stateQ）
    private func beginTransfer(_ id: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        guard items[idx].phase == .connecting else { return } // 可能已被暂停/取消
        let item = items[idx]
        guard let endpoint = endpointProvider() else {
            finishWithEngineError(id: id, error: EngineError.notConnected)
            return
        }
        let handle = TransferHandle()
        handles[id] = handle
        switch item.direction {
        case .download:
            startDownload(item, endpoint: endpoint, handle: handle)
        case .upload:
            // 重试/断线恢复的项沿用已定目标（SIZE+APPE 续传语义），不再重新分流
            if item.remotePath != nil {
                startUpload(id, handle: handle)
                return
            }
            // 两层目标解析（设计稿 v2 §6.1）：任务项批级目标（「上传到这里」）> 全局指定位置 > 智能分流。
            // 指定目录（非根）直列目标目录本身：存在与否以 LIST 结果为准，比智能分流少一次根目录 LIST
            let explicit = item.dirOverride ?? targetDirProvider?()
            if let dir = explicit, dir != "/" {
                listUploadTarget(id, dir: dir, handle: handle)
                return
            }
            // 智能分流（或显式根目录）：先看根目录定目标文件夹（根列表兼作重名判定依据）
            engineProvider().list(endpoint, path: "/") { [weak self] result in
                guard let self = self else { return }
                self.stateQ.async { self.chooseUploadDir(id, rootEntries: result, handle: handle) }
            }
        }
    }

    /// 智能分流第一步：根目录列表 → 目标文件夹（Movies/Pictures/根）
    private func chooseUploadDir(_ id: String, rootEntries: Result<[FTPFileEntry], Error>, handle: TransferHandle) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        guard items[idx].phase == .connecting else { return } // 可能已被暂停/取消
        guard case .success(let root) = rootEntries else {
            // 根列表读不到（新盘挂载怪癖/空目录 LIST 报错/偶发失败）→ 降级直传根目录。
            // 无目录列表 = 无重名判定（覆盖风险让位于可用性）；上传本身失败再如实报错
            let reason = (rootEntries.failureError as? LocalizedError)?.errorDescription ?? "未知"
            startUploadWithFallback(id, dir: "/", handle: handle)
            return
        }
        // 两层解析（设计稿 v2 §6.1）：批级覆盖 / 全局指定 / 智能分流。非根指定目录已在 beginTransfer
        // 直列目标目录，走到这里只可能是「显式根目录」或「智能分流」
        let dir = items[idx].dirOverride ?? targetDirProvider?() ?? SmartRouting.destinationDir(kind: items[idx].kind)
        if dir == "/" {
            finalizeUploadRouting(id, dir: dir, dirExisted: true, dirEntries: rootEntries, handle: handle)
            return
        }
        guard let endpoint = endpointProvider() else {
            finishWithEngineError(id: id, error: EngineError.notConnected)
            return
        }
        // 重名顺延必须依据【目标目录】里的已有文件——只看根目录会让 /Movies 里的同名文件被静默覆盖
        let dirName = (dir as NSString).lastPathComponent
        let dirExisted = root.contains { $0.isDirectory && $0.name.lowercased() == dirName.lowercased() }
        if dirExisted {
            engineProvider().list(endpoint, path: dir) { [weak self] dirResult in
                guard let self = self else { return }
                self.stateQ.async { self.finalizeUploadRouting(id, dir: dir, dirExisted: true, dirEntries: dirResult, handle: handle) }
            }
            return
        }
        // 目录不存在 → 尽力创建（视频/图片两个目录）：支持 MKD 的设备自动归类；
        // MKD 被拒（真机 SwiFTP 550）→ list 也失败 → 回根目录降级
        engineProvider().makeDirectory(endpoint, path: dir) { [weak self] _ in
            guard let self = self else { return }
            self.stateQ.async {
                guard let idx2 = self.items.firstIndex(where: { $0.id == id }),
                      self.items[idx2].phase == .connecting,
                      let endpoint2 = self.endpointProvider() else {
                    self.finishWithEngineError(id: id, error: EngineError.notConnected)
                    return
                }
                self.engineProvider().list(endpoint2, path: dir) { dirResult in
                    self.stateQ.async { self.finalizeUploadRouting(id, dir: dir, dirExisted: false, dirEntries: dirResult, handle: handle) }
                }
            }
        }
    }

    /// 指定目标目录上传（设计稿 v2 §6.3）：直列该目录；目录不存在 → 尽力 MKD 重建最后一级 →
    /// 仍失败回退电视根目录（D6）+ onUploadFallback（主队列，每批至多一次防 toast 刷屏）
    private func listUploadTarget(_ id: String, dir: String, handle: TransferHandle) {
        guard let endpoint = endpointProvider() else {
            finishWithEngineError(id: id, error: EngineError.notConnected)
            return
        }
        engineProvider().list(endpoint, path: dir) { [weak self] result in
            guard let self = self else { return }
            self.stateQ.async {
                guard let idx = self.items.firstIndex(where: { $0.id == id }),
                      self.items[idx].phase == .connecting else { return } // 可能已被暂停/取消
                if case .success(let entries) = result {
                    self.finalizeUploadRouting(id, dir: dir, dirExisted: true, dirEntries: .success(entries), handle: handle)
                } else {
                    self.recoverUploadTarget(id, dir: dir, handle: handle)
                }
            }
        }
    }

    /// 指定目录 LIST 失败的兜底：尽力 MKD（支持建目录的设备自动重建）→ LIST；
    /// 仍失败（真机 MKD 550 等）→ 回根目录 + 每批一次的降级告知
    private func recoverUploadTarget(_ id: String, dir: String, handle: TransferHandle) {
        guard let endpoint = endpointProvider() else {
            finishWithEngineError(id: id, error: EngineError.notConnected)
            return
        }
        engineProvider().makeDirectory(endpoint, path: dir) { [weak self] _ in
            guard let self = self else { return }
            self.stateQ.async {
                guard let idx = self.items.firstIndex(where: { $0.id == id }),
                      self.items[idx].phase == .connecting,
                      let endpoint2 = self.endpointProvider() else {
                    self.finishWithEngineError(id: id, error: EngineError.notConnected)
                    return
                }
                self.engineProvider().list(endpoint2, path: dir) { result in
                    self.stateQ.async {
                        guard let idx2 = self.items.firstIndex(where: { $0.id == id }),
                              self.items[idx2].phase == .connecting else { return }
                        if case .success(let entries) = result {
                            self.finalizeUploadRouting(id, dir: dir, dirExisted: false, dirEntries: .success(entries), handle: handle)
                        } else {
                            let batchId = self.items[idx2].batchId
                            if !self.fallbackNotifiedBatches.contains(batchId) {
                                self.fallbackNotifiedBatches.insert(batchId)
                                DispatchQueue.main.async { [weak self] in self?.onUploadFallback?(batchId, dir) }
                            }
                            self.startUploadWithFallback(id, dir: "/", handle: handle)
                        }
                    }
                }
            }
        }
    }

    /// 智能分流第二步：目标目录列表 → 净化命名 / 同名判定（相同文件跳过，不同文件加 MD5 后缀）→ 起传
    private func finalizeUploadRouting(_ id: String, dir: String, dirExisted: Bool,
                                       dirEntries: Result<[FTPFileEntry], Error>, handle: TransferHandle) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        guard items[idx].phase == .connecting else { return }
        guard case .success(let dirList) = dirEntries else {
            let reason = (dirEntries.failureError as? LocalizedError)?.errorDescription ?? "未知"
            if dirExisted {
                // 目录在第一跳确认存在，但列不出内容（空目录 LIST 报错的服务器怪癖）→ 降级直传该目录
                startUploadWithFallback(id, dir: dir, handle: handle)
            } else {
                // 目录不存在且创建失败（MKD 550 等）→ 该目录传不进去，回根目录
                startUploadWithFallback(id, dir: "/", handle: handle)
            }
            return
        }
        let mapped = NameCodec.remoteName(for: items[idx].displayName)
        // 磁盘上已有同名文件 → 「相同文件」判定（尺寸 → 前 10MB 指纹）
        if let clash = dirList.first(where: { !$0.isDirectory && $0.name.caseInsensitiveCompare(mapped.remote) == .orderedSame }) { // FAT 大小写不敏感
            decideSameFileOrSuffix(id, dir: dir, proposedName: mapped.remote, needsMapping: mapped.needsMapping,
                                   clash: clash, dirList: dirList, handle: handle)
            return
        }
        beginUpload(id, dir: dir, remoteName: mapped.remote, needsMapping: mapped.needsMapping,
                    dirList: dirList, handle: handle)
    }

    /// 同名冲突判定：远端是相同文件 → 跳过上传；不同文件（或判定不了）→ 原名后加内容指纹改名；
    /// 指纹名若也被占用，对它再做一次相同判定（同一内容此前已传过 → 跳过，不堆积 (2)(3)）
    private func decideSameFileOrSuffix(_ id: String, dir: String, proposedName: String, needsMapping: Bool,
                                        clash: FTPFileEntry, dirList: [FTPFileEntry],
                                        handle: TransferHandle) {
        func stillConnecting(_ id: String) -> Bool {
            guard let idx = items.firstIndex(where: { $0.id == id }) else { return false }
            return items[idx].phase == .connecting
        }
        guard stillConnecting(id) else { return }
        let localSize = items.first(where: { $0.id == id })!.sizeBytes
        let localURL = items.first(where: { $0.id == id })!.localURL

        // 本地指纹（后台计算，回调在后台队列、由下方 hop 回 stateQ）——前 min(size,10MB) 字节，巨大文件也秒级
        FileDigest.fingerprintAsync(url: localURL, fileSize: localSize) { [weak self] localHex, prefixLen in
            guard let self = self else { return }
            self.stateQ.async {
                guard stillConnecting(id) else { return }
                guard let localHex = localHex, let prefixLen = prefixLen else {
                    self.finishWithEngineError(id: id, error: EngineError.ioError("无法读取本地文件指纹：\(localURL.lastPathComponent)"))
                    return
                }
                let digest8 = String(localHex.prefix(8))
                let candidate = SmartRouting.md5SuffixedName(proposedName, digest8: digest8)

                // 第二层：指纹名已存在 → 对其判定（相同 → 跳过；不同/判不了 → 顺延）
                func uploadOrConverge() {
                    if let second = dirList.first(where: { !$0.isDirectory && $0.name.caseInsensitiveCompare(candidate) == .orderedSame }) {
                        self.verifyRemoteSameFile(id: id, clash: second, localSize: localSize,
                                                  localHex: localHex, prefixLen: prefixLen) { same2 in
                            self.stateQ.async {
                                guard stillConnecting(id) else { return }
                                if same2 == true {
                                    self.skipUploadAsDuplicate(id, dir: dir, remotePath: second.path, needsMapping: needsMapping)
                                } else {
                                    self.beginUpload(id, dir: dir, remoteName: candidate, needsMapping: needsMapping,
                                                     dirList: dirList, handle: handle)
                                }
                            }
                        }
                    } else {
                        self.beginUpload(id, dir: dir, remoteName: candidate, needsMapping: needsMapping,
                                         dirList: dirList, handle: handle)
                    }
                }

                // 第一层：对同名 clash 判定
                self.verifyRemoteSameFile(id: id, clash: clash, localSize: localSize,
                                          localHex: localHex, prefixLen: prefixLen) { same in
                    self.stateQ.async {
                        guard stillConnecting(id) else { return }
                        if same == true {
                            self.skipUploadAsDuplicate(id, dir: dir, remotePath: clash.path, needsMapping: needsMapping)
                        } else {
                            uploadOrConverge()
                        }
                    }
                }
            }
        }
    }

    /// 远端 clash 是否与本地内容相同：尺寸相等 → 拉 clash 前 prefixLen 字节比对（回调 hop 回 stateQ）。
    /// completion: true=相同 / false=不同（尺寸不等或字节不符）/ nil=判定不了（读取失败、远端消失）
    private func verifyRemoteSameFile(id: String, clash: FTPFileEntry, localSize: Int64,
                                      localHex: String, prefixLen: Int64,
                                      completion: @escaping (_ same: Bool?) -> Void) {
        guard let remoteSize = clash.size, remoteSize == localSize else { completion(false); return }
        guard let endpoint = endpointProvider() else { completion(nil); return }
        engineProvider().downloadPrefix(endpoint, remotePath: clash.path, maxBytes: Int(prefixLen)) { [weak self] r in
            guard let self = self else { return }
            self.stateQ.async {
                switch r {
                case .success(let remoteData):
                    completion((Int64(remoteData.count) == prefixLen && FileDigest.md5Hex(remoteData) == localHex) ? true : false)
                case .failure:
                    completion(nil)
                }
            }
        }
    }

    /// 列表不可得时的降级（review D0 修复）：先 engine.size 探同名——
    /// 不存在（或 SIZE 不可用）→ 原名直传；已存在 → 指纹后缀改名。
    /// 降级路径一律禁用 APPE：若旧同名文件更小，SIZE+APPE 会把新内容追加到旧文件尾部产出坏文件
    private func startUploadWithFallback(_ id: String, dir: String, handle: TransferHandle) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        guard items[idx].phase == .connecting else { return }
        guard let endpoint = endpointProvider() else {
            finishWithEngineError(id: id, error: EngineError.notConnected)
            return
        }
        let mapped = NameCodec.remoteName(for: items[idx].displayName)
        let targetPath = dir == "/" ? "/" + mapped.remote : dir + "/" + mapped.remote
        let localSize = items[idx].sizeBytes
        let localURL = items[idx].localURL
        engineProvider().size(endpoint, remotePath: targetPath) { [weak self] sizeResult in
            guard let self = self else { return }
            self.stateQ.async {
                guard let idx = self.items.firstIndex(where: { $0.id == id }),
                      self.items[idx].phase == .connecting else { return }
                // nil = 不存在或 SIZE 不可用（如真机 SIZE=false）→ 原名直传
                guard let remoteSize = (try? sizeResult.get()) ?? nil, remoteSize > 0 else {
                    self.commitFallbackUpload(id: id, dir: dir, finalName: mapped.remote,
                                              needsMapping: mapped.needsMapping, resume: false, handle: handle)
                    return
                }
                // 同名已存在 → 本地指纹后缀改名（背景计算指纹）
                FileDigest.fingerprintAsync(url: localURL, fileSize: localSize) { [weak self] hex, _ in
                    guard let self = self else { return }
                    self.stateQ.async {
                        let digest8 = hex.map { String($0.prefix(8)) }
                            ?? String(format: "%08x", UInt32(truncatingIfNeeded: localSize))
                        self.commitFallbackUpload(id: id, dir: dir,
                                                  finalName: SmartRouting.md5SuffixedName(mapped.remote, digest8: digest8),
                                                  needsMapping: mapped.needsMapping, resume: false, handle: handle)
                    }
                }
            }
        }
    }

    private func commitFallbackUpload(id: String, dir: String, finalName: String,
                                      needsMapping: Bool, resume: Bool, handle: TransferHandle) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        guard items[idx].phase == .connecting else { return }
        if let dup = completedDuplicatePath(localPath: items[idx].localPath, dir: dir, excluding: id) {
            skipUploadAsDuplicate(id, dir: dir, remotePath: dup, needsMapping: needsMapping)
            return
        }
        // 降级路径同样要查 inflight：两项同名都降级时，SIZE 探测都返回 nil（盘上还没有），
        // 不查重就会并发 STOR 同一目标互相毁掉；已完成兄弟项的占名同样要查（hop 期间完成者不可见）
        let unique = NameCodec.capped(NameCodec.uniqued(finalName, existing: occupiedUploadNames(dir: dir, excluding: id),
                                       caseInsensitive: true)).name
        items[idx].remoteDir = dir
        items[idx].remotePath = dir == "/" ? "/" + unique : dir + "/" + unique
        items[idx].needsNameMapping = needsMapping
        startUpload(id, handle: handle, resumeOverride: resume)
    }

    /// 相同文件：不传输，直接标记完成并说明原因
    private func skipUploadAsDuplicate(_ id: String, dir: String, remotePath: String, needsMapping: Bool) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        guard items[idx].phase == .connecting else { return }
        items[idx].remoteDir = dir
        items[idx].remotePath = remotePath
        items[idx].needsNameMapping = needsMapping
        items[idx].skippedReason = "电视上已有相同文件 · 已跳过"
        items[idx] = QueueStateMachine.apply(.complete, to: items[idx])
        persistLocked()
        notifyChange()
        scheduleIfNeeded() // 释放的槽位立刻派给后续排队项（与 applyEngineEvent 的完成路径一致）
    }

    /// 同一目标目录内，其他未终结上传项已占用的远端名（stateQ 上调用）
    private func inflightUploadNames(dir: String, excluding id: String) -> Set<String> {
        Set(items.compactMap { other -> String? in
            guard other.id != id, other.direction == .upload, !other.phase.isTerminal,
                  other.remoteDir == dir, let p = other.remotePath else { return nil }
            return (p as NSString).lastPathComponent
        })
    }

    /// 定名时的已占用名 = inflight 占位 + 已完成兄弟项的实际占名。
    /// 兄弟项在异步 hop（LIST/SIZE/指纹）期间完成时 inflight 看不见它、dirList 快照也旧：
    /// 无 clash 路径用原名 → 会 STOR 覆盖兄弟项刚传好的不同内容文件
    private func occupiedUploadNames(dir: String, excluding id: String) -> Set<String> {
        inflightUploadNames(dir: dir, excluding: id).union(items.compactMap { other -> String? in
            guard other.id != id, other.direction == .upload, other.phase == .completed,
                  other.remoteDir == dir, let p = other.remotePath else { return nil }
            return (p as NSString).lastPathComponent
        })
    }

    /// 同一本地文件被重复拖入：已有【已完成】的同文件同目录项 → 直接收敛为跳过，
    /// 不再传一份副本（未完成项不收敛——它可能失败，顺延改名更安全）
    private func completedDuplicatePath(localPath: String, dir: String, excluding id: String) -> String? {
        items.first { other in
            other.id != id && other.direction == .upload && other.phase == .completed
                && other.localPath == localPath && other.remoteDir == dir && other.skippedReason == nil
                && other.remotePath != nil
        }?.remotePath
    }

    /// 定名（净化名/指纹名 + 重名顺延）→ 起传
    private func beginUpload(_ id: String, dir: String, remoteName: String, needsMapping: Bool,
                             dirList: [FTPFileEntry], handle: TransferHandle) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        guard items[idx].phase == .connecting else { return } // 可能已被暂停/取消
        if let dup = completedDuplicatePath(localPath: items[idx].localPath, dir: dir, excluding: id) {
            skipUploadAsDuplicate(id, dir: dir, remotePath: dup, needsMapping: needsMapping)
            return
        }
        // inflight 必须在此刻现算：clash 判定经过指纹/远端前缀多次异步 hop，
        // finalize 时的快照里看不见 hop 期间其他项的占位 → 会并发 STOR 同一远端名
        let allNames = SmartRouting.existingNames(entries: dirList).union(occupiedUploadNames(dir: dir, excluding: id))
        // 顺延后缀可能把名字推过 NAME_MAX → 定名后再按 GBK 字节截断
        let unique = NameCodec.capped(NameCodec.uniqued(remoteName, existing: allNames, caseInsensitive: true)).name
        items[idx].remoteDir = dir
        items[idx].remotePath = dir == "/" ? "/" + unique : dir + "/" + unique
        items[idx].needsNameMapping = needsMapping
        // 首传强制整传 STOR（resume=false）：resume=true 时同名旧文件更小会被 APPE 拼接出坏文件
        // （首传撞名只可能覆盖，覆盖后是完整好文件；拼接是双输）。续传（重试/暂停恢复/重启恢复，
        // 走 remotePath != nil 分支）才开 APPE——那时远端半截确为本任务文件的前缀。
        startUpload(id, handle: handle, resumeOverride: false)
    }

    private func startUpload(_ id: String, handle: TransferHandle, resumeOverride: Bool? = nil) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        guard items[idx].phase == .connecting else { return } // 可能已被暂停/取消
        guard let target = items[idx].remotePath else {
            // 理论不可达（调用方保证已分流）；兜底置失败，避免项卡死在 connecting
            finishWithEngineError(id: id, error: EngineError.connectionFailed("传输目标未确定，请重试"))
            return
        }
        guard let endpoint = endpointProvider() else {
            finishWithEngineError(id: id, error: EngineError.notConnected)
            return
        }
        items[idx] = QueueStateMachine.apply(.startRunning, to: items[idx])
        persistLocked()
        notifyChange()

        // resumeOverride：降级路径强制 false（STOR 整传，防 APPE 拼接旧文件）
        let resume = resumeOverride ?? (capabilitiesProvider()?.appeResume == true)
        engineProvider().upload(endpoint,
                                from: items[idx].localURL,
                                to: target,
                                resume: resume,
                                handle: handle,
                                onProgress: { [weak self] progress in
                                    guard let self = self else { return }
                                    self.stateQ.async {
                                        self.applyEngineEvent(.progress(bytes: progress.bytes, bps: progress.bytesPerSecond), id: id)
                                    }
                                },
                                completion: { [weak self] result in
                                    guard let self = self else { return }
                                    self.stateQ.async { self.handleTransferResult(id, result) }
                                })
    }

    private func startDownload(_ item: QueueItem, endpoint: FTPEndpoint, handle: TransferHandle) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        guard let remote = items[idx].remotePath else {
            finishWithEngineError(id: item.id, error: EngineError.remoteNotFound(item.displayName))
            return
        }
        items[idx] = QueueStateMachine.apply(.startRunning, to: items[idx])
        notifyChange()
        engineProvider().download(endpoint,
                                  remotePath: remote,
                                  to: items[idx].localURL,
                                  handle: handle,
                                  onProgress: { [weak self] progress in
                                      guard let self = self else { return }
                                      self.stateQ.async {
                                          self.applyEngineEvent(.progress(bytes: progress.bytes, bps: progress.bytesPerSecond), id: item.id)
                                      }
                                  },
                                  completion: { [weak self] result in
                                      guard let self = self else { return }
                                      self.stateQ.async { self.handleTransferResult(item.id, result) }
                                  })
    }

    private func applyEngineEvent(_ event: QueueEvent, id: String, connectionDropped: Bool = false) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        let before = items[idx].phase
        items[idx] = QueueStateMachine.apply(event, to: items[idx])
        if items[idx].phase != before || event.isProgress {
            if connectionDropped { items[idx].connectionDropped = true }
            // 终态必须立即落盘：进度事件可节流，但 complete/fail 若也被节流窗口吞掉，
            // app 被杀后重启会从陈旧的 queue.json 恢复出错误状态
            persistLocked(force: items[idx].phase.isTerminal)
            notifyChange()
            if event.isProgress == false { scheduleIfNeeded() }
        }
    }

    private func handleTransferResult(_ id: String, _ result: Result<Int64, Error>) {
        switch result {
        case .success:
            applyEngineEvent(.complete, id: id)
        case .failure(let error):
            finishWithEngineError(id: id, error: error)
        }
    }

    private func finishWithEngineError(id: String, error: Error) {
        let reason = error.localizedDescription
        // 连接类失败（电视离线/断连/超时）标记 connectionDropped：重连成功后自动重试（review A2）
        var dropped = false
        if case EngineError.connectionFailed = error { dropped = true }
        if case EngineError.aborted = error {
            // 引擎中断来自句柄取消（暂停/取消已先行改状态）；若状态仍在传输中（异常中断）标记失败
            applyEngineEvent(.fail(reason: "传输中断，可重试"), id: id)
        } else {
            applyEngineEvent(.fail(reason: reason), id: id, connectionDropped: dropped)
        }
    }

    // MARK: 持久化与通知（stateQ 上调用）

    private func persistLocked(force: Bool = false) {
        let now = Date()
        if !force, now.timeIntervalSince(lastPersistAt) < persistInterval { return }
        lastPersistAt = now
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        if let data = try? enc.encode(items) {
            try? data.write(to: persistenceURL, options: .atomic)
        }
    }

    private func notifyChange() {
        // 批量完成判定必须每次无条件执行（review S2）：若藏在 notifyPending 合并守卫后面，
        // 终态回调与最终进度背靠背到达时 onBatchCompleted 会丢失/延迟（「删除前先下载」依赖它）
        checkBatchCompletions()
        notifyDirty = true
        guard !notifyPending else { return }
        notifyPending = true
        notifyDirty = false // 本轮已派发；合并窗口内再来变更会重新置 dirty
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // 复位必须在 stateQ（与置位同队列）；主回调期间到达的新变更由 dirty 补发一轮，
            // 否则「复位前最后一刻的变更」会被合并守卫吞掉，UI 停在旧状态
            self.stateQ.async {
                self.notifyPending = false
                if self.notifyDirty { self.notifyChange() }
            }
            self.onChanged?()
        }
    }

    /// 批量完成判定（stateQ 上执行，用最新状态）
    private func checkBatchCompletions() {
        let batchIDs = Set(items.map { $0.batchId })
        for b in batchIDs {
            let members = items.filter { $0.batchId == b }
            if !members.isEmpty, members.allSatisfy({ $0.phase.isTerminal }), !batchNotified.contains(b) {
                batchNotified.insert(b)
                let ok = members.filter { $0.phase == .completed }.count
                let bad = members.count - ok
                DispatchQueue.main.async { [weak self] in self?.onBatchCompleted?(b, ok, bad) }
            }
        }
    }
}

private extension Result {
    var failureError: Error? {
        if case .failure(let e) = self { return e }
        return nil
    }
}

private extension QueueEvent {
    var isProgress: Bool {
        if case .progress = self { return true }
        return false
    }
}
