import Foundation

// MARK: - 连接端点

/// 电视 FTP 端点（持久化到 ~/Library/Application Support/MiTVHelper/）
public struct FTPEndpoint: Codable, Equatable, Hashable {
    public var host: String
    public var port: Int
    public var user: String?
    public var password: String?

    public init(host: String, port: Int = 2121, user: String? = nil, password: String? = nil) {
        self.host = host
        self.port = port
        self.user = user
        self.password = password
    }

    /// 界面展示用，零术语原则：显示为 "192.168.31.171:2121"
    public var display: String { "\(host):\(port)" }
}

// MARK: - 远程文件条目

/// 远程（电视 U 盘）文件条目。name 是解码后的显示名；path 是发送命令用的原始路径。
public struct FTPFileEntry: Identifiable, Equatable {
    /// 完整远程路径，如 "/Movies/a.mp4"
    public var path: String
    /// 显示名（已按编码规则解码）
    public var name: String
    public var isDirectory: Bool
    public var size: Int64?
    public var modified: Date?

    public init(path: String, name: String, isDirectory: Bool, size: Int64? = nil, modified: Date? = nil) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
    }

    public var id: String { path }
}

// MARK: - 传输进度与状态

public struct TransferProgress: Equatable {
    /// 已确认字节（断线重连后 = 远端已写入字节数）
    public var bytes: Int64
    /// 总字节；-1 表示未知
    public var totalBytes: Int64
    public var bytesPerSecond: Double

    public init(bytes: Int64, totalBytes: Int64, bytesPerSecond: Double = 0) {
        self.bytes = bytes
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
    }

    public var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(bytes) / Double(totalBytes))
    }
}

/// 单个传输任务的阶段（UI 状态机）
public enum TransferPhase: Equatable {
    case queued
    case connecting
    case running
    case paused
    case failed(String)
    case completed
    case canceled
}

// MARK: - 电视能力矩阵（首连探测结果，缓存）

public struct Capabilities: Equatable, Codable {
    /// 控制通道/文件名能否用 UTF-8；false 时必须用 GBK
    public var utf8Filenames: Bool
    /// APPE 追加可用（实测 SwiFTP 为 true）
    public var appeResume: Bool
    /// REST 偏移续传（实测 SwiFTP 502 为 false）
    public var restResume: Bool
    /// MKD 建目录（实测 550 为 false）
    public var mkdir: Bool
    /// DELE 删除文件（未实测，运行时探测）
    public var deleteFile: Bool
    /// RNFR/RNTO 改名，含跨目录（未实测；软删除依赖它）
    public var rename: Bool
    /// MLSD 目录列表（LIST 兜底）
    public var mlsd: Bool
    /// SIZE 命令
    public var sizeCommand: Bool

    public init(utf8Filenames: Bool = false, appeResume: Bool = false, restResume: Bool = false,
                mkdir: Bool = false, deleteFile: Bool = false, rename: Bool = false,
                mlsd: Bool = false, sizeCommand: Bool = false) {
        self.utf8Filenames = utf8Filenames
        self.appeResume = appeResume
        self.restResume = restResume
        self.mkdir = mkdir
        self.deleteFile = deleteFile
        self.rename = rename
        self.mlsd = mlsd
        self.sizeCommand = sizeCommand
    }
}

// MARK: - 错误

public enum EngineError: LocalizedError {
    case connectionFailed(String)
    case authFailed
    case notConnected
    case remoteNotFound(String)
    case permissionDenied(String)
    /// 服务器不支持该能力（探测矩阵里为 false 时调用方应避免调用）
    case unsupported(String)
    case ioError(String)
    case aborted
    case protocolError(Int, String)

    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let s): return "连接电视失败：\(s)"
        case .authFailed: return "登录被拒绝"
        case .notConnected: return "尚未连接电视"
        case .remoteNotFound(let p): return "电视上找不到：\(p)"
        case .permissionDenied(let p): return "电视拒绝写入：\(p)"
        case .unsupported(let w): return "电视不支持：\(w)"
        case .ioError(let s): return "读写错误：\(s)"
        case .aborted: return "已取消"
        case .protocolError(let code, let msg): return "协议错误 \(code)：\(msg)"
        }
    }
}

// MARK: - 传输取消句柄

/// 每个上传/下载任务一个句柄；UI 侧 cancel() 后引擎在下一次 IO 检查点中断并以 .aborted 结束。
public final class TransferHandle {
    private let lock = NSLock()
    private var _canceled = false
    public private(set) var isCanceled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _canceled }
        set { lock.lock(); _canceled = newValue; lock.unlock() }
    }
    public init() {}
    public func cancel() { isCanceled = true }
}
