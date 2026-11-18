import Foundation

/// 心跳服务：10s NOOP 探活；连续两连失败 → 判掉线（黄条 + 队列整体暂停）；
/// 掉线后指数退避重连 5s/15s/30s/60s/120s 封顶；重连成功恢复队列（由协调层驱动）。
final class HeartbeatService {

    enum Status: Equatable {
        case off
        case connected
        /// attempt = 第 N 次重连尝试（UI 显示「正在重试（第 N 次）」）
        case lost(attempt: Int)
    }

    var onStatus: ((Status) -> Void)? // 主队列回调

    private let engineProvider: () -> TransferEngine
    private let endpointProvider: () -> FTPEndpoint?
    private let heartbeatInterval: TimeInterval
    private let backoffSteps: [TimeInterval]

    private let q = DispatchQueue(label: "mitv.heartbeat", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var consecutiveFailures = 0
    private var backoffIndex = 0
    private var isLost = false
    private(set) var status: Status = .off

    init(engineProvider: @escaping () -> TransferEngine,
         endpointProvider: @escaping () -> FTPEndpoint?,
         heartbeatInterval: TimeInterval = 10,
         backoffSteps: [TimeInterval] = [5, 15, 30, 60, 120]) {
        self.engineProvider = engineProvider
        self.endpointProvider = endpointProvider
        self.heartbeatInterval = heartbeatInterval
        self.backoffSteps = backoffSteps
    }

    func start() {
        q.async { [weak self] in
            guard let self = self else { return }
            self.consecutiveFailures = 0
            self.isLost = false
            self.backoffIndex = 0
            self.setStatus(.connected) // 连接由 connect 流程先行确认；心跳从此保持
            self.schedulePing(self.heartbeatInterval)
        }
    }

    func stop() {
        q.async { [weak self] in
            guard let self = self else { return }
            self.timer?.cancel()
            self.timer = nil
            self.isLost = false
            self.consecutiveFailures = 0
            self.setStatus(.off)
        }
    }

    /// 立即探活一次（用户点状态胶囊时）
    func checkNow() {
        q.async { [weak self] in self?.schedulePing(0.05) }
    }

    // MARK: - 内部（q 上执行）

    private func schedulePing(_ delay: TimeInterval) {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + delay)
        t.setEventHandler { [weak self] in self?.doPing() }
        t.resume()
        timer = t
    }

    private func doPing() {
        guard let endpoint = endpointProvider() else {
            // 尚未连接电视：静默等待，不进入黄条状态
            FileHandle.standardError.write(Data("[diag] heartbeat: no endpoint\n".utf8))
            setStatus(.off)
            schedulePing(heartbeatInterval)
            return
        }
        FileHandle.standardError.write(Data("[diag] heartbeat ping → \(endpoint.display)\n".utf8))
        engineProvider().ping(endpoint) { [weak self] error in
            guard let self = self else { return }
            FileHandle.standardError.write(Data("[diag] heartbeat result: \(error?.localizedDescription ?? "ok")\n".utf8))
            // 引擎契约：回调在主队列 → 跳回心跳队列改状态
            self.q.async { self.handleResult(ok: error == nil) }
        }
    }

    private func handleResult(ok: Bool) {
        if ok {
            consecutiveFailures = 0
            if isLost {
                isLost = false
                backoffIndex = 0
                setStatus(.connected)
            }
            schedulePing(heartbeatInterval)
        } else {
            consecutiveFailures += 1
            if !isLost {
                guard consecutiveFailures >= 2 else {
                    schedulePing(heartbeatInterval)
                    return
                }
                isLost = true
                backoffIndex = 0
                setStatus(.lost(attempt: 1))
                schedulePing(backoffSteps[0])
            } else {
                backoffIndex = min(backoffIndex + 1, backoffSteps.count - 1)
                setStatus(.lost(attempt: backoffIndex + 1))
                schedulePing(backoffSteps[backoffIndex])
            }
        }
    }

    private func setStatus(_ s: Status) {
        guard status != s else { return }
        status = s
        DispatchQueue.main.async { [weak self] in self?.onStatus?(s) }
    }
}
