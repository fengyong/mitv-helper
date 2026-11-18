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

    /// 显示名 → 远端名。规则（尽可能保留原名）：
    /// 1. GBK 可表示且文件系统安全的字符 → 原样
    /// 2. 不安全字符（emoji 等 GBK 不可表示、路径/通配/引号等风险字符、控制字符）→ 替换为 "-"
    /// 3. 去首部空格、去尾部空格/点（FAT32/exFAT 要求）
    /// needsMapping = 名字发生过任何改写
    public static func remoteName(for displayName: String) -> (remote: String, needsMapping: Bool) {
        var out = ""
        for ch in displayName {
            if isSafeRemoteChar(ch) {
                out.append(ch)
            } else {
                out.append("-")
            }
        }
        var trimmed = out
        while let f = trimmed.first, f == " " { trimmed.removeFirst() }
        while let l = trimmed.last, l == " " || l == "." { trimmed.removeLast() }
        if trimmed.isEmpty { trimmed = "file" } // 整名都是特殊字符的兜底
        return (trimmed, trimmed != displayName)
    }

    /// 远端文件名安全字符判定
    private static func isSafeRemoteChar(_ ch: Character) -> Bool {
        let scalars = Array(ch.unicodeScalars)
        guard scalars.count == 1 else { return false } // 组合字符序列一律替换
        if scalars[0].value < 0x20 || scalars[0].value == 0x7F { return false } // 控制字符
        if "/\\:*?\"<>|".contains(ch) { return false } // 文件系统风险字符
        return isGBKRepresentable(String(ch))
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
