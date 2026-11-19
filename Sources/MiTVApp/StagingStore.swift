import AppKit
import Foundation

/// 照片/视频导出暂存区：照片库导出的原文件先落到这里，再进入上传队列。
final class StagingStore {

    let root: URL

    init(root: URL? = nil) {
        if let root = root {
            self.root = root
        } else {
            self.root = TVStore.defaultDirectory().appendingPathComponent("Staging", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true, attributes: nil)
    }

    /// 把外部文件（临时导出文件）移入暂存区，重名自动顺延；后台执行。
    /// 导出原件可能几个 GB：移动代替拷贝，省一次整文件读写（跨卷等移动失败时退回拷贝）。
    func stage(from url: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let dest = self.uniquedURL(for: self.root.appendingPathComponent(url.lastPathComponent))
            do {
                do {
                    try FileManager.default.moveItem(at: url, to: dest)
                } catch {
                    try FileManager.default.copyItem(at: url, to: dest)
                }
                DispatchQueue.main.async { completion(.success(dest)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func uniquedURL(for proposed: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: proposed.path) else { return proposed }
        let stem = proposed.deletingPathExtension().lastPathComponent
        let ext = proposed.pathExtension
        var i = 2
        while true {
            let name = ext.isEmpty ? "\(stem) (\(i))" : "\(stem) (\(i)).\(ext)"
            let candidate = root.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            i += 1
        }
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// 队列里引用的源文件是否还在（供双击完成项 / 重试前检查）
    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
}
