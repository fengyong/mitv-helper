import AppKit
import Foundation

/// 文件/文件夹选择（NSOpenPanel 封装）：默认 ~/Downloads、记住上次目录、文件夹递归展开媒体文件。
final class PickService {

    private static let lastDirKey = "lastPickDirectory"
    private static let lastDownloadDirKey = "lastDownloadDirectory"

    var lastDirectory: URL {
        get {
            if let s = UserDefaults.standard.string(forKey: PickService.lastDirKey) {
                return URL(fileURLWithPath: s, isDirectory: true)
            }
            return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        }
        set { UserDefaults.standard.set(newValue.path, forKey: PickService.lastDirKey) }
    }

    /// 取回保存目录单独记忆：与「挑选发送文件」的目录互不串味（旧实现共用一个键，
    /// 选一次保存位置就把发送面板的默认目录也改了）
    var lastDownloadDirectory: URL {
        get {
            if let s = UserDefaults.standard.string(forKey: PickService.lastDownloadDirKey) {
                return URL(fileURLWithPath: s, isDirectory: true)
            }
            return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        }
        set { UserDefaults.standard.set(newValue.path, forKey: PickService.lastDownloadDirKey) }
    }

    /// 选择文件或文件夹（sheet 呈现在主窗口）。文件夹递归展开媒体文件；非媒体自动忽略。
    func chooseMedia(on window: NSWindow?, completion: @escaping (_ media: [URL], _ ignoredCount: Int) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "选择要发送的照片和视频"
        panel.message = "可以选文件，也可以直接选一个文件夹"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.directoryURL = lastDirectory
        panel.beginSheetModal(for: window ?? NSWindow()) { response in
            guard response == .OK else { completion([], 0); return }
            let urls = panel.urls
            if let dir = panel.directoryURL { self.lastDirectory = dir }
            // 递归展开可能扫上万文件（大文件夹/网络卷）——放后台，主线程只收结果
            DispatchQueue.global(qos: .userInitiated).async {
                var files: [URL] = []
                for url in urls {
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                        files.append(contentsOf: PickService.expandFolder(url))
                    } else {
                        files.append(url)
                    }
                }
                let result = PickService.filterMedia(files)
                DispatchQueue.main.async { completion(result.media, result.ignored) }
            }
        }
    }

    /// 选择一个用于保存取回文件的文件夹
    func chooseFolder(on window: NSWindow?, completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "选择保存位置"
        panel.message = "取回的文件会保存到这个文件夹"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = lastDownloadDirectory
        panel.beginSheetModal(for: window ?? NSWindow()) { response in
            guard response == .OK, let url = panel.url else { completion(nil); return }
            self.lastDownloadDirectory = url
            completion(url)
        }
    }

    // MARK: - 纯工具

    /// 递归展开文件夹内的媒体文件（跳过隐藏文件与 .MITV-Trash 之类）
    static func expandFolder(_ folder: URL, depth: Int = 0) -> [URL] {
        guard depth < 8 else { return [] }
        if (try? folder.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true { return [] }
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: []) else {
            return []
        }
        var out: [URL] = []
        for item in items {
            if item.lastPathComponent.hasPrefix(".") { continue }
            // 包（.photoslibrary/.app 等）是目录形态的单文件：钻进去会捞出图库 masters/应用资源
            if (try? item.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true { continue }
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                out.append(contentsOf: expandFolder(item, depth: depth + 1))
            } else {
                out.append(item)
            }
        }
        return out
    }

    static func filterMedia(_ urls: [URL]) -> (media: [URL], ignored: Int) {
        let media = urls.filter { MediaKind.of(url: $0) != .other }
        return (media, urls.count - media.count)
    }
}
