// EngineTests_A —— FTP 引擎离线单测（不依赖网络）。
// 覆盖：LIST/MLSD 解析、PASV 响应解析、APPE 偏移计算、进度节流、GBK 命令编码字节、错误映射、路径工具、响应行切分。
import Foundation

enum EngineTests_A {
    static func run() {

        // MARK: PASV 响应解析

        let p1 = FTPPASVParser.parse("227 Entering Passive Mode (192,168,1,5,10,20).")
        assertTrue(p1 != nil, "PASV 标准括号格式可解析")
        assertEqual(p1?.host ?? "", "192.168.1.5", "PASV host")
        assertEqual(p1?.port ?? 0, 10 * 256 + 20, "PASV port = p1*256+p2")

        let p2 = FTPPASVParser.parse("227 Entering passive mode (127,0,0,1,160,132)")
        assertEqual(p2?.host ?? "", "127.0.0.1", "PASV 小写 passive")
        assertEqual(p2?.port ?? 0, 160 * 256 + 132, "PASV 大端口 41092")

        let p3 = FTPPASVParser.parse("227 Passive mode h1,h2,h3,h4,p1,p2 (1,2,3,4,5,6)")
        assertTrue(p3 != nil, "无括号文本可解析")
        assertEqual(p3?.host ?? "", "1.2.3.4", "多组数字取最后一组")

        let p4 = FTPPASVParser.parse("227 Entering Passive Mode (192,168,1,300,10,20)")
        assertTrue(p4 == nil, "段超 255 拒绝")

        let p5 = FTPPASVParser.parse("500 PASV not understood")
        assertTrue(p5 == nil, "非 227 文本返回 nil")

        // MARK: LIST 解析（unix ls -l 风格）

        let unix = FTPListParser.parse([
            "total 24",
            "-rw-r--r-- 1 owner group 12345 Nov 18 10:30 周岁生日.mp4",
            "drwxr-xr-x 5 owner group     4096 Nov 18 10:31 Movies",
            "-rw-r--r-- 1 owner group  88 Nov 18 10:32 with double  space.txt",
            "",
            ".",
            "..",
        ], parentPath: "/")
        assertEqual(unix.count, 3, "噪声行/./.. 被跳过")
        assertEqual(unix[0].name, "周岁生日.mp4", "unix 中文文件名")
        assertEqual(unix[0].path, "/周岁生日.mp4", "根路径拼接")
        assertFalse(unix[0].isDirectory, "unix 文件类型位 -")
        assertEqual(unix[0].size ?? -1, 12345, "unix size")
        assertTrue(unix[0].modified != nil, "unix 传统日期可解析")
        assertEqual(unix[1].name, "Movies", "unix 目录名")
        assertTrue(unix[1].isDirectory, "unix 目录类型位 d")
        assertEqual(unix[1].size ?? -1, 4096, "unix 目录 size")
        assertEqual(unix[2].name, "with double  space.txt", "名字内空格保留原文")
        assertEqual(unix[2].size ?? -1, 88, "多空格行 size 不受影响")

        // busybox/toybox 风格（ISO 日期 + 数字 owner/group）
        let busy = FTPListParser.parse([
            "-rw-rw-r-- 1000 1000 777 2020-01-01 12:00 a.mp4",
            "drwxrwx--x root sdcard_r 4096 2021-02-03 08:05 DCIM",
        ], parentPath: "/Movies")
        assertEqual(busy.count, 2, "busybox 两行都解析")
        assertEqual(busy[0].size ?? -1, 777, "busybox 数字 uid/gid 逆序取 size")
        assertEqual(busy[0].path, "/Movies/a.mp4", "子目录路径拼接")
        assertEqual(busy[1].name, "DCIM", "busybox 目录")
        assertTrue(busy[1].isDirectory, "busybox 目录类型")

        // 符号链接 + 尾斜杠目录
        let link = FTPListParser.parse([
            "lrwxrwxrwx 1 u g 7 Nov 18 10:30 latest.mp4 -> v2.mp4",
            "drwxr-xr-x 2 u g 4096 Nov 18 10:30 dirslash/",
        ], parentPath: "/")
        assertEqual(link[0].name, "latest.mp4", "符号链接剥离 -> 目标")
        assertFalse(link[0].isDirectory, "符号链接按文件")
        assertEqual(link[1].name, "dirslash", "尾斜杠目录名剥离")
        assertTrue(link[1].isDirectory, "尾斜杠识别为目录")

        // 无日期行 + 裸文件名行
        let odd = FTPListParser.parse([
            "-rw-r--r-- 1 u g 42 ftf.mp4",
            "bare-name.mkv",
        ], parentPath: "/")
        assertEqual(odd.count, 2, "无日期/裸行容错")
        assertEqual(odd[0].name, "ftf.mp4", "无日期行取末 token")
        assertEqual(odd[0].size ?? -1, 42, "无日期行 size 逆序提取")
        assertEqual(odd[1].name, "bare-name.mkv", "裸文件名行")

        // Windows 风格
        let win = FTPListParser.parse([
            "11-18-26  10:30AM  <DIR>  Movies",
            "11-18-26  10:31AM  12345  a b.mp4",
        ], parentPath: "/")
        assertEqual(win.count, 2, "Windows 两行")
        assertTrue(win[0].isDirectory, "Windows <DIR>")
        assertEqual(win[1].size ?? -1, 12345, "Windows size")
        assertEqual(win[1].name, "a b.mp4", "Windows 名带空格")

        // MARK: MLSD 解析

        let ml = FTPMLSDParser.parse([
            "type=dir;size=0;modify=20201118103000; Movies",
            "type=file;size=12345;modify=20201118103045; 周岁生日.mp4",
            "type=unix.symlink;size=0;modify=20201118103000; link.mp4",
            "",
        ], parentPath: "/Movies")
        assertEqual(ml.count, 3, "MLSD 三行")
        assertTrue(ml[0].isDirectory, "MLSD type=dir")
        assertEqual(ml[0].path, "/Movies/Movies", "MLSD 路径")
        assertEqual(ml[1].size ?? -1, 12345, "MLSD size")
        assertTrue(ml[1].modified != nil, "MLSD modify 时间戳")
        assertFalse(ml[2].isDirectory, "MLSD OS.* 类型按文件兜底")

        // MARK: APPE 续传偏移计算（SIZE 校验 + APPE，REST 不可用）

        assertEqual(FTPTransferPlanner.resumeOffset(remoteSize: 100, localSize: 500) ?? -1, 100,
                    "远端<本地 → seek 到远端大小")
        assertEqual(FTPTransferPlanner.resumeOffset(remoteSize: 500, localSize: 500) ?? -1, 500,
                    "远端==本地 → seek 到末尾（0 字节追加收尾）")
        assertTrue(FTPTransferPlanner.resumeOffset(remoteSize: 600, localSize: 500) == nil,
                   "远端>本地 → 整传")
        assertTrue(FTPTransferPlanner.resumeOffset(remoteSize: 0, localSize: 500) == nil,
                   "远端不存在(0) → 整传")
        assertTrue(FTPTransferPlanner.resumeOffset(remoteSize: -1, localSize: 500) == nil,
                   "远端异常值 → 整传")
        assertTrue(FTPTransferPlanner.resumeOffset(remoteSize: 100, localSize: 0) == nil,
                   "本地空文件 → 整传")

        // MARK: 进度节流（≥100ms）

        let t = FTPProgressThrottler(minInterval: 0.1)
        assertTrue(t.shouldEmit(now: 10.0), "首次必发")
        assertFalse(t.shouldEmit(now: 10.05), "50ms 内被节流")
        assertFalse(t.shouldEmit(now: 10.099), "99ms 内被节流")
        assertTrue(t.shouldEmit(now: 10.11), "间隔 ≥100ms 放行（避开浮点边界）")
        t.forceEmit(now: 10.15)
        assertFalse(t.shouldEmit(now: 10.2), "forceEmit 后重新计时")

        // MARK: GBK 命令编码字节（严格 GBK = windowsCP936）

        let gbkCmd = "STOR /周岁.mp4\r\n".data(using: NameCodec.gbkEncoding) ?? Data()
        assertEqual(Array(gbkCmd),
                    [0x53, 0x54, 0x4F, 0x52, 0x20, 0x2F, 0xD6, 0xDC, 0xCB, 0xEA, 0x2E, 0x6D, 0x70, 0x34, 0x0D, 0x0A],
                    "STOR 中文路径按 GBK 逐字节编码（周=D6DC 岁=CBEA）")

        let gbkName = "周岁生日 [高清]。mp4".data(using: NameCodec.gbkEncoding) ?? Data()
        assertEqual(gbkName.count, 20, "实测中文名 GBK 字节数")
        assertEqual(Array(gbkName.prefix(4)), [0xD6, 0xDC, 0xCB, 0xEA], "『周岁』GBK 字节")

        // 控制通道解码：GBK 字节 → 中文
        let decoded = FTPControlConnection.decode([0x32, 0x35, 0x30, 0x20, 0xD6, 0xD0], encoding: NameCodec.gbkEncoding)
        assertEqual(decoded, "250 中", "GBK 响应解码")

        assertTrue(NameCodec.isGBKRepresentable("周岁生日 [高清]。mp4"), "实测字符集可 GBK 编码（对齐契约）")

        // MARK: 错误映射（550/530/502/421 规约）

        let e1 = FTPErrorMapper.map(code: 550, text: "No such file or directory.", op: .retr, cmd: "RETR")
        assertTrue(matches(e1) { if case .remoteNotFound = $0 { return true }; return false },
                   "550 not found → remoteNotFound")
        let e2 = FTPErrorMapper.map(code: 550, text: "Permission denied.", op: .retr, cmd: "RETR")
        assertTrue(matches(e2) { if case .permissionDenied = $0 { return true }; return false },
                   "550 denied → permissionDenied")
        let e3 = FTPErrorMapper.map(code: 550, text: "Couldn't create directory", op: .mkd, cmd: "MKD")
        assertTrue(matches(e3) { if case .permissionDenied = $0 { return true }; return false },
                   "550 MKD 无关键词 → 写操作按 permissionDenied")
        let e4 = FTPErrorMapper.map(code: 550, text: "Could not create file.", op: .stor, cmd: "STOR")
        assertTrue(matches(e4) { if case .permissionDenied = $0 { return true }; return false },
                   "550 STOR 默认 → permissionDenied")
        let e5 = FTPErrorMapper.map(code: 530, text: "Login incorrect.", op: .auth, cmd: "USER")
        assertTrue(matches(e5) { if case .authFailed = $0 { return true }; return false },
                   "530 → authFailed")
        let e6 = FTPErrorMapper.map(code: 502, text: "Command not implemented.", op: .rest, cmd: "REST")
        assertTrue(matches(e6) { if case .unsupported = $0 { return true }; return false },
                   "502 → unsupported")
        let e7 = FTPErrorMapper.map(code: 421, text: "Service not available.", op: .noop, cmd: "NOOP")
        assertTrue(matches(e7) { if case .connectionFailed = $0 { return true }; return false },
                   "421 → connectionFailed")

        // MARK: 路径工具

        assertEqual(FTPPath.normalize(""), "/", "空路径 → 根")
        assertEqual(FTPPath.normalize("Movies"), "/Movies", "无前导斜杠补全")
        assertEqual(FTPPath.normalize("/Movies/"), "/Movies", "尾斜杠剥离")
        assertEqual(FTPPath.normalize("/"), "/", "根保持")
        assertEqual(FTPPath.join("/", "Movies"), "/Movies", "根下拼接")
        assertEqual(FTPPath.join("/Movies/", "a.mp4"), "/Movies/a.mp4", "子目录拼接")

        // MARK: 响应/数据行切分（CRLF / 裸 LF / 尾行无换行）

        let lines = FTPControlConnection.splitLines(Array("a\r\nbb\r\nccc".utf8), encoding: .utf8)
        assertEqual(lines, ["a", "bb", "ccc"], "CRLF+尾行切分")
        let lines2 = FTPControlConnection.splitLines(Array("x\ny\n".utf8), encoding: .utf8)
        assertEqual(lines2, ["x", "y"], "裸 LF 切分")
    }

    /// EngineError 带关联值无法 ==，用模式匹配判定
    private static func matches(_ e: Error, _ test: (EngineError) -> Bool) -> Bool {
        guard let engineError = e as? EngineError else { return false }
        return test(engineError)
    }
}
