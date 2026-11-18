import Foundation

/// 真实 FTP 传输引擎（POSIX socket + 阻塞 I/O + 后台队列）。
///
/// 协议事实约束（实测，见 ARCHITECTURE §2）：
/// - 只用 PASV（EPSV 不支持）；控制通道与文件名默认严格 GBK，仅探测 utf8Filenames 通过才切 UTF-8
/// - REST 不可用（502）→ 续传 = SIZE 校验 + APPE 追加
/// - MKD 可能被拒（550）→ 调用方先看 Capabilities
///
/// 线程契约：I/O 在私有后台并发队列；completion 与 onProgress 一律派发主队列；
/// progress 节流 ≥100ms 且成功结束时必有最终进度。
/// 连接模型：每次调用自建控制连接、用完 QUIT（断线重连属服务层）。
public final class SwiftFTPEngine: TransferEngine {
    public init() {}

    private let ioQueue = DispatchQueue(label: "mitv.engine.io", qos: .userInitiated, attributes: .concurrent)

    // MARK: - 通用执行壳

    private func run<T>(_ job: @escaping () throws -> T,
                        completion: @escaping (Result<T, Error>) -> Void) {
        ioQueue.async {
            let result: Result<T, Error>
            do { result = .success(try job()) }
            catch { result = .failure(error) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// 每次调用自建连接、干净失败
    private func withConnection<T>(_ endpoint: FTPEndpoint,
                                   config: FTPControlConnection.Config = .init(),
                                   body: (FTPControlConnection) throws -> T) throws -> T {
        let conn = FTPControlConnection(endpoint: endpoint, config: config)
        do {
            try conn.connectAndLogin()
            let r = try body(conn)
            conn.quit()
            return r
        } catch {
            conn.quit()
            throw error
        }
    }

    private static let chunkSize = 262144 // 256KB

    /// Swift 5.1 的 Result 没有 .error 属性——统一从这里取
    private static func failure<T>(_ result: Result<T, Error>) -> Error? {
        if case .failure(let e) = result { return e }
        return nil
    }

    // MARK: - TransferEngine

    public func ping(_ endpoint: FTPEndpoint, completion: @escaping (Error?) -> Void) {
        run({ () -> Void in
            var cfg = FTPControlConnection.Config()
            cfg.connectTimeout = 5
            cfg.ioTimeout = 5 // 心跳契约：5s 超时
            try self.withConnection(endpoint, config: cfg) { conn in
                try conn.noop()
            }
        }, completion: { result in
            completion(SwiftFTPEngine.failure(result))
        })
    }

    public func list(_ endpoint: FTPEndpoint, path: String,
                     completion: @escaping (Result<[FTPFileEntry], Error>) -> Void) {
        run({ () -> [FTPFileEntry] in
            let parent = FTPPath.normalize(path)
            return try self.withConnection(endpoint) { conn in
                // MLSD 优先（机器可读、含精确 size/mtime），失败回退 LIST 兜底
                if let lines = (try? conn.retrieveListing(cmd: "MLSD", path: parent)) ?? nil {
                    return FTPMLSDParser.parse(lines, parentPath: parent)
                }
                let lines = try conn.retrieveListing(cmd: "LIST", path: parent)
                return FTPListParser.parse(lines, parentPath: parent)
            }
        }, completion: completion)
    }

    public func upload(_ endpoint: FTPEndpoint, from localURL: URL, to remotePath: String,
                       resume: Bool, handle: TransferHandle?,
                       onProgress: ((TransferProgress) -> Void)?,
                       completion: @escaping (Result<Int64, Error>) -> Void) {
        run({ () -> Int64 in
            if let h = handle, h.isCanceled { throw EngineError.aborted }

            let fm = FileManager.default
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: localURL.path, isDirectory: &isDir), !isDir.boolValue else {
                throw EngineError.ioError("本地文件不存在：\(localURL.path)")
            }
            guard let attrs = try? fm.attributesOfItem(atPath: localURL.path),
                  let localSize = (attrs[.size] as? NSNumber)?.int64Value else {
                throw EngineError.ioError("无法读取本地文件大小：\(localURL.path)")
            }

            let remote = FTPPath.normalize(remotePath)
            return try self.withConnection(endpoint) { conn in
                guard let fh = FileHandle(forReadingAtPath: localURL.path) else {
                    throw EngineError.ioError("无法打开本地文件：\(localURL.path)")
                }
                defer { fh.closeFile() }

                // 续传规划（resume=true）：SIZE 校验 + APPE 追加；远端不存在/更大/SIZE 不支持 → 整传
                var useAppend = false
                var offset: Int64 = 0
                if resume {
                    let rs: Int64? = (try? conn.remoteSize(remote)) ?? nil
                    if let planned = FTPTransferPlanner.resumeOffset(remoteSize: rs ?? 0, localSize: localSize) {
                        offset = planned
                        useAppend = true
                    }
                }

                // 进度（节流 ≥100ms；结束时强制一次最终进度）
                var sent: Int64 = 0
                let throttler = FTPProgressThrottler(minInterval: 0.1)
                var lastSampleTime = CFAbsoluteTimeGetCurrent()
                var lastSampleBytes: Int64 = 0
                var speed: Double = 0

                func emit(force: Bool) {
                    let now = CFAbsoluteTimeGetCurrent()
                    guard force || throttler.shouldEmit(now: now) else { return }
                    let dt = now - lastSampleTime
                    if dt > 0.05 {
                        let inst = Double(sent - lastSampleBytes) / dt
                        speed = speed <= 0 ? inst : speed * 0.6 + inst * 0.4 // 平滑
                        lastSampleTime = now
                        lastSampleBytes = sent
                    }
                    if let cb = onProgress {
                        let p = TransferProgress(bytes: sent, totalBytes: localSize, bytesPerSecond: speed)
                        DispatchQueue.main.async { cb(p) } // 线程契约：主队列
                    }
                }

                func transfer(append: Bool, seekTo: Int64) throws -> Int64 {
                    fh.seek(toFileOffset: UInt64(max(0, seekTo)))
                    sent = max(0, seekTo)
                    lastSampleTime = CFAbsoluteTimeGetCurrent()
                    lastSampleBytes = sent
                    speed = 0
                    let data = try conn.beginTransfer(cmd: append ? "APPE" : "STOR", path: remote)
                    do {
                        while true {
                            if let h = handle, h.isCanceled { throw EngineError.aborted }
                            let chunk = fh.readData(ofLength: SwiftFTPEngine.chunkSize)
                            if chunk.isEmpty { break }
                            try data.write(chunk)
                            sent += Int64(chunk.count)
                            emit(force: false)
                        }
                        data.shutdownWrite() // FIN：通知服务器数据发完
                        try conn.finishTransfer()
                        data.closeNow()
                        emit(force: true)
                        return sent
                    } catch {
                        data.closeNow() // 取消/出错：断数据连接，服务器自行终止传输
                        throw error
                    }
                }

                if useAppend {
                    do {
                        return try transfer(append: true, seekTo: offset)
                    } catch let e as EngineError {
                        guard case .unsupported = e else { throw e }
                        // APPE 不被支持 → 整传兜底（此时尚未发出任何数据，可安全重来）
                        return try transfer(append: false, seekTo: 0)
                    }
                }
                return try transfer(append: false, seekTo: 0)
            }
        }, completion: completion)
    }

    public func download(_ endpoint: FTPEndpoint, remotePath: String, to localURL: URL,
                         handle: TransferHandle?, onProgress: ((TransferProgress) -> Void)?,
                         completion: @escaping (Result<Int64, Error>) -> Void) {
        run({ () -> Int64 in
            if let h = handle, h.isCanceled { throw EngineError.aborted }

            let remote = FTPPath.normalize(remotePath)
            let fm = FileManager.default
            if !fm.createFile(atPath: localURL.path, contents: nil, attributes: nil) {
                throw EngineError.ioError("无法创建本地文件：\(localURL.path)")
            }
            guard let fh = FileHandle(forWritingAtPath: localURL.path) else {
                throw EngineError.ioError("无法打开本地文件：\(localURL.path)")
            }
            defer { fh.closeFile() }
            fh.truncateFile(atOffset: 0) // 覆盖式下载

            do {
                let bytes = try self.withConnection(endpoint) { conn -> Int64 in
                    let rs: Int64? = (try? conn.remoteSize(remote)) ?? nil
                    let total: Int64 = rs ?? -1 // SIZE 拿不到 → 未知

                    var received: Int64 = 0
                    let throttler = FTPProgressThrottler(minInterval: 0.1)
                    var lastSampleTime = CFAbsoluteTimeGetCurrent()
                    var lastSampleBytes: Int64 = 0
                    var speed: Double = 0

                    func emit(force: Bool) {
                        let now = CFAbsoluteTimeGetCurrent()
                        guard force || throttler.shouldEmit(now: now) else { return }
                        let dt = now - lastSampleTime
                        if dt > 0.05 {
                            let inst = Double(received - lastSampleBytes) / dt
                            speed = speed <= 0 ? inst : speed * 0.6 + inst * 0.4
                            lastSampleTime = now
                            lastSampleBytes = received
                        }
                        if let cb = onProgress {
                            let p = TransferProgress(bytes: received, totalBytes: total, bytesPerSecond: speed)
                            DispatchQueue.main.async { cb(p) }
                        }
                    }

                    let data = try conn.beginTransfer(cmd: "RETR", path: remote)
                    do {
                        var buf = [UInt8](repeating: 0, count: SwiftFTPEngine.chunkSize)
                        while true {
                            if let h = handle, h.isCanceled { throw EngineError.aborted }
                            let n = try data.read(&buf, maxCount: buf.count)
                            if n == 0 { break } // 服务器 EOF = 数据收完
                            fh.write(Data(buf[0..<n]))
                            received += Int64(n)
                            emit(force: false)
                        }
                        data.closeNow()
                        // 完整性校验：SIZE 已知时字节数必须吻合——防服务器提前断流把半截文件当成功
                        if total >= 0, received != total {
                            throw EngineError.ioError("下载不完整：应收 \(total) 字节，实收 \(received) 字节")
                        }
                        try conn.finishTransfer()
                        emit(force: true)
                        return received
                    } catch {
                        data.closeNow()
                        throw error
                    }
                }
                return bytes
            } catch {
                // 失败/取消：清掉半截本地文件（重试会重新创建）
                try? fm.removeItem(at: localURL)
                throw error
            }
        }, completion: completion)
    }

    public func delete(_ endpoint: FTPEndpoint, remotePath: String, completion: @escaping (Error?) -> Void) {
        run({ () -> Void in
            try self.withConnection(endpoint) { conn in
                try conn.deleteFile(FTPPath.normalize(remotePath))
            }
        }, completion: { result in
            completion(SwiftFTPEngine.failure(result))
        })
    }

    public func move(_ endpoint: FTPEndpoint, from: String, to: String, completion: @escaping (Error?) -> Void) {
        run({ () -> Void in
            try self.withConnection(endpoint) { conn in
                try conn.rename(from: FTPPath.normalize(from), to: FTPPath.normalize(to))
            }
        }, completion: { result in
            completion(SwiftFTPEngine.failure(result))
        })
    }

    public func makeDirectory(_ endpoint: FTPEndpoint, path: String, completion: @escaping (Error?) -> Void) {
        run({ () -> Void in
            try self.withConnection(endpoint) { conn in
                try conn.makeDirectory(FTPPath.normalize(path))
            }
        }, completion: { result in
            completion(SwiftFTPEngine.failure(result))
        })
    }

    public func size(_ endpoint: FTPEndpoint, remotePath: String,
                     completion: @escaping (Result<Int64?, Error>) -> Void) {
        run({ () -> Int64? in
            try self.withConnection(endpoint) { conn in
                try conn.remoteSize(FTPPath.normalize(remotePath))
            }
        }, completion: completion)
    }

    public func probeCapabilities(_ endpoint: FTPEndpoint,
                                  completion: @escaping (Result<Capabilities, Error>) -> Void) {
        run({ () -> Capabilities in
            try self.withConnection(endpoint) { conn in
                try CapabilityProbe.run(conn: conn)
            }
        }, completion: completion)
    }
}
