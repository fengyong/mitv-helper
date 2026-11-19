import AVFoundation
import AppKit
import Foundation

/// 电视文件服务：浏览 / 取回下载编排 / 直删（DELE）/ 缩略图。
final class TVFileService {

    // MARK: 注入

    private let engineProvider: () -> TransferEngine
    private let endpointProvider: () -> FTPEndpoint?
    private let capabilitiesProvider: () -> Capabilities?
    private let thumbDirectoryOverride: URL?

    init(engineProvider: @escaping () -> TransferEngine,
         endpointProvider: @escaping () -> FTPEndpoint?,
         capabilitiesProvider: @escaping () -> Capabilities?,
         thumbDirectory: URL? = nil) {
        self.engineProvider = engineProvider
        self.endpointProvider = endpointProvider
        self.capabilitiesProvider = capabilitiesProvider
        self.thumbDirectoryOverride = thumbDirectory
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

    /// 建目录（MKD，选择存放位置弹窗用）。caps.mkdir=false 的设备上 UI 门控不发起；
    /// 探测后能力变化的竞态在此如实失败（设计稿 v2 §5.2/D1）
    func makeDirectory(_ path: String, completion: @escaping (Error?) -> Void) {
        guard let endpoint = endpointProvider() else {
            completion(EngineError.notConnected)
            return
        }
        engineProvider().makeDirectory(endpoint, path: path) { error in
            DispatchQueue.main.async { completion(error) }
        }
    }

    // MARK: 删除（直删 DELE，永久不可撤销）

    /// 当前能力下的删除策略（UI 用它决定按钮与文案）
    func currentStrategy() -> DeleteStrategy {
        SoftDeletePolicy.strategy(capabilities: capabilitiesProvider() ?? Capabilities())
    }

    /// 批量删除结果：成功数 + 失败名单（部分失败如实上报，不再被吞掉）
    struct DeleteOutcome {
        let deletedCount: Int
        let failedNames: [String]
    }

    /// 批量直删。progress(done, total, name) 主队列；completion 返回成功数与失败名单。
    /// tolerateMissing：远端已不存在视为删除成功（重启补删时，上次已删掉的项不应再算失败）
    func deleteEntries(_ entries: [FTPFileEntry],
                       tolerateMissing: Bool = false,
                       progress: @escaping (_ done: Int, _ total: Int, _ name: String) -> Void,
                       completion: @escaping (Result<DeleteOutcome, Error>) -> Void) {
        let files = entries.filter { !$0.isDirectory }
        guard !files.isEmpty else { completion(.success(DeleteOutcome(deletedCount: 0, failedNames: []))); return }
        guard let endpoint = endpointProvider() else {
            completion(.failure(EngineError.notConnected))
            return
        }
        let caps = capabilitiesProvider() ?? Capabilities()
        guard caps.deleteFile else {
            completion(.failure(EngineError.unsupported("删除")))
            return
        }
        let engine = engineProvider()
        var deleted = 0
        var failedNames: [String] = []
        let total = files.count
        func step(_ i: Int) {
            guard i < total else {
                DispatchQueue.main.async { completion(.success(DeleteOutcome(deletedCount: deleted, failedNames: failedNames))) }
                return
            }
            let entry = files[i]
            progress(i, total, entry.name)
            engine.delete(endpoint, remotePath: entry.path) { error in
                if error == nil {
                    deleted += 1
                } else if tolerateMissing, let e = error as? EngineError, case .remoteNotFound = e {
                    deleted += 1
                } else {
                    failedNames.append(entry.name)
                }
                progress(i + 1, total, entry.name)
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
    /// 排队或传输中的路径 → 等待结果的回调（同路径多次请求共享一次下载）
    private var thumbPending: [String: [(NSImage?) -> Void]] = [:]
    private var thumbWaiting: [FTPFileEntry] = []
    private var thumbActive = 0
    private var thumbHandles: [String: TransferHandle] = [:]
    private var failedThumbs = Set<String>()
    /// 被主动取消的路径：收尾时不进负缓存（滚回来还要重新取）
    private var canceledThumbs = Set<String>()
    private let fetchLock = NSLock()
    /// 嵌入式 FTP 服务器连接数有限：缩略图下载最多 2 路并发，其余排队
    private let thumbMaxActive = 2
    private let maxThumbBytes: Int64 = 20 * 1024 * 1024
    /// SQLite 磁盘索引 + 缩略图文件落盘：重启后浏览不再重复下载（用户需求）
    private lazy var thumbStore = ThumbCacheStore(directory: thumbDir)

    private var thumbDir: URL {
        let dir: URL
        if let override = thumbDirectoryOverride {
            dir = override
        } else {
            let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            dir = base.appendingPathComponent("MiTVHelper/Thumbs", isDirectory: true)
        }
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
        let sizeKey = entry.size ?? -1
        if let file = thumbStore.lookup(path: entry.path, size: sizeKey) {
            let thumbURL = thumbDir.appendingPathComponent(file)
            if let image = NSImage(contentsOf: thumbURL) {
                thumbCache.setObject(image, forKey: key)
                completion(image)
                return
            }
            thumbStore.delete(path: entry.path)
            try? FileManager.default.removeItem(at: thumbURL)
        }
        fetchLock.lock()
        // 负缓存：失败一次本会话内不再重试（防每次浏览都重下大图）
        if failedThumbs.contains(entry.path) {
            fetchLock.unlock()
            completion(nil)
            return
        }
        if thumbPending[entry.path] != nil {
            thumbPending[entry.path]?.append(completion)
            fetchLock.unlock()
            return
        }
        thumbPending[entry.path] = [completion]
        thumbWaiting.append(entry)
        fetchLock.unlock()
        pumpThumbs()
    }

    /// 单元格复用/滚出视野：取消该路径的缩略图获取（排队中的直接丢弃，传输中的断连接）
    func cancelThumbnail(forPath path: String) {
        guard !path.isEmpty else { return }
        fetchLock.lock()
        if let i = thumbWaiting.firstIndex(where: { $0.path == path }) {
            thumbWaiting.remove(at: i)
            let cbs = thumbPending.removeValue(forKey: path) ?? []
            fetchLock.unlock()
            DispatchQueue.main.async { for cb in cbs { cb(nil) } }
            return
        }
        if thumbPending[path] != nil {
            canceledThumbs.insert(path)
        }
        let handle = thumbHandles[path]
        fetchLock.unlock()
        handle?.cancel()
    }

    private func pumpThumbs() {
        fetchLock.lock()
        while thumbActive < thumbMaxActive, !thumbWaiting.isEmpty {
            let entry = thumbWaiting.removeFirst()
            thumbActive += 1
            fetchLock.unlock()
            startThumbFetch(entry)
            fetchLock.lock()
        }
        fetchLock.unlock()
    }

    private func startThumbFetch(_ entry: FTPFileEntry) {
        fetchLock.lock()
        if canceledThumbs.remove(entry.path) != nil {
            // 排队→起传的间隙里被取消：直接收尾，不起连接
            let cbs = thumbPending.removeValue(forKey: entry.path) ?? []
            thumbActive -= 1
            fetchLock.unlock()
            DispatchQueue.main.async { for cb in cbs { cb(nil) } }
            DispatchQueue.global().async { [weak self] in self?.pumpThumbs() }
            return
        }
        fetchLock.unlock()

        let key = entry.path as NSString
        // 缓存文件名用路径哈希：中文长路径的 percent-encoding 可超 NAME_MAX=255 导致永不落盘（review D7）
        // orig- 前缀：原图/前缀临时文件——与缩略图持久文件（md5.jpg）区分，防 finish 收尾误删缩略图
        let ext = (entry.name as NSString).pathExtension
        let hashed = FileDigest.md5Hex(Data(entry.path.utf8)) + (ext.isEmpty ? "" : "." + ext)
        let localURL = thumbDir.appendingPathComponent("orig-" + hashed)
        let sizeKey = entry.size ?? -1
        // 生成成功：缩略图 JPEG 落盘 + 记录入 SQLite（在后台队列执行，见 finish 调用点）
        let persist: (NSImage) -> Void = { [weak self] img in
            guard let self = self else { return }
            let thumbFile = FileDigest.md5Hex(Data(entry.path.utf8)) + ".jpg"
            if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
                try? jpeg.write(to: self.thumbDir.appendingPathComponent(thumbFile))
                let digest = FileDigest.fingerprint(url: localURL,
                                                    fileSize: min(max(0, entry.size ?? 0), FileDigest.prefixLimit))?.hex
                self.thumbStore.store(path: entry.path, size: sizeKey, digest: digest, file: thumbFile)
            }
        }
        let finish: (NSImage?) -> Void = { [weak self] img in
            guard let self = self else { return }
            self.fetchLock.lock()
            let cbs = self.thumbPending.removeValue(forKey: entry.path) ?? []
            self.thumbHandles.removeValue(forKey: entry.path)
            let canceled = self.canceledThumbs.remove(entry.path) != nil
            if img == nil && !canceled { self.failedThumbs.insert(entry.path) }
            self.thumbActive -= 1
            self.fetchLock.unlock()
            if let img = img {
                self.thumbCache.setObject(img, forKey: key)
                persist(img)
            }
            try? FileManager.default.removeItem(at: localURL)
            DispatchQueue.main.async { for cb in cbs { cb(img) } }
            self.pumpThumbs()
        }
        guard let endpoint = endpointProvider() else {
            DispatchQueue.global().async { finish(nil) }
            return
        }
        if entry.kind == .video {
            // 视频：读前 2MB 试帧（本机 AVAsset 能解就出首帧；moov 在尾部解不出 → nil 兜底）
            engineProvider().downloadPrefix(endpoint, remotePath: entry.path, maxBytes: 2 * 1024 * 1024) { result in
                // 引擎回调在主队列：写盘/解码都是重活，hop 后台再收尾
                DispatchQueue.global(qos: .userInitiated).async {
                    switch result {
                    case .failure:
                        finish(nil)
                    case .success(let data):
                        try? data.write(to: localURL)
                        finish(Self.firstFrame(from: localURL)?.scaled(maxPixel: 400))
                    }
                }
            }
            return
        }
        let handle = TransferHandle()
        fetchLock.lock()
        thumbHandles[entry.path] = handle
        fetchLock.unlock()
        engineProvider().download(endpoint, remotePath: entry.path, to: localURL,
                                  handle: handle, onProgress: nil) { result in
            // 引擎回调在主队列：整图解码 + 缩放 + JPEG 落盘 + 指纹都在后台做
            DispatchQueue.global(qos: .userInitiated).async {
                guard case .success = result, let image = NSImage(contentsOf: localURL) else {
                    finish(nil)
                    return
                }
                finish(image.scaled(maxPixel: 400) ?? image)
            }
        }
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
    /// 用 CGContext 离屏绘制：lockFocus 依赖 AppKit 图形上下文，后台队列调用不安全，
    /// 而缩略图缩放恰恰都在后台队列发生。
    func scaled(maxPixel: CGFloat) -> NSImage? {
        let ratio = min(maxPixel / max(size.width, 1), maxPixel / max(size.height, 1), 1)
        let target = NSSize(width: size.width * ratio, height: size.height * ratio)
        guard target.width > 1, target.height > 1 else { return nil }
        guard let src = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = Int(target.width.rounded()), h = Int(target.height.rounded())
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { return nil }
        let img = NSImage(cgImage: out, size: target)
        img.isTemplate = false
        return img
    }
}
