import AppKit
import Foundation

/// 电视端删除记账（软删除的「原路径在哪」）：JSON 原子写。
final class TrashStore {

    struct Record: Codable, Equatable {
        let id: String
        /// 移动后的路径（目录形态 /.MITV-Trash/... 或前缀形态 /.MITV-Trash--...）
        var trashPath: String
        /// 原始完整路径（撤销时 rename 回去）
        var originalPath: String
        var name: String
        var sizeBytes: Int64
        var deletedAt: Date
    }

    private let fileURL: URL
    private let lock = NSLock()
    private(set) var records: [Record] = []

    init(directory: URL = TVStore.defaultDirectory()) {
        fileURL = directory.appendingPathComponent("trash.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        reload()
    }

    func reload() {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        records = (try? dec.decode([Record].self, from: data)) ?? []
    }

    private func persist() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        if let data = try? enc.encode(records) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func add(_ record: Record) {
        lock.lock()
        records.append(record)
        persist()
        lock.unlock()
    }

    func remove(ids: [String]) {
        lock.lock()
        let set = Set(ids)
        records.removeAll { set.contains($0.id) }
        persist()
        lock.unlock()
    }

    var totalBytes: Int64 { lock.lock(); defer { lock.unlock() }; return records.reduce(0) { $0 + $1.sizeBytes } }
    var count: Int { lock.lock(); defer { lock.unlock() }; return records.count }
}

/// 电视文件服务：浏览 / 取回下载编排 / 软删除（按 §7 决策表）/ 缩略图。
final class TVFileService {

    // MARK: 注入

    private let engineProvider: () -> TransferEngine
    private let endpointProvider: () -> FTPEndpoint?
    private let capabilitiesProvider: () -> Capabilities?
    let trashStore: TrashStore

    init(engineProvider: @escaping () -> TransferEngine,
         endpointProvider: @escaping () -> FTPEndpoint?,
         capabilitiesProvider: @escaping () -> Capabilities?,
         trashStore: TrashStore) {
        self.engineProvider = engineProvider
        self.endpointProvider = endpointProvider
        self.capabilitiesProvider = capabilitiesProvider
        self.trashStore = trashStore
    }

    // MARK: 浏览

    /// 列目录（目录在前、按本地化名称排序）
    func list(_ path: String, completion: @escaping (Result<[FTPFileEntry], Error>) -> Void) {
        guard let endpoint = endpointProvider() else {
            completion(.failure(EngineError.notConnected))
            return
        }
        engineProvider().list(endpoint, path: path) { result in
            switch result {
            case .success(let entries):
                let sorted = TVFileService.sort(entries)
                DispatchQueue.main.async { completion(.success(sorted)) }
            case .failure(let error):
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    static func sort(_ entries: [FTPFileEntry]) -> [FTPFileEntry] {
        return entries.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    // MARK: 删除（§7 决策表）

    /// 当前能力下的删除策略（UI 用它决定按钮与文案）
    func currentStrategy(trashDirExists: Bool = false) -> DeleteStrategy {
        SoftDeletePolicy.strategy(capabilities: capabilitiesProvider() ?? Capabilities(),
                                  trashDirExists: trashDirExists)
    }

    /// 批量删除结果：成功记账（撤销用）+ 失败名单（部分失败如实上报，不再被吞掉）
    struct DeleteOutcome {
        let records: [TrashStore.Record]
        let failedNames: [String]
    }

    /// 批量删除。progress(done, total, name) 主队列；completion 返回成功记账与失败名单。
    func deleteEntries(_ entries: [FTPFileEntry],
                       progress: @escaping (_ done: Int, _ total: Int, _ name: String) -> Void,
                       completion: @escaping (Result<DeleteOutcome, Error>) -> Void) {
        let files = entries.filter { !$0.isDirectory }
        guard !files.isEmpty else { completion(.success(DeleteOutcome(records: [], failedNames: []))); return }
        guard let endpoint = endpointProvider() else {
            completion(.failure(EngineError.notConnected))
            return
        }
        let engine = engineProvider()
        let caps = capabilitiesProvider() ?? Capabilities()

        // 软删除：先确保回收站目录存在（mkdir 可用则尝试建；不行则前缀形态兜底）
        func beginSoftDelete() {
            let doPrefix: () -> Void = { self.softDelete(files, form: .prefix, endpoint: endpoint, engine: engine, progress: progress, completion: completion) }
            let doDirectory: () -> Void = { self.softDelete(files, form: .directory, endpoint: endpoint, engine: engine, progress: progress, completion: completion) }
            if caps.mkdir {
                engine.makeDirectory(endpoint, path: SoftDeletePolicy.trashRoot) { _ in
                    // 无论 mkdir 成败，都用 list 验证目录是否存在（可能早已存在）
                    self.checkTrashDir(endpoint, exists: { exists in
                        exists ? doDirectory() : doPrefix()
                    })
                }
            } else {
                self.checkTrashDir(endpoint, exists: { exists in
                    exists ? doDirectory() : doPrefix()
                })
            }
        }

        switch SoftDeletePolicy.strategy(capabilities: caps, trashDirExists: false) {
        case .soft:
            beginSoftDelete()
        case .hard:
            hardDelete(files, endpoint: endpoint, engine: engine, progress: progress, completion: completion)
        case .disabled:
            completion(.failure(EngineError.unsupported("删除")))
        }
    }

    private func checkTrashDir(_ endpoint: FTPEndpoint, exists: @escaping (Bool) -> Void) {
        engineProvider().list(endpoint, path: "/") { result in
            guard case .success(let entries) = result else { exists(false); return }
            exists(entries.contains { $0.isDirectory && $0.name == SoftDeletePolicy.trashRoot.replacingOccurrences(of: "/", with: "") })
        }
    }

    private func softDelete(_ files: [FTPFileEntry], form: DeleteStrategy.TrashForm,
                            endpoint: FTPEndpoint, engine: TransferEngine,
                            progress: @escaping (Int, Int, String) -> Void,
                            completion: @escaping (Result<DeleteOutcome, Error>) -> Void) {
        var records: [TrashStore.Record] = []
        var failedNames: [String] = []
        let total = files.count
        func step(_ i: Int) {
            guard i < total else {
                DispatchQueue.main.async { completion(.success(DeleteOutcome(records: records, failedNames: failedNames))) }
                return
            }
            let entry = files[i]
            progress(i, total, entry.name)
            let target: String
            switch form {
            case .directory:
                target = SoftDeletePolicy.directoryTrashPath(forRemotePath: entry.path)
            case .prefix:
                target = "/" + SoftDeletePolicy.prefixTrashName(forRemotePath: entry.path)
            }
            engine.move(endpoint, from: entry.path, to: target) { error in
                if error == nil {
                    let record = TrashStore.Record(id: UUID().uuidString,
                                                   trashPath: target,
                                                   originalPath: entry.path,
                                                   name: entry.name,
                                                   sizeBytes: entry.size ?? 0,
                                                   deletedAt: Date())
                    self.trashStore.add(record)
                    records.append(record)
                } else {
                    failedNames.append(entry.name)
                }
                progress(i + 1, total, entry.name)
                step(i + 1)
            }
        }
        step(0)
    }

    private func hardDelete(_ files: [FTPFileEntry], endpoint: FTPEndpoint, engine: TransferEngine,
                            progress: @escaping (Int, Int, String) -> Void,
                            completion: @escaping (Result<DeleteOutcome, Error>) -> Void) {
        var failedNames: [String] = []
        let total = files.count
        func step(_ i: Int) {
            guard i < total else {
                DispatchQueue.main.async { completion(.success(DeleteOutcome(records: [], failedNames: failedNames))) }
                return
            }
            let entry = files[i]
            progress(i, total, entry.name)
            engine.delete(endpoint, remotePath: entry.path) { error in
                if error != nil { failedNames.append(entry.name) }
                progress(i + 1, total, entry.name)
                step(i + 1)
            }
        }
        step(0)
    }

    /// 撤销：把记录的文件移回原位
    func restore(_ records: [TrashStore.Record],
                 progress: @escaping (_ done: Int, _ total: Int, _ name: String) -> Void,
                 completion: @escaping (_ restoredCount: Int, _ failedCount: Int) -> Void) {
        guard let endpoint = endpointProvider() else {
            completion(0, records.count)
            return
        }
        let engine = engineProvider()
        let total = records.count
        var ok = 0
        var bad = 0
        var restoredIds: [String] = []
        func step(_ i: Int) {
            guard i < total else {
                trashStore.remove(ids: restoredIds)
                completion(ok, bad)
                return
            }
            let record = records[i]
            progress(i, total, record.name)
            engine.move(endpoint, from: record.trashPath, to: record.originalPath) { error in
                if error == nil {
                    ok += 1
                    restoredIds.append(record.id)
                } else {
                    bad += 1
                }
                progress(i + 1, total, record.name)
                step(i + 1)
            }
        }
        step(0)
    }

    // MARK: 取回下载

    /// 入队一批下载（选择保存目录由 UI 层完成）
    func enqueueDownloads(_ entries: [FTPFileEntry], toDirectory dir: URL, queue: QueueService) -> [QueueItem] {
        queue.addDownloads(entries, toDirectory: dir)
    }

    // MARK: 浏览缩略图（远端图片）

    private let thumbCache = NSCache<NSString, NSImage>()
    private var fetchingPaths = Set<String>()
    private let fetchLock = NSLock()
    private let maxThumbBytes: Int64 = 20 * 1024 * 1024

    private var thumbDir: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("MiTVHelper/Thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        return dir
    }

    /// 远端图片缩略图（≤20MB 才取）；completion 主队列，失败给 nil（UI 用图标兜底）
    func fetchThumbnail(_ entry: FTPFileEntry, completion: @escaping (NSImage?) -> Void) {
        guard !entry.isDirectory, entry.kind == .image, (entry.size ?? 1) <= maxThumbBytes else {
            completion(nil)
            return
        }
        let key = entry.path as NSString
        if let cached = thumbCache.object(forKey: key) {
            completion(cached)
            return
        }
        fetchLock.lock()
        if fetchingPaths.contains(entry.path) { fetchLock.unlock(); completion(nil); return }
        fetchingPaths.insert(entry.path)
        fetchLock.unlock()

        let localURL = thumbDir.appendingPathComponent(entry.path.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? UUID().uuidString)
        guard let endpoint = endpointProvider() else {
            markNotFetching(entry.path); completion(nil); return
        }
        engineProvider().download(endpoint, remotePath: entry.path, to: localURL,
                                  handle: nil, onProgress: nil) { [weak self] result in
            guard let self = self else { return }
            self.markNotFetching(entry.path)
            if case .success = result, let image = NSImage(contentsOf: localURL) {
                let thumb = image.scaled(maxPixel: 400) ?? image
                self.thumbCache.setObject(thumb, forKey: key)
                try? FileManager.default.removeItem(at: localURL)
                DispatchQueue.main.async { completion(thumb) }
            } else {
                try? FileManager.default.removeItem(at: localURL)
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }

    private func markNotFetching(_ path: String) {
        fetchLock.lock()
        fetchingPaths.remove(path)
        fetchLock.unlock()
    }
}

extension MediaKind {
    init(entry: FTPFileEntry) { self = MediaKind.of(fileName: entry.name) }
}

extension FTPFileEntry {
    var kind: MediaKind { MediaKind.of(fileName: name) }
}

extension NSImage {
    /// 等比缩到 maxPixel 内（供网格缩略）。from 必须传 .zero（整图）——传固定矩形会变成裁切。
    func scaled(maxPixel: CGFloat) -> NSImage? {
        let ratio = min(maxPixel / max(size.width, 1), maxPixel / max(size.height, 1), 1)
        let target = NSSize(width: size.width * ratio, height: size.height * ratio)
        guard target.width > 1, target.height > 1 else { return nil }
        let img = NSImage(size: target)
        img.lockFocus()
        draw(in: NSRect(origin: .zero, size: target),
             from: .zero,
             operation: .copy, fraction: 1.0)
        img.unlockFocus()
        img.isTemplate = false
        return img
    }
}
