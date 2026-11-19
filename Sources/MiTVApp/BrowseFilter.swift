import Foundation

/// 浏览列表可见性过滤（纯逻辑，可测试）。
/// 对普通用户隐藏系统/设备自建的隐藏文件与目录——它们不是「用户的内容」：
/// - POSIX 隐藏（. 开头）：.fseventsd、.Spotlight-V100、._* AppleDouble、.MITV-Trash 等
/// - Windows 卷信息与回收站：System Volume Information、$RECYCLE.BIN、RECYCLER、RECYCLED
/// - 检查点/丢失目录：FOUND.000（Windows chkdsk）、LOST.DIR（Android）
/// 回收站入口按本地记账呈现，不依赖此列表。
enum BrowseFilter {
    static func isVisible(_ name: String) -> Bool {
        if name.hasPrefix(".") { return false }
        let lower = name.lowercased()
        if lower == "system volume information" { return false }
        if lower == "$recycle.bin" || lower == "recycler" || lower == "recycled" { return false }
        if lower == "lost.dir" { return false }
        if lower.hasPrefix("found."), lower.dropFirst("found.".count).allSatisfy({ $0.isNumber }) { return false }
        return true
    }

    static func filter(_ entries: [FTPFileEntry]) -> [FTPFileEntry] {
        entries.filter { isVisible($0.name) }
    }
}
