import Foundation
import Darwin

/// POSIX BSD socket 轻封装：阻塞 I/O + SO_RCVTIMEO/SO_SNDTIMEO 超时。
/// 引擎硬性约束：只用 Foundation/Darwin（CLI 目标只链 Foundation/Network），不 import AppKit / Network.framework。
///
/// 连接超时用「非阻塞 connect + poll」实现（SO_RCVTIMEO 管不到 connect 阶段）；
/// 读写超时用内核级 SO_RCVTIMEO/SO_SNDTIMEO（阻塞 I/O 超时后 recv/send 返回 EAGAIN）。
final class FTPSocket {
    private let fd: Int32
    private var closed = false

    private init(fd: Int32) { self.fd = fd }

    deinit { closeNow() }

    // MARK: - 建连

    /// 阻塞式 TCP 连接（带连接超时）。目标：x86_64-apple-macos10.15，纯 POSIX。
    static func connect(host: String, port: Int, timeout: TimeInterval) throws -> FTPSocket {
        guard port > 0, port <= 65535 else {
            throw EngineError.connectionFailed("端口非法：\(port)")
        }
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var info: UnsafeMutablePointer<addrinfo>? = nil
        let rc = getaddrinfo(host, String(port), &hints, &info)
        guard rc == 0, let first = info else {
            throw EngineError.connectionFailed("无法解析地址 \(host)（getaddrinfo \(rc)）")
        }
        defer { freeaddrinfo(info) }

        let fd = socket(first.pointee.ai_family, first.pointee.ai_socktype, first.pointee.ai_protocol)
        guard fd >= 0 else {
            throw EngineError.connectionFailed("socket 创建失败（errno \(errno)）")
        }
        let sock = FTPSocket(fd: fd)
        do {
            var noSig: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSig, socklen_t(MemoryLayout<Int32>.size))

            // 非阻塞 connect + poll 等待完成
            let oldFlags = fcntl(fd, F_GETFL, 0)
            guard oldFlags >= 0 else { throw EngineError.ioError("fcntl(F_GETFL) 失败") }
            _ = fcntl(fd, F_SETFL, oldFlags | O_NONBLOCK)
            let c = Darwin.connect(fd, first.pointee.ai_addr, first.pointee.ai_addrlen)
            if c != 0 {
                guard errno == EINPROGRESS else {
                    throw EngineError.connectionFailed("连接 \(host):\(port) 失败（errno \(errno)）")
                }
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let pr = poll(&pfd, 1, Int32(max(1, timeout * 1000)))
                guard pr > 0 else {
                    throw EngineError.connectionFailed("连接超时（\(host):\(port)，上限 \(Int(timeout))s）")
                }
                var soErr: Int32 = 0
                var len = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len) == 0, soErr == 0 else {
                    throw EngineError.connectionFailed("连接 \(host):\(port) 失败（errno \(soErr)）")
                }
            }
            _ = fcntl(fd, F_SETFL, oldFlags) // 恢复阻塞模式
            return sock
        } catch {
            sock.closeNow()
            throw error
        }
    }

    // MARK: - 超时

    func setTimeouts(readTimeout: TimeInterval, writeTimeout: TimeInterval) {
        setSocketTimeout(SO_RCVTIMEO, readTimeout)
        setSocketTimeout(SO_SNDTIMEO, writeTimeout)
    }

    func setReadTimeout(_ seconds: TimeInterval) { setSocketTimeout(SO_RCVTIMEO, seconds) }

    private func setSocketTimeout(_ option: Int32, _ seconds: TimeInterval) {
        let usec = (seconds * 1_000_000).truncatingRemainder(dividingBy: 1_000_000)
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32(usec))
        _ = setsockopt(fd, SOL_SOCKET, option, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    // MARK: - 读写

    /// 读最多 maxCount 字节；EOF 返回 0；超时/断连抛 EngineError
    func read(_ buffer: UnsafeMutablePointer<UInt8>, maxCount: Int) throws -> Int {
        while true {
            let n = Darwin.recv(fd, buffer, maxCount, 0)
            if n > 0 { return n }
            if n == 0 { return 0 } // 对端关闭
            let e = errno
            if e == EINTR { continue }
            if e == EAGAIN || e == EWOULDBLOCK {
                throw EngineError.connectionFailed("等待数据超时（SO_RCVTIMEO）")
            }
            throw EngineError.connectionFailed("读失败（errno \(e)）")
        }
    }

    /// 写满整个 Data（处理部分写）；超时/断连抛 EngineError
    func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress, raw.count > 0 else { return }
            let p = base.assumingMemoryBound(to: UInt8.self)
            var offset = 0
            while offset < raw.count {
                let n = Darwin.send(fd, p + offset, raw.count - offset, 0)
                if n > 0 { offset += n; continue }
                let e = errno
                if e == EINTR { continue }
                if e == EAGAIN || e == EWOULDBLOCK {
                    throw EngineError.connectionFailed("发送超时（SO_SNDTIMEO）")
                }
                throw EngineError.connectionFailed("写失败（errno \(e)）")
            }
        }
    }

    /// 半关（发 FIN）：上传结束后通知服务器「数据发完」
    func shutdownWrite() { _ = Darwin.shutdown(fd, SHUT_WR) }

    /// 立即关闭（幂等）
    func closeNow() {
        if !closed {
            closed = true
            _ = Darwin.close(fd)
        }
    }
}
