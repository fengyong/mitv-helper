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
        testUploadCollision()
        testBrowseFilter()
        testEmptyDiskFallback()
        testAutoMakeDir()
        testThumbCacheStore()
        testDirectDelete()
        testPauseAllCancelsHandles()
        testBatchNameCollisions()
        testThumbFetchSafety()
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
        // 2026-11-19 定案：目标恒定（目录不存在由 QueueService 尽力 MKD；被拒回根）
        assertEqual(SmartRouting.destinationDir(kind: .video), "/Movies", "视频恒定→Movies")
        assertEqual(SmartRouting.destinationDir(kind: .image), "/Pictures", "图片恒定→Pictures")
        assertEqual(SmartRouting.destinationDir(kind: .other), "/", "其他→根")

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

        // 同名不同内容 → 原名 + md5 前 8 位
        assertEqual(SmartRouting.md5SuffixedName("a.mp4", digest8: "1b2c3d4e"), "a-1b2c3d4e.mp4", "md5 后缀名")
        assertEqual(SmartRouting.md5SuffixedName("无扩展名", digest8: "1b2c3d4e"), "无扩展名-1b2c3d4e", "无扩展名 md5 后缀")
    }

    // MARK: - 删除决策表（直删，不再软删除）

    static func testSoftDeletePolicy() {
        print("· 删除决策表（直删）")
        var caps = Capabilities(deleteFile: true, rename: false)
        assertEqual(SoftDeletePolicy.strategy(capabilities: caps), .hard, "DELE 可用 → 直删")
        caps = Capabilities(deleteFile: true, rename: true)
        assertEqual(SoftDeletePolicy.strategy(capabilities: caps), .hard, "rename 可用也直删（不再进回收站）")
        caps = Capabilities(deleteFile: false, rename: true)
        assertEqual(SoftDeletePolicy.strategy(capabilities: caps), .disabled, "DELE 不可用 → 禁用")
        caps = Capabilities(deleteFile: false, rename: false)
        assertEqual(SoftDeletePolicy.strategy(capabilities: caps), .disabled, "都不支持 → 禁用")

        // 历史回收站残留判定（旧版本软删除的文件仍可能留在电视上，浏览过滤要用）
        assertTrue(SoftDeletePolicy.isInTrashDir("/.MITV-Trash/Movies/a.mp4"), "回收站内判定")
        assertTrue(SoftDeletePolicy.isInTrashDir("/.MITV-Trash"), "回收站根目录判定")
        assertFalse(SoftDeletePolicy.isInTrashDir("/Movies/.MITV-Trash-x"), "相似路径不误判")
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

        // 并发冒烟：后台写 + 并发读不崩溃、终值有效（state 快照与 update 同锁守卫）
        let group = DispatchGroup()
        let pool = DispatchQueue(label: "mitv.test.tvstore", attributes: .concurrent)
        for i in 0..<50 {
            group.enter()
            pool.async {
                store.update { $0.tvName = "并发\(i)" }
                group.leave()
            }
        }
        group.enter()
        pool.async {
            for _ in 0..<200 { _ = store.endpoint; _ = store.state.tvName }
            group.leave()
        }
        assertTrue(group.wait(timeout: .now() + 10) == .success, "TVStore 并发读写完成")
        assertTrue(store.state.tvName?.hasPrefix("并发") == true, "并发写后终值有效")
    }

    // MARK: - QueueService 集成（真实服务 + 桩引擎，确定性回调）

    final class InlineEngine: TransferEngine {
        struct UploadCall { var remotePath: String; var resume: Bool }
        struct MoveCall { var from: String; var to: String }
        private(set) var uploadCalls: [UploadCall] = []
        private(set) var moveCalls: [MoveCall] = []
        private(set) var deleteCalls: [String] = []
        /// 指定路径的 delete 以失败收场（清空回收站部分失败测试用）
        var failDeletePaths: Set<String> = []
        private(set) var uploadHandles: [TransferHandle?] = []
        private(set) var downloadHandles: [TransferHandle?] = []
        /// true 时 upload 完成回调被扣住，供测试精确控制时序；false 时延迟自动成功/失败
        var hangUploads = false
        /// true 时 upload 以失败收场
        var failUploads = false
        var pendingUploadCompletions: [(Result<Int64, Error>) -> Void] = []
        /// list 返回的目录内容（重名判定测试用）
        var dirEntries: [FTPFileEntry] = [FTPFileEntry(path: "/Movies", name: "Movies", isDirectory: true)]
        /// 按路径覆盖 list 结果（回收站去重/还原守卫测试用）
        var dirEntriesByPath: [String: [FTPFileEntry]] = [:]
        /// true 时所有 list 以失败收场（空盘/列表降级测试）
        var failAllLists = false
        /// true 时 download 完成回调被扣住（跨批次下载互斥测试用）
        var hangDownloads = false
        var pendingDownloadCompletions: [(Result<Int64, Error>) -> Void] = []
        /// 指定路径的 list 以失败收场（目录存在但列不出内容的怪癖模拟）
        var failListPath: String?
        /// MKD 是否成功（真机 SwiFTP 550 → false）
        var allowMKD = false
        /// size() 按路径返回预设值（降级同名探测测试用）；未命中 → success(nil)
        var remoteSizes: [String: Int64] = [:]
        /// downloadPrefix 返回的「远端前缀」内容（nil → 失败）
        var remotePrefix: Data?
        private var prefixCallCount = 0
        private let lock = NSLock()

        var prefixCalls: Int { lock.lock(); defer { lock.unlock() }; return prefixCallCount }

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
                if self.failAllLists {
                    completion(.failure(EngineError.connectionFailed("模拟列表失败")))
                    return
                }
                if let p = self.failListPath, p == path {
                    completion(.failure(EngineError.connectionFailed("模拟目录列表失败")))
                    return
                }
                completion(.success(self.dirEntriesByPath[path] ?? self.dirEntries))
            }
        }
        func downloadPrefix(_ endpoint: FTPEndpoint, remotePath: String, maxBytes: Int,
                            completion: @escaping (Result<Data, Error>) -> Void) {
            lock.lock()
            prefixCallCount += 1
            let data = remotePrefix
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) {
                if let d = data { completion(.success(d)) }
                else { completion(.failure(EngineError.ioError("无预置前缀"))) }
            }
        }
        func upload(_ endpoint: FTPEndpoint, from localURL: URL, to remotePath: String, resume: Bool,
                    handle: TransferHandle?, onProgress: ((TransferProgress) -> Void)?,
                    completion: @escaping (Result<Int64, Error>) -> Void) {
            lock.lock(); uploadHandles.append(handle); lock.unlock()
            record(remotePath, resume, completion)
        }
        func download(_ endpoint: FTPEndpoint, remotePath: String, to localURL: URL, handle: TransferHandle?,
                      onProgress: ((TransferProgress) -> Void)?, completion: @escaping (Result<Int64, Error>) -> Void) {
            lock.lock()
            downloadHandles.append(handle)
            let hang = hangDownloads
            if hang { pendingDownloadCompletions.append(completion) }
            lock.unlock()
            if !hang {
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) { completion(.success(1)) }
            }
        }
        func releaseAllDownloads(_ result: Result<Int64, Error>) {
            lock.lock(); let cbs = pendingDownloadCompletions; pendingDownloadCompletions = []; lock.unlock()
            for cb in cbs { cb(result) }
        }
        func delete(_ endpoint: FTPEndpoint, remotePath: String, completion: @escaping (Error?) -> Void) {
            lock.lock()
            deleteCalls.append(remotePath)
            let fail = failDeletePaths.contains(remotePath)
            lock.unlock()
            DispatchQueue.global().async { completion(fail ? EngineError.permissionDenied("模拟删除失败") : nil) }
        }
        func move(_ endpoint: FTPEndpoint, from: String, to: String, completion: @escaping (Error?) -> Void) {
            lock.lock(); moveCalls.append(MoveCall(from: from, to: to)); lock.unlock()
            DispatchQueue.global().async { completion(nil) }
        }
        func makeDirectory(_ endpoint: FTPEndpoint, path: String, completion: @escaping (Error?) -> Void) {
            DispatchQueue.global().async { completion(self.allowMKD ? nil : EngineError.unsupported("MKD")) }
        }
        func size(_ endpoint: FTPEndpoint, remotePath: String, completion: @escaping (Result<Int64?, Error>) -> Void) {
            DispatchQueue.global().async { completion(.success(self.remoteSizes[remotePath])) }
        }
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
        // 各步骤用不同文件：同一文件重复入队会被「已完成同文件」查重跳过（W1-3 新契约）
        let f2 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mitv-引擎自测-\(UUID().uuidString).mp4")
        try? Data(repeating: 1, count: 10).write(to: f2)
        defer { try? FileManager.default.removeItem(at: f2) }
        let f3 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mitv-引擎自测-\(UUID().uuidString).mp4")
        try? Data(repeating: 2, count: 10).write(to: f3)
        defer { try? FileManager.default.removeItem(at: f3) }
        let f4 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mitv-引擎自测-\(UUID().uuidString).mp4")
        try? Data(repeating: 3, count: 10).write(to: f4)
        defer { try? FileManager.default.removeItem(at: f4) }

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
        assertFalse(engine.uploadCalls[0].resume, "首传强制整传（resume=false）：防同名旧文件被 APPE 拼接出坏文件")
        assertTrue((try? Data(contentsOf: dir.appendingPathComponent("queue.json"))) != nil, "queue.json 已写")

        // 1b. 同一文件再次入队（同目标目录）→ 命中「已完成同文件」查重：直接完成+跳过说明，不再调引擎
        _ = queue.addUploads([f1])
        waitUntil("重复文件被跳过") { queue.snapshot().filter { $0.phase == .completed }.count == 2 }
        let dupItem = queue.snapshot().first { $0.skippedReason != nil }
        assertTrue(dupItem?.skippedReason != nil, "重复项带跳过说明")
        assertEqual(engine.uploadCalls.count, 1, "重复项不再调用引擎")

        // 2. 悬挂上传 → 暂停 → resume（APPE 续传标志）→ 完成
        engine.hangUploads = true
        _ = queue.addUploads([f2])
        waitUntil("第二项进入 running") { queue.snapshot().filter { $0.phase == .running }.count == 1 }
        guard let runningID = queue.snapshot().first(where: { $0.phase == .running })?.id else {
            assertTrue(false, "未找到 running 项"); return
        }
        queue.pause(id: runningID)
        waitUntil("暂停生效") { queue.snapshot().first { $0.id == runningID }?.phase == .paused }
        queue.resume(id: runningID)
        // 恢复 = 续传：beginTransfer 走 remotePath != nil 分支，再次调用引擎且开 APPE
        waitUntil("恢复后再次调用引擎（续传第二次 upload）") { engine.uploadCalls.count == 3 }
        assertTrue(engine.uploadCalls[2].resume, "暂停恢复=同任务续传 → APPE 标志")
        engine.releaseAllUploads(.success(1))
        waitUntil("悬挂恢复后完成") { queue.snapshot().filter { $0.phase == .completed }.count == 3 }

        // 3. 失败 → 重试 → 完成
        engine.hangUploads = false
        engine.failUploads = true
        _ = queue.addUploads([f3])
        waitUntil("失败可见") { queue.snapshot().filter { $0.phase == .failed }.count == 1 }
        guard let failedID = queue.snapshot().first(where: { $0.phase == .failed })?.id else {
            assertTrue(false, "未找到 failed 项"); return
        }
        assertTrue(queue.snapshot().first(where: { $0.id == failedID })?.failureReason != nil, "失败原因已记录")
        engine.failUploads = false
        let callsBeforeRetry = engine.uploadCalls.count
        queue.retry(id: failedID)
        waitUntil("重试后完成") { queue.snapshot().first { $0.id == failedID }?.phase == .completed }
        assertEqual(engine.uploadCalls.count, callsBeforeRetry + 1, "重试再次调用引擎")
        assertTrue(engine.uploadCalls[callsBeforeRetry].resume, "重试=同任务续传 → APPE（远端半截确为本任务文件前缀）")

        // 4. 清空已完成
        queue.clearFinished()
        assertEqual(queue.snapshot().filter { $0.phase.isTerminal }.count, 0, "清空后无 terminal 项")

        // 5. 持久化恢复：running 状态写入 JSON，重启后（不自动续跑）回到 queued
        engine.hangUploads = true
        _ = queue.addUploads([f4])
        waitUntil("第四项进入 running") { queue.snapshot().filter { $0.phase == .running }.count == 1 }
        let countBefore = queue.snapshot().count
        queue.suspendForShutdown() // 模拟退出：停调度 + 原子写
        let restored = QueueService(engineProvider: { engine }, endpointProvider: { FTPEndpoint(host: "mock") },
                                    capabilitiesProvider: { caps }, persistenceDirectory: dir,
                                    concurrency: 2, resumeOnStart: false)
        assertEqual(restored.snapshot().count, countBefore, "重启恢复队列项数")
        let restoredItem = restored.snapshot().first { $0.phase == .queued }
        assertTrue(restoredItem != nil, "running 项恢复为 queued（等待续传）")
        assertEqual(restoredItem?.displayName, f4.lastPathComponent, "恢复项信息完整")
    }
}

// MARK: - 浏览隐藏文件过滤（对普通用户隐藏系统自建项）

extension ServiceTests_B {

    static func testBrowseFilter() {
        print("· 浏览隐藏文件过滤")
        assertTrue(BrowseFilter.isVisible("Movies"), "普通目录可见")
        assertTrue(BrowseFilter.isVisible("周岁生日.mp4"), "中文名可见")
        assertTrue(BrowseFilter.isVisible("Found Treasures"), "found 开头普通目录不误伤")
        assertTrue(BrowseFilter.isVisible("使用说明.txt"), "普通文件可见")
        assertFalse(BrowseFilter.isVisible(".fseventsd"), "POSIX 隐藏目录")
        assertFalse(BrowseFilter.isVisible(".Spotlight-V100"), "macOS 索引目录")
        assertFalse(BrowseFilter.isVisible("._星际迷航.mp4"), "AppleDouble 资源文件")
        assertFalse(BrowseFilter.isVisible(".MITV-Trash"), "回收站本体隐藏（入口按本地记账呈现）")
        assertFalse(BrowseFilter.isVisible("System Volume Information"), "Windows 卷信息")
        assertFalse(BrowseFilter.isVisible("$RECYCLE.BIN"), "Windows 回收站（大写）")
        assertFalse(BrowseFilter.isVisible("$recycle.bin"), "Windows 回收站（小写）")
        assertFalse(BrowseFilter.isVisible("lost.dir"), "Android 丢失目录")
        assertFalse(BrowseFilter.isVisible("FOUND.000"), "Windows 检查点")
        assertFalse(BrowseFilter.isVisible("found.007"), "检查点编号系列")
    }
}

// MARK: - 缩略图磁盘缓存索引（SQLite）

extension ServiceTests_B {

    static func testThumbCacheStore() {
        print("· 缩略图磁盘缓存索引")
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mitv-thumbdb-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ThumbCacheStore(directory: dir)
        store.store(path: "/Pictures/a.jpg", size: 1024, digest: "aaaa1111", file: "h1.jpg")
        assertEqual(store.lookup(path: "/Pictures/a.jpg", size: 1024), "h1.jpg", "path+size 命中")

        // size 变化（内容已变）→ miss
        assertTrue(store.lookup(path: "/Pictures/a.jpg", size: 2048) == nil, "size 变化视为 miss")

        // 覆盖更新：同 path 新 size → 新文件名
        store.store(path: "/Pictures/a.jpg", size: 2048, digest: nil, file: "h2.jpg")
        assertEqual(store.lookup(path: "/Pictures/a.jpg", size: 2048), "h2.jpg", "覆盖更新")
        assertTrue(store.lookup(path: "/Pictures/a.jpg", size: 1024) == nil, "旧记录被替换")

        // 重启（新实例）→ 仍命中（SQLite 持久化）
        let store2 = ThumbCacheStore(directory: dir)
        assertEqual(store2.lookup(path: "/Pictures/a.jpg", size: 2048), "h2.jpg", "重启后仍命中")

        // 删除
        store2.delete(path: "/Pictures/a.jpg")
        assertTrue(store2.lookup(path: "/Pictures/a.jpg", size: 2048) == nil, "删除后 miss")

        // 超限剪枝：上限 10，插 16 条 → 剩 ≤10（按 created_at 删最旧）
        let smallDir = dir.appendingPathComponent("small")
        let small = ThumbCacheStore(directory: smallDir, maxEntries: 10)
        // 预置缩略图文件本体：剪枝必须连带删文件，否则磁盘孤儿只增不减
        for i in 1...16 {
            try? Data("x".utf8).write(to: smallDir.appendingPathComponent("f\(i).jpg"))
        }
        for i in 1...16 {
            small.store(path: "/p/\(i).jpg", size: Int64(i), digest: nil, file: "f\(i).jpg")
        }
        let left = small.count
        assertTrue(left <= 10, "超限剪枝到上限内（实际 \(left)）")
        assertTrue(small.lookup(path: "/p/1.jpg", size: 1) == nil, "最旧的被剪掉")
        assertTrue(small.lookup(path: "/p/16.jpg", size: 16) != nil, "最新的保留")
        assertFalse(FileManager.default.fileExists(atPath: smallDir.appendingPathComponent("f1.jpg").path),
                    "被剪记录的缩略图文件一并删除")
        assertTrue(FileManager.default.fileExists(atPath: smallDir.appendingPathComponent("f16.jpg").path),
                   "保留记录的文件仍在")
    }
}

// MARK: - 缩略图获取：并发上限 / 同路径共享 / 取消 / 负缓存

extension ServiceTests_B {

    static func testThumbFetchSafety() {
        print("· 缩略图获取并发/取消/负缓存")
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mitv-thumb-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = InlineEngine()
        engine.hangDownloads = true
        let files = TVFileService(engineProvider: { engine },
                                  endpointProvider: { FTPEndpoint(host: "mock") },
                                  capabilitiesProvider: { Capabilities() },
                                  thumbDirectory: dir.appendingPathComponent("thumbs"))
        func entry(_ name: String) -> FTPFileEntry {
            FTPFileEntry(path: "/Pictures/" + name, name: name, isDirectory: false, size: 100, modified: nil)
        }
        let a = entry("a.jpg")

        // 同路径重复请求共享一次下载（网格重配置/定时器不会叠连接）
        files.fetchThumbnail(a) { _ in }
        waitUntil("首个缩略图下载启动") { engine.pendingDownloadCompletions.count == 1 }
        files.fetchThumbnail(a) { _ in }
        Thread.sleep(forTimeInterval: 0.1)
        assertEqual(engine.pendingDownloadCompletions.count, 1, "同路径再请求不叠加下载")

        // 取消 = 断下载句柄，且不进负缓存（滚回来还能重新取）
        files.cancelThumbnail(forPath: a.path)
        assertTrue(engine.downloadHandles.last??.isCanceled == true, "取消断下载句柄")
        engine.releaseAllDownloads(.failure(EngineError.aborted))
        Thread.sleep(forTimeInterval: 0.15) // 等后台收尾释放槽位/清 pending，再重新请求
        files.fetchThumbnail(a) { _ in }
        waitUntil("取消后可重新取（无负缓存污染 + 槽位已释放）") { engine.pendingDownloadCompletions.count == 1 }

        // 真失败 → 负缓存：本会话不再重试
        engine.releaseAllDownloads(.failure(EngineError.ioError("模拟失败")))
        Thread.sleep(forTimeInterval: 0.15) // 等后台收尾把负缓存写入
        files.fetchThumbnail(a) { _ in }
        Thread.sleep(forTimeInterval: 0.1)
        assertEqual(engine.pendingDownloadCompletions.count, 0, "失败后进负缓存不再下载")

        // 并发上限 2：三个新路径只起两路，第三路排队；释放一个槽位后排队项顶上
        files.fetchThumbnail(entry("b.jpg")) { _ in }
        files.fetchThumbnail(entry("c.jpg")) { _ in }
        files.fetchThumbnail(entry("d.jpg")) { _ in }
        waitUntil("两路并发启动") { engine.pendingDownloadCompletions.count == 2 }
        Thread.sleep(forTimeInterval: 0.1)
        assertEqual(engine.pendingDownloadCompletions.count, 2, "并发上限 2，第三路排队")
        engine.releaseAllDownloads(.failure(EngineError.ioError("模拟失败")))
        waitUntil("释放槽位后排队项顶上") { engine.pendingDownloadCompletions.count == 1 }
    }
}

// MARK: - 目标目录自动创建（无目录尽力 MKD；被拒回根）

extension ServiceTests_B {

    static func testAutoMakeDir() {
        print("· 目标目录自动创建")
        let baseDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mitv-mkdir-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: baseDir) }
        let caps = Capabilities(utf8Filenames: false, appeResume: false, restResume: false,
                                mkdir: true, deleteFile: true, rename: true, mlsd: false, sizeCommand: false)
        let f1 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mitv-mkd-\(UUID().uuidString).mp4")
        try! Data(repeating: 0xE1, count: 512).write(to: f1)
        defer { try? FileManager.default.removeItem(at: f1) }
        let fname = f1.lastPathComponent

        func makeQueue(_ dir: String, _ engine: InlineEngine) -> QueueService {
            QueueService(engineProvider: { engine }, endpointProvider: { FTPEndpoint(host: "mock") },
                         capabilitiesProvider: { caps }, persistenceDirectory: baseDir.appendingPathComponent(dir),
                         concurrency: 1, resumeOnStart: true)
        }

        // 1) 无目录 + MKD 成功 → list 新目录（空）→ 直传 /Movies
        do {
            let engine = InlineEngine()
            engine.dirEntries = []        // 根列表：无任何目录
            engine.allowMKD = true
            let queue = makeQueue("mkdok", engine)
            queue.addUploads([f1])
            waitUntil("无目录 + MKD 成功 → 直传 /Movies") { queue.snapshot().first?.phase == .completed }
            assertEqual(engine.uploadCalls.first?.remotePath, "/Movies/" + fname, "自动建目录后归入 Movies")
        }

        // 2) 无目录 + MKD 被拒（真机 550）→ 回退根目录
        do {
            let engine = InlineEngine()
            engine.dirEntries = []
            engine.allowMKD = false
            engine.failListPath = "/Movies" // MKD 拒后 LIST /Movies 也 550
            let queue = makeQueue("mkddeny", engine)
            queue.addUploads([f1])
            waitUntil("MKD 被拒 → 回根目录") { queue.snapshot().first?.phase == .completed }
            assertEqual(engine.uploadCalls.first?.remotePath, "/" + fname, "MKD 拒 → 根目录原名")
        }
    }
}

// MARK: - 空盘/列表失败降级（新 U 盘没有任何目录 → 允许直传根目录）

extension ServiceTests_B {

    static func testEmptyDiskFallback() {
        print("· 空盘/列表失败降级")
        let baseDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mitv-emptydisk-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: baseDir) }
        let caps = Capabilities(utf8Filenames: false, appeResume: false, restResume: false,
                                mkdir: false, deleteFile: true, rename: true, mlsd: false, sizeCommand: false)
        let f1 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mitv-empty-\(UUID().uuidString).mp4")
        try! Data(repeating: 0xCD, count: 1024).write(to: f1)
        defer { try? FileManager.default.removeItem(at: f1) }
        let fname = f1.lastPathComponent
        let moviesDir = FTPFileEntry(path: "/Movies", name: "Movies", isDirectory: true)

        func makeQueue(_ dir: String, _ engine: InlineEngine) -> QueueService {
            QueueService(engineProvider: { engine }, endpointProvider: { FTPEndpoint(host: "mock") },
                         capabilitiesProvider: { caps }, persistenceDirectory: baseDir.appendingPathComponent(dir),
                         concurrency: 1, resumeOnStart: true)
        }

        // 1) 根列表读不到（全新空盘 LIST 报错）→ 降级直传根目录，不再判死
        do {
            let engine = InlineEngine()
            engine.failAllLists = true
            let queue = makeQueue("rootfail", engine)
            queue.addUploads([f1])
            waitUntil("根列表失败 → 降级直传根目录") { queue.snapshot().first?.phase == .completed }
            assertEqual(engine.uploadCalls.count, 1, "降级后仍发起上传")
            assertEqual(engine.uploadCalls.first?.remotePath, "/" + fname, "落到根目录原名")
            let it = queue.snapshot().first!
            assertEqual(it.remoteDir, "/", "卡片显示电视根目录")
            assertTrue(it.failureReason == nil, "无失败原因")
        }

        // 2) 根正常、目标目录列不出内容（空 Movies LIST 报错怪癖）→ 降级直传 /Movies
        do {
            let engine = InlineEngine()
            engine.dirEntries = [moviesDir]
            engine.failListPath = "/Movies"
            let queue = makeQueue("dirfail", engine)
            queue.addUploads([f1])
            waitUntil("目标目录列表失败 → 降级直传该目录") { queue.snapshot().first?.phase == .completed }
            assertEqual(engine.uploadCalls.count, 1, "降级后仍发起上传")
            assertEqual(engine.uploadCalls.first?.remotePath, "/Movies/" + fname, "落到已确认存在的目标目录")
        }

        // 3) 全新空盘（无任何目录 + MKD 被拒，真机 550 语义）→ 回根直传
        do {
            let engine = InlineEngine()
            engine.dirEntries = []
            engine.allowMKD = false
            engine.failListPath = "/Movies" // MKD 拒 → 目录不存在 → LIST 也 550
            let queue = makeQueue("cleanempty", engine)
            queue.addUploads([f1])
            waitUntil("空盘 MKD 被拒 → 回根直传") { queue.snapshot().first?.phase == .completed }
            assertEqual(engine.uploadCalls.first?.remotePath, "/" + fname, "MKD 拒 → 根目录原名")
        }

        // 4) 列表失败 + SIZE 显示同名已存在（review D0）→ 指纹名改名 + 禁 APPE（防拼接）
        do {
            let engine = InlineEngine()
            engine.failAllLists = true
            engine.remoteSizes = ["/" + fname: 999999] // 远端恰有同名旧文件
            let queue = makeQueue("d0clash", engine)
            queue.addUploads([f1])
            waitUntil("降级同名冲突 → 指纹名") { queue.snapshot().first?.phase == .completed }
            let call = engine.uploadCalls.first
            assertTrue(call != nil, "仍发起上传")
            assertFalse(call?.resume ?? true, "降级路径禁 APPE（防旧文件尾部拼接坏文件）")
            assertTrue(call?.remotePath != "/" + fname, "不覆盖远端同名旧文件")
            let rp = call?.remotePath ?? ""
            assertTrue(rp.hasPrefix("/") && rp.contains("-"), "改用指纹后缀名")
        }

        // 5) 列表失败 + SIZE 不可用（nil：不存在或 SIZE=false）→ 原名直传 + 禁 APPE
        do {
            let engine = InlineEngine()
            engine.failAllLists = true
            let queue = makeQueue("d0noclash", engine)
            queue.addUploads([f1])
            waitUntil("降级无同名 → 原名直传") { queue.snapshot().first?.phase == .completed }
            let call = engine.uploadCalls.first
            assertEqual(call?.remotePath, "/" + fname, "无同名 → 原名")
            assertFalse(call?.resume ?? true, "降级路径禁 APPE")
        }
    }
}

// MARK: - 上传重名判定（净化 / 相同文件跳过 / 不同文件 MD5 后缀改名）

extension ServiceTests_B {

    static func testUploadCollision() {
        print("· 上传重名判定")
        let baseDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mitv-collide-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: baseDir) }
        let caps = Capabilities(utf8Filenames: false, appeResume: true, restResume: false,
                                mkdir: false, deleteFile: true, rename: true, mlsd: false, sizeCommand: true)

        // 本地素材：4096 字节 0xAB（<10MB → 指纹 = 全文件 md5）
        let content = Data(repeating: 0xAB, count: 4096)
        let f1 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mitv-collide-\(UUID().uuidString).mp4")
        try! content.write(to: f1)
        defer { try? FileManager.default.removeItem(at: f1) }
        let fname = f1.lastPathComponent
        let localFP = FileDigest.fingerprint(url: f1, fileSize: Int64(content.count))!
        let digest8 = String(localFP.hex.prefix(8))
        let moviesDir = FTPFileEntry(path: "/Movies", name: "Movies", isDirectory: true)
        let clashEntry = FTPFileEntry(path: "/Movies/" + fname, name: fname, isDirectory: false, size: Int64(content.count))

        // 1) 同名 + 同尺寸 + 同前缀 → 相同文件，跳过上传
        do {
            let engine = InlineEngine()
            engine.dirEntries = [moviesDir, clashEntry]
            engine.remotePrefix = content // 远端前缀与本地内容一致
            let queue = QueueService(engineProvider: { engine }, endpointProvider: { FTPEndpoint(host: "mock") },
                                     capabilitiesProvider: { caps }, persistenceDirectory: baseDir.appendingPathComponent("same"),
                                     concurrency: 1, resumeOnStart: true)
            queue.addUploads([f1])
            waitUntil("同名相同文件 → 跳过") { queue.snapshot().first?.phase == .completed }
            let it = queue.snapshot().first!
            assertTrue(it.skippedReason != nil, "跳过原因已记录")
            assertEqual(engine.uploadCalls.count, 0, "相同文件不发起上传")
            assertEqual(engine.prefixCalls, 1, "同尺寸 → 拉一次远端前缀")
        }

        // 2) 同名 + 同尺寸 + 不同前缀 → 改名（原名-md5前8）上传
        do {
            let engine = InlineEngine()
            engine.dirEntries = [moviesDir, clashEntry]
            engine.remotePrefix = Data(repeating: 0x11, count: content.count) // 同尺寸不同内容
            let queue = QueueService(engineProvider: { engine }, endpointProvider: { FTPEndpoint(host: "mock") },
                                     capabilitiesProvider: { caps }, persistenceDirectory: baseDir.appendingPathComponent("diff"),
                                     concurrency: 1, resumeOnStart: true)
            queue.addUploads([f1])
            waitUntil("同名不同文件 → 改名上传") { queue.snapshot().first?.phase == .completed }
            let it = queue.snapshot().first!
            assertTrue(it.skippedReason == nil, "不同文件不跳过")
            assertEqual(engine.uploadCalls.count, 1, "发起一次上传")
            assertEqual(engine.uploadCalls.first?.remotePath,
                        "/Movies/" + SmartRouting.md5SuffixedName(fname, digest8: digest8),
                        "远端名 = 原名-指纹8.mp4")
        }

        // 3) 同名但尺寸不同 → 免拉前缀，直接改名上传
        do {
            let engine = InlineEngine()
            engine.dirEntries = [moviesDir, FTPFileEntry(path: "/Movies/" + fname, name: fname,
                                                         isDirectory: false, size: Int64(content.count) + 1)]
            let queue = QueueService(engineProvider: { engine }, endpointProvider: { FTPEndpoint(host: "mock") },
                                     capabilitiesProvider: { caps }, persistenceDirectory: baseDir.appendingPathComponent("sizediff"),
                                     concurrency: 1, resumeOnStart: true)
            queue.addUploads([f1])
            waitUntil("同名尺寸不同 → 改名上传") { queue.snapshot().first?.phase == .completed }
            assertEqual(engine.prefixCalls, 0, "尺寸不同免拉前缀")
            assertEqual(engine.uploadCalls.count, 1, "发起一次上传")
            assertEqual(engine.uploadCalls.first?.remotePath,
                        "/Movies/" + SmartRouting.md5SuffixedName(fname, digest8: digest8),
                        "尺寸不同也用指纹后缀")
        }

        // 4) 远端前缀读取失败 → 判定不了 → 保守改名上传（不覆盖）
        do {
            let engine = InlineEngine()
            engine.dirEntries = [moviesDir, clashEntry]
            engine.remotePrefix = nil
            let queue = QueueService(engineProvider: { engine }, endpointProvider: { FTPEndpoint(host: "mock") },
                                     capabilitiesProvider: { caps }, persistenceDirectory: baseDir.appendingPathComponent("failfetch"),
                                     concurrency: 1, resumeOnStart: true)
            queue.addUploads([f1])
            waitUntil("前缀拉取失败 → 保守改名") { queue.snapshot().first?.phase == .completed }
            assertEqual(engine.uploadCalls.count, 1, "保守改名上传")
            assertEqual(engine.uploadCalls.first?.remotePath,
                        "/Movies/" + SmartRouting.md5SuffixedName(fname, digest8: digest8),
                        "判定失败不覆盖远端")
        }

        // 5) 指纹名已存在且内容相同（同一内容此前已传过）→ 跳过，不再堆积 (2)(3)
        do {
            let engine = InlineEngine()
            let candName = SmartRouting.md5SuffixedName(fname, digest8: digest8)
            engine.dirEntries = [moviesDir,
                                 FTPFileEntry(path: "/Movies/" + fname, name: fname, isDirectory: false,
                                              size: Int64(content.count) + 1), // 同名但尺寸不同 → 第一层判不同
                                 FTPFileEntry(path: "/Movies/" + candName, name: candName, isDirectory: false,
                                              size: Int64(content.count))]     // 指纹名内容与本地一致
            engine.remotePrefix = content
            let queue = QueueService(engineProvider: { engine }, endpointProvider: { FTPEndpoint(host: "mock") },
                                     capabilitiesProvider: { caps }, persistenceDirectory: baseDir.appendingPathComponent("converge"),
                                     concurrency: 1, resumeOnStart: true)
            queue.addUploads([f1])
            waitUntil("指纹名命中相同内容 → 跳过收敛") { queue.snapshot().first?.phase == .completed }
            assertEqual(engine.uploadCalls.count, 0, "不重复上传（不堆 (2)(3)）")
            let it = queue.snapshot().first!
            assertTrue(it.skippedReason != nil, "收敛为跳过")
            assertEqual(it.remotePath, "/Movies/" + candName, "跳过指向已有指纹文件")
        }

        // 6) 同名仅大小写不同（FAT U 盘）→ 仍按同名判定，相同内容跳过
        do {
            let engine = InlineEngine()
            let upper = fname.uppercased()
            engine.dirEntries = [moviesDir,
                                 FTPFileEntry(path: "/Movies/" + upper, name: upper, isDirectory: false,
                                              size: Int64(content.count))]
            engine.remotePrefix = content
            let queue = QueueService(engineProvider: { engine }, endpointProvider: { FTPEndpoint(host: "mock") },
                                     capabilitiesProvider: { caps }, persistenceDirectory: baseDir.appendingPathComponent("casefold"),
                                     concurrency: 1, resumeOnStart: true)
            queue.addUploads([f1])
            waitUntil("仅大小写不同的同名 → 跳过") { queue.snapshot().first?.phase == .completed }
            assertEqual(engine.uploadCalls.count, 0, "大小写不同也不覆盖（FAT 语义）")
            assertTrue(queue.snapshot().first?.skippedReason != nil, "按相同文件跳过")
        }
    }
}

// MARK: - 直删（DELE）批量行为

extension ServiceTests_B {

    /// 线程安全结果盒（引擎回调在后台队列，completion 在主队列）
    final class DeleteBox {
        private let lock = NSLock()
        private var _outcome: TVFileService.DeleteOutcome?
        private var _error: Error?
        private var _lastDone = -1
        var outcome: TVFileService.DeleteOutcome? { lock.lock(); defer { lock.unlock() }; return _outcome }
        var error: Error? { lock.lock(); defer { lock.unlock() }; return _error }
        var lastDone: Int { lock.lock(); defer { lock.unlock() }; return _lastDone }
        var done: Bool { lock.lock(); defer { lock.unlock() }; return _outcome != nil || _error != nil }
        func set(_ result: Result<TVFileService.DeleteOutcome, Error>) {
            lock.lock()
            switch result {
            case .success(let o): _outcome = o
            case .failure(let e): _error = e
            }
            lock.unlock()
        }
        func progress(_ done: Int) { lock.lock(); _lastDone = done; lock.unlock() }
    }

    /// completion 派发在主队列：必须转主 RunLoop 才能收到（Thread.sleep 会饿死它）
    static func waitMain(_ msg: String, timeout: TimeInterval = 5, _ cond: @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        assertTrue(cond(), msg)
    }

    static func testDirectDelete() {
        print("· 直删批量行为")
        let caps = Capabilities(utf8Filenames: false, appeResume: true, restResume: false,
                                mkdir: true, deleteFile: true, rename: true, mlsd: false, sizeCommand: true)
        let a = FTPFileEntry(path: "/Movies/a.mp4", name: "a.mp4", isDirectory: false, size: 5)
        let b = FTPFileEntry(path: "/Movies/b.mp4", name: "b.mp4", isDirectory: false, size: 7)
        let dir = FTPFileEntry(path: "/Movies", name: "Movies", isDirectory: true)

        // 1) 全部成功：按序逐条 DELE，目录不参与，进度到满
        do {
            let engine = InlineEngine()
            let service = TVFileService(engineProvider: { engine }, endpointProvider: { FTPEndpoint(host: "mock") },
                                        capabilitiesProvider: { caps })
            let box = DeleteBox()
            service.deleteEntries([dir, a, b], progress: { done, total, _ in
                box.progress(done)
                if total != 2 { box.set(.failure(EngineError.unsupported("目录不应计入总数"))) }
            }) { box.set($0) }
            waitMain("直删完成") { box.done }
            assertEqual(box.outcome?.deletedCount, 2, "两项全部删除")
            assertEqual(box.outcome?.failedNames.count, 0, "无失败")
            assertEqual(engine.deleteCalls, ["/Movies/a.mp4", "/Movies/b.mp4"], "按序 DELE，不删目录")
            assertEqual(box.lastDone, 2, "进度到达满量")
        }

        // 2) 部分失败：如实上报失败名单，失败后继续删剩余项
        do {
            let engine = InlineEngine()
            engine.failDeletePaths = ["/Movies/a.mp4"]
            let service = TVFileService(engineProvider: { engine }, endpointProvider: { FTPEndpoint(host: "mock") },
                                        capabilitiesProvider: { caps })
            let box = DeleteBox()
            service.deleteEntries([a, b], progress: { _, _, _ in }) { box.set($0) }
            waitMain("部分失败返回") { box.done }
            assertEqual(box.outcome?.deletedCount, 1, "成功一项")
            assertEqual(box.outcome?.failedNames, ["a.mp4"], "失败名单如实上报")
            assertEqual(engine.deleteCalls.count, 2, "失败不中断，继续删剩余项")
        }

        // 3) 能力不支持：报 unsupported，不发起任何 DELE
        do {
            let engine = InlineEngine()
            let noDelete = Capabilities(deleteFile: false, rename: true)
            let service = TVFileService(engineProvider: { engine }, endpointProvider: { FTPEndpoint(host: "mock") },
                                        capabilitiesProvider: { noDelete })
            let box = DeleteBox()
            service.deleteEntries([a], progress: { _, _, _ in }) { box.set($0) }
            waitMain("不支持返回") { box.done }
            if case .unsupported = box.error {} else { assertTrue(false, "不支持删除 → unsupported 错误") }
            assertEqual(engine.deleteCalls.count, 0, "不支持时不发起 DELE")
        }

        // 4) 空选择 / 只有目录：0 删除，不发起引擎调用
        do {
            let engine = InlineEngine()
            let service = TVFileService(engineProvider: { engine }, endpointProvider: { FTPEndpoint(host: "mock") },
                                        capabilitiesProvider: { caps })
            let box = DeleteBox()
            service.deleteEntries([dir], progress: { _, _, _ in }) { box.set($0) }
            waitMain("空选择返回") { box.done }
            assertEqual(box.outcome?.deletedCount, 0, "只有目录 → 0 删除")
            assertEqual(engine.deleteCalls.count, 0, "空选择不发起 DELE")
        }

        // 5) 未连接：报 notConnected
        do {
            let engine = InlineEngine()
            let service = TVFileService(engineProvider: { engine }, endpointProvider: { nil },
                                        capabilitiesProvider: { caps })
            let box = DeleteBox()
            service.deleteEntries([a], progress: { _, _, _ in }) { box.set($0) }
            waitMain("未连接返回") { box.done }
            if case .notConnected = box.error {} else { assertTrue(false, "未连接 → notConnected 错误") }
            assertEqual(engine.deleteCalls.count, 0, "未连接不发起 DELE")
        }
    }
}

// MARK: - 批量暂停必须取消引擎句柄（否则「暂停」是假的：传输继续跑完）

extension ServiceTests_B {

    static func testPauseAllCancelsHandles() {
        print("· 批量暂停取消句柄")
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mitv-pauseall-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let f1 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mitv-pauseall-\(UUID().uuidString).mp4")
        try? Data(repeating: 0, count: 10).write(to: f1)
        defer { try? FileManager.default.removeItem(at: f1) }

        let engine = InlineEngine()
        engine.hangUploads = true
        let caps = Capabilities(utf8Filenames: false, appeResume: true, restResume: false,
                                mkdir: false, deleteFile: true, rename: true, mlsd: false, sizeCommand: true)
        let queue = QueueService(engineProvider: { engine }, endpointProvider: { FTPEndpoint(host: "mock") },
                                 capabilitiesProvider: { caps }, persistenceDirectory: dir,
                                 concurrency: 2, resumeOnStart: true)
        queue.addUploads([f1])
        waitUntil("起传") { queue.snapshot().first?.phase == .running }
        let id = queue.snapshot().first!.id

        // 全部暂停 → 引擎句柄必须被取消
        queue.pauseAllByUser()
        waitUntil("全部暂停生效") { queue.snapshot().first?.phase == .paused }
        assertTrue(engine.uploadHandles.last??.isCanceled == true, "全部暂停取消引擎句柄（传输不再偷跑）")

        // 全部继续 → 新句柄起传；断线自动暂停 → 同样取消
        queue.resumeAllByUser()
        waitUntil("恢复起传") { queue.snapshot().first?.phase == .running }
        assertTrue(engine.uploadHandles.last??.isCanceled == false, "恢复后新句柄未取消")
        queue.autoPauseForDisconnect()
        waitUntil("断线暂停生效") { queue.snapshot().first?.phase == .paused }
        assertTrue(engine.uploadHandles.last??.isCanceled == true, "断线自动暂停也取消引擎句柄")
        _ = id
        engine.releaseAllUploads(.failure(EngineError.aborted))
    }
}

// MARK: - 批内/跨批命名碰撞（下载大小写 / 上传降级 inflight / 同文件重复拖入）

extension ServiceTests_B {

    static func testBatchNameCollisions() {
        print("· 批内命名碰撞")
        let baseDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mitv-batch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: baseDir) }
        let caps = Capabilities(utf8Filenames: false, appeResume: true, restResume: false,
                                mkdir: false, deleteFile: true, rename: true, mlsd: false, sizeCommand: true)
        let dlDir = baseDir.appendingPathComponent("dl")
        try? FileManager.default.createDirectory(at: dlDir, withIntermediateDirectories: true)

        // 1) 同批下载 IMG.jpg + img.jpg → 本地目标必须不同（大小写不敏感卷上是同一文件）
        do {
            let engine = InlineEngine()
            engine.hangDownloads = true
            let queue = QueueService(engineProvider: { engine }, endpointProvider: { FTPEndpoint(host: "mock") },
                                     capabilitiesProvider: { caps }, persistenceDirectory: baseDir.appendingPathComponent("q1"),
                                     concurrency: 2, resumeOnStart: true)
            let items = queue.addDownloads([
                FTPFileEntry(path: "/a/IMG.jpg", name: "IMG.jpg", isDirectory: false, size: 1),
                FTPFileEntry(path: "/a/img.jpg", name: "img.jpg", isDirectory: false, size: 1),
            ], toDirectory: dlDir)
            assertEqual(items.count, 2, "两项都入队")
            let a = items[0].localPath.lowercased()
            let b = items[1].localPath.lowercased()
            assertTrue(a != b, "同批大小写碰撞 → 本地目标顺延（不写同一文件）")
            engine.releaseAllDownloads(.success(1))
        }

        // 2) 跨批下载：IMG.jpg 在传 → img.jpg 新批必须顺延
        do {
            let engine = InlineEngine()
            engine.hangDownloads = true
            let queue = QueueService(engineProvider: { engine }, endpointProvider: { FTPEndpoint(host: "mock") },
                                     capabilitiesProvider: { caps }, persistenceDirectory: baseDir.appendingPathComponent("q2"),
                                     concurrency: 2, resumeOnStart: true)
            let first = queue.addDownloads([FTPFileEntry(path: "/a/IMG.jpg", name: "IMG.jpg", isDirectory: false, size: 1)],
                                           toDirectory: dlDir)
            waitUntil("第一批起传") { queue.snapshot().first?.phase == .running }
            let second = queue.addDownloads([FTPFileEntry(path: "/a/img.jpg", name: "img.jpg", isDirectory: false, size: 1)],
                                            toDirectory: dlDir)
            assertTrue(first[0].localPath.lowercased() != second[0].localPath.lowercased(),
                       "跨批大小写碰撞 → 顺延（inflight 大小写不敏感）")
            engine.releaseAllDownloads(.success(1))
        }

        // 3) 上传降级（LIST 全失败）：两个同名不同内容文件 → 目标名必须不同（inflight 查重）
        do {
            let subA = baseDir.appendingPathComponent("A"); let subB = baseDir.appendingPathComponent("B")
            try? FileManager.default.createDirectory(at: subA, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: subB, withIntermediateDirectories: true)
            let fa = subA.appendingPathComponent("同名.mp4"); let fb = subB.appendingPathComponent("同名.mp4")
            try? Data(repeating: 0xAA, count: 16).write(to: fa)
            try? Data(repeating: 0xBB, count: 16).write(to: fb)
            let engine = InlineEngine()
            engine.failAllLists = true
            let queue = QueueService(engineProvider: { engine }, endpointProvider: { FTPEndpoint(host: "mock") },
                                     capabilitiesProvider: { caps }, persistenceDirectory: baseDir.appendingPathComponent("q3"),
                                     concurrency: 2, resumeOnStart: true)
            queue.addUploads([fa, fb])
            waitUntil("两项降级上传完成") { queue.snapshot().filter { $0.phase == .completed }.count == 2 }
            assertEqual(engine.uploadCalls.count, 2, "两项都上传")
            let p0 = engine.uploadCalls[0].remotePath.lowercased()
            let p1 = engine.uploadCalls[1].remotePath.lowercased()
            assertTrue(p0 != p1, "降级路径同名 → inflight 查重顺延（不并发 STOR 同一目标）")
            assertFalse(engine.uploadCalls[0].resume, "降级禁 APPE（0）")
            assertFalse(engine.uploadCalls[1].resume, "降级禁 APPE（1）")
        }

        // 4) 同一本地文件同批拖两次 → 第二份收敛为跳过，不传副本
        do {
            let f1 = baseDir.appendingPathComponent("double.mp4")
            try? Data(repeating: 0xCC, count: 16).write(to: f1)
            let engine = InlineEngine()
            let queue = QueueService(engineProvider: { engine }, endpointProvider: { FTPEndpoint(host: "mock") },
                                     capabilitiesProvider: { caps }, persistenceDirectory: baseDir.appendingPathComponent("q4"),
                                     concurrency: 1, resumeOnStart: true)
            queue.addUploads([f1, f1])
            waitUntil("两项都终结") { queue.snapshot().filter { $0.phase == .completed }.count == 2 }
            assertEqual(engine.uploadCalls.count, 1, "同文件重复拖入只传一次")
            assertTrue(queue.snapshot().contains { $0.skippedReason != nil }, "第二份标记跳过")
        }
    }
}
