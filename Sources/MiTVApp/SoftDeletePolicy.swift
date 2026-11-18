import Foundation

/// 删除策略结果（对应 ARCHITECTURE §7 软删除决策表）
enum DeleteStrategy: Equatable {
    enum TrashForm: Equatable {
        /// move → /.MITV-Trash/<父目录扁平化>/<原名>
        case directory
        /// mkdir 不可用且回收站目录不存在 → 根目录 `.MITV-Trash--<父>--<名>` 前缀改名兜底
        case prefix
    }
    /// rename 可用 → 软删除（可撤销）
    case soft(TrashForm)
    /// 仅 DELE 可用 → 直删 + 强确认（「永久删除，无法撤销」）
    case hard
    /// 都不支持 → 删除按钮禁用
    case disabled
}

/// 软删除决策表（纯函数，可测试）。回收站目录名纯 ASCII。
enum SoftDeletePolicy {

    static let trashRoot = "/.MITV-Trash"
    static let prefixTag = ".MITV-Trash--"

    /// 决策表：
    /// | rename | deleteFile | 行为 |
    /// | true   | *          | 软删除（目录形态需 mkdir 可用或目录已存在，否则前缀兜底） |
    /// | false  | true       | 直删 + 强确认 |
    /// | false  | false      | 禁用 |
    static func strategy(capabilities: Capabilities, trashDirExists: Bool) -> DeleteStrategy {
        if capabilities.rename {
            if capabilities.mkdir || trashDirExists {
                return .soft(.directory)
            }
            return .soft(.prefix)
        }
        if capabilities.deleteFile { return .hard }
        return .disabled
    }

    /// "/Movies/a.mp4" → "Movies"；"/A/B/c.mp4" → "A--B"；"/a.mp4" → ""（根目录文件）
    static func flattenParent(ofPath path: String) -> String {
        let comps = path.split(separator: "/").map(String.init)
        guard comps.count >= 2 else { return "" }
        return comps.dropLast().joined(separator: "--")
    }

    /// 目录形态回收站路径："/.MITV-Trash/<扁平化父目录>/<原名>"
    static func directoryTrashPath(forRemotePath path: String) -> String {
        let name = (path as NSString).lastPathComponent
        let parent = flattenParent(ofPath: path)
        if parent.isEmpty { return trashRoot + "/" + name }
        return trashRoot + "/" + parent + "/" + name
    }

    /// 前缀兜底名：".MITV-Trash--Movies--a.mp4"（根目录文件为 ".MITV-Trash--a.mp4"）
    static func prefixTrashName(forRemotePath path: String) -> String {
        let name = (path as NSString).lastPathComponent
        let parent = flattenParent(ofPath: path)
        if parent.isEmpty { return prefixTag + name }
        return prefixTag + parent + "--" + name
    }

    /// 前缀兜底名 → 扁平化父目录（供还原解析）
    static func parentFromPrefixTrashName(_ name: String) -> String? {
        guard name.hasPrefix(prefixTag) else { return nil }
        let rest = String(name.dropFirst(prefixTag.count))
        // rest = "<扁平化父目录>--<文件名>"；根目录文件没有 "--" 分隔
        guard let sep = rest.range(of: "--", options: .backwards) else { return nil }
        let parent = String(rest[..<sep.lowerBound])
        return parent.isEmpty ? nil : parent
    }

    /// 目录形态回收站路径是否属于回收站（含子目录）
    static func isInTrashDir(_ path: String) -> Bool {
        path == trashRoot || path.hasPrefix(trashRoot + "/")
    }

    /// 是否为前缀兜底的回收站文件
    static func isPrefixTrashFile(name: String) -> Bool {
        name.hasPrefix(prefixTag)
    }
}
