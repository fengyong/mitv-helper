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

    // SDK 10.15 没有 FileHandle throwing API（10.15.4 才加声明，#available 也编译不过）；
    // 旧 readData/write 在 IO 错误时抛 ObjC 异常，Swift 接不住会崩溃 → 直接 POSIX IO。
    private static func posixRead(_ fd: Int32, into buf: UnsafeMutablePointer<UInt8>, count: Int) throws -> Int {
        while true {
            let n = read(fd, buf, count)
            if n >= 0 { return n }
            if errno == EINTR { continue }
            throw EngineError.ioError("读取本地文件失败（errno \(errno)）")
        }
    }

    private static func posixWrite(_ fd: Int32, from buf: UnsafePointer<UInt8>, count: Int) throws {
        var done = 0
        while done < count {
            let n = write(fd, buf + done, count - done)
            if n > 0 { done += n; continue }
            if n < 0 && errno == EINTR { continue }
            throw EngineError.ioError("写入本地文件失败（errno \(errno)）")
        }
    }

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
                        var readBuf = [UInt8](repeating: 0, count: SwiftFTPEngine.chunkSize)
                        while true {
                            if let h = handle, h.isCanceled { throw EngineError.aborted }
                            let n = try SwiftFTPEngine.posixRead(fh.fileDescriptor, into: &readBuf, count: readBuf.count)
                            if n == 0 { break } // EOF
                            try data.write(Data(readBuf[0..<n]))
                            sent += Int64(n)
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

                let sentBytes: Int64
                if useAppend {
                    do {
                        sentBytes = try transfer(append: true, seekTo: offset)
                    } catch let e as EngineError {
                        guard case .unsupported = e else { throw e }
                        // APPE 不被支持 → 整传兜底（此时尚未发出任何数据，可安全重来）
                        sentBytes = try transfer(append: false, seekTo: 0)
                    }
                } else {
                    sentBytes = try transfer(append: false, seekTo: 0)
                }
                // 上传后校验：SIZE 可用时远端必须与本地一致——防服务端静默截断
                //（FAT32 单文件 4GB 上限/磁盘满/嵌入式服务器怪癖），与下载侧完整性校验对称。
                if let remoteFinal = (try? conn.remoteSize(remote)) ?? nil, remoteFinal != localSize {
                    try? conn.deleteFile(remote) // 尽力清掉坏文件，避免重试 APPE 拼接
                    throw EngineError.ioError("上传校验失败：远端 \(remoteFinal) 字节 ≠ 本地 \(localSize) 字节")
                }
                return sentBytes
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
            // 先写同目录临时文件、成功后原子替换：连接/远端文件出问题时不碰已有本地文件
            //（旧实现先截断已有文件再连接——远端文件已不在时本地旧文件被一并销毁）
            let tmpURL = localURL.deletingLastPathComponent()
                .appendingPathComponent(".mitv-dl-" + UUID().uuidString + ".part")
            guard fm.createFile(atPath: tmpURL.path, contents: nil, attributes: nil),
                  let fh = FileHandle(forWritingAtPath: tmpURL.path) else {
                throw EngineError.ioError("无法创建本地文件：\(localURL.path)")
            }

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
                            try buf.withUnsafeBufferPointer { raw in
                                try SwiftFTPEngine.posixWrite(fh.fileDescriptor, from: raw.baseAddress!, count: n)
                            }
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
                fh.closeFile()
                if fm.fileExists(atPath: localURL.path) {
                    _ = try fm.replaceItemAt(localURL, withItemAt: tmpURL)
                } else {
                    try fm.moveItem(at: tmpURL, to: localURL)
                }
                return bytes
            } catch {
                fh.closeFile()
                // 失败/取消：只清临时文件，已有本地文件原样保留（重试会重新下载）
                try? fm.removeItem(at: tmpURL)
                throw error
            }
        }, completion: completion)
    }

    /// 读远端文件前 maxBytes 字节：RETR 后读够即断（不等到 EOF，226/426 由 QUIT 吸收）
    public func downloadPrefix(_ endpoint: FTPEndpoint, remotePath: String, maxBytes: Int,
                               completion: @escaping (Result<Data, Error>) -> Void) {
        run({ () -> Data in
            return try self.withConnection(endpoint) { conn -> Data in
                let data = try conn.beginTransfer(cmd: "RETR", path: FTPPath.normalize(remotePath))
                do {
                    var acc = [UInt8]()
                    acc.reserveCapacity(maxBytes)
                    var buf = [UInt8](repeating: 0, count: 65536)
                    var remain = maxBytes
                    while remain > 0 {
                        let n = try data.read(&buf, maxCount: min(buf.count, remain))
                        if n == 0 { break } // 文件先于请求长度结束
                        acc.append(contentsOf: buf[0..<n])
                        remain -= n
                    }
                    data.closeNow() // 读够即断：服务器自行终止传输
                    return Data(acc)
                } catch {
                    data.closeNow()
                    throw error
                }
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
