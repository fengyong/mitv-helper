import AVFoundation
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
            // 目录形态需要 /.MITV-Trash/<扁平化父目录> 存在（review B2）：逐个尽力 MKD（失败继续——可能已存在，真失败由 move 上报）
            let parentNames = Set(files.map { SoftDeletePolicy.flattenParent(ofPath: $0.path) }.filter { !$0.isEmpty })
            let doDirectory: () -> Void = {
                guard !parentNames.isEmpty else { self.softDelete(files, form: .directory, endpoint: endpoint, engine: engine, progress: progress, completion: completion); return }
                var remaining = parentNames
                func mkNext() {
                    if let name = remaining.popFirst() {
                        engine.makeDirectory(endpoint, path: SoftDeletePolicy.trashRoot + "/" + name) { _ in mkNext() }
                    } else {
                        self.softDelete(files, form: .directory, endpoint: endpoint, engine: engine, progress: progress, completion: completion)
                    }
                }
                mkNext()
            }
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
    private var failedThumbs = Set<String>()
    private let fetchLock = NSLock()
    private let maxThumbBytes: Int64 = 20 * 1024 * 1024
    /// SQLite 磁盘索引 + 缩略图文件落盘：重启后浏览不再重复下载（用户需求）
    private lazy var thumbStore = ThumbCacheStore(directory: thumbDir)

    private var thumbDir: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("MiTVHelper/Thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        return dir
    }

    /// 远端媒体缩略图。图片：整图下载（≤20MB）；视频：下载前 2MB 试帧
    /// （moov 在头部的 MP4 可解出首帧；moov 在尾部的解不出 → 图标兜底 + 负缓存）。
    /// completion 主队列，失败给 nil（UI 用图标兜底）。
    func fetchThumbnail(_ entry: FTPFileEntry, completion: @escaping (NSImage?) -> Void) {
        guard !entry.isDirectory, entry.kind == .image || entry.kind == .video, (entry.size ?? 1) > 0 else {
            completion(nil)
            return
        }
        if entry.kind == .image && (entry.size ?? 1) > maxThumbBytes {
            completion(nil)
            return
        }
        let key = entry.path as NSString
        if let cached = thumbCache.object(forKey: key) {
            completion(cached)
            return
        }
        // SQLite 磁盘命中（path+size）：重启后免重复下载；缩略图文件丢失则删记录走重新生成
        let cachedFile = thumbStore.lookup(path: entry.path, size: entry.size ?? -1)
        if let file = cachedFile {
            let thumbURL = thumbDir.appendingPathComponent(file)
            if let image = NSImage(contentsOf: thumbURL) {
                thumbCache.setObject(image, forKey: key)
                completion(image)
                return
            }
            thumbStore.delete(path: entry.path)
            try? FileManager.default.removeItem(at: thumbURL)
        }
        // 负缓存：失败一次本会话内不再重试（防每次浏览都重下大图）
        fetchLock.lock()
        if failedThumbs.contains(entry.path) || fetchingPaths.contains(entry.path) {
            fetchLock.unlock()
            completion(nil)
            return
        }
        fetchingPaths.insert(entry.path)
        fetchLock.unlock()

        // 缓存文件名用路径哈希：中文长路径的 percent-encoding 可超 NAME_MAX=255 导致永不落盘（review D7）
        // orig- 前缀：原图/前缀临时文件——与缩略图持久文件（md5.jpg）区分，防 finish 收尾误删缩略图
        let ext = (entry.name as NSString).pathExtension
        let hashed = FileDigest.md5Hex(Data(entry.path.utf8)) + (ext.isEmpty ? "" : "." + ext)
        let localURL = thumbDir.appendingPathComponent("orig-" + hashed)
        guard let endpoint = endpointProvider() else {
            markNotFetching(entry.path); completion(nil); return
        }
        // 生成成功：缩略图 JPEG 落盘 + 记录入 SQLite（digest=原文件/前缀文件的 md5，供内容寻址扩展）
        let localSize = entry.size ?? 0
        let persist: (NSImage) -> Void = { [weak self] img in
            guard let self = self else { return }
            let thumbFile = FileDigest.md5Hex(Data(entry.path.utf8)) + ".jpg"
            if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
                try? jpeg.write(to: self.thumbDir.appendingPathComponent(thumbFile))
                let digest = FileDigest.fingerprint(url: localURL, fileSize: min(localSize, FileDigest.prefixLimit))?.hex
                self.thumbStore.store(path: entry.path, size: entry.size ?? localSize, digest: digest, file: thumbFile)
            }
        }
        let finish: (NSImage?) -> Void = { [weak self] img in
            guard let self = self else { return }
            self.markNotFetching(entry.path)
            if let img = img {
                self.thumbCache.setObject(img, forKey: key)
                persist(img)
            } else {
                self.fetchLock.lock()
                self.failedThumbs.insert(entry.path)
                self.fetchLock.unlock()
            }
            try? FileManager.default.removeItem(at: localURL)
            DispatchQueue.main.async { completion(img) }
        }
        if entry.kind == .video {
            // 视频：读前 2MB 试帧（本机 AVAsset 能解就出首帧；moov 在尾部解不出 → nil 兜底）
            engineProvider().downloadPrefix(endpoint, remotePath: entry.path, maxBytes: 2 * 1024 * 1024) { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .failure:
                    finish(nil)
                case .success(let data):
                    try? data.write(to: localURL)
                    let image = Self.firstFrame(from: localURL)?.scaled(maxPixel: 400) ?? nil
                    finish(image)
                }
            }
            return
        }
        engineProvider().download(endpoint, remotePath: entry.path, to: localURL,
                                  handle: nil, onProgress: nil) { [weak self] result in
            guard let self = self else { return }
            // 统一走 finish：落盘 + 入 SQLite（此前图片分支旧内联尾部绕过 finish → 永不入库）
            guard case .success = result, let image = NSImage(contentsOf: localURL) else {
                finish(nil)
                return
            }
            finish(image.scaled(maxPixel: 400) ?? image)
        }
    }

    private func markNotFetching(_ path: String) {
        fetchLock.lock()
        fetchingPaths.remove(path)
        fetchLock.unlock()
    }

    /// 视频文件首帧（AVAssetImageGenerator；无法解码返回 nil）
    private static func firstFrame(from url: URL) -> NSImage? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 400, height: 400)
        guard let cg = try? gen.copyCGImage(at: .zero, actualTime: nil) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
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
