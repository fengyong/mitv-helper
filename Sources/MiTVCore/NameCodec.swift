import Foundation

/// 文件名编解码（实测：电视端文件名必须 GBK；UTF-8 会乱码）。
/// 注意必须用严格 GBK（windowsCP936），不能用 GB18030——GB18030 是全 Unicode 编码，
/// emoji 等 GBK 之外字符会被编成电视端无法解释的 4 字节序列。
public enum NameCodec {
    /// 严格 GBK = Windows CP936（dosChineseSimplif）
    public static let gbkEncoding: String.Encoding = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.dosChineseSimplif.rawValue)))

    /// 是否能无损编码为 GBK
    public static func isGBKRepresentable(_ name: String) -> Bool {
        guard let data = name.data(using: gbkEncoding) else { return false }
        // 无损往返校验（防止某些字符被替换为 "?" 之类）
        return String(data: data, encoding: gbkEncoding) == name
    }

    /// 显示名 → 远端名。规则：
    /// 1. 纯 ASCII → 原样
    /// 2. GBK 可表示 → 原样（引擎负责以 GBK 编码发送）
    /// 3. 不可表示（emoji 等）→ 逐字符替换为 "-"，并标记 needsMapping
    public static func remoteName(for displayName: String) -> (remote: String, needsMapping: Bool) {
        guard !isGBKRepresentable(displayName) else { return (displayName, false) }
        var out = ""
        for ch in displayName {
            out += isGBKRepresentable(String(ch)) ? String(ch) : "-"
        }
        return (out, true)
    }

    /// 重名冲突：a.mp4 → a (2).mp4 → a (3).mp4
    public static func uniqued(_ proposed: String, existing: Set<String>) -> String {
        guard existing.contains(proposed) else { return proposed }
        let stem = (proposed as NSString).deletingPathExtension
        let ext = (proposed as NSString).pathExtension
        var i = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) (\(i))" : "\(stem) (\(i)).\(ext)"
            if !existing.contains(candidate) { return candidate }
            i += 1
        }
    }
}
