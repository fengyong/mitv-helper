import Foundation

/// 小数据传输辅助（探测用）：STOR/APPE/RETR 整块搬运。
extension FTPControlConnection {
    func storeData(_ path: String, data: Data) throws {
        try smallTransfer(cmd: "STOR", path: path, data: data)
    }

    func appendData(_ path: String, data: Data) throws {
        try smallTransfer(cmd: "APPE", path: path, data: data)
    }

    private func smallTransfer(cmd: String, path: String, data: Data) throws {
        let d = try beginTransfer(cmd: cmd, path: path)
        do {
            try d.write(data)
            d.shutdownWrite()
            try finishTransfer()
            d.closeNow()
        } catch {
            d.closeNow()
            throw error
        }
    }

    func retrieveData(_ path: String) throws -> Data {
        let d = try beginTransfer(cmd: "RETR", path: path)
        do {
            var acc = [UInt8]()
            var chunk = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = try d.read(&chunk, maxCount: chunk.count)
                if n == 0 { break }
                acc.append(contentsOf: chunk[0..<n])
            }
            d.closeNow()
            try finishTransfer()
            return Data(acc)
        } catch {
            d.closeNow()
            throw error
        }
    }
}

/// 首连能力探测：对远端根做全部 8 项（ARCHITECTURE §5）。
/// 规约：临时文件一律 `mitv-probe-*` 前缀，结束后全部清理（含 MKD 出来的目录，RMD 兜底）。
/// 单项失败不中断探测（矩阵如实记录 false）；只有连接/登录层错误才向外抛。
///
/// 顺序要点：
/// - REST 探测放最后（REST 会为下一条传输命令设置偏移，污染后续传输）
/// - UTF-8 文件名探测在同一连接上切编码进行（编码是客户端侧行为）
/// - 跨目录改名优先用 MKD 出的探针目录；MKD 被拒（如 SwiFTP）则借 LIST 找到的现成目录
enum CapabilityProbe {
    static let probePrefix = "mitv-probe-"

    static func run(conn: FTPControlConnection) throws -> Capabilities {
        var caps = Capabilities()
        let root = "/"

        let fBase = root + probePrefix + "stor.bin"
        let fRenamed = root + probePrefix + "renamed.bin"
        let fAppe = root + probePrefix + "appe.bin"
        let fUtf8Name = probePrefix + "utf8-中文测试.txt"
        let fUtf8 = root + fUtf8Name
        let dProbe = root + probePrefix + "dir"

        var probeFile = fBase // 探针文件当前位置（随改名移动）
        var dirCreated = false
        var sameDirRenameOK = false

        // 1) STOR 基础探针文件（写不进去 → 后续写类探测如实为 false）
        var storOK = false
        do {
            try conn.storeData(fBase, data: Data("MITV".utf8))
            storOK = true
        } catch {
            storOK = false
        }

        // 2) SIZE（探针文件恰好 4 字节，内容一并校验）
        if storOK {
            let sz: Int64? = (try? conn.remoteSize(fBase)) ?? nil
            caps.sizeCommand = (sz == 4)
        }

        // 3) MLSD
        caps.mlsd = ((try? conn.retrieveListing(cmd: "MLSD", path: root)) ?? nil) != nil

        // 4) 同目录改名
        if storOK {
            do {
                try conn.rename(from: fBase, to: fRenamed)
                probeFile = fRenamed
                sameDirRenameOK = true
            } catch {
                sameDirRenameOK = false
            }
        }

        // 5) MKD
        do {
            try conn.makeDirectory(dProbe)
            dirCreated = true
            caps.mkdir = true
        } catch {
            caps.mkdir = false
        }

        // 6) 跨目录改名（软删除依赖）
        var crossOK = false
        var crossTested = false
        if storOK {
            var targetDirs: [String] = dirCreated ? [dProbe] : []
            if targetDirs.isEmpty {
                if let lines = (try? conn.retrieveListing(cmd: "LIST", path: root)) ?? nil {
                    // 借现成目录时多试几个：LIST 第一个可能是只读系统目录，
                    // 只试它会把「能跨目录改名」误判成 false，软删除被错误降级
                    targetDirs = FTPListParser.parse(lines, parentPath: root)
                        .filter { $0.isDirectory && $0.path != root }
                        .prefix(3).map { $0.path }
                }
            }
            for target in targetDirs {
                crossTested = true
                do {
                    try conn.rename(from: probeFile, to: FTPPath.join(target, probePrefix + "cross.bin"))
                    probeFile = FTPPath.join(target, probePrefix + "cross.bin")
                    crossOK = true
                    break
                } catch {
                    crossOK = false
                }
            }
        }
        caps.rename = sameDirRenameOK && (!crossTested || crossOK)

        // 7) DELE（顺带清走探针文件）
        do {
            try conn.deleteFile(probeFile)
            caps.deleteFile = true
        } catch {
            caps.deleteFile = false
        }

        // 8) APPE 续传：STOR "AAAA" + APPE "BBBB" → SIZE == 8
        do {
            try conn.storeData(fAppe, data: Data("AAAA".utf8))
            try conn.appendData(fAppe, data: Data("BBBB".utf8))
            let sz: Int64? = (try? conn.remoteSize(fAppe)) ?? nil
            caps.appeResume = (sz == 8)
        } catch {
            caps.appeResume = false
        }

        // 9) UTF-8 文件名试写读回比对（同一连接切编码；STOR 成功 + LIST 里名字一致 才算通过）
        do {
            conn.config.encoding = .utf8
            try conn.storeData(fUtf8, data: Data("X".utf8))
            var found = false
            if let lines = (try? conn.retrieveListing(cmd: "LIST", path: root)) ?? nil {
                found = FTPListParser.parse(lines, parentPath: root).contains { $0.name == fUtf8Name }
            }
            if !found {
                // 兜底：能按 UTF-8 名原样读回内容也算字节级往返成功
                if let data = (try? conn.retrieveData(fUtf8)) ?? nil, data == Data("X".utf8) {
                    found = true
                }
            }
            caps.utf8Filenames = found
            try? conn.deleteFile(fUtf8)
        } catch {
            caps.utf8Filenames = false
        }

        // 10) REST（放最后：会为下一条传输命令设置偏移）
        do {
            try conn.rest(1)
            caps.restResume = true
        } catch {
            caps.restResume = false
        }

        // 清理：全部尽力而为，探针不留下任何东西
        for p in [fBase, fRenamed, fAppe, fUtf8, probeFile] {
            try? conn.deleteFile(p)
        }
        if dirCreated {
            try? conn.rmdir(dProbe)
        }
        return caps
    }
}
