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
        testStartupWaitsForConnection()
        testReconnectAutoRetryDropped()
        testUploadCollision()
        testBrowseFilter()
        testEmptyDiskFallback()
        testAutoMakeDir()
        testThumbCacheStore()
        testDirectDelete()
        testPauseAllCancelsHandles()
        testBatchNameCollisions()
        testStaleInflightRace()
        testBatchRetryRearm()
        testCompletedSiblingBlindSpot()
        testThumbFetchSafety()
        testUploadTargetPersistence()
        testQueueItemDirOverrideRoundTrip()
        testExplicitTargetDirRouting()
        testCustomTargetDegradation()
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
        it2.connectionDropped = true
        let back2 = (try! dec.decode([QueueItem].self, from: try! enc.encode([it2]))).first!
        assertEqual(back2.failureReason, "电视拒绝写入", "失败原因往返")
        assertEqual(back2.connectionDropped, Optional<Bool>.some(true), "connectionDropped 往返")

        // 旧版本 queue.json（无 connectionDropped 字段）必须可解码：Optional 字段缺 key 解码为 nil
        let legacyJSON = """
        [{"id":"x","direction":"upload","kind":"video","localPath":"/tmp/a.mp4","displayName":"a.mp4",
        "sizeBytes":100,"phase":"queued","bytes":0,"bytesPerSecond":0,"needsNameMapping":false,
        "autoPaused":false,"batchId":"b","addedAt":"2026-11-19T12:00:00Z"}]
        """.data(using: .utf8)!
        let legacy = (try! dec.decode([QueueItem].self, from: legacyJSON)).first!
        assertTrue(legacy.connectionDropped == nil, "旧 JSON 缺 connectionDropped 解码为 nil（向后兼容）")
        assertEqual(legacy.displayName, "a.mp4", "旧 JSON 其余字段完整")
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
        /// 指定路径的 delete 报 remoteNotFound（重启补删 tolerateMissing 测试用）
        var notFoundDeletePaths: Set<String> = []
        /// 指定路径的 delete 报 ioError（未识别 550：文件可能还在，补删不得容忍）
        var ioErrorDeletePaths: Set<String> = []
        private(set) var uploadHandles: [TransferHandle?] = []
        private(set) var downloadHandles: [TransferHandle?] = []
        /// true 时 upload 完成回调被扣住，供测试精确控制时序；false 时延迟自动成功/失败
        var hangUploads = false
        /// true 时 upload 以失败收场
        var failUploads = false
        /// 失败时使用的错误（默认 connectionFailed；连接类/非连接类失败自动重试测试用）
        var failUploadsError: EngineError?
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
        /// 指定路径前 N 次 list 失败、之后成功（指定目录「首列失败 → MKD 重建 → 再列成功」测试用）
        var listFailCounts: [String: Int] = [:]
        /// MKD 是否成功（真机 SwiFTP 550 → false）
        var allowMKD = false
        /// size() 按路径返回预设值（降级同名探测测试用）；未命中 → success(nil)
        var remoteSizes: [String: Int64] = [:]
        /// downloadPrefix 返回的「远端前缀」内容（nil → 失败）
        var remotePrefix: Data?
        /// downloadPrefix 回调延迟（拉宽异步窗口，复现过期 inflight 快照竞态用）
        var prefixDelay: TimeInterval = 0.02
        /// LIST/SIZE 回调延迟序列（按调用次序消费，末值重复；nil=无延迟）：
        /// 让兄弟项在另一项的 LIST/SIZE hop 期间完成，确定性复现定名盲区
        var listDelays: [TimeInterval]?
        var sizeDelays: [TimeInterval]?
        private var listCallCount = 0
        private var sizeCallCount = 0
        private var prefixCallCount = 0
        private let lock = NSLock()

        var prefixCalls: Int { lock.lock(); defer { lock.unlock() }; return prefixCallCount }
        var listCalls: Int { lock.lock(); defer { lock.unlock() }; return listCallCount }

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
                    completion(fail ? .failure(self.failUploadsError ?? EngineError.connectionFailed("模拟断线")) : .success(1))
                }
            }
        }

        func ping(_ endpoint: FTPEndpoint, completion: @escaping (Error?) -> Void) { DispatchQueue.global().async { completion(nil) } }
        func list(_ endpoint: FTPEndpoint, path: String, completion: @escaping (Result<[FTPFileEntry], Error>) -> Void) {
            lock.lock()
            let i = listCallCount; listCallCount += 1
            let seq = listDelays
            lock.unlock()
            let delay = seq.map { $0[min(i, $0.count - 1)] } ?? 0
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                if self.failAllLists {
                    completion(.failure(EngineError.connectionFailed("模拟列表失败")))
                    return
                }
                // 按路径的「前 N 次失败」脚本：MKD 重建后同一路径再列即成功
                var remainingFail = 0
                self.lock.lock()
                if let c = self.listFailCounts[path], c > 0 {
                    self.listFailCounts[path] = c - 1
                    remainingFail = c
                }
                self.lock.unlock()
                if remainingFail > 0 {
                    completion(.failure(EngineError.connectionFailed("模拟目录列表失败")))
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
            DispatchQueue.global().asyncAfter(deadline: .now() + prefixDelay) {
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
            let notFound = notFoundDeletePaths.contains(remotePath)
            let ioErr = ioErrorDeletePaths.contains(remotePath)
            lock.unlock()
            DispatchQueue.global().async {
                if notFound { completion(EngineError.remoteNotFound(remotePath)) }
                else if ioErr { completion(EngineError.ioError("550 Could not delete file")) }
                else { completion(fail ? EngineError.permissionDenied("模拟删除失败") : nil) }
            }
        }
        func move(_ endpoint: FTPEndpoint, from: String, to: String, completion: @escaping (Error?) -> Void) {
            lock.lock(); moveCalls.append(MoveCall(from: from, to: to)); lock.unlock()
            DispatchQueue.global().async { completion(nil) }
        }
        func makeDirectory(_ endpoint: FTPEndpoint, path: String, completion: @escaping (Error?) -> Void) {
            DispatchQueue.global().async { completion(self.allowMKD ? nil : EngineError.unsupported("MKD")) }
        }
        func size(_ endpoint: FTPEndpoint, remotePath: String, completion: @escaping (Result<Int64?, Error>) -> Void) {
            lock.lock()
            let i = sizeCallCount; sizeCallCount += 1
            let seq = sizeDelays
            lock.unlock()
            let delay = seq.map { $0[min(i, $0.count - 1)] } ?? 0
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { completion(.success(self.remoteSizes[remotePath])) }
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

    // MARK: - 启动恢复等待连接（review A1）

    static func testStartupWaitsForConnection() {
        print("· 启动恢复项等待连接就绪再调度")
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mitv-startup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mitv-startup-\(UUID().uuidString).mp4")
        try? Data(repeating: 7, count: 16).write(to: f)
        defer { try? FileManager.default.removeItem(at: f) }

        // 预置上次会话遗留的 queue.json（重启时电视多半已关机）
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var leftover = QueueItem(direction: .upload, kind: .video, localPath: f.path,
                                 displayName: f.lastPathComponent, sizeBytes: 16)
        leftover.phase = .queued
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try! enc.encode([leftover]).write(to: dir.appendingPathComponent("queue.json"))

        let engine = InlineEngine()
        let caps = Capabilities(appeResume: true, deleteFile: true, rename: true, sizeCommand: true)
        let queue = QueueService(engineProvider: { engine },
                                 endpointProvider: { FTPEndpoint(host: "mock") },
                                 capabilitiesProvider: { caps },
                                 persistenceDirectory: dir,
                                 concurrency: 2, resumeOnStart: true)
        // 恢复项不抢跑：等连接就绪（协调器 connect 成功后 connectionReady），电视离线时不再逐项判失败
        Thread.sleep(forTimeInterval: 0.4)
        assertEqual(engine.uploadCalls.count, 0, "连接就绪前不发起任何上传")
        assertEqual(engine.listCalls, 0, "连接就绪前不做智能分流 LIST")
        assertEqual(queue.snapshot().first?.phase, .queued, "恢复项保持 queued（不是 failed）")

        // 连接就绪（首连成功）→ 放行调度 → 正常完成
        queue.connectionReady()
        waitUntil("连接就绪后恢复项完成") { queue.snapshot().first?.phase == .completed }
        assertEqual(engine.uploadCalls.count, 1, "就绪后恰好一次上传")
    }

    // MARK: - 重连自动重试连接类失败（review A2）

    static func testReconnectAutoRetryDropped() {
        print("· 重连自动重试连接类失败项")
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mitv-retry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let f1 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mitv-retry-a-\(UUID().uuidString).mp4")
        try? Data(repeating: 0, count: 10).write(to: f1)
        defer { try? FileManager.default.removeItem(at: f1) }
        let f2 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mitv-retry-b-\(UUID().uuidString).mp4")
        try? Data(repeating: 1, count: 10).write(to: f2)
        defer { try? FileManager.default.removeItem(at: f2) }

        let engine = InlineEngine()
        let caps = Capabilities(appeResume: true, deleteFile: true, rename: true, sizeCommand: true)
        let queue = QueueService(engineProvider: { engine },
                                 endpointProvider: { FTPEndpoint(host: "mock") },
                                 capabilitiesProvider: { caps },
                                 persistenceDirectory: dir,
                                 concurrency: 1, resumeOnStart: true)

        // 1) 连接类失败（心跳判掉线前的窗口期）→ 标记 connectionDropped
        engine.failUploads = true
        _ = queue.addUploads([f1])
        waitUntil("连接失败可见") { queue.snapshot().first?.phase == .failed }
        assertTrue(queue.snapshot().first?.connectionDropped == true, "连接类失败已标记 connectionDropped")

        // 2) 断线（心跳掉线整体暂停）→ 重连成功 → 自动重试并完成（无需手动逐项重试）
        queue.autoPauseForDisconnect()
        engine.failUploads = false
        queue.autoResumeAfterReconnect()
        waitUntil("重连后自动重试完成") { queue.snapshot().first?.phase == .completed }
        assertEqual(engine.uploadCalls.count, 2, "自动重试恰好再调一次引擎")
        assertTrue(engine.uploadCalls[1].resume, "自动重试=同任务续传 → APPE（远端半截是本任务前缀）")

        // 3) 非连接类失败（如磁盘满）不得被自动重试
        engine.failUploads = true
        engine.failUploadsError = EngineError.ioError("磁盘满")
        _ = queue.addUploads([f2])
        waitUntil("非连接失败可见") { queue.snapshot().first(where: { $0.localPath == f2.path })?.phase == .failed }
        let failedID = queue.snapshot().first { $0.localPath == f2.path }!.id
        let callsBeforeResume = engine.uploadCalls.count // 含 f2 的首次失败调用
        queue.autoPauseForDisconnect()
        engine.failUploads = false
        engine.failUploadsError = nil
        queue.autoResumeAfterReconnect()
        Thread.sleep(forTimeInterval: 0.3)
        assertEqual(queue.snapshot().first { $0.id == failedID }?.phase, .failed, "非连接类失败不自动重试（等用户手动重试）")
        assertEqual(engine.uploadCalls.count, callsBeforeResume, "引擎未被再次调用")
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
            if case .unsupported? = box.error as? EngineError {} else { assertTrue(false, "不支持删除 → unsupported 错误") }
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
            if case .notConnected? = box.error as? EngineError {} else { assertTrue(false, "未连接 → notConnected 错误") }
            assertEqual(engine.deleteCalls.count, 0, "未连接不发起 DELE")
        }

        // 6) tolerateMissing：远端已不存在视为删成功（重启补删幂等）；默认仍如实报失败
        do {
            let engine = InlineEngine()
            engine.notFoundDeletePaths = ["/Movies/a.mp4"]
            let service = TVFileService(engineProvider: { engine }, endpointProvider: { FTPEndpoint(host: "mock") },
                                        capabilitiesProvider: { caps })
            let box = DeleteBox()
            service.deleteEntries([a, b], tolerateMissing: true, progress: { _, _, _ in }) { box.set($0) }
            waitMain("补删完成") { box.done }
            assertEqual(box.outcome?.deletedCount, 2, "notFound 计入删除成功（上次已删掉的项不再算失败）")
            assertEqual(box.outcome?.failedNames.count, 0, "补删无失败名单")

            let engine2 = InlineEngine()
            engine2.notFoundDeletePaths = ["/Movies/a.mp4"]
            let service2 = TVFileService(engineProvider: { engine2 }, endpointProvider: { FTPEndpoint(host: "mock") },
                                         capabilitiesProvider: { caps })
            let box2 = DeleteBox()
            service2.deleteEntries([a, b], progress: { _, _, _ in }) { box2.set($0) }
            waitMain("默认模式返回") { box2.done }
            assertEqual(box2.outcome?.deletedCount, 1, "默认不容忍 notFound")
            assertEqual(box2.outcome?.failedNames, ["a.mp4"], "默认模式 notFound 如实报失败")
        }

        // 7) fail-safe：ioError（450/未识别 550 泛化失败）+ LIST 证明文件还在 → 不计删成功
        do {
            let engine = InlineEngine()
            engine.ioErrorDeletePaths = ["/Movies/a.mp4"]
            engine.dirEntriesByPath["/Movies"] = [a, b]
            let service = TVFileService(engineProvider: { engine }, endpointProvider: { FTPEndpoint(host: "mock") },
                                        capabilitiesProvider: { caps })
            let box = DeleteBox()
            service.deleteEntries([a, b], tolerateMissing: true, progress: { _, _, _ in }) { box.set($0) }
            waitMain("ioError 补删返回") { box.done }
            assertEqual(box.outcome?.deletedCount, 1, "ioError 且 LIST 在场 → 不计删成功（fail-open 会谎报已删除）")
            assertEqual(box.outcome?.failedNames, ["a.mp4"], "ioError 留失败名单 → 登记保留待重试")
        }

        // 8) G2：ioError（SwiFTP 真机 450）+ LIST 确认缺席 → 计删成功（补删容忍真机生效）
        do {
            let engine = InlineEngine()
            engine.ioErrorDeletePaths = ["/Movies/a.mp4"]
            engine.dirEntriesByPath["/Movies"] = [b]
            let service = TVFileService(engineProvider: { engine }, endpointProvider: { FTPEndpoint(host: "mock") },
                                        capabilitiesProvider: { caps })
            let box = DeleteBox()
            service.deleteEntries([a, b], tolerateMissing: true, progress: { _, _, _ in }) { box.set($0) }
            waitMain("450 缺席补删返回") { box.done }
            assertEqual(box.outcome?.deletedCount, 2, "450 泛化失败 + LIST 缺席 → 容忍计删成功")
            assertEqual(box.outcome?.failedNames.count, 0, "缺席确认无失败名单")
        }

        // 9) fail-safe：ioError + LIST 本身失败 → 证明不了缺席 → 不计删成功
        do {
            let engine = InlineEngine()
            engine.ioErrorDeletePaths = ["/Movies/a.mp4"]
            engine.failListPath = "/Movies"
            let service = TVFileService(engineProvider: { engine }, endpointProvider: { FTPEndpoint(host: "mock") },
                                        capabilitiesProvider: { caps })
            let box = DeleteBox()
            service.deleteEntries([a, b], tolerateMissing: true, progress: { _, _, _ in }) { box.set($0) }
            waitMain("LIST 失败补删返回") { box.done }
            assertEqual(box.outcome?.deletedCount, 1, "LIST 失败证明不了缺席 → 保留失败")
            assertEqual(box.outcome?.failedNames, ["a.mp4"], "LIST 失败留失败名单")
        }

        // 10) 默认模式不做 LIST 确认（ioError 直接报失败，不额外发 LIST）
        do {
            let engine = InlineEngine()
            engine.ioErrorDeletePaths = ["/Movies/a.mp4"]
            let service = TVFileService(engineProvider: { engine }, endpointProvider: { FTPEndpoint(host: "mock") },
                                        capabilitiesProvider: { caps })
            let box = DeleteBox()
            service.deleteEntries([a, b], progress: { _, _, _ in }) { box.set($0) }
            waitMain("默认 ioError 返回") { box.done }
            assertEqual(box.outcome?.deletedCount, 1, "默认模式 ioError 报失败")
            assertEqual(engine.listCalls, 0, "默认模式不发确认 LIST")
        }

        // 11) 缺席判定大小写不敏感（U 盘 FAT/exFAT）：LIST 里 A.MP4 视为 a.mp4 还在
        do {
            let engine = InlineEngine()
            engine.ioErrorDeletePaths = ["/Movies/a.mp4"]
            engine.dirEntriesByPath["/Movies"] = [FTPFileEntry(path: "/Movies/A.MP4", name: "A.MP4", isDirectory: false, size: 5)]
            let service = TVFileService(engineProvider: { engine }, endpointProvider: { FTPEndpoint(host: "mock") },
                                        capabilitiesProvider: { caps })
            let box = DeleteBox()
            service.deleteEntries([a, b], tolerateMissing: true, progress: { _, _, _ in }) { box.set($0) }
            waitMain("大小写在场补删返回") { box.done }
            assertEqual(box.outcome?.deletedCount, 1, "大小写不敏感：A.MP4 在场 → a.mp4 不算缺席")
            assertEqual(box.outcome?.failedNames, ["a.mp4"], "大小写在场留失败名单")
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

// MARK: - 过期 inflight 快照竞态（clash 判定异步 hop 期间另一项已占位）

extension ServiceTests_B {

    /// 同内容两份拷贝（不同 localPath）+ 远端同尺寸不同内容同名文件：
    /// 两项都走 clash→指纹→远端前缀比对的异步路径，finalizeUploadRouting 时
    /// 互不见对方占位。beginUpload 若沿用 finalize 时的 inflight 快照，
    /// 两项会定出同一个指纹名 → 并发 STOR 同一远端路径。
    static func testStaleInflightRace() {
        print("· 过期 inflight 快照竞态")
        let baseDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mitv-stale-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: baseDir) }
        let subA = baseDir.appendingPathComponent("A"); let subB = baseDir.appendingPathComponent("B")
        try? FileManager.default.createDirectory(at: subA, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: subB, withIntermediateDirectories: true)
        let fa = subA.appendingPathComponent("同名.mp4"); let fb = subB.appendingPathComponent("同名.mp4")
        try? Data(repeating: 0xAA, count: 16).write(to: fa)
        try? Data(repeating: 0xAA, count: 16).write(to: fb) // 内容相同的另一份拷贝

        let caps = Capabilities(utf8Filenames: false, appeResume: true, restResume: false,
                                mkdir: false, deleteFile: true, rename: true, mlsd: false, sizeCommand: true)
        let engine = InlineEngine()
        engine.dirEntries = [
            FTPFileEntry(path: "/Movies", name: "Movies", isDirectory: true),
            FTPFileEntry(path: "/Movies/同名.mp4", name: "同名.mp4", isDirectory: false, size: 16),
        ]
        engine.remotePrefix = Data(repeating: 0xFF, count: 16) // 同尺寸、不同内容 → 前缀比对判「不同」
        engine.prefixDelay = 0.3 // 拉宽窗口：两项都在对方占位前完成 finalize
        let queue = QueueService(engineProvider: { engine }, endpointProvider: { FTPEndpoint(host: "mock") },
                                 capabilitiesProvider: { caps }, persistenceDirectory: baseDir.appendingPathComponent("q"),
                                 concurrency: 2, resumeOnStart: true)
        queue.addUploads([fa, fb])
        waitUntil("两项都完成") { queue.snapshot().filter { $0.phase == .completed }.count == 2 }
        assertEqual(engine.uploadCalls.count, 2, "两份拷贝都实际上传（localPath 不同，不收敛跳过）")
        let p0 = engine.uploadCalls[0].remotePath.lowercased()
        let p1 = engine.uploadCalls[1].remotePath.lowercased()
        assertTrue(p0 != p1, "异步 hop 后定名必须现算 inflight：两项不得并发 STOR 同一远端路径")
        queue.suspendForShutdown()
    }
}

// MARK: - 批次完成回调必须在重试后重新武装（「删除前先下载」续删依赖它）

extension ServiceTests_B {

    /// 整批失败 → 回调一次；重试一项成功（另一项仍失败）→ 批次再次全终态，回调必须再发；
    /// 全部重试成功 → 回调第三次且 bad==0（这是续删的触发点）。
    /// 若 batchNotified 不随重试移除，后两次回调丢失 → 取回成功后删除永远不会执行。
    static func testBatchRetryRearm() {
        print("· 批次完成回调重试后重新武装")
        let baseDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mitv-rearm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: baseDir) }
        let dlDir = baseDir.appendingPathComponent("dl")
        try? FileManager.default.createDirectory(at: dlDir, withIntermediateDirectories: true)
        let caps = Capabilities(utf8Filenames: false, appeResume: true, restResume: false,
                                mkdir: false, deleteFile: true, rename: true, mlsd: false, sizeCommand: true)
        let engine = InlineEngine()
        engine.hangDownloads = true
        let queue = QueueService(engineProvider: { engine }, endpointProvider: { FTPEndpoint(host: "mock") },
                                 capabilitiesProvider: { caps }, persistenceDirectory: baseDir.appendingPathComponent("q"),
                                 concurrency: 2, resumeOnStart: true)
        let lock = NSLock()
        var fires: [(ok: Int, bad: Int)] = []
        queue.onBatchCompleted = { _, ok, bad in lock.lock(); fires.append((ok, bad)); lock.unlock() }
        func fireCount() -> Int { lock.lock(); defer { lock.unlock() }; return fires.count }

        let items = queue.addDownloads([
            FTPFileEntry(path: "/a/x.mp4", name: "x.mp4", isDirectory: false, size: 1),
            FTPFileEntry(path: "/a/y.mp4", name: "y.mp4", isDirectory: false, size: 1),
        ], toDirectory: dlDir)
        assertEqual(items.count, 2, "两项都入队")
        waitUntil("两项起传") { queue.snapshot().filter { $0.phase == .running }.count == 2 }
        engine.releaseAllDownloads(.failure(EngineError.connectionFailed("模拟断线")))
        waitMain("整批失败 → 首次完成回调") { fireCount() == 1 }

        engine.hangDownloads = false
        queue.retry(id: items[0].id)
        waitMain("重试一项成功 → 回调重新武装并再发") { fireCount() == 2 }
        lock.lock(); let second = fires.count > 1 ? fires[1] : (ok: -1, bad: -1); lock.unlock()
        assertEqual(second.ok, 1, "第二次回调：一项成功")
        assertEqual(second.bad, 1, "第二次回调：一项仍失败")

        queue.retry(id: items[1].id)
        waitMain("全部重试成功 → 第三次回调") { fireCount() == 3 }
        lock.lock(); let third = fires.count > 2 ? fires[2] : (ok: -1, bad: -1); lock.unlock()
        assertEqual(third.ok, 2, "第三次回调：两项全部成功")
        assertEqual(third.bad, 0, "bad==0 才会触发续删")
        queue.suspendForShutdown()
    }
}

// MARK: - 存放位置持久化（设计稿 docs/20261119_design_upload_target.md v2 §7）

extension ServiceTests_B {

    static func testUploadTargetPersistence() {
        print("· 存放位置持久化（customUploadDir / recentUploadDirs）")
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mitv-target-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = TVStore(directory: dir)
        assertTrue(store.state.customUploadDir == nil, "初始无指定位置（智能分类）")
        store.setUploadTarget("/电视剧/庆余年2")
        store.recordRecentUploadDir("/电视剧/庆余年2")
        store.recordRecentUploadDir("/电影")
        store.recordRecentUploadDir("/电视剧/庆余年2")

        // 新实例（模拟重启）读回
        let store2 = TVStore(directory: dir)
        assertEqual(store2.state.customUploadDir, "/电视剧/庆余年2", "customUploadDir round-trip")
        assertEqual(store2.state.recentUploadDirs, ["/电视剧/庆余年2", "/电影"], "recentUploadDirs 去重且最新在前")

        // 恢复智能分类：目标清空，最近记录保留
        store.setUploadTarget(nil)
        let store3 = TVStore(directory: dir)
        assertTrue(store3.state.customUploadDir == nil, "恢复智能分类后落盘为 nil")
        assertEqual(store3.state.recentUploadDirs, ["/电视剧/庆余年2", "/电影"], "恢复分类不清最近记录")

        // pushRecentDir 纯逻辑：上限 5、去重、最新在前
        var list: [String]? = nil
        for i in 1...7 { list = TVStore.pushRecentDir(list, "/目录\(i)") }
        assertEqual(list?.count, 5, "最近目录上限 5")
        assertEqual(list?.first, "/目录7", "最新在前")
        assertEqual(list?.last, "/目录3", "最旧的被截断")
        assertEqual(TVStore.pushRecentDir(["/a", "/b"], "/a"), ["/a", "/b"], "重复推入 → 移到最前不堆积")

        // 旧版本 tv.json（无新字段）→ 解码 nil，无感升级（边界场景 #9）
        let legacyJSON = "{\"endpoint\":{\"host\":\"1.2.3.4\",\"port\":2121},\"onboardingDone\":true}".data(using: .utf8)!
        try! legacyJSON.write(to: dir.appendingPathComponent("tv.json"))
        let store4 = TVStore(directory: dir)
        assertTrue(store4.state.customUploadDir == nil, "旧 JSON 缺 customUploadDir → nil")
        assertTrue(store4.state.recentUploadDirs == nil, "旧 JSON 缺 recentUploadDirs → nil")
        assertEqual(store4.endpoint?.host, "1.2.3.4", "旧 JSON 其余字段照常读回")
    }

    static func testQueueItemDirOverrideRoundTrip() {
        print("· 队列项批级目标 dirOverride round-trip")
        var it = QueueItem(direction: .upload, kind: .video, localPath: "/tmp/a.mp4",
                           displayName: "a.mp4", sizeBytes: 100)
        assertTrue(it.dirOverride == nil, "默认无批级目标（跟随全局存放位置/智能分流）")
        it.dirOverride = "/剧集/庆余年2"

        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = (try! dec.decode([QueueItem].self, from: try! enc.encode([it]))).first!
        assertEqual(back.dirOverride, "/剧集/庆余年2", "dirOverride 随 queue.json 持久化（重启恢复不丢批级目标）")

        // 旧版本队列 JSON（无 dirOverride 字段）→ nil
        let legacy = ("[{\"id\":\"x\",\"direction\":\"upload\",\"kind\":\"video\",\"localPath\":\"/tmp/a.mp4\","
            + "\"displayName\":\"a.mp4\",\"sizeBytes\":100,\"phase\":\"queued\",\"bytes\":0,\"bytesPerSecond\":0,"
            + "\"needsNameMapping\":false,\"batchId\":\"b\",\"addedAt\":\"2026-11-19T00:00:00Z\",\"autoPaused\":false}]").data(using: .utf8)!
        let old = (try! dec.decode([QueueItem].self, from: legacy)).first!
        assertTrue(old.dirOverride == nil, "旧 JSON 缺 dirOverride → nil")
    }
}

// MARK: - 定名盲区：异步 hop 期间已完成的兄弟项（inflight 与 dirList 快照都看不见）

extension ServiceTests_B {

    /// 同名不同内容两份、远端无同名（无 clash → 用原名，不走指纹名）：
    /// A 的 LIST/SIZE 快、B 的慢 → A 在 B 的 hop 期间完成。定名若只查
    /// inflight + dirList 快照，B 会原名 STOR 覆盖 A 刚传好的不同内容文件。
    static func testCompletedSiblingBlindSpot() {
        print("· 已完成兄弟项定名盲区")
        let baseDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mitv-sibling-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: baseDir) }
        let subA = baseDir.appendingPathComponent("A"); let subB = baseDir.appendingPathComponent("B")
        try? FileManager.default.createDirectory(at: subA, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: subB, withIntermediateDirectories: true)
        let fa = subA.appendingPathComponent("同名.mp4"); let fb = subB.appendingPathComponent("同名.mp4")
        try? Data(repeating: 0xAA, count: 16).write(to: fa)
        try? Data(repeating: 0xBB, count: 16).write(to: fb) // 不同内容 → 覆盖即丢数据
        let caps = Capabilities(utf8Filenames: false, appeResume: true, restResume: false,
                                mkdir: false, deleteFile: true, rename: true, mlsd: false, sizeCommand: true)
        let movies = FTPFileEntry(path: "/Movies", name: "Movies", isDirectory: true)

        // 1) 主路径：B 的 LIST hop 期间 A 完成
        do {
            let engine = InlineEngine()
            engine.dirEntries = [movies] // 远端无同名 → 无 clash → 原名定名
            engine.listDelays = [0.02, 0.5]
            let queue = QueueService(engineProvider: { engine }, endpointProvider: { FTPEndpoint(host: "mock") },
                                     capabilitiesProvider: { caps }, persistenceDirectory: baseDir.appendingPathComponent("q1"),
                                     concurrency: 2, resumeOnStart: true)
            queue.addUploads([fa, fb])
            waitUntil("两项都完成") { queue.snapshot().filter { $0.phase == .completed }.count == 2 }
            assertEqual(engine.uploadCalls.count, 2, "两项都上传")
            let p0 = engine.uploadCalls[0].remotePath.lowercased()
            let p1 = engine.uploadCalls[1].remotePath.lowercased()
            assertTrue(p0 != p1, "hop 期间完成的兄弟项占名必须可见：不得原名 STOR 覆盖其不同内容文件")
            queue.suspendForShutdown()
        }

        // 2) 降级路径（LIST 全失败 → SIZE hop）：B 的 SIZE hop 期间 A 完成
        do {
            let engine = InlineEngine()
            engine.failAllLists = true
            engine.sizeDelays = [0.02, 0.5]
            let queue = QueueService(engineProvider: { engine }, endpointProvider: { FTPEndpoint(host: "mock") },
                                     capabilitiesProvider: { caps }, persistenceDirectory: baseDir.appendingPathComponent("q2"),
                                     concurrency: 2, resumeOnStart: true)
            queue.addUploads([fa, fb])
            waitUntil("两项降级完成") { queue.snapshot().filter { $0.phase == .completed }.count == 2 }
            assertEqual(engine.uploadCalls.count, 2, "降级两项都上传")
            let p0 = engine.uploadCalls[0].remotePath.lowercased()
            let p1 = engine.uploadCalls[1].remotePath.lowercased()
            assertTrue(p0 != p1, "降级定名同样要查已完成兄弟项占名")
            queue.suspendForShutdown()
        }
    }
}

// MARK: - 指定存放位置上传（设计稿 docs/20261119_design_upload_target.md v2 §6.1 两层解析 + §6.3 失效降级）

extension ServiceTests_B {

    /// 构造：单并发队列 + 注入全局指定目录（AppCoordinator 场景：targetDirProvider 读 TVStore 快照）
    static func makeTargetQueue(_ engine: InlineEngine, _ dir: URL, global: String?) -> QueueService {
        let q = QueueService(engineProvider: { engine }, endpointProvider: { FTPEndpoint(host: "mock") },
                             capabilitiesProvider: { Capabilities() },
                             persistenceDirectory: dir, concurrency: 1, resumeOnStart: true)
        q.targetDirProvider = { global }
        return q
    }

    static func testExplicitTargetDirRouting() {
        print("· 指定存放位置：两层解析与混合批次")
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mitv-expr-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let fv = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mitv-expr-v-\(UUID().uuidString).mp4")
        try! Data(repeating: 1, count: 64).write(to: fv)
        defer { try? FileManager.default.removeItem(at: fv) }
        let fi = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mitv-expr-i-\(UUID().uuidString).jpg")
        try! Data(repeating: 2, count: 64).write(to: fi)
        defer { try? FileManager.default.removeItem(at: fi) }
        let fo = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mitv-expr-o-\(UUID().uuidString).txt")
        try! Data(repeating: 3, count: 64).write(to: fo)
        defer { try? FileManager.default.removeItem(at: fo) }

        // 1) 批级目标（深层目录）直列：跳过根 LIST，落指定目录
        do {
            let engine = InlineEngine()
            let target = "/剧集/庆余年2"
            engine.dirEntriesByPath[target] = []
            let q = makeTargetQueue(engine, base.appendingPathComponent("t1"), global: nil)
            let items = q.addUploads([fv], targetDir: target)
            assertEqual(items.first?.dirOverride, target, "批级目标写入任务项 dirOverride")
            waitUntil("批级目标上传完成") { q.snapshot().first?.phase == .completed }
            assertEqual(engine.uploadCalls.first?.remotePath, target + "/" + fv.lastPathComponent, "深层指定目录直列")
            assertEqual(q.snapshot().first?.remoteDir, target, "卡片目标 = 指定目录")
            assertEqual(engine.listCalls, 1, "只 LIST 一次（直列目标目录，无根 LIST 前置跳）")
        }

        // 2) 全局指定 + 混合批次：视频/图片/其他 全部进同一指定目录（设计稿 §6.2）
        do {
            let engine = InlineEngine()
            let target = "/家庭相册"
            engine.dirEntriesByPath[target] = []
            let q = makeTargetQueue(engine, base.appendingPathComponent("t2"), global: target)
            _ = q.addUploads([fv, fi, fo])
            waitUntil("混合批次全部完成") { q.snapshot().filter { $0.phase == .completed }.count == 3 }
            for it in q.snapshot() {
                assertEqual(it.remoteDir, target, "混合批次全部进指定目录（含 .other）")
            }
            let dirs = Set(engine.uploadCalls.map { ($0.remotePath as NSString).deletingLastPathComponent })
            assertEqual(dirs, Set([target]), "引擎层三个文件同目录")
        }

        // 3) 全局指定根目录：显式「/」= 原名入根
        do {
            let engine = InlineEngine()
            let q = makeTargetQueue(engine, base.appendingPathComponent("t3"), global: "/")
            _ = q.addUploads([fv])
            waitUntil("根目录上传完成") { q.snapshot().first?.phase == .completed }
            assertEqual(engine.uploadCalls.first?.remotePath, "/" + fv.lastPathComponent, "指定根目录 = 原名入根")
            assertEqual(q.snapshot().first?.remoteDir, "/", "卡片显示电视根目录")
        }

        // 4) 批级目标优先于全局指定（两层解析的任务项层覆盖）
        do {
            let engine = InlineEngine()
            let batchTarget = "/批级"
            let globalTarget = "/全局"
            engine.dirEntriesByPath[batchTarget] = []
            engine.dirEntriesByPath[globalTarget] = []
            let q = makeTargetQueue(engine, base.appendingPathComponent("t4"), global: globalTarget)
            _ = q.addUploads([fv], targetDir: batchTarget)
            waitUntil("批级覆盖完成") { q.snapshot().first?.phase == .completed }
            assertEqual(engine.uploadCalls.first?.remotePath, batchTarget + "/" + fv.lastPathComponent, "批级目标优先于全局指定")
        }
    }

    static func testCustomTargetDegradation() {
        print("· 指定目录失效降级（MKD 兜底 / 回根 + 每批一次告知）")
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mitv-deg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let f1 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mitv-deg-a-\(UUID().uuidString).mp4")
        try! Data(repeating: 9, count: 64).write(to: f1)
        defer { try? FileManager.default.removeItem(at: f1) }
        let f2 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mitv-deg-b-\(UUID().uuidString).mp4")
        try! Data(repeating: 8, count: 64).write(to: f2)
        defer { try? FileManager.default.removeItem(at: f2) }

        // 1) 目录消失 + MKD 被拒（真机 550 语义）→ 回根目录 + 每批一次降级告知（D6）
        do {
            let engine = InlineEngine()
            let target = "/没了"
            engine.failListPath = target
            engine.allowMKD = false
            let q = makeTargetQueue(engine, base.appendingPathComponent("d1"), global: nil)
            let lock = NSLock()
            var fallbackDirs: [String] = []
            q.onUploadFallback = { _, dir in lock.lock(); fallbackDirs.append(dir); lock.unlock() }
            _ = q.addUploads([f1, f2], targetDir: target)
            waitUntil("两项降级回根完成") { q.snapshot().filter { $0.phase == .completed }.count == 2 }
            waitMain("降级告知送达主队列") {
                lock.lock(); let c = fallbackDirs.count; lock.unlock(); return c == 1
            }
            assertEqual(fallbackDirs.first, target, "告知携带失效目录")
            for it in q.snapshot() {
                assertEqual(it.remoteDir, "/", "失效目录 → 回根（D6 终点）")
            }
            let dirs = Set(engine.uploadCalls.map { ($0.remotePath as NSString).deletingLastPathComponent })
            assertEqual(dirs, Set(["/"]), "两项实际都落在根目录")
        }

        // 2) 目录消失 + MKD 成功 → 重建后归入指定目录，无降级告知
        do {
            let engine = InlineEngine()
            let target = "/重建"
            engine.listFailCounts = [target: 1] // 首列失败（目录没了）→ MKD 成功 → 再列成功
            engine.allowMKD = true
            let q = makeTargetQueue(engine, base.appendingPathComponent("d2"), global: nil)
            let lock = NSLock()
            var fallbackCount = 0
            q.onUploadFallback = { _, _ in lock.lock(); fallbackCount += 1; lock.unlock() }
            _ = q.addUploads([f1], targetDir: target)
            waitUntil("MKD 重建后完成") { q.snapshot().first?.phase == .completed }
            assertEqual(engine.uploadCalls.first?.remotePath, target + "/" + f1.lastPathComponent, "MKD 重建后归入指定目录")
            waitMain("重建成功不发降级告知") {
                lock.lock(); let c = fallbackCount; lock.unlock(); return c == 0
            }
        }

        // 3) 智能分流回归：未指定时保持现状（视频 → /Movies）
        do {
            let engine = InlineEngine()
            let q = makeTargetQueue(engine, base.appendingPathComponent("d3"), global: nil)
            _ = q.addUploads([f1])
            waitUntil("智能分流完成") { q.snapshot().first?.phase == .completed }
            assertEqual(engine.uploadCalls.first?.remotePath, "/Movies/" + f1.lastPathComponent, "未指定 → 智能分流行为不变")
        }
    }
}
