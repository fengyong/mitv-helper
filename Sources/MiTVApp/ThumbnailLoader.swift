import AVFoundation
import AppKit
import Foundation

/// 本地文件缩略图：照片直接 NSImage 缩放；视频取首帧（AVAssetImageGenerator）。
final class LocalThumbnailLoader {

    static let shared = LocalThumbnailLoader()

    private let cache = NSCache<NSString, NSImage>()
    private let inflightLock = NSLock()
    private var inflight = Set<String>()

    /// 同步命中缓存（未命中返回 nil，不触发加载）
    func cached(forPath path: String, kind: MediaKind) -> NSImage? {
        cache.object(forKey: ("\(path)|\(kind.rawValue)" as NSString))
    }

    func thumbnail(forPath path: String, kind: MediaKind, completion: @escaping (NSImage?) -> Void) {
        let key = "\(path)|\(kind.rawValue)" as NSString
        if let hit = cache.object(forKey: key) {
            completion(hit)
            return
        }
        inflightLock.lock()
        if inflight.contains(path) {
            inflightLock.unlock()
            completion(nil)
            return
        }
        inflight.insert(path)
        inflightLock.unlock()

        let finish: (NSImage?) -> Void = { [weak self] img in
            if let img = img { self?.cache.setObject(img, forKey: key) }
            self?.inflightLock.lock()
            self?.inflight.remove(path)
            self?.inflightLock.unlock()
            DispatchQueue.main.async { completion(img) }
        }

        switch kind {
        case .image:
            DispatchQueue.global(qos: .userInitiated).async {
                let img = NSImage(contentsOfFile: path)?.scaled(maxPixel: 200)
                finish(img)
            }
        case .video:
            DispatchQueue.global(qos: .userInitiated).async {
                let asset = AVURLAsset(url: URL(fileURLWithPath: path))
                let gen = AVAssetImageGenerator(asset: asset)
                gen.appliesPreferredTrackTransform = true
                gen.maximumSize = CGSize(width: 400, height: 400)
                do {
                    let cg = try gen.copyCGImage(at: CMTime(seconds: 0.3, preferredTimescale: 600), actualTime: nil)
                    let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)).scaled(maxPixel: 200)
                    finish(img)
                } catch {
                    // 部分视频首帧解码失败：回落到 0.0 秒
                    do {
                        let cg = try gen.copyCGImage(at: .zero, actualTime: nil)
                        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)).scaled(maxPixel: 200)
                        finish(img)
                    } catch {
                        finish(nil)
                    }
                }
            }
        case .other:
            finish(nil)
        }
    }

    /// 种类图标兜底（缩略图缺失时）
    static func fallbackIcon(for kind: MediaKind) -> NSImage {
        switch kind {
        case .video: return Icons.film
        case .image: return Icons.photo
        case .other: return Icons.doc
        }
    }
}
