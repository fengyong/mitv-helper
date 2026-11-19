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

    // MARK: 状态（全部仅 stateQ 内访问）

    private let stateQ = DispatchQueue(label: "mitv.queue.state", qos: .utility)
    private var items: [QueueItem] = []
    private var handles: [String: TransferHandle] = [:]
    private var batchNotified: Set<String> = []
    private var schedulerHalted = false
    private var hold: HoldReason = .none
    private var lastPersistAt = Date.distantPast
    private var notifyPending = false
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
            stateQ.async { [weak self] in
                self?.notifyChange()
                self?.scheduleIfNeeded()
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
    func addUploads(_ urls: [URL]) -> [QueueItem] {
        let fm = FileManager.default
        let batch = UUID().uuidString
        let created: [QueueItem] = urls.compactMap { url in
            let name = url.lastPathComponent
            var size: Int64 = 0
            if let attr = try? fm.attributesOfItem(atPath: url.path),
               let n = attr[.size] as? NSNumber { size = n.int64Value }
            return QueueItem(direction: .upload, kind: MediaKind.of(url: url),
                             localPath: url.path, displayName: name,
                             sizeBytes: size, batchId: batch)
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
        let created: [QueueItem] = entries.compactMap { entry in
            guard !entry.isDirectory else { return nil }
            // 本地重名顺延：同批去重 + 目标目录已存在时顺延
            var unique = NameCodec.uniqued(entry.name, existing: usedNames)
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
                items[i] = QueueStateMachine.apply(.userPause, to: items[i])
            }
            persistLocked(force: true)
            notifyChange()
        }
    }

    func resumeAllByUser() {
        stateQ.sync {
            guard hold == .user else { return }
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
                items[i] = QueueStateMachine.apply(.autoPause, to: items[i])
            }
            persistLocked(force: true)
            notifyChange()
        }
    }

    /// 重连成功：恢复因断线暂停的任务
    func autoResumeAfterReconnect() {
        stateQ.sync {
            guard hold == .disconnected else { return }
            hold = .none
            for i in items.indices where items[i].phase == .paused && items[i].autoPaused {
                items[i] = QueueStateMachine.apply(.resume, to: items[i])
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
            // 智能分流：先看根目录定目标文件夹
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
            finishWithEngineError(id: id, error: rootEntries.failureError ?? EngineError.connectionFailed("无法读取电视文件列表"))
            return
        }
        let dir = SmartRouting.destinationDir(kind: items[idx].kind, rootEntries: root)
        if dir == "/" {
            finalizeUploadRouting(id, dir: dir, dirEntries: rootEntries, handle: handle)
            return
        }
        guard let endpoint = endpointProvider() else {
            finishWithEngineError(id: id, error: EngineError.notConnected)
            return
        }
        // 重名顺延必须依据【目标目录】里的已有文件——只看根目录会让 /Movies 里的同名文件被静默覆盖
        engineProvider().list(endpoint, path: dir) { [weak self] dirResult in
            guard let self = self else { return }
            self.stateQ.async { self.finalizeUploadRouting(id, dir: dir, dirEntries: dirResult, handle: handle) }
        }
    }

    /// 智能分流第二步：目标目录列表 → 净化命名 / 同名判定（相同文件跳过，不同文件加 MD5 后缀）→ 起传
    private func finalizeUploadRouting(_ id: String, dir: String,
                                       dirEntries: Result<[FTPFileEntry], Error>, handle: TransferHandle) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        guard items[idx].phase == .connecting else { return }
        guard case .success(let dirList) = dirEntries else {
            // 目标目录读不到就不盲传——宁可失败也不覆盖
            finishWithEngineError(id: id, error: dirEntries.failureError ?? EngineError.connectionFailed("无法读取目标文件夹"))
            return
        }
        // 并发互斥：其他未终结上传项已占用的远端名也计入（各项回调在 stateQ 串行处理，无竞态）
        let inflight = Set(items.compactMap { other -> String? in
            guard other.id != id, other.direction == .upload, !other.phase.isTerminal,
                  let p = other.remotePath else { return nil }
            return (p as NSString).lastPathComponent
        })
        let mapped = NameCodec.remoteName(for: items[idx].displayName)
        // 磁盘上已有同名文件 → 「相同文件」判定（尺寸 → 前 10MB 指纹）
        if let clash = dirList.first(where: { !$0.isDirectory && $0.name.caseInsensitiveCompare(mapped.remote) == .orderedSame }) { // FAT 大小写不敏感
            decideSameFileOrSuffix(id, dir: dir, proposedName: mapped.remote, needsMapping: mapped.needsMapping,
                                   clash: clash, dirList: dirList, inflight: inflight, handle: handle)
            return
        }
        beginUpload(id, dir: dir, remoteName: mapped.remote, needsMapping: mapped.needsMapping,
                    dirList: dirList, inflight: inflight, handle: handle)
    }

    /// 同名冲突判定：远端是相同文件 → 跳过上传；不同文件（或判定不了）→ 原名后加内容指纹改名；
    /// 指纹名若也被占用，对它再做一次相同判定（同一内容此前已传过 → 跳过，不堆积 (2)(3)）
    private func decideSameFileOrSuffix(_ id: String, dir: String, proposedName: String, needsMapping: Bool,
                                        clash: FTPFileEntry, dirList: [FTPFileEntry], inflight: Set<String>,
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
                                                     dirList: dirList, inflight: inflight, handle: handle)
                                }
                            }
                        }
                    } else {
                        self.beginUpload(id, dir: dir, remoteName: candidate, needsMapping: needsMapping,
                                         dirList: dirList, inflight: inflight, handle: handle)
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

    /// 定名（净化名/指纹名 + 重名顺延）→ 起传
    private func beginUpload(_ id: String, dir: String, remoteName: String, needsMapping: Bool,
                             dirList: [FTPFileEntry], inflight: Set<String>, handle: TransferHandle) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        guard items[idx].phase == .connecting else { return } // 可能已被暂停/取消
        let allNames = SmartRouting.existingNames(entries: dirList).union(inflight)
        let unique = NameCodec.uniqued(remoteName, existing: allNames, caseInsensitive: true)
        items[idx].remoteDir = dir
        items[idx].remotePath = dir == "/" ? "/" + unique : dir + "/" + unique
        items[idx].needsNameMapping = needsMapping
        startUpload(id, handle: handle)
    }

    private func startUpload(_ id: String, handle: TransferHandle) {
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

        let resume = capabilitiesProvider()?.appeResume == true
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

    private func applyEngineEvent(_ event: QueueEvent, id: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        let before = items[idx].phase
        items[idx] = QueueStateMachine.apply(event, to: items[idx])
        if items[idx].phase != before || event.isProgress {
            persistLocked()
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
        if case EngineError.aborted = error {
            // 引擎中断来自句柄取消（暂停/取消已先行改状态）；若状态仍在传输中（异常中断）标记失败
            applyEngineEvent(.fail(reason: "传输中断，可重试"), id: id)
        } else {
            applyEngineEvent(.fail(reason: reason), id: id)
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
        guard !notifyPending else { return }
        notifyPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.notifyPending = false
            // 批量完成检查也借主队列回调触发
            self.onChanged?()
        }
        // 批量完成判定在状态队列上做（用最新状态）
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
