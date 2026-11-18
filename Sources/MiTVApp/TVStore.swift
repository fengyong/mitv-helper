import Foundation

/// 电视相关持久化状态（JSON 原子写，round-trip 可测试）
struct TVPersistState: Codable, Equatable {
    var endpoint: FTPEndpoint?
    var capabilities: Capabilities?
    /// 界面昵称（如「客厅电视」），零术语原则下只显示这个 + 地址
    var tvName: String?
    /// 浏览上次所在目录
    var lastRemotePath: String?
    var onboardingDone: Bool = false
}

/// 电视信息持久化：endpoint + capabilities + 上次目录。
/// 目录可注入（默认 ~/Library/Application Support/MiTVHelper/）。
final class TVStore {

    static func defaultDirectory() -> URL {
        // 冒烟隔离：设置 MITV_DATA_DIR 时所有持久化（tv/queue/trash/Staging）都落到该目录
        if let custom = ProcessInfo.processInfo.environment["MITV_DATA_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("MiTVHelper", isDirectory: true)
    }

    private let fileURL: URL
    private let lock = NSLock()
    private(set) var state: TVPersistState

    init(directory: URL = TVStore.defaultDirectory()) {
        fileURL = directory.appendingPathComponent("tv.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        state = TVStore.load(from: fileURL) ?? TVPersistState()
    }

    var endpoint: FTPEndpoint? { state.endpoint }
    var capabilities: Capabilities? { state.capabilities }

    func update(_ mutate: (inout TVPersistState) -> Void) {
        lock.lock()
        mutate(&state)
        let snapshot = state
        TVStore.persist(snapshot, to: fileURL)
        lock.unlock()
    }

    func setEndpoint(_ endpoint: FTPEndpoint?) {
        update { $0.endpoint = endpoint }
    }

    func setCapabilities(_ capabilities: Capabilities?) {
        update { $0.capabilities = capabilities }
    }

    func setLastRemotePath(_ path: String?) {
        update { $0.lastRemotePath = path }
    }

    // MARK: - 私有

    private static func load(from url: URL) -> TVPersistState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(TVPersistState.self, from: data)
    }

    private static func persist(_ state: TVPersistState, to url: URL) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(state) else { return }
        try? data.write(to: url, options: .atomic) // 原子写：不会留下半截文件
    }
}
