import Foundation

// 骨架 stub：由引擎 Agent（Agent A）替换为真实实现。
// 设计要点见 docs/ARCHITECTURE.md §Agent A。线程契约：所有回调派发到主队列。
public final class SwiftFTPEngine: TransferEngine {
    public init() {}

    private func notImplemented() -> Error { EngineError.unsupported("引擎尚未实现（stub）") }

    public func ping(_ endpoint: FTPEndpoint, completion: @escaping (Error?) -> Void) {
        DispatchQueue.main.async { completion(self.notImplemented()) }
    }

    public func list(_ endpoint: FTPEndpoint, path: String,
                     completion: @escaping (Result<[FTPFileEntry], Error>) -> Void) {
        DispatchQueue.main.async { completion(.failure(self.notImplemented())) }
    }

    public func upload(_ endpoint: FTPEndpoint, from localURL: URL, to remotePath: String,
                       resume: Bool, handle: TransferHandle?,
                       onProgress: ((TransferProgress) -> Void)?,
                       completion: @escaping (Result<Int64, Error>) -> Void) {
        DispatchQueue.main.async { completion(.failure(self.notImplemented())) }
    }

    public func download(_ endpoint: FTPEndpoint, remotePath: String, to localURL: URL,
                         handle: TransferHandle?, onProgress: ((TransferProgress) -> Void)?,
                         completion: @escaping (Result<Int64, Error>) -> Void) {
        DispatchQueue.main.async { completion(.failure(self.notImplemented())) }
    }

    public func delete(_ endpoint: FTPEndpoint, remotePath: String, completion: @escaping (Error?) -> Void) {
        DispatchQueue.main.async { completion(self.notImplemented()) }
    }

    public func move(_ endpoint: FTPEndpoint, from: String, to: String, completion: @escaping (Error?) -> Void) {
        DispatchQueue.main.async { completion(self.notImplemented()) }
    }

    public func makeDirectory(_ endpoint: FTPEndpoint, path: String, completion: @escaping (Error?) -> Void) {
        DispatchQueue.main.async { completion(self.notImplemented()) }
    }

    public func size(_ endpoint: FTPEndpoint, remotePath: String,
                     completion: @escaping (Result<Int64?, Error>) -> Void) {
        DispatchQueue.main.async { completion(.failure(self.notImplemented())) }
    }

    public func probeCapabilities(_ endpoint: FTPEndpoint,
                                  completion: @escaping (Result<Capabilities, Error>) -> Void) {
        DispatchQueue.main.async { completion(.failure(self.notImplemented())) }
    }
}
