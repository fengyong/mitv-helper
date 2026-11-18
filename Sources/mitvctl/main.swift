import Foundation

// mitvctl —— MiTV Helper 传输引擎无头 CLI（ARCHITECTURE.md §5）。
// 子命令：ping / probe / list / upload / download / delete / move / mkdir
// 退出码：0 成功；1 运行错误；2 参数错误。错误一律走 stderr。
//
// 注意：引擎 completion 一律派发主队列——CLI 在主线程 dispatchMain() 等待，回调内 exit()。

// MARK: - 参数解析

final class Options {
    var host: String?
    var port = 2121
    var user: String?
    var password: String?
    var path: String?
    var file: String?
    var from: String?
    var to: String?
    var resume = false
    var progress = false
}

func usage(_ message: String? = nil) -> Never {
    if let m = message { FileHandle.standardError.write("mitvctl: \(m)\n".data(using: .utf8)!) }
    let help = """
    用法:
      mitvctl ping     --host H [--port P] [--user U] [--pass PW]
      mitvctl probe    --host H [--port P] [--user U] [--pass PW]   # 能力矩阵 JSON
      mitvctl list     --host H --path /Movies [--port P]
      mitvctl upload   --host H --file F --to /Movies/a.mp4 [--resume] [--progress]
      mitvctl download --host H --from /Movies/a.mp4 --to F
      mitvctl delete   --host H --path P
      mitvctl move     --host H --from A --to B
      mitvctl mkdir    --host H --path P
    """
    print(help)
    exit(2)
}

let opts = Options()
let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage("缺少子命令") }

var i = 1
while i < args.count {
    let a = args[i]
    func value(_ key: String) -> String {
        guard i + 1 < args.count else { usage("--\(key) 缺少值") }
        i += 1
        return args[i]
    }
    switch a {
    case "--host": opts.host = value("host")
    case "--port":
        guard let p = Int(value("port")), p > 0, p <= 65535 else { usage("--port 非法") }
        opts.port = p
    case "--user": opts.user = value("user")
    case "--pass": opts.password = value("pass")
    case "--path": opts.path = value("path")
    case "--file": opts.file = value("file")
    case "--from": opts.from = value("from")
    case "--to": opts.to = value("to")
    case "--resume": opts.resume = true
    case "--progress": opts.progress = true
    default: usage("未知参数 \(a)")
    }
    i += 1
}

let knownCommands = ["ping", "probe", "list", "upload", "download", "delete", "move", "mkdir"]
guard knownCommands.contains(command) else { usage("未知子命令 \(command)") }
guard let host = opts.host, !host.isEmpty else { usage("缺少 --host") }

func require(_ v: String?, _ name: String) -> String {
    guard let s = v, !s.isEmpty else { usage("\(command) 需要 --\(name)") }
    return s
}

// MARK: - 执行

let endpoint = FTPEndpoint(host: host, port: opts.port, user: opts.user, password: opts.password)
let engine = SwiftFTPEngine()
let cliCancelHandle = TransferHandle() // 全局：signal 处理器不能捕获上下文

func installInterrupt() {
    signal(SIGINT) { _ in cliCancelHandle.cancel() } // Ctrl-C 走引擎取消路径，服务器侧保留已传部分
}

func finish(_ error: Error?) -> Never {
    if let e = error {
        FileHandle.standardError.write("mitvctl: \(e.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }
    exit(0)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("mitvctl: \(message)\n".data(using: .utf8)!)
    exit(1)
}

func printProgress(_ p: TransferProgress) {
    let percent = p.totalBytes > 0 ? String(format: "%5.1f%%", p.fraction * 100) : "  --  "
    let speed = p.bytesPerSecond > 0 ? String(format: "%6.1f MB/s", p.bytesPerSecond / 1_048_576) : "      --    "
    fputs("\r  \(percent)  \(String(format: "%12lld", p.bytes)) / \(p.totalBytes < 0 ? "-" : String(p.totalBytes)) B  \(speed)", stdout)
    fflush(stdout)
}

switch command {
case "ping":
    let started = CFAbsoluteTimeGetCurrent()
    engine.ping(endpoint) { error in
        if let e = error { finish(e) }
        let ms = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
        print("pong \(endpoint.display) (\(ms)ms)")
        finish(nil)
    }

case "probe":
    engine.probeCapabilities(endpoint) { result in
        switch result {
        case .failure(let e): finish(e)
        case .success(let caps):
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(caps), let json = String(data: data, encoding: .utf8) {
                print(json)
            } else {
                fail("能力矩阵序列化失败")
            }
            finish(nil)
        }
    }

case "list":
    let path = require(opts.path, "path")
    engine.list(endpoint, path: path) { result in
        switch result {
        case .failure(let e): finish(e)
        case .success(let entries):
            for e in entries {
                let kind = e.isDirectory ? "d" : "-"
                let size = e.isDirectory ? "<DIR>" : (e.size.map(String.init) ?? "-")
                print("\(kind)\t\(size)\t\(e.path)")
            }
            finish(nil)
        }
    }

case "upload":
    let file = require(opts.file, "file")
    let to = require(opts.to, "to")
    guard FileManager.default.fileExists(atPath: file) else { fail("本地文件不存在：\(file)") }
    installInterrupt()
    engine.upload(endpoint, from: URL(fileURLWithPath: file), to: to,
                  resume: opts.resume, handle: cliCancelHandle,
                  onProgress: opts.progress ? { printProgress($0) } : nil) { result in
        if opts.progress { fputs("\n", stdout); fflush(stdout) }
        switch result {
        case .failure(let e): finish(e)
        case .success(let bytes): print("uploaded \(bytes) bytes → \(to)")
            finish(nil)
        }
    }

case "download":
    let from = require(opts.from, "from")
    let to = require(opts.to, "to")
    installInterrupt()
    engine.download(endpoint, remotePath: from, to: URL(fileURLWithPath: to),
                    handle: cliCancelHandle,
                    onProgress: opts.progress ? { printProgress($0) } : nil) { result in
        if opts.progress { fputs("\n", stdout); fflush(stdout) }
        switch result {
        case .failure(let e): finish(e)
        case .success(let bytes): print("downloaded \(bytes) bytes → \(to)")
            finish(nil)
        }
    }

case "delete":
    let path = require(opts.path, "path")
    engine.delete(endpoint, remotePath: path) { error in
        if let e = error { finish(e) }
        print("deleted \(path)")
        finish(nil)
    }

case "move":
    let from = require(opts.from, "from")
    let to = require(opts.to, "to")
    engine.move(endpoint, from: from, to: to) { error in
        if let e = error { finish(e) }
        print("moved \(from) → \(to)")
        finish(nil)
    }

case "mkdir":
    let path = require(opts.path, "path")
    engine.makeDirectory(endpoint, path: path) { error in
        if let e = error { finish(e) }
        print("mkdir \(path)")
        finish(nil)
    }

default:
    usage("未知子命令 \(command)")
}

dispatchMain()
