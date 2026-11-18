// NameCodec 测试套件（由 runner main.swift 调起；断言助手也在 runner 中定义）。
// 注意：本项目把核心与测试源文件合并为单模块编译，无需 import。

enum NameCodecTests {
    static func run() {
        assertEqual(NameCodec.remoteName(for: "movie.mp4").remote, "movie.mp4", "ASCII 原样")
        assertFalse(NameCodec.remoteName(for: "movie.mp4").needsMapping, "ASCII 无映射")

        assertTrue(NameCodec.isGBKRepresentable("周岁生日 [高清]。mp4"), "GBK 可表示实测字符集")
        assertEqual(NameCodec.remoteName(for: "周岁生日.mp4").remote, "周岁生日.mp4", "中文名保留")

        let r = NameCodec.remoteName(for: "生日🎂.mp4")
        assertTrue(r.needsMapping, "emoji 触发映射")
        assertFalse(r.remote.contains("🎂"), "emoji 被替换")
        assertTrue(r.remote.contains("生日"), "可表示部分保留")

        let existing: Set<String> = ["a.mp4", "a (2).mp4"]
        assertEqual(NameCodec.uniqued("a.mp4", existing: existing), "a (3).mp4", "重名顺延")
        assertEqual(NameCodec.uniqued("b.mp4", existing: existing), "b.mp4", "无冲突原样")
    }
}
