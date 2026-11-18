import Foundation

// MARK: - 传输方向与文件种类（纯逻辑，可测试；无 AppKit 依赖）

/// 任务方向
enum TransferDirection: String, Codable {
    case upload
    case download
}

/// 媒体种类：决定智能分流（视频 Movies/、图片 Pictures/）与卡片缩略图
enum MediaKind: String, Codable {
    case video
    case image
    case other

    static let videoExtensions: Set<String> = [
        "mp4", "mov", "mkv", "avi", "rmvb", "rm", "flv", "wmv", "ts", "m4v",
        "webm", "mpg", "mpeg", "3gp", "vob", "m2ts", "mts", "divx", "asf",
    ]
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "bmp",
        "webp", "dng", "cr2", "cr3", "arw", "raf", "rw2", "nef", "orf",
    ]

    static func of(fileName: String) -> MediaKind {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if MediaKind.videoExtensions.contains(ext) { return .video }
        if MediaKind.imageExtensions.contains(ext) { return .image }
        return .other
    }

    static func of(url: URL) -> MediaKind { of(fileName: url.lastPathComponent) }
}

/// 队列阶段（与契约 TransferPhase 对应；rawString 便于持久化）
enum QueuePhase: String, Codable {
    case queued
    case connecting
    case running
    case paused
    case failed
    case completed
    case canceled

    var isTerminal: Bool { self == .completed || self == .canceled || self == .failed }
}

// MARK: - 队列单项（Codable，JSON 持久化）

struct QueueItem: Codable, Equatable {
    let id: String
    var direction: TransferDirection
    var kind: MediaKind
    /// 本地路径：上传=源文件；下载=目标文件
    var localPath: String
    /// 界面显示名（原始文件名）
    var displayName: String
    var sizeBytes: Int64
    /// 远端完整路径：上传=分流决定后；下载=来源
    var remotePath: String?
    /// 上传分流结果目录（卡片显示「将存到 …」）
    var remoteDir: String?
    var phase: QueuePhase
    var failureReason: String?
    /// 已传字节
    var bytes: Int64
    var bytesPerSecond: Double
    /// 文件名含 GBK 不可表示字符，已自动兼容命名
    var needsNameMapping: Bool
    /// 一次批量入队的分组 id（全部完成后发整队完成通知）
    var batchId: String
    var addedAt: Date
    var finishedAt: Date?
    /// 因断线被自动暂停（重连后自动恢复，与用户手动暂停区分）
    var autoPaused: Bool

    init(direction: TransferDirection,
         kind: MediaKind,
         localPath: String,
         displayName: String,
         sizeBytes: Int64,
         batchId: String = UUID().uuidString,
         addedAt: Date = Date()) {
        self.id = UUID().uuidString
        self.direction = direction
        self.kind = kind
        self.localPath = localPath
        self.displayName = displayName
        self.sizeBytes = sizeBytes
        self.remotePath = nil
        self.remoteDir = nil
        self.phase = .queued
        self.failureReason = nil
        self.bytes = 0
        self.bytesPerSecond = 0
        self.needsNameMapping = false
        self.batchId = batchId
        self.addedAt = addedAt
        self.finishedAt = nil
        self.autoPaused = false
    }

    var isBusy: Bool { phase == .queued || phase == .connecting || phase == .running }
    var localURL: URL { URL(fileURLWithPath: localPath) }
    var remoteName: String? {
        guard let p = remotePath else { return nil }
        return (p as NSString).lastPathComponent
    }
}

// MARK: - 状态机事件

enum QueueEvent: Equatable {
    case startConnecting
    case startRunning
    case progress(bytes: Int64, bps: Double)
    case userPause
    case autoPause
    case userCancel
    case resume
    case retry
    case fail(reason: String)
    case complete
}

/// 队列状态机（纯函数）：非法迁移一律原样返回，保证可测试与幂等。
/// 说明：用户暂停/取消会先同步置 phase，引擎随后回报的 .aborted 事件在状态机上自然被忽略。
enum QueueStateMachine {
    static func apply(_ event: QueueEvent, to item: QueueItem, now: Date = Date()) -> QueueItem {
        var it = item
        switch event {
        case .startConnecting:
            guard it.phase == .queued else { return item }
            it.phase = .connecting
        case .startRunning:
            guard it.phase == .connecting else { return item }
            it.phase = .running
        case .progress(let bytes, let bps):
            guard it.phase == .connecting || it.phase == .running else { return item }
            it.bytes = max(it.bytes, bytes) // 防止进度回退
            it.bytesPerSecond = bps
        case .userPause:
            guard it.isBusy else { return item }
            it.phase = .paused
            it.autoPaused = false
            it.bytesPerSecond = 0
        case .autoPause:
            guard it.isBusy else { return item }
            it.phase = .paused
            it.autoPaused = true
            it.bytesPerSecond = 0
        case .userCancel:
            guard !it.phase.isTerminal else { return item }
            it.phase = .canceled
            it.finishedAt = now
            it.bytesPerSecond = 0
        case .resume:
            guard it.phase == .paused else { return item }
            it.phase = .queued
            it.autoPaused = false
        case .retry:
            guard it.phase == .failed || it.phase == .canceled else { return item }
            it.phase = .queued
            it.failureReason = nil
            it.finishedAt = nil
            it.bytes = 0
            it.bytesPerSecond = 0
            it.autoPaused = false
        case .fail(let reason):
            guard it.phase == .connecting || it.phase == .running else { return item }
            it.phase = .failed
            it.failureReason = reason
            it.finishedAt = now
            it.bytesPerSecond = 0
        case .complete:
            guard it.phase == .connecting || it.phase == .running else { return item }
            it.phase = .completed
            if it.sizeBytes > 0 { it.bytes = it.sizeBytes }
            it.finishedAt = now
            it.bytesPerSecond = 0
        }
        return it
    }
}
