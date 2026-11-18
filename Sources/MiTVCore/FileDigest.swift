import Foundation
import CommonCrypto

/// 文件内容指纹（上传重名判定用）。
/// 规约：取文件前 min(size, 10MB) 字节的 MD5 —— 小文件即全文件 md5，大文件为前 10M 指纹；
/// 对任意大小文件都秒级可得（巨大文件可行性：本地读 10MB <1s，远端拉 10MB 局域网数秒）。
enum FileDigest {
    /// 指纹取样上限
    static let prefixLimit: Int64 = 10 * 1024 * 1024

    static func md5Hex(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            _ = CC_MD5(raw.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 流式读文件前 maxBytes 字节；打不开/IO 失败返回 nil（读到的字节数可能少于请求值=文件较短）
    static func readPrefix(at url: URL, maxBytes: Int64) -> Data? {
        guard maxBytes >= 0 else { return nil }
        guard let fh = FileHandle(forReadingAtPath: url.path) else { return nil }
        defer { fh.closeFile() }
        var acc = Data()
        var remain = maxBytes
        let chunk = 262144
        while remain > 0 {
            let want = Int(min(Int64(chunk), remain))
            let d = fh.readData(ofLength: want)
            if d.isEmpty { break }
            acc.append(d)
            remain -= Int64(d.count)
            if d.count < want { break } // 文件先于请求长度结束
        }
        return acc
    }

    /// 本地内容指纹：前 min(size, prefixLimit) 字节的 MD5。读不到完整前缀（IO 错误）返回 nil。
    static func fingerprint(url: URL, fileSize: Int64) -> (hex: String, prefixLen: Int64)? {
        let len = min(max(0, fileSize), prefixLimit)
        guard let data = readPrefix(at: url, maxBytes: len), Int64(data.count) == len else { return nil }
        return (md5Hex(data), len)
    }

    /// 后台计算指纹。注意：completion 在后台队列回调（不 hop 主队列——测试/服务的消费方
    /// 各自持有串行队列自行 hop；若在主线程阻塞等待的环境里 hop 主队列会死锁）
    static func fingerprintAsync(url: URL, fileSize: Int64,
                                 completion: @escaping (_ hex: String?, _ prefixLen: Int64?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let r = fingerprint(url: url, fileSize: fileSize)
            completion(r?.hex, r?.prefixLen)
        }
    }
}
