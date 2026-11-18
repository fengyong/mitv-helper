import Foundation

/// 传输引擎协议。实现方：MiTVEngine.SwiftFTPEngine（Agent A）；UI 层 Mock（Agent B）。
///
/// 线程契约（严格遵守）：
/// - 所有方法可在任意线程调用；内部 I/O 在私有后台队列执行
/// - 所有 completion 与 onProgress 回调**统一派发到 DispatchQueue.main**
/// - onProgress 至少每 100ms 一次（可更频繁），结束时必有一次最终进度
///
/// 协议事实约束（实测，勿按 RFC 假设）：
/// - 只用 PASV（EPSV 不支持）；控制通道默认 GBK 编码（探测 utf8Filenames 后可换）
/// - REST 不可用；续传 = SIZE 校验 + APPE 追加
/// - MKD 可能被拒绝；调用方先看 Capabilities
public protocol TransferEngine: AnyObject {
    /// 心跳/连通性检查（NOOP，超时 5s）
    func ping(_ endpoint: FTPEndpoint, completion: @escaping (Error?) -> Void)

    /// 列目录。path 为 "/" 开头的完整路径
    func list(_ endpoint: FTPEndpoint, path: String,
              completion: @escaping (Result<[FTPFileEntry], Error>) -> Void)

    /// 上传。remotePath 是含文件名的完整路径。
    /// resume=true 且远端已存在同名文件时：SIZE 校验后用 APPE 追加剩余部分（服务器不支持则整传）。
    /// 成功时返回远端最终字节数。
    func upload(_ endpoint: FTPEndpoint,
                from localURL: URL,
                to remotePath: String,
                resume: Bool,
                handle: TransferHandle?,
                onProgress: ((TransferProgress) -> Void)?,
                completion: @escaping (Result<Int64, Error>) -> Void)

    /// 下载到本地 URL（父目录需已存在）。成功返回写入字节数。
    func download(_ endpoint: FTPEndpoint,
                  remotePath: String,
                  to localURL: URL,
                  handle: TransferHandle?,
                  onProgress: ((TransferProgress) -> Void)?,
                  completion: @escaping (Result<Int64, Error>) -> Void)

    /// 删除远程文件（DELE）
    func delete(_ endpoint: FTPEndpoint, remotePath: String, completion: @escaping (Error?) -> Void)

    /// 远程改名/移动（RNFR+RNTO），from/to 均为完整路径
    func move(_ endpoint: FTPEndpoint, from: String, to: String, completion: @escaping (Error?) -> Void)

    /// 建目录（MKD）
    func makeDirectory(_ endpoint: FTPEndpoint, path: String, completion: @escaping (Error?) -> Void)

    /// 远程文件大小；目录或不存在返回 nil（不视为错误）
    func size(_ endpoint: FTPEndpoint, remotePath: String,
              completion: @escaping (Result<Int64?, Error>) -> Void)

    /// 首连能力探测（GBK/UTF-8 文件名、APPE、REST、MKD、DELE、RNTO、MLSD、SIZE）。
    /// 探测产生的临时测试文件/目录必须清理干净；探测目录为远端根。
    func probeCapabilities(_ endpoint: FTPEndpoint,
                           completion: @escaping (Result<Capabilities, Error>) -> Void)
}

/// 引擎工厂。UI/服务层通过它获取实现（生产=SwiftFTPEngine，测试=Mock），便于注入。
public protocol TransferEngineFactory: AnyObject {
    func makeEngine() -> TransferEngine
}
