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

        // 特殊字符净化：尽可能保留原名，风险字符替换为 "-"
        assertEqual(NameCodec.remoteName(for: "a:b.mp4").remote, "a-b.mp4", "冒号替换")
        assertTrue(NameCodec.remoteName(for: "a:b.mp4").needsMapping, "冒号标记改写")
        assertEqual(NameCodec.remoteName(for: "a/b\\c*d.mp4").remote, "a-b-c-d.mp4", "路径/通配字符替换")
        assertEqual(NameCodec.remoteName(for: "名字?.mp4").remote, "名字-.mp4", "问号替换")
        assertEqual(NameCodec.remoteName(for: "name. ").remote, "name", "尾部空格/点去除(FAT32)")
        assertEqual(NameCodec.remoteName(for: "  lead.mp4").remote, "lead.mp4", "首部空格去除")
        assertEqual(NameCodec.remoteName(for: "...").remote, "file", "整名特殊字符兜底")
        assertEqual(NameCodec.remoteName(for: "a\tb.mp4").remote, "a-b.mp4", "控制字符替换")
        assertFalse(NameCodec.remoteName(for: "正常名字 [高清].mp4").needsMapping, "GBK 可表示且安全 → 不改写")
        assertEqual(NameCodec.uniqued("a.mp4", existing: ["A.mp4"], caseInsensitive: true), "a (2).mp4", "大小写不敏感重名顺延")
        assertEqual(NameCodec.uniqued("a.mp4", existing: ["A.mp4"]), "a.mp4", "默认大小写敏感（契约不变）")

        // FAT NAME_MAX=255 字节：GBK 中文 2 字节/字，长名必须按字节截断且保留扩展名
        func gbkBytes(_ s: String) -> Int { s.data(using: NameCodec.gbkEncoding)?.count ?? .max }
        let longCN = String(repeating: "电", count: 200) + ".mp4"
        let cn = NameCodec.remoteName(for: longCN)
        assertTrue(gbkBytes(cn.remote) <= NameCodec.maxNameBytes, "中文长名截断到 255 字节内")
        assertTrue(cn.remote.hasSuffix(".mp4"), "截断保留扩展名")
        assertTrue(cn.needsMapping, "截断标记改写")
        assertTrue(NameCodec.isGBKRepresentable(cn.remote), "截断结果 GBK 可表示（不切断双字节）")
        let longASCII = String(repeating: "b", count: 300) + ".mp4"
        assertTrue(gbkBytes(NameCodec.remoteName(for: longASCII).remote) <= NameCodec.maxNameBytes, "ASCII 长名截断")
        assertEqual(NameCodec.capped("短名.mp4").truncated, false, "短名不截断")
        assertEqual(NameCodec.capped("短名.mp4").name, "短名.mp4", "短名原样")
        let nearLimit = String(repeating: "b", count: 250) + ".mp4"
        let deduped = NameCodec.uniqued(nearLimit, existing: [nearLimit])
        assertTrue(gbkBytes(NameCodec.capped(deduped).name) <= NameCodec.maxNameBytes, "重名顺延后再截断仍 ≤255")
        let longTrash = SoftDeletePolicy.prefixTrashName(forRemotePath: "/" + String(repeating: "目录", count: 100) + "/" + longCN)
        assertTrue(gbkBytes(longTrash) <= NameCodec.maxNameBytes, "回收站前缀名截断到 255 字节内")
        assertTrue(longTrash.hasPrefix(SoftDeletePolicy.prefixTag), "截断保留回收站前缀")
        let longFlat = SoftDeletePolicy.flattenParent(ofPath: "/" + String(repeating: "目录", count: 100) + "/f.mp4")
        assertTrue(gbkBytes(longFlat) <= NameCodec.maxNameBytes, "扁平化父目录截断到 255 字节内")
    }
}
