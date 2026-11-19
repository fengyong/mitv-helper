import Foundation

/// Mock 传输引擎：内存目录树 + 假进度，让 App 在没有真实电视时完整可走通。
/// 线程契约与真实引擎一致：所有 completion / onProgress 派发到主队列。
/// 可脚本化：
///   - uploadSpeedBytesPerSec / failNextUploadCount / failNextPingCount
///   - probeMatrix 默认按实测矩阵（GBK 名称 / APPE 有 / REST 无 / MKD 无 / DELE 有 / RNTO 有 / MLSD 无 / SIZE 有）
final class MockEngine: TransferEngine {

    // MARK: - 内存目录树

    final class Node {
        var name: String
        var isDirectory: Bool
        var size: Int64
        var children: [Node] = []
        weak var parent: Node?
        /// 真实上传来源（downloadPrefix 读前缀字节做「相同文件」判定用；预置树节点为 nil）
        var sourceLocalPath: String?
        init(name: String, isDirectory: Bool, size: Int64 = 0) {
            self.name = name
            self.isDirectory = isDirectory
            self.size = size
        }
    }

    // MARK: - 可脚本化参数

    var uploadSpeedBytesPerSec: Double = {
        let mb = UserDefaults.standard.double(forKey: "mockSpeedMBps")
        return (mb > 0 ? mb : 4) * 1024 * 1024
    }()
    /// 随后的 N 次 upload 以连接错误收场（测重试/黄条）
    var failNextUploadCount = 0
    /// 随后的 N 次 ping 失败（测断线黄条与退避）
    var failNextPingCount = 0
    /// 命令仿真延迟（秒）
    var latency: TimeInterval = 0.12
    var probeMatrix = Capabilities(utf8Filenames: false, appeResume: true, restResume: false,
                                   mkdir: false, deleteFile: true, rename: true,
                                   mlsd: false, sizeCommand: true)

    // MARK: - 状态

    private let lock = NSLock()
    private let root: Node
    private var probeUsed = false
    private var timers: [DispatchSourceTimer] = []

    init() {
        root = Node(name: "/", isDirectory: true)
        MockEngine.seedDefaultTree(into: root)
    }

    static func seedDefaultTree(into root: Node) {
        func add(_ parent: Node, _ name: String, isDir: Bool, size: Int64 = 0) -> Node {
            let n = Node(name: name, isDirectory: isDir, size: size)
            n.parent = parent
            parent.children.append(n)
            return n
        }
        // 隐藏系统项（验证 BrowseFilter 对 UI 生效）
        _ = add(root, ".fseventsd", isDir: true)
        _ = add(root, "System Volume Information", isDir: true)
        _ = add(root, "$RECYCLE.BIN", isDir: true)
        let movies = add(root, "Movies", isDir: true)
        _ = add(movies, "周岁生日宴.mp4", isDir: false, size: 812_000_000)
        _ = add(movies, "毕业旅行 Vlog.mp4", isDir: false, size: 1_280_000_000)
        let pictures = add(root, "Pictures", isDir: true)
        _ = add(pictures, "海边 IMG_2043.jpg", isDir: false, size: 3_400_000)
        _ = add(pictures, "全家福 2026.jpg", isDir: false, size: 5_200_000)
        _ = add(pictures, "天空[特写].png", isDir: false, size: 2_100_000)
        _ = add(root, "家庭相册 2026.jpg", isDir: false, size: 4_800_000)
        _ = add(root, "使用说明.txt", isDir: false, size: 1_024)
    }

    func resetTree() {
        lock.lock()
        root.children.removeAll()
        MockEngine.seedDefaultTree(into: root)
        lock.unlock()
    }

    // MARK: - 路径定位

    private func find(_ path: String) -> Node? {
        let comps = path.split(separator: "/").map(String.init)
        var node = root
        for c in comps {
            guard node.isDirectory,
                  let next = node.children.first(where: { $0.name == c }) else { return nil }
            node = next
        }
        return node
    }

    private func entry(for node: Node, parentPath: String) -> FTPFileEntry {
        let path = parentPath == "/" ? "/" + node.name : parentPath + "/" + node.name
        return FTPFileEntry(path: path, name: node.name, isDirectory: node.isDirectory,
                            size: node.isDirectory ? nil : node.size)
    }

    // MARK: - TransferEngine

    func ping(_ endpoint: FTPEndpoint, completion: @escaping (Error?) -> Void) {
        after(latency) {
            self.lock.lock()
            var fail = false
            if self.failNextPingCount > 0 { self.failNextPingCount -= 1; fail = true }
            self.lock.unlock()
            completion(fail ? EngineError.connectionFailed("模拟断线") : nil)
        }
    }

    func list(_ endpoint: FTPEndpoint, path: String,
              completion: @escaping (Result<[FTPFileEntry], Error>) -> Void) {
        after(latency) {
            self.lock.lock()
            defer { self.lock.unlock() }
            guard let node = self.find(path), node.isDirectory else {
                completion(.failure(EngineError.remoteNotFound(path)))
                return
            }
            let entries = node.children.map { self.entry(for: $0, parentPath: path) }
            completion(.success(entries))
        }
    }

    func upload(_ endpoint: FTPEndpoint, from localURL: URL, to remotePath: String,
                resume: Bool, handle: TransferHandle?, onProgress: ((TransferProgress) -> Void)?,
                completion: @escaping (Result<Int64, Error>) -> Void) {
        let fm = FileManager.default
        guard let attr = try? fm.attributesOfItem(atPath: localURL.path), let total = (attr[.size] as? NSNumber)?.int64Value else {
            DispatchQueue.main.async { completion(.failure(EngineError.ioError("本地文件不可读：\(localURL.lastPathComponent)"))) }
            return
        }
        after(latency) {
            self.lock.lock()
            var fail = false
            if self.failNextUploadCount > 0 { self.failNextUploadCount -= 1; fail = true }
            // resume：远端已有同名 → 从其大小续传（SIZE + APPE）
            var startOffset: Int64 = 0
            if resume, let parent = self.findParent(remotePath),
               let existing = parent.children.first(where: { !$0.isDirectory && $0.name == (remotePath as NSString).lastPathComponent }) {
                if existing.size > 0 && existing.size < total { startOffset = existing.size }
                else if existing.size >= total { existing.parent?.children.removeAll { $0 === existing } }
            }
            self.lock.unlock()

            if fail {
                DispatchQueue.main.async { completion(.failure(EngineError.connectionFailed("模拟断线"))) }
                return
            }
            self.simulateTransfer(totalBytes: total, startBytes: startOffset,
                                  handle: handle, onProgress: onProgress) { result in
                switch result {
                case .success:
                    self.lock.lock()
                    self.placeFile(at: remotePath, size: total, source: localURL.path)
                    self.lock.unlock()
                    DispatchQueue.main.async { completion(.success(total)) }
                case .failure(let e):
                    DispatchQueue.main.async { completion(.failure(e)) }
                }
            }
        }
    }

    func download(_ endpoint: FTPEndpoint, remotePath: String, to localURL: URL,
                  handle: TransferHandle?, onProgress: ((TransferProgress) -> Void)?,
                  completion: @escaping (Result<Int64, Error>) -> Void) {
        after(latency) {
            self.lock.lock()
            let node = self.find(remotePath)
            let isFile = node?.isDirectory == false
            let size = node?.size ?? 0
            self.lock.unlock()
            guard isFile else {
                DispatchQueue.main.async { completion(.failure(EngineError.remoteNotFound(remotePath))) }
                return
            }
            // Mock：立即写盘（内容为可重复的伪随机块），一次最终进度
            let data = MockEngine.sampleData(size: Int(min(size, 64 * 1024 * 1024)), seed: abs(remotePath.hashValue))
            do {
                if size <= 64 * 1024 * 1024 {
                    try data.write(to: localURL)
                } else {
                    try data.write(to: localURL) // Mock 树中文件不超此限
                }
            } catch {
                DispatchQueue.main.async { completion(.failure(EngineError.ioError(error.localizedDescription))) }
                return
            }
            DispatchQueue.main.async {
                onProgress?(TransferProgress(bytes: size, totalBytes: size, bytesPerSecond: 0))
            }
            DispatchQueue.main.async { completion(.success(size)) }
        }
    }

    func delete(_ endpoint: FTPEndpoint, remotePath: String, completion: @escaping (Error?) -> Void) {
        after(latency) {
            self.lock.lock()
            defer { self.lock.unlock() }
            guard let node = self.find(remotePath), !node.isDirectory, node.parent != nil else {
                DispatchQueue.main.async { completion(EngineError.remoteNotFound(remotePath)) }
                return
            }
            node.parent?.children.removeAll { $0 === node }
            DispatchQueue.main.async { completion(nil) }
        }
    }

    func move(_ endpoint: FTPEndpoint, from: String, to: String, completion: @escaping (Error?) -> Void) {
        after(latency) {
            self.lock.lock()
            defer { self.lock.unlock() }
            guard let node = self.find(from), node.parent != nil else {
                DispatchQueue.main.async { completion(EngineError.remoteNotFound(from)) }
                return
            }
            guard let toParent = self.findParent(to) else {
                DispatchQueue.main.async { completion(EngineError.remoteNotFound(to)) }
                return
            }
            node.parent?.children.removeAll { $0 === node }
            node.name = (to as NSString).lastPathComponent
            node.parent = toParent
            toParent.children.append(node)
            DispatchQueue.main.async { completion(nil) }
        }
    }

    func makeDirectory(_ endpoint: FTPEndpoint, path: String, completion: @escaping (Error?) -> Void) {
        after(latency) {
            // 实测矩阵：MKD 550 不可用
            DispatchQueue.main.async { completion(EngineError.unsupported("建目录")) }
        }
    }

    func size(_ endpoint: FTPEndpoint, remotePath: String,
              completion: @escaping (Result<Int64?, Error>) -> Void) {
        after(latency) {
            self.lock.lock()
            let node = self.find(remotePath)
            let s = (node?.isDirectory == false) ? node!.size : nil
            self.lock.unlock()
            DispatchQueue.main.async { completion(.success(s)) }
        }
    }

    func probeCapabilities(_ endpoint: FTPEndpoint,
                           completion: @escaping (Result<Capabilities, Error>) -> Void) {
        after(0.4) {
            self.lock.lock()
            self.probeUsed = true
            let matrix = self.probeMatrix
            self.lock.unlock()
            DispatchQueue.main.async { completion(.success(matrix)) }
        }
    }

    // MARK: - 假进度传输

    private func simulateTransfer(totalBytes: Int64, startBytes: Int64, handle: TransferHandle?,
                                  onProgress: ((TransferProgress) -> Void)?,
                                  completion: @escaping (Result<Void, Error>) -> Void) {
        let speed = max(1, uploadSpeedBytesPerSec)
        var bytes = startBytes
        let queue = DispatchQueue(label: "mitv.mock.transfer")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        lock.lock()
        timers.append(timer)
        lock.unlock()
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak self] in
            guard self != nil else { return }
            if let h = handle, h.isCanceled {
                timer.cancel()
                DispatchQueue.main.async {
                    onProgress?(TransferProgress(bytes: bytes, totalBytes: totalBytes, bytesPerSecond: 0))
                    completion(.failure(EngineError.aborted))
                }
                return
            }
            bytes = min(totalBytes, bytes + Int64(speed * 0.1))
            let bps = (bytes >= totalBytes) ? 0 : speed
            DispatchQueue.main.async {
                onProgress?(TransferProgress(bytes: bytes, totalBytes: totalBytes, bytesPerSecond: bps))
            }
            if bytes >= totalBytes {
                timer.cancel()
                DispatchQueue.main.async {
                    onProgress?(TransferProgress(bytes: totalBytes, totalBytes: totalBytes, bytesPerSecond: 0))
                    completion(.success(()))
                }
            }
        }
        timer.resume()
    }

    // MARK: - 工具

    private func findParent(_ path: String) -> Node? {
        let dir = (path as NSString).deletingLastPathComponent
        return find(dir.isEmpty ? "/" : dir)
    }

    private func placeFile(at path: String, size: Int64, source: String? = nil) {
        guard let parent = findParent(path) else { return }
        let name = (path as NSString).lastPathComponent
        if let existing = parent.children.first(where: { !$0.isDirectory && $0.name == name }) {
            existing.size = size
            existing.sourceLocalPath = source ?? existing.sourceLocalPath
        } else {
            let n = Node(name: name, isDirectory: false, size: size)
            n.sourceLocalPath = source
            n.parent = parent
            parent.children.append(n)
        }
    }

    /// 读「远端」文件前 maxBytes 字节：真实上传的节点读其本地源文件（同文件判定在 Mock 下也成立）；
    /// 预置树节点回退到确定性伪随机样例数据
    func downloadPrefix(_ endpoint: FTPEndpoint, remotePath: String, maxBytes: Int,
                        completion: @escaping (Result<Data, Error>) -> Void) {
        after(latency) {
            self.lock.lock()
            let node = self.find(remotePath)
            let isFile = node?.isDirectory == false
            let size = node?.size ?? 0
            let source = node?.sourceLocalPath
            self.lock.unlock()
            guard isFile else {
                DispatchQueue.main.async { completion(.failure(EngineError.remoteNotFound(remotePath))) }
                return
            }
            let want = Int(min(Int64(max(0, maxBytes)), size))
            let data: Data?
            if let src = source {
                data = FileDigest.readPrefix(at: URL(fileURLWithPath: src), maxBytes: Int64(want))
            } else {
                data = MockEngine.sampleData(size: want, seed: abs(remotePath.hashValue))
            }
            DispatchQueue.main.async {
                if let d = data { completion(.success(d)) }
                else { completion(.failure(EngineError.ioError("本地文件不可读：\(source ?? remotePath)"))) }
            }
        }
    }

    private func after(_ seconds: TimeInterval, _ block: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds, execute: block)
    }

    /// 确定性伪随机样例数据（下载落盘用）
    static func sampleData(size: Int, seed: Int) -> Data {
        var data = Data(count: size)
        if size > 0 {
            var s = UInt64(bitPattern: Int64(seed == 0 ? 88172645463325252 : seed))
            data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
                let p = raw.bindMemory(to: UInt8.self)
                var i = 0
                while i < size {
                    s = s &* 6364136223846793005 &+ 1442695040888963407
                    let chunk = min(8, size - i)
                    for j in 0..<chunk where i + j < size {
                        p[i + j] = UInt8(truncatingIfNeeded: s >> UInt64(8 * j))
                    }
                    i += 8
                }
            }
        }
        return data
    }
}

/// 默认工厂：App 默认走 Mock（UserDefaults `useMockEngine`，默认 true），主控集成时切真实引擎。
final class MockEngineFactory: TransferEngineFactory {
    func makeEngine() -> TransferEngine { MockEngineHolder.shared.engine }
}

/// 单例持有（多个服务共享同一棵内存树）
final class MockEngineHolder {
    static let shared = MockEngineHolder()
    let engine = MockEngine()
}

/// 真实引擎工厂（主控集成用：UserDefaults `useMockEngine=false` 时生效）
final class ProductionEngineFactory: TransferEngineFactory {
    func makeEngine() -> TransferEngine { SwiftFTPEngine() }
}

/// 引擎持有者：App 默认走 Mock；设置里切换后立即生效（新连接用新引擎）。
final class EngineHolder {
    static let shared = EngineHolder()
    private let lock = NSLock()
    private var current: TransferEngine

    private init() {
        UserDefaults.standard.register(defaults: ["useMockEngine": false])
        current = EngineHolder.makeForCurrentSetting()
    }

    static func makeForCurrentSetting() -> TransferEngine {
        let mock = UserDefaults.standard.bool(forKey: "useMockEngine")
        FileHandle.standardError.write(Data("[diag] engine factory: \(mock ? "MOCK" : "PRODUCTION")\n".utf8))
        return mock ? MockEngineHolder.shared.engine : ProductionEngineFactory().makeEngine()
    }

    func engine() -> TransferEngine {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    var isMock: Bool {
        UserDefaults.standard.bool(forKey: "useMockEngine")
    }

    func switchTo(mock: Bool) {
        UserDefaults.standard.set(mock, forKey: "useMockEngine")
        lock.lock()
        current = EngineHolder.makeForCurrentSetting()
        lock.unlock()
    }
}
