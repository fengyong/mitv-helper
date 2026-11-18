import Foundation

/// 智能分流（纯决策，可测试）。
/// 实测事实（ARCHITECTURE §2）：电视端 MKD 550 不能建目录 → 目标只能用已有目录：
/// 视频 → `Movies/`、图片 → `Pictures/`、对应目录不存在 → 根目录。
/// 说明：视频在 Movies 缺失时不落入 Pictures（两类互不混放），直接回根目录。
enum SmartRouting {

    /// 依据远端根目录列表决定目标目录。目录名匹配大小写不敏感。
    static func destinationDir(kind: MediaKind, rootEntries: [FTPFileEntry]) -> String {
        func hasDir(_ name: String) -> Bool {
            rootEntries.contains { $0.isDirectory && $0.name.lowercased() == name.lowercased() }
        }
        switch kind {
        case .video: return hasDir("Movies") ? "/Movies" : "/"
        case .image: return hasDir("Pictures") ? "/Pictures" : "/"
        case .other: return "/"
        }
    }

    /// 决定最终远端完整路径：GBK 兼容映射 + 重名顺延。
    /// 返回 (完整路径, 远端名, 是否发生了兼容命名映射)。
    static func remoteTarget(displayName: String,
                             dir: String,
                             existingNames: Set<String>) -> (path: String, name: String, needsMapping: Bool) {
        let mapped = NameCodec.remoteName(for: displayName)
        let unique = NameCodec.uniqued(mapped.remote, existing: existingNames)
        let path = dir == "/" ? "/" + unique : dir + "/" + unique
        return (path, unique, mapped.needsMapping)
    }

    /// 一次取回远端目录内已有文件名集合（供重名顺延）
    static func existingNames(entries: [FTPFileEntry]) -> Set<String> {
        Set(entries.map { $0.name })
    }
}
