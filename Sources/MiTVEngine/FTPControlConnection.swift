import Foundation

// MARK: - 路径工具

/// 远端路径规整/拼接（纯函数，离线可测）
enum FTPPath {
    /// 保证 "/" 开头、去掉尾部 "/"（根除外）；空串 → "/"
    static func normalize(_ path: String) -> String {
        var p = path
        if p.isEmpty { return "/" }
        if !p.hasPrefix("/") { p = "/" + p }
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// 父目录 + 名字 → 完整路径
    static func join(_ parent: String, _ name: String) -> String {
        let p = normalize(parent)
        if p == "/" { return "/" + name }
        return p + "/" + name
    }
}

// MARK: - 控制通道响应

struct FTPReply {
    let code: Int
    let lines: [String]
    /// 多行拼接为一行（错误消息用）
    var text: String { lines.joined(separator: " ") }
}

// MARK: - PASV 响应解析（纯函数，离线可测）

enum FTPPASVParser {
    /// "227 Entering Passive Mode (192,168,1,5,10,20)" → ("192.168.1.5", 2580)
    /// 宽松：取文本中最后一组合法的 6 段逗号分隔数字（h1..h4, p1, p2，各 0-255）。
    static func parse(_ text: String) -> (host: String, port: Int)? {
        guard let regex = try? NSRegularExpression(pattern: "(\\d+),(\\d+),(\\d+),(\\d+),(\\d+),(\\d+)") else {
            return nil
        }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var best: [Int]? = nil
        for m in matches {
            var nums = [Int]()
            var valid = true
            for i in 1...6 {
                let s = ns.substring(with: m.range(at: i))
                guard let v = Int(s), v >= 0, v <= 255 else { valid = false; break }
                nums.append(v)
            }
            if valid, nums.count == 6 { best = nums } // 有多组时取最后一组
        }
        guard let n = best else { return nil }
        let port = n[4] * 256 + n[5]
        guard port > 0, port <= 65535 else { return nil }
        return ("\(n[0]).\(n[1]).\(n[2]).\(n[3])", port)
    }
}

// MARK: - 服务器错误码 → EngineError（映射规约见 ARCHITECTURE §5）

enum FTPErrorMapper {
    enum Op {
        case connect, auth, pasv, list, size, stor, appe, retr
        case dele, rnfr, rnto, mkd, rmd, noop, rest, type, cwd, transfer
    }

    /// 550 → remoteNotFound / permissionDenied（按响应文本判断）；
    /// 530 → authFailed；502（含 500/501/504）→ unsupported；421/断连 → connectionFailed。
    static func map(code: Int, text: String, op: Op, cmd: String) -> EngineError {
        let t = text.lowercased()
        switch code {
        case 421:
            return .connectionFailed("服务器主动断开：\(text)")
        case 425, 426:
            return .connectionFailed("数据连接失败：\(text)")
        case 530, 531:
            return .authFailed
        case 500, 501, 502, 504:
            return .unsupported(cmd)
        case 550, 553:
            if t.contains("permission") || t.contains("denied") || t.contains("not permitted")
                || t.contains("forbidden") || t.contains("not allowed") {
                return .permissionDenied(text)
            }
            if t.contains("not found") || t.contains("no such") || t.contains("doesn't exist")
                || t.contains("does not exist") || t.contains("can't find") || t.contains("cannot find")
                || t.contains("not a directory") || t.contains("failed to open")
                || t.contains("couldn't open") || t.contains("illegal byte sequence") {
                return .remoteNotFound(text)
            }
            switch op {
            case .stor, .appe, .mkd, .rnto, .rmd:
                return .permissionDenied(text) // 写操作被拒（如 SwiFTP MKD 550）
            default:
                return .remoteNotFound(text)
            }
        case 552:
            return .ioError("服务器存储超限：\(text)")
        case 100...499:
            return .connectionFailed("服务器临时错误 \(code)：\(text)")
        default:
            return .protocolError(code, "\(cmd)：\(text)")
        }
    }
}

// MARK: - FTP 控制连接

/// 一条 FTP 控制连接。阻塞 I/O，只允许在引擎后台队列使用。
/// 编码：命令发送与响应解码均按 config.encoding（默认严格 GBK；UTF-8 探测通过才切换）。
final class FTPControlConnection {
    struct Config {
        var connectTimeout: TimeInterval = 6
        var ioTimeout: TimeInterval = 15
        /// 传输收尾（226）等待上限——大文件服务器落盘收尾可能较久
        var finalReplyTimeout: TimeInterval = 180
        /// 数据连接单次读写超时
        var dataIOTimeout: TimeInterval = 30
        /// 控制通道与文件名编码（默认严格 GBK = windowsCP936）
        var encoding: String.Encoding = NameCodec.gbkEncoding
        var user: String? = nil
        var password: String? = nil
    }

    let host: String
    let port: Int
    var config: Config
    private var sock: FTPSocket?
    private var lineBuf: [UInt8] = []

    init(endpoint: FTPEndpoint, config: Config = Config()) {
        self.host = endpoint.host
        self.port = endpoint.port
        self.config = config
        self.config.user = config.user ?? endpoint.user
        self.config.password = config.password ?? endpoint.password
    }

    // MARK: 连接与登录

    func connectAndLogin() throws {
        guard sock == nil else { return }
        let s = try FTPSocket.connect(host: host, port: port, timeout: config.connectTimeout)
        sock = s
        do {
            s.setTimeouts(readTimeout: config.ioTimeout, writeTimeout: config.ioTimeout)
            lineBuf.removeAll(keepingCapacity: true)
            let greeting = try readReply()
            guard greeting.code == 220 else {
                throw FTPErrorMapper.map(code: greeting.code, text: greeting.text, op: .connect, cmd: "GREETING")
            }
            try send("USER", arg: config.user ?? "anonymous")
            var r = try readReply()
            if r.code == 331 {
                try send("PASS", arg: config.password ?? "mitv-helper@local")
                r = try readReply()
            }
            guard r.code == 230 || r.code == 202 else {
                throw FTPErrorMapper.map(code: r.code, text: r.text, op: .auth, cmd: "USER/PASS")
            }
            try send("TYPE", arg: "I")
            let tr = try readReply()
            guard tr.code == 200 || tr.code == 202 else {
                throw FTPErrorMapper.map(code: tr.code, text: tr.text, op: .type, cmd: "TYPE")
            }
        } catch {
            close()
            throw error
        }
    }

    /// 礼貌收尾：QUIT + 关闭（任何错误都忽略）。
    /// 发送失败（连接已死）不再等响应——旧实现在死连接上 readReply 干等满 ioTimeout（15s），
    /// 每次失败传输的收尾都白卡 15 秒；QUIT 响应也只需短超时。
    func quit() {
        if sock != nil {
            if (try? send("QUIT")) != nil {
                sock?.setReadTimeout(2)
                _ = try? readReply()
            }
        }
        close()
    }

    func close() {
        sock?.closeNow()
        sock = nil
    }

    // MARK: 命令发送 / 响应读取

    private func send(_ cmd: String, arg: String? = nil) throws {
        guard let s = sock else { throw EngineError.notConnected }
        var line = cmd
        if let a = arg, !a.isEmpty { line += " " + a }
        line += "\r\n"
        guard let data = line.data(using: config.encoding) else {
            throw EngineError.ioError("命令无法按当前编码发送：\(line)")
        }
        try s.write(data)
    }

    private func readLine() throws -> String {
        guard let s = sock else { throw EngineError.notConnected }
        while true {
            if let idx = lineBuf.firstIndex(of: 0x0A) {
                var end = idx
                if end > 0 && lineBuf[end - 1] == 0x0D { end -= 1 }
                let bytes = Array(lineBuf[0..<end])
                lineBuf.removeFirst(idx + 1)
                return FTPControlConnection.decode(bytes, encoding: config.encoding)
            }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = try s.read(&chunk, maxCount: chunk.count)
            if n == 0 { throw EngineError.connectionFailed("控制连接已被服务器关闭") }
            lineBuf.append(contentsOf: chunk[0..<n])
        }
    }

    /// 按配置编码解码；失败时依次回退 UTF-8 / 有损解码
    static func decode(_ bytes: [UInt8], encoding: String.Encoding) -> String {
        let data = Data(bytes)
        if let s = String(data: data, encoding: encoding) { return s }
        if let s = String(data: data, encoding: .utf8) { return s }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// 读一条完整响应（支持 ddd- 多行，直到 ddd<space> 结束）
    func readReply() throws -> FTPReply {
        var lines = [String]()
        var code = 0
        while true {
            let line = try readLine()
            let prefix3 = String(line.prefix(3))
            if line.count == 3, let c = Int(prefix3), c >= 100 {
                if code == 0 { code = c }
                lines.append(line)
                return FTPReply(code: code, lines: lines)
            }
            let sep = line.dropFirst(3).first
            if let c = Int(prefix3), c >= 100, sep == " " {
                if code == 0 { code = c }
                lines.append(line)
                return FTPReply(code: code, lines: lines)
            }
            if let c = Int(prefix3), c >= 100, sep == "-", (code == 0 || c == code) {
                if code == 0 { code = c }
                lines.append(line)
                continue
            }
            guard !lines.isEmpty else {
                throw EngineError.protocolError(0, "控制通道响应格式异常：\(line)")
            }
            lines.append(line) // 多行中间的自由文本行，容错收集
        }
    }

    /// 传输收尾专用：放宽读超时再等响应
    func readFinalReply() throws -> FTPReply {
        sock?.setReadTimeout(config.finalReplyTimeout)
        defer { sock?.setReadTimeout(config.ioTimeout) }
        return try readReply()
    }

    @discardableResult
    func expectReply(_ okCodes: [Int], op: FTPErrorMapper.Op, cmd: String) throws -> FTPReply {
        let r = try readReply()
        guard okCodes.contains(r.code) else {
            throw FTPErrorMapper.map(code: r.code, text: r.text, op: op, cmd: cmd)
        }
        return r
    }

    // MARK: 数据连接（严格 PASV——实测服务器不支持 EPSV）

    func openDataConnection() throws -> FTPSocket {
        try send("PASV")
        let r = try readReply()
        guard r.code == 227, let hp = FTPPASVParser.parse(r.text) else {
            throw FTPErrorMapper.map(code: r.code, text: r.text, op: .pasv, cmd: "PASV")
        }
        var target = hp.host
        // 服务器误报回环/通配地址时回退到控制连接主机
        if target == "127.0.0.1" || target == "0.0.0.0" { target = host }
        let d = try FTPSocket.connect(host: target, port: hp.port, timeout: config.connectTimeout)
        d.setTimeouts(readTimeout: config.dataIOTimeout, writeTimeout: config.dataIOTimeout)
        return d
    }

    /// 建数据连接并下达传输命令（STOR/APPE/RETR）；成功返回数据 socket
    func beginTransfer(cmd: String, path: String) throws -> FTPSocket {
        let op: FTPErrorMapper.Op
        switch cmd.uppercased() {
        case "RETR": op = .retr
        case "APPE": op = .appe
        default: op = .stor
        }
        let d = try openDataConnection()
        do {
            try send(cmd, arg: path)
            let r = try readReply()
            guard r.code == 150 || r.code == 125 else {
                throw FTPErrorMapper.map(code: r.code, text: r.text, op: op, cmd: cmd)
            }
            return d
        } catch {
            d.closeNow()
            throw error
        }
    }

    /// 传输完成确认（226/250），使用放宽的超时
    func finishTransfer() throws {
        let r = try readFinalReply()
        guard r.code == 226 || r.code == 250 else {
            throw FTPErrorMapper.map(code: r.code, text: r.text, op: .transfer, cmd: "TRANSFER")
        }
    }

    // MARK: 目录/文件命令

    /// LIST / MLSD 原始行（读到数据连接 EOF 为止）
    func retrieveListing(cmd: String, path: String) throws -> [String] {
        let d = try openDataConnection()
        var accepted = false
        do {
            try send(cmd, arg: path)
            let r = try readReply()
            guard r.code == 150 || r.code == 125 else {
                throw FTPErrorMapper.map(code: r.code, text: r.text, op: .list, cmd: cmd)
            }
            accepted = true
            var acc = [UInt8]()
            var chunk = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = try d.read(&chunk, maxCount: chunk.count)
                if n == 0 { break }
                acc.append(contentsOf: chunk[0..<n])
            }
            d.closeNow()
            let final = try readFinalReply()
            guard final.code == 226 || final.code == 250 else {
                throw FTPErrorMapper.map(code: final.code, text: final.text, op: .transfer, cmd: cmd)
            }
            return FTPControlConnection.splitLines(acc, encoding: config.encoding)
        } catch {
            d.closeNow()
            // 命令已被接受（150）但中途失败：服务器还会发 226/426 收尾响应。
            // 不吸收掉这条残留响应，同一连接上的下一条命令（如 MLSD→LIST 回退）
            // 会把它当成自己的应答，整个控制通道从此错位。
            if accepted {
                sock?.setReadTimeout(2)
                _ = try? readReply()
                sock?.setReadTimeout(config.ioTimeout)
            }
            throw error
        }
    }

    /// 按 LF（容忍 CRLF/裸 CR 尾）切行
    static func splitLines(_ bytes: [UInt8], encoding: String.Encoding) -> [String] {
        var lines = [String]()
        var start = 0
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x0A {
                var end = i
                if end > start && bytes[end - 1] == 0x0D { end -= 1 }
                if end > start { lines.append(decode(Array(bytes[start..<end]), encoding: encoding)) }
                start = i + 1
            }
            i += 1
        }
        if start < bytes.count {
            var end = bytes.count
            if bytes[end - 1] == 0x0D { end -= 1 }
            if end > start { lines.append(decode(Array(bytes[start..<end]), encoding: encoding)) }
        }
        return lines
    }

    func noop() throws {
        try send("NOOP")
        _ = try expectReply([200, 202], op: .noop, cmd: "NOOP")
    }

    func cwd(_ path: String) throws {
        try send("CWD", arg: path)
        _ = try expectReply([250, 200], op: .cwd, cmd: "CWD")
    }

    func deleteFile(_ path: String) throws {
        try send("DELE", arg: path)
        _ = try expectReply([250], op: .dele, cmd: "DELE")
    }

    func rmdir(_ path: String) throws {
        try send("RMD", arg: path)
        _ = try expectReply([250], op: .rmd, cmd: "RMD")
    }

    func makeDirectory(_ path: String) throws {
        try send("MKD", arg: path)
        _ = try expectReply([257, 250], op: .mkd, cmd: "MKD")
    }

    /// RNFR + RNTO（改名/移动，含跨目录）
    func rename(from: String, to: String) throws {
        try send("RNFR", arg: from)
        _ = try expectReply([350], op: .rnfr, cmd: "RNFR")
        try send("RNTO", arg: to)
        _ = try expectReply([250], op: .rnto, cmd: "RNTO")
    }

    /// REST 仅用于能力探测（实测电视端 502，不可用于续传）
    func rest(_ offset: Int64) throws {
        try send("REST", arg: String(offset))
        _ = try expectReply([350], op: .rest, cmd: "REST")
    }

    /// SIZE；nil = 目录或不存在（不视为错误）；SIZE 命令本身不被支持（502）→ unsupported
    func remoteSize(_ path: String) throws -> Int64? {
        try send("SIZE", arg: path)
        let r = try readReply()
        if r.code == 213 {
            let s = r.text.dropFirst(3).trimmingCharacters(in: .whitespaces)
            return Int64(s)
        }
        if r.code == 550 || r.code == 553 { return nil }
        throw FTPErrorMapper.map(code: r.code, text: r.text, op: .size, cmd: "SIZE")
    }
}
