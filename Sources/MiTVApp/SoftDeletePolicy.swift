import Foundation

/// 删除策略结果：产品决策改为直删（不再软删除/回收站，2026-11-19）
enum DeleteStrategy: Equatable {
    /// DELE 可用 → 直删 + 强确认（「永久删除，无法撤销」）
    case hard
    /// 不支持 → 删除按钮禁用
    case disabled
}

/// 删除决策表（纯函数，可测试）
enum SoftDeletePolicy {

    /// 历史遗留回收站标记：仅用于浏览过滤（旧版本软删除残留仍可能出现在电视上）
    static let trashRoot = "/.MITV-Trash"
    static let prefixTag = ".MITV-Trash--"

    static func strategy(capabilities: Capabilities) -> DeleteStrategy {
        capabilities.deleteFile ? .hard : .disabled
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