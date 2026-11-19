import Foundation

/// 智能分流（纯决策，可测试）。
/// 产品决策（2026-11-19 定案）：视频恒定目标 /Movies、图片恒定 /Pictures、其他 → 根目录。
/// 目录不存在时由 QueueService 尽力 MKD 创建；创建被拒（如真机 SwiFTP MKD 550）→ 回退根目录。
/// 早期「目录缺失直接回根」的行为已废弃（会把 MKD 机会掐死，永远建不出分类目录）。
enum SmartRouting {

    static func destinationDir(kind: MediaKind) -> String {
        switch kind {
        case .video: return "/Movies"
        case .image: return "/Pictures"
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

    /// 同名不同内容的兜底名：stem-<md5 前 8 位>.ext
    /// （指纹=文件前 min(大小,10MB) 字节的 md5——小文件即全文件 md5，大文件前 10M 指纹）
    static func md5SuffixedName(_ name: String, digest8: String) -> String {
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? "\(stem)-\(digest8)" : "\(stem)-\(digest8).\(ext)"
    }
}
