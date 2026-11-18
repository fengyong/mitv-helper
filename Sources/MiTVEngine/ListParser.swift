import Foundation

// MARK: - LIST 解析（unix ls -l 风格为主、Windows 风格兜底、宽松容错）

enum FTPListParser {
    /// 解析 LIST 输出；噪声行（空行 / total N / "." / ".."）跳过。
    static func parse(_ rawLines: [String], parentPath: String) -> [FTPFileEntry] {
        var out = [FTPFileEntry]()
        for raw in rawLines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || isNoise(line) { continue }
            if let e = parseLine(line, parentPath: parentPath) { out.append(e) }
        }
        return out
    }

    static func isNoise(_ line: String) -> Bool {
        let lower = line.lowercased()
        return lower.hasPrefix("total ") || lower == "total"
    }

    /// 单行解析。识别不了时尽量按裸文件名兜底；仍不行返回 nil。
    static func parseLine(_ line: String, parentPath: String) -> FTPFileEntry? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let tokens = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }

        // Windows 风格："11-18-26 10:30AM <DIR> Movies" / "11-18-26 10:30AM 12345 a.mp4"
        if tokens.count >= 4, isWindowsDate(tokens[0]), isWindowsTime(tokens[1]) {
            return parseWindows(tokens, line: trimmed, parentPath: parentPath)
        }

        let first = trimmed.first ?? "-"
        // 单 token 行 / 首字符非类型位 → 裸文件名行（NLIST、部分嵌入式服务器；整行作名字，空格保留）
        let looksLikeUnixPerms = tokens.count >= 2 && "-dlbcpsDL".contains(first)
        if !looksLikeUnixPerms {
            var name = trimmed
            var isDir = false
            if name.hasSuffix("/") { name = String(name.dropLast()); isDir = true }
            if name == "." || name == ".." { return nil }
            return makeEntry(name: name, isDirectory: isDir, size: nil, modified: nil, parentPath: parentPath)
        }

        let dateStart = findDateStart(tokens)

        // size = 日期块之前最后一个纯数字 token（links/owner/group 一般非数字；即便为数字，逆序取最后一个即 size）
        var size: Int64? = nil
        if let ds = dateStart, ds > 1 {
            for i in (1..<ds).reversed() {
                if let v = Int64(tokens[i]) { size = v; break }
            }
        }

        // 名字起点：日期块之后是「时间/年份」token（可能缺失，如 "Nov 18 file.mp4"），名字紧随其后；
        // 无日期行兜底为最后一个 token
        var nameStart: Int
        if let ds = dateStart {
            let timeSlot = tokens[ds].contains("-") ? ds + 1 : ds + 2 // ISO 日期后一段；unix 传统月名的「日」后一段
            if timeSlot < tokens.count, looksLikeTimeOrYear(tokens[timeSlot]) {
                nameStart = timeSlot + 1
            } else {
                nameStart = timeSlot // 时间字段缺失：名字紧跟日期
            }
        } else {
            nameStart = tokens.count - 1
            if tokens.count > 2 {
                for i in (1..<tokens.count - 1).reversed() {
                    if let v = Int64(tokens[i]) { size = v; break }
                }
            }
        }
        guard nameStart < tokens.count else { return nil }
        let nameRaw: String
        if dateStart != nil {
            nameRaw = substringFromToken(trimmed, tokenIndex: nameStart)
                ?? tokens[nameStart...].joined(separator: " ")
        } else {
            nameRaw = tokens[nameStart...].joined(separator: " ")
        }

        var name = nameRaw
        var isDir = (first == "d")
        if first == "l", let arrow = name.range(of: " -> ") {
            name = String(name[..<arrow.lowerBound]) // 符号链接：剥离 " -> 目标"
        }
        if name.hasSuffix("/") { name = String(name.dropLast()); isDir = true }
        if name == "." || name == ".." { return nil }
        let modified = parseUnixDate(tokens, dateStart: dateStart)
        return makeEntry(name: name, isDirectory: isDir, size: size, modified: modified, parentPath: parentPath)
    }

    // MARK: 内部

    static func makeEntry(name: String, isDirectory: Bool, size: Int64?, modified: Date?, parentPath: String) -> FTPFileEntry {
        FTPFileEntry(path: FTPPath.join(parentPath, name), name: name,
                     isDirectory: isDirectory, size: size, modified: modified)
    }

    static let months: Set<String> = ["jan", "feb", "mar", "apr", "may", "jun",
                                      "jul", "aug", "sep", "oct", "nov", "dec"]

    /// 日期块起点：月名缩写（Nov）或 ISO 数字日期（2020-01-01 / 11-18-26）
    static func findDateStart(_ tokens: [String]) -> Int? {
        guard tokens.count > 1 else { return nil }
        for i in 1..<tokens.count {
            let t = tokens[i].lowercased()
            if months.contains(t) { return i }
            if looksLikeNumericDate(t) { return i }
        }
        return nil
    }

    static func looksLikeNumericDate(_ s: String) -> Bool {
        let parts = s.split(separator: "-")
        return parts.count == 3 && parts.allSatisfy({ Int($0) != nil })
    }

    static func looksLikeTimeOrYear(_ s: String) -> Bool {
        if s.contains(":") { return true }
        if s.count == 4, Int(s) != nil { return true } // 年份
        let u = s.uppercased()
        return u.hasSuffix("AM") || u.hasSuffix("PM")
    }

    /// Windows 日期首段（1-2 位开头；4 位开头的 ISO 日期归 unix 分支）
    static func isWindowsDate(_ s: String) -> Bool {
        let parts = s.split(separator: "-")
        guard parts.count == 3, parts.allSatisfy({ Int($0) != nil }) else { return false }
        return parts[0].count <= 2
    }

    static func isWindowsTime(_ s: String) -> Bool {
        let u = s.uppercased()
        let core = (u.hasSuffix("AM") || u.hasSuffix("PM")) ? String(u.dropLast(2)) : u
        guard core.contains(":") else { return false }
        return Int(core.replacingOccurrences(of: ":", with: "")) != nil
    }

    static func parseWindows(_ tokens: [String], line: String, parentPath: String) -> FTPFileEntry? {
        // [date, time, <DIR>|size, name...]
        let third = tokens[2].uppercased()
        let isDir = (third == "<DIR>")
        let size: Int64? = isDir ? nil : Int64(tokens[2])
        var name = substringFromToken(line, tokenIndex: 3) ?? tokens[3...].joined(separator: " ")
        if name.hasSuffix("/") { name = String(name.dropLast()) }
        if name == "." || name == ".." { return nil }
        return makeEntry(name: name, isDirectory: isDir, size: size, modified: nil, parentPath: parentPath)
    }

    /// "Nov 18 10:30" / "Nov 18 2020" / "2020-01-01 12:00" → Date（宽松，失败返回 nil）
    static func parseUnixDate(_ tokens: [String], dateStart: Int?) -> Date? {
        guard let ds = dateStart, ds < tokens.count else { return nil }
        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        let t0 = tokens[ds].lowercased()

        var comps = DateComponents()
        if months.contains(t0) {
            guard tokens.count > ds + 2, let day = Int(tokens[ds + 1]) else { return nil }
            guard months.contains(t0) else { return nil }
            // Set 无稳定顺序 → 用固定表
            let order = ["jan", "feb", "mar", "apr", "may", "jun",
                         "jul", "aug", "sep", "oct", "nov", "dec"]
            guard let m = order.firstIndex(of: t0) else { return nil }
            comps.month = m + 1
            comps.day = day
            var year = cal.component(.year, from: now)
            var recent = false
            let last = tokens[ds + 2]
            if !last.contains(":"), Int(last) == nil {
                return nil // 无时间/年份字段（名字紧跟日期），日期信息不完整
            }
            if last.contains(":") {
                let parts = last.split(separator: ":")
                comps.hour = Int(parts.first ?? "0") ?? 0
                comps.minute = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
                recent = true
            } else if let y = Int(last), y >= 1970 {
                year = y
            }
            comps.year = year
            guard let d = cal.date(from: comps) else { return nil }
            if recent, d.timeIntervalSince(now) > 48 * 3600 {
                var c2 = comps
                c2.year = year - 1 // ls 惯例：超过半年的时间只显示年份
                return cal.date(from: c2) ?? d
            }
            return d
        }
        if looksLikeNumericDate(t0) {
            let parts = tokens[ds].split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            comps.year = parts[0]; comps.month = parts[1]; comps.day = parts[2]
            if tokens.count > ds + 1, tokens[ds + 1].contains(":") {
                let tp = tokens[ds + 1].split(separator: ":")
                comps.hour = Int(tp.first ?? "0") ?? 0
                comps.minute = tp.count > 1 ? Int(tp[1]) ?? 0 : 0
            }
            return cal.date(from: comps)
        }
        return nil
    }

    /// 取第 tokenIndex 个 token 起到行尾的原文（保留名字中的原始空格）
    static func substringFromToken(_ line: String, tokenIndex: Int) -> String? {
        var seen = 0
        var prevSpace = true
        for (pos, ch) in line.enumerated() {
            if ch == " " || ch == "\t" { prevSpace = true; continue }
            if prevSpace {
                if seen == tokenIndex {
                    return String(line[line.index(line.startIndex, offsetBy: pos)...])
                }
                seen += 1
                prevSpace = false
            }
        }
        return nil
    }
}

// MARK: - MLSD 解析（RFC 3659 facts 行）

enum FTPMLSDParser {
    static func parse(_ rawLines: [String], parentPath: String) -> [FTPFileEntry] {
        var out = [FTPFileEntry]()
        for raw in rawLines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if let e = parseLine(line, parentPath: parentPath) { out.append(e) }
        }
        return out
    }

    /// "type=dir;size=0;modify=20201118103000; Movies" → entry
    static func parseLine(_ line: String, parentPath: String) -> FTPFileEntry? {
        guard let sp = line.firstIndex(of: " ") else { return nil }
        let factsPart = String(line[..<sp])
        let name = String(line[line.index(after: sp)...])
        if name.isEmpty || name == "." || name == ".." { return nil }

        var isDir = false
        var size: Int64? = nil
        var modified: Date? = nil
        for fact in factsPart.split(separator: ";") {
            let f = fact.trimmingCharacters(in: .whitespaces)
            let kv = f.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let key = kv[0].lowercased()
            let value = String(kv[1])
            switch key {
            case "type":
                let v = value.lowercased()
                isDir = (v == "dir" || v == "cdir" || v == "pdir")
            case "size":
                size = Int64(value)
            case "modify", "created":
                if let d = parseTimestamp(value) { modified = d }
            default:
                break // unique/perm/unix.* 等忽略
            }
        }
        return FTPFileEntry(path: FTPPath.join(parentPath, name), name: name,
                            isDirectory: isDir, size: size, modified: modified)
    }

    /// YYYYMMDDHHMMSS（容忍小数毫秒/时区尾巴）→ Date
    static func parseTimestamp(_ s: String) -> Date? {
        let digits = s.prefix(14)
        guard digits.count == 14 else { return nil }
        let str = String(digits)
        guard let y = Int(str.prefix(4)),
              let mo = Int(str.dropFirst(4).prefix(2)),
              let d = Int(str.dropFirst(6).prefix(2)),
              let h = Int(str.dropFirst(8).prefix(2)),
              let mi = Int(str.dropFirst(10).prefix(2)),
              let se = Int(str.dropFirst(12).prefix(2)) else { return nil }
        var comps = DateComponents()
        comps.year = y; comps.month = mo; comps.day = d
        comps.hour = h; comps.minute = mi; comps.second = se
        return Calendar(identifier: .gregorian).date(from: comps)
    }
}
