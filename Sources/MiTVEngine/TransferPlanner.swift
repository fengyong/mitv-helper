import Foundation

// MARK: - 续传规划（纯函数，离线可测）

enum FTPTransferPlanner {
    /// APPE 续传偏移：远端已有 >0 且 ≤ 本地大小 → 返回 seek 偏移（= 远端大小，用 APPE 追加）；
    /// 否则整传（返回 nil）。REST 偏移续传不可用（实测 502），一律走 SIZE+APPE。
    static func resumeOffset(remoteSize: Int64, localSize: Int64) -> Int64? {
        guard localSize > 0, remoteSize > 0, remoteSize <= localSize else { return nil }
        return remoteSize
    }
}

// MARK: - 进度节流（离线可测）

/// 上传/下载 progress 回调节流：距上次发出 ≥ minInterval 才放行；首次必然放行；
/// 传输结束时由调用方 forceEmit 保证「最终进度必发」。
final class FTPProgressThrottler {
    let minInterval: TimeInterval
    private(set) var lastEmit: TimeInterval = -Double.infinity

    init(minInterval: TimeInterval = 0.1) {
        self.minInterval = minInterval
    }

    /// 返回是否应当发出（发出即记时间）
    func shouldEmit(now: TimeInterval) -> Bool {
        if now - lastEmit >= minInterval {
            lastEmit = now
            return true
        }
        return false
    }

    /// 不经过判断直接记录一次发出时间
    func forceEmit(now: TimeInterval) {
        lastEmit = now
    }
}
