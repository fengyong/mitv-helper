// ServiceTests_B —— Agent B 服务层测试（队列状态机 / 智能分流 / 软删除决策表 / TVStore 持久化 / QueueService 集成）。
// 注意：Makefile 的 test 目标只编译 MiTVCore + Tests 目录；纯逻辑文件经符号链接进入测试目标
//（见 docs/DELETE_PENDING_B.md，[CONTRACT-REQUEST] 已提出把 $(APP) 纳入 test 目标）。
import Foundation

enum ServiceTests_B {

    static func run() {
        testQueueStateMachine()
        testQueueItemCodableRoundTrip()
        testSmartRouting()
        testSoftDeletePolicy()
        testTVStoreRoundTrip()
        testQueueServiceIntegration()
    }

    // MARK: - 队列状态机

    static func testQueueStateMachine() {
        print("· 队列状态机")
        func item(_ phase: QueuePhase = .queued) -> QueueItem {
            var it = QueueItem(direction: .upload, kind: .video, localPath: "/tmp/a.mp4",
                               displayName: "a.mp4", sizeBytes: 100)
            it.phase = phase
            return it
        }

        // 合法主线：queued → connecting → running → complete
        var it = item()
        it = QueueStateMachine.apply(.startConnecting, to: it)
        assertEqual(it.phase, .connecting, "queued→connecting")
        it = QueueStateMachine.apply(.startRunning, to: it)
        assertEqual(it.phase, .running, "connecting→running")
        it = QueueStateMachine.apply(.progress(bytes: 40, bps: 10), to: it)
        assertEqual(it.bytes, 40, "进度写入")
        assertEqual(it.bytesPerSecond, 10, "速度写入")
        it = QueueStateMachine.apply(.progress(bytes: 30, bps: 10), to: it)
        assertEqual(it.bytes, 40, "进度不回退")
        it = QueueStateMachine.apply(.complete, to: it)
        assertEqual(it.phase, .completed, "running→completed")
        assertTrue(it.finishedAt != nil, "完成时间已记录")
        assertEqual(it.bytes, it.sizeBytes, "完成时 bytes=总大小")

        // 非法迁移：terminal 状态后一切事件无效
        let done = item(.completed)
        assertEqual(QueueStateMachine.apply(.retry, to: done).phase, .completed, "completed 不响应 retry")
        assertEqual(QueueStateMachine.apply(.userCancel, to: done).phase, .completed, "completed 不响应 cancel")
        assertEqual(QueueStateMachine.apply(.progress(bytes: 1, bps: 1), to: done).bytes, 0, "completed 不响应 progress")

        // failed → retry → queued；canceled → retry → queued
        let failed = item(.failed)
        let retried = QueueStateMachine.apply(.retry, to: failed)
        assertEqual(retried.phase, .queued, "failed→retry→queued")
        assertTrue(retried.failureReason == nil, "retry 清空失败原因")
        let canceled = item(.canceled)
        assertEqual(QueueStateMachine.apply(.retry, to: canceled).phase, .queued, "canceled→retry→queued")

        // 暂停语义：用户暂停 vs 断线自动暂停
        let running = item(.running)
        var userPaused = QueueStateMachine.apply(.userPause, to: running)
        assertEqual(userPaused.phase, .paused, "running→paused(用户)")
        assertFalse(userPaused.autoPaused, "用户暂停不标记 autoPaused")
        userPaused = QueueStateMachine.apply(.resume, to: userPaused)
        assertEqual(userPaused.phase, .queued, "paused→resume→queued")
        let autoP = QueueStateMachine.apply(.autoPause, to: item(.queued))
        assertTrue(autoP.autoPaused, "断线暂停标记 autoPaused")

        // 取消：非 terminal 任何阶段均可取消
        for p in [QueuePhase.queued, .connecting, .running, .paused] {
            assertEqual(QueueStateMachine.apply(.userCancel, to: item(p)).phase, .canceled, "\(p) 可取消")
        }

        // fail 仅在传输中生效
        assertEqual(QueueStateMachine.apply(.fail(reason: "x"), to: item(.queued)).phase, .queued, "queued 不响应 fail")
        assertEqual(QueueStateMachine.apply(.fail(reason: "x"), to: item(.running)).phase, .failed, "running 响应 fail")
        assertEqual(QueueStateMachine.apply(.fail(reason: "磁盘满"), to: item(.running)).failureReason, "磁盘满", "失败原因保留")
    }

    // MARK: - 队列项持久化 round-trip

    static func testQueueItemCodableRoundTrip() {
        print("· 队列项 Codable round-trip")
        var it = QueueItem(direction: .download, kind: .image, localPath: "/tmp/海边.jpg",
                           displayName: "海边.jpg", sizeBytes: 3400000)
        it.remotePath = "/Pictures/海边.jpg"
        it.remoteDir = "/Pictures"
        it.phase = .running
        it.bytes = 12345
        it.bytesPerSecond = 88000
        it.needsNameMapping = true
        it.autoPaused = true
        it.addedAt = Date(timeIntervalSince1970: 1_700_000_000)
        it.finishedAt = Date(timeIntervalSince1970: 1_700_000_060)

        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let data = try! enc.encode([it])
        let back = (try! dec.decode([QueueItem].self, from: data)).first!
        assertEqual(back, it, "QueueItem JSON round-trip 完整还原（含中文与全字段）")

        // canceled/failed 同样完整往返
        var it2 = it
        it2.phase = .failed
        it2.failureReason = "电视拒绝写入"
        let back2 = (try! dec.decode([QueueItem].self, from: try! enc.encode([it2]))).first!
        assertEqual(back2.failureReason, "电视拒绝写入", "失败原因往返")
    }

    // MARK: - 智能分流

    static func testSmartRouting() {
        print("· 智能分流")
        func entry(_ path: String, _ name: String, dir: Bool) -> FTPFileEntry {
            FTPFileEntry(path: path, name: name, isDirectory: dir)
        }
        let rootWithBoth = [entry("/", "Movies", dir: true), entry("/", "Pictures", dir: true)]
        let rootNone: [FTPFileEntry] = [entry("/", "DCIM", dir: true)]
        let rootOnlyPictures = [entry("/", "Pictures", dir: true)]

        // 实测矩阵主分支
        assertEqual(SmartRouting.destinationDir(kind: .video, rootEntries: rootWithBoth), "/Movies", "视频→Movies")
        assertEqual(SmartRouting.destinationDir(kind: .image, rootEntries: rootWithBoth), "/Pictures", "图片→Pictures")
        assertEqual(SmartRouting.destinationDir(kind: .other, rootEntries: rootWithBoth), "/", "其他→根")
        // 目录缺失回退：不混放，直接根目录
        assertEqual(SmartRouting.destinationDir(kind: .video, rootEntries: rootNone), "/", "Movies 缺失视频→根")
        assertEqual(SmartRouting.destinationDir(kind: .image, rootEntries: rootNone), "/", "Pictures 缺失图片→根")
        assertEqual(SmartRouting.destinationDir(kind: .video, rootEntries: rootOnlyPictures), "/", "只有 Pictures 时视频→根")
        // 大小写不敏感
        let lower = [entry("/", "movies", dir: true)]
        assertEqual(SmartRouting.destinationDir(kind: .video, rootEntries: lower), "/Movies", "movies 小写也命中")

        // GBK 兼容映射 + 重名顺延
        let existing: Set<String> = ["周岁.mp4", "a.mp4"]
        let r1 = SmartRouting.remoteTarget(displayName: "周岁.mp4", dir: "/Movies", existingNames: existing)
        assertEqual(r1.path, "/Movies/周岁 (2).mp4", "重名顺延")
        assertFalse(r1.needsMapping, "中文 GBK 可表示，无需映射")

        let r2 = SmartRouting.remoteTarget(displayName: "生日🎉.mp4", dir: "/Movies", existingNames: [])
        assertFalse(r2.name.contains("🎉"), "emoji 被替换")
        assertTrue(r2.needsMapping, "标记需要映射")
        assertEqual(r2.path, "/Movies/" + r2.name, "路径由目录+名拼接")

        let r3 = SmartRouting.remoteTarget(displayName: "b.mp4", dir: "/", existingNames: [])
        assertEqual(r3.path, "/b.mp4", "根目录路径无重复斜杠")
    }

    // MARK: - 软删除决策表（§7 三分支）

    static func testSoftDeletePolicy() {
        print("· 软删除决策表")
        // 分支 1：rename=true → 软删除
        var caps = Capabilities(deleteFile: false, rename: true)
        assertEqual(SoftDeletePolicy.strategy(capabilities: caps, trashDirExists: false),
                    .soft(.prefix), "rename 有、无 mkdir、回收站不存在 → 前缀兜底")
        assertEqual(SoftDeletePolicy.strategy(capabilities: caps, trashDirExists: true),
                    .soft(.directory), "rename 有、回收站已存在 → 目录形态")
        caps.mkdir = true
        assertEqual(SoftDeletePolicy.strategy(capabilities: caps, trashDirExists: false),
                    .soft(.directory), "rename+mkdir 可用 → 目录形态（先建目录）")

        // 分支 2：rename=false, deleteFile=true → 直删
        caps = Capabilities(deleteFile: true, rename: false)
        assertEqual(SoftDeletePolicy.strategy(capabilities: caps, trashDirExists: false),
                    .hard, "仅 DELE 可用 → 直删")

        // 分支 3：都不可用 → 禁用
        caps = Capabilities(deleteFile: false, rename: false)
        assertEqual(SoftDeletePolicy.strategy(capabilities: caps, trashDirExists: false),
                    .disabled, "都不支持 → 禁用")

        // 回收站路径构造
        assertEqual(SoftDeletePolicy.directoryTrashPath(forRemotePath: "/Movies/a.mp4"),
                    "/.MITV-Trash/Movies/a.mp4", "目录形态路径")
        assertEqual(SoftDeletePolicy.directoryTrashPath(forRemotePath: "/a.mp4"),
                    "/.MITV-Trash/a.mp4", "根文件目录形态路径")
        assertEqual(SoftDeletePolicy.directoryTrashPath(forRemotePath: "/A/B/c.mp4"),
                    "/.MITV-Trash/A--B/c.mp4", "多级父目录扁平化")
        assertEqual(SoftDeletePolicy.prefixTrashName(forRemotePath: "/Movies/a.mp4"),
                    ".MITV-Trash--Movies--a.mp4", "前缀兜底名（与契约示例一致）")
        assertEqual(SoftDeletePolicy.prefixTrashName(forRemotePath: "/a.mp4"),
                    ".MITV-Trash--a.mp4", "根文件前缀兜底名")
        assertEqual(SoftDeletePolicy.flattenParent(ofPath: "/Movies/a.mp4"), "Movies", "flattenParent 单级")
        assertEqual(SoftDeletePolicy.flattenParent(ofPath: "/a.mp4"), "", "flattenParent 根文件")
        assertEqual(SoftDeletePolicy.parentFromPrefixTrashName(".MITV-Trash--Movies--a.mp4"), "Movies", "前缀名还原父目录")
        assertTrue(SoftDeletePolicy.isInTrashDir("/.MITV-Trash/Movies/a.mp4"), "回收站内判定")
        assertTrue(SoftDeletePolicy.isPrefixTrashFile(name: ".MITV-Trash--Movies--a.mp4"), "前缀回收文件判定")
        assertFalse(SoftDeletePolicy.isPrefixTrashFile(name: "正常.mp4"), "普通文件不误判")
    }

    // MARK: - TVStore 持久化 round-trip

    static func testTVStoreRoundTrip() {
        print("· TVStore 持久化 round-trip")
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mitv-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = TVStore(directory: dir)
        assertTrue(store.endpoint == nil, "初始无 endpoint")
        store.update {
            $0.endpoint = FTPEndpoint(host: "192.168.31.171", port: 2121, user: nil, password: nil)
            $0.capabilities = Capabilities(utf8Filenames: false, appeResume: true, restResume: false,
                                           mkdir: false, deleteFile: true, rename: true, mlsd: false, sizeCommand: true)
            $0.tvName = "客厅电视"
            $0.lastRemotePath = "/Movies"
            $0.onboardingDone = true
        }
        assertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("tv.json").path), "tv.json 已落盘")

        // 新实例（模拟重启）读回
        let store2 = TVStore(directory: dir)
        assertEqual(store2.endpoint, FTPEndpoint(host: "192.168.31.171", port: 2121), "endpoint round-trip")
        assertEqual(store2.capabilities, store.capabilities, "capabilities round-trip")
        assertEqual(store2.state.tvName, "客厅电视", "昵称 round-trip")
        assertEqual(store2.state.lastRemotePath, "/Movies", "上次目录 round-trip")
        assertTrue(store2.state.onboardingDone, "向导完成标记 round-trip")
    }

    // MARK: - QueueService 集成（真实服务 + 桩引擎，确定性回调）

    final class InlineEngine: TransferEngine {
        struct UploadCall { var remotePath: String; var resume: Bool }
        private(set) var uploadCalls: [UploadCall] = []
        /// true 时 upload 完成回调被扣住，供测试精确控制时序；false 时延迟自动成功/失败
        var hangUploads = false
        /// true 时 upload 以失败收场
        var failUploads = false
        var pendingUploadCompletions: [(Result<Int64, Error>) -> Void] = []
        private let lock = NSLock()

        func releaseAllUploads(_ result: Result<Int64, Error>) {
            lock.lock(); let cbs = pendingUploadCompletions; pendingUploadCompletions = []; lock.unlock()
            for cb in cbs { cb(result) }
        }

        private func record(_ remotePath: String, _ resume: Bool, _ completion: @escaping (Result<Int64, Error>) -> Void) {
            lock.lock()
            uploadCalls.append(UploadCall(remotePath: remotePath, resume: resume))
            let hang = hangUploads
            let fail = failUploads
            if hang { pendingUploadCompletions.append(completion) }
            lock.unlock()
            if !hang {
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) {
                    completion(fail ? .failure(EngineError.connectionFailed("模拟断线")) : .success(1))
                }
            }
        }

        func ping(_ endpoint: FTPEndpoint, completion: @escaping (Error?) -> Void) { DispatchQueue.global().async { completion(nil) } }
        func list(_ endpoint: FTPEndpoint, path: String, completion: @escaping (Result<[FTPFileEntry], Error>) -> Void) {
            DispatchQueue.global().async {
                completion(.success([FTPFileEntry(path: "/Movies", name: "Movies", isDirectory: true)]))
            }
        }
        func upload(_ endpoint: FTPEndpoint, from localURL: URL, to remotePath: String, resume: Bool,
                    handle: TransferHandle?, onProgress: ((TransferProgress) -> Void)?,
                    completion: @escaping (Result<Int64, Error>) -> Void) {
            record(remotePath, resume, completion)
        }
        func download(_ endpoint: FTPEndpoint, remotePath: String, to localURL: URL, handle: TransferHandle?,
                      onProgress: ((TransferProgress) -> Void)?, completion: @escaping (Result<Int64, Error>) -> Void) {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) { completion(.success(1)) }
        }
        func delete(_ endpoint: FTPEndpoint, remotePath: String, completion: @escaping (Error?) -> Void) { DispatchQueue.global().async { completion(nil) } }
        func move(_ endpoint: FTPEndpoint, from: String, to: String, completion: @escaping (Error?) -> Void) { DispatchQueue.global().async { completion(nil) } }
        func makeDirectory(_ endpoint: FTPEndpoint, path: String, completion: @escaping (Error?) -> Void) { DispatchQueue.global().async { completion(EngineError.unsupported("MKD")) } }
        func size(_ endpoint: FTPEndpoint, remotePath: String, completion: @escaping (Result<Int64?, Error>) -> Void) { DispatchQueue.global().async { completion(.success(nil)) } }
        func probeCapabilities(_ endpoint: FTPEndpoint, completion: @escaping (Result<Capabilities, Error>) -> Void) {
            DispatchQueue.global().async { completion(.success(Capabilities())) }
        }
    }

    static func waitUntil(_ msg: String, timeout: TimeInterval = 5, _ cond: @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        assertTrue(cond(), msg)
    }

    static func testQueueServiceIntegration() {
        print("· QueueService 集成")
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mitv-queue-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let f1 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mitv-引擎自测-\(UUID().uuidString).mp4")
        try? Data(repeating: 0, count: 10).write(to: f1)
        defer { try? FileManager.default.removeItem(at: f1) }

        let engine = InlineEngine()
        let caps = Capabilities(utf8Filenames: false, appeResume: true, restResume: false,
                                mkdir: false, deleteFile: true, rename: true, mlsd: false, sizeCommand: true)
        let queue = QueueService(
            engineProvider: { engine },
            endpointProvider: { FTPEndpoint(host: "mock") },
            capabilitiesProvider: { caps },
            persistenceDirectory: dir,
            concurrency: 2,
            resumeOnStart: true)

        // 1. 入队 → 自动开始 → 完成；智能分流命中 Movies；持久化落盘
        let batch = queue.addUploads([f1])
        assertEqual(batch.count, 1, "入队返回 1 项")
        waitUntil("自动开始并完成") { queue.snapshot().first?.phase == .completed }
        let snap = queue.snapshot()
        assertEqual(snap.count, 1, "队列 1 项")
        assertEqual(snap[0].phase, .completed, "上传完成")
        assertEqual(snap[0].remoteDir, "/Movies", "智能分流命中 Movies")
        assertTrue(snap[0].remotePath?.hasPrefix("/Movies/") == true, "远端路径落在 Movies/")
        assertEqual(engine.uploadCalls.count, 1, "引擎被调用一次")
        assertTrue(engine.uploadCalls[0].resume, "能力矩阵 appeResume=true → resume 标志开启（引擎 SIZE 校验决定是否续传）")
        assertTrue((try? Data(contentsOf: dir.appendingPathComponent("queue.json"))) != nil, "queue.json 已写")

        // 2. 悬挂上传 → 暂停 → resume（APPE 续传标志）→ 完成
        engine.hangUploads = true
        _ = queue.addUploads([f1])
        waitUntil("第二项进入 running") { queue.snapshot().filter { $0.phase == .running }.count == 1 }
        guard let runningID = queue.snapshot().first(where: { $0.phase == .running })?.id else {
            assertTrue(false, "未找到 running 项"); return
        }
        queue.pause(id: runningID)
        waitUntil("暂停生效") { queue.snapshot().first { $0.id == runningID }?.phase == .paused }
        queue.resume(id: runningID)
        waitUntil("恢复后再次调用引擎") { engine.uploadCalls.count == 2 }
        assertTrue(engine.uploadCalls[1].resume, "resume 上传带 APPE 续传标志")
        engine.releaseAllUploads(.success(1))
        waitUntil("悬挂恢复后完成") { queue.snapshot().filter { $0.phase == .completed }.count == 2 }

        // 3. 失败 → 重试 → 完成
        engine.hangUploads = false
        engine.failUploads = true
        _ = queue.addUploads([f1])
        waitUntil("失败可见") { queue.snapshot().filter { $0.phase == .failed }.count == 1 }
        guard let failedID = queue.snapshot().first(where: { $0.phase == .failed })?.id else {
            assertTrue(false, "未找到 failed 项"); return
        }
        assertTrue(queue.snapshot().first(where: { $0.id == failedID })?.failureReason != nil, "失败原因已记录")
        engine.failUploads = false
        queue.retry(id: failedID)
        waitUntil("重试后完成") { queue.snapshot().first { $0.id == failedID }?.phase == .completed }

        // 4. 清空已完成
        queue.clearFinished()
        assertEqual(queue.snapshot().filter { $0.phase.isTerminal }.count, 0, "清空后无 terminal 项")

        // 5. 持久化恢复：running 状态写入 JSON，重启后（不自动续跑）回到 queued
        engine.hangUploads = true
        _ = queue.addUploads([f1])
        waitUntil("第四项进入 running") { queue.snapshot().filter { $0.phase == .running }.count == 1 }
        let countBefore = queue.snapshot().count
        queue.suspendForShutdown() // 模拟退出：停调度 + 原子写
        let restored = QueueService(engineProvider: { engine }, endpointProvider: { FTPEndpoint(host: "mock") },
                                    capabilitiesProvider: { caps }, persistenceDirectory: dir,
                                    concurrency: 2, resumeOnStart: false)
        assertEqual(restored.snapshot().count, countBefore, "重启恢复队列项数")
        let restoredItem = restored.snapshot().first { $0.phase == .queued }
        assertTrue(restoredItem != nil, "running 项恢复为 queued（等待续传）")
        assertEqual(restoredItem?.displayName, f1.lastPathComponent, "恢复项信息完整")
    }
}
