import AppKit
import Foundation

// MARK: - 局域网扫描（自动查找附近的电视；纯 POSIX socket，无术语暴露）

final class TVScanner {

    /// 扫本网段常见端口，返回应答主机 IP（主队列回调）
    static func scan(completion: @escaping ([String]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let prefix = TVScanner.localSubnetPrefix() else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            let ports: [UInt16] = [2121, 2221, 21]
            var found = Set<String>()
            let lock = NSLock()
            let group = DispatchGroup()
            let workers = DispatchQueue.global(qos: .userInitiated)

            // 固定 worker 池分段扫描：旧实现 254×3=762 个并发块各自阻塞 poll，
            // GCD 会瞬时膨胀出几十上百线程（线程爆炸）；24 路顺序探测足够快且资源恒定
            let hosts = (1...254).map { "\(prefix).\($0)" }
            let workerCount = 24
            let chunk = (hosts.count + workerCount - 1) / workerCount
            for w in 0..<workerCount {
                let slice = hosts[(w * chunk)..<(min((w + 1) * chunk, hosts.count))]
                guard !slice.isEmpty else { continue }
                group.enter()
                workers.async {
                    for ip in slice {
                        for port in ports where TVScanner.isOpen(ip, port: port) {
                            lock.lock()
                            found.insert(ip)
                            lock.unlock()
                        }
                    }
                    group.leave()
                }
            }
            group.wait()
            let result = found.sorted()
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// 通过 UDP connect 技巧获取本机出口 IP → /24 前缀；无默认路由时退回网卡枚举
    private static func localSubnetPrefix() -> String? {
        if let p = prefixViaUDP() { return p }
        return prefixViaInterfaces()
    }

    private static func prefixViaUDP() -> String? {
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { return nil }
        defer { close(sock) }
        var target = sockaddr_in()
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = (53 as UInt16).bigEndian
        inet_pton(AF_INET, "8.8.8.8", &target.sin_addr)
        let r = withUnsafePointer(to: &target) { tp -> Int32 in
            tp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                connect(sock, sp, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard r == 0 else { return nil }
        var local = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let gr = withUnsafeMutablePointer(to: &local) { lp -> Int32 in
            lp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                getsockname(sock, sp, &len)
            }
        }
        guard gr == 0 else { return nil }
        return prefixFromSockAddr(local)
    }

    /// 纯局域网（无互联网路由）时 UDP connect 会失败——枚举网卡找私网 IPv4
    private static func prefixViaInterfaces() -> String? {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return nil }
        defer { freeifaddrs(ifap) }
        var fallback: String?
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            guard let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            if (cur.pointee.ifa_flags & UInt32(IFF_LOOPBACK)) != 0 { continue }
            let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            guard let p = prefixFromSockAddr(addr) else { continue }
            if p.hasPrefix("192.168.") || p.hasPrefix("10.") { return p }
            if p.hasPrefix("172.") {
                let second = p.split(separator: ".").dropFirst().first.flatMap { Int($0) } ?? 0
                if (16...31).contains(second) { return p }
            }
            if fallback == nil { fallback = p }
        }
        return fallback
    }

    private static func prefixFromSockAddr(_ addr: sockaddr_in) -> String? {
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var inAddr = addr.sin_addr
        guard inet_ntop(AF_INET, &inAddr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        let ip = String(cString: buf)
        let comps = ip.split(separator: ".")
        guard comps.count == 4, comps[0] != "127" else { return nil }
        return comps.prefix(3).joined(separator: ".")
    }

    /// 非阻塞 connect + select 判端口开放
    private static func isOpen(_ ip: String, port: UInt16, timeoutMs: Int32 = 180) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }
        let flags = fcntl(sock, F_GETFL, 0)
        _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, ip, &addr.sin_addr)
        let r = withUnsafePointer(to: &addr) { ap -> Int32 in
            ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                connect(sock, sp, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if r == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var pfd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
        let sel = poll(&pfd, 1, timeoutMs)
        guard sel > 0 else { return false }
        guard (pfd.revents & Int16(POLLOUT)) != 0 else { return false }
        var soError: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(sock, SOL_SOCKET, SO_ERROR, &soError, &len)
        return soError == 0
    }
}

// MARK: - 首连向导（三步，全屏遮罩 + 居中卡片，一屏一步）

final class OnboardingOverlay: NSView {

    unowned let coordinator: AppCoordinator
    private let card = NSView()
    private var stepContainer = NSView()
    private let stepsRow = NSStackView()
    private var stepIndex = 0
    private var didFinish: (() -> Void)?

    private let addressField = NSTextField()
    private let candidatesStack = NSStackView()
    private let scanButton: CapsuleButton
    private let scanSpinner = NSProgressIndicator()
    private let statusLabel = UIUtil.label("", size: 13, color: .secondaryLabelColor, align: .center)
    private let errorLabel = UIUtil.label("", size: 12, color: .systemRed, align: .center)
    private let connectSpinner = NSProgressIndicator()
    private var connectButton: CapsuleButton?
    /// 连接进行中：重复点「连接/重试/候选」会被协调器 guard 弹回 (false, nil)，
    /// 旧实现把这当成失败显示「连不上」误导用户；这里直接忽略重复触发
    private var connecting = false

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        scanButton = CapsuleButton("自动查找附近的电视", style: .secondary)
        super.init(frame: .zero)
        buildUI()
    }
    required init?(coder: NSCoder) { fatalError("不支持") }

    func present(in parent: NSView, onDismiss: @escaping () -> Void) {
        self.didFinish = onDismiss
        frame = parent.bounds
        autoresizingMask = [.width, .height]
        parent.addSubview(self, positioned: .above, relativeTo: nil)
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            animator().alphaValue = 1
        }
        if let stored = coordinator.store.endpoint {
            addressField.stringValue = stored.host
        }
        showStep(0)
    }

    private func dismiss() {
        didFinish?()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.removeFromSuperview()
        })
    }

    // MARK: UI

    private func buildUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.30).cgColor

        card.wantsLayer = true
        card.layer?.cornerRadius = 16
        card.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        card.layer?.borderColor = NSColor.separatorColor.cgColor
        card.layer?.borderWidth = 0.5
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        let close = NSButton(image: Icons.xMark, target: self, action: #selector(closeTapped))
        close.isBordered = false
        close.imagePosition = .imageOnly
        close.contentTintColor = .secondaryLabelColor
        close.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(close)

        let title = UIUtil.label("连接你的电视", size: 20, weight: .semibold, align: .center)
        title.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(title)

        for i in 0..<3 {
            let dot = UIUtil.label(i == 0 ? "●" : "○", size: 10, color: .controlAccentColor)
            dot.tag = 100 + i
            stepsRow.addArrangedSubview(dot)
        }
        stepsRow.orientation = .horizontal
        stepsRow.spacing = 10
        stepsRow.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stepsRow)

        stepContainer.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stepContainer)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 520),
            card.heightAnchor.constraint(greaterThanOrEqualToConstant: 340),

            close.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            close.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),

            title.topAnchor.constraint(equalTo: card.topAnchor, constant: 30),
            title.centerXAnchor.constraint(equalTo: card.centerXAnchor),

            stepsRow.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            stepsRow.centerXAnchor.constraint(equalTo: card.centerXAnchor),

            stepContainer.topAnchor.constraint(equalTo: stepsRow.bottomAnchor, constant: 22),
            stepContainer.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 36),
            stepContainer.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -36),
            stepContainer.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -28),
        ])
    }

    private func showStep(_ index: Int) {
        stepIndex = index
        for case let dot as NSTextField in stepsRow.arrangedSubviews {
            let i = dot.tag - 100
            dot.stringValue = i == index ? "●" : (i < index ? "✓" : "○")
            dot.textColor = i == index ? .controlAccentColor : .tertiaryLabelColor
        }
        for sub in stepContainer.subviews { sub.removeFromSuperview() }
        let v: NSView
        switch index {
        case 0: v = stepOne()
        case 1: v = stepTwo()
        default: v = stepThree()
        }
        v.translatesAutoresizingMaskIntoConstraints = false
        stepContainer.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: stepContainer.topAnchor),
            v.bottomAnchor.constraint(equalTo: stepContainer.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: stepContainer.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: stepContainer.trailingAnchor),
        ])
    }

    private func stepOne() -> NSView {
        let lines = [
            "在电视上：插好 U 盘",
            "打开「高清播放器」",
            "按遥控器的菜单键，选择「远程管理」",
            "电视屏幕会显示一个地址",
        ]
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 12
        stack.alignment = .centerX
        for (i, line) in lines.enumerated() {
            let l = UIUtil.label(line, size: i == lines.count - 1 ? 13 : 16,
                                 weight: i == 2 ? .medium : .regular,
                                 color: i == 2 ? .labelColor : .secondaryLabelColor, align: .center)
            stack.addArrangedSubview(l)
        }
        let tvIcon = NSImageView(image: Icons.tv)
        tvIcon.contentTintColor = .controlAccentColor
        stack.insertArrangedSubview(tvIcon, at: 0)
        return stack
    }

    private func stepTwo() -> NSView {
        let container = NSView()
        let prompt = UIUtil.label("输入电视屏幕上显示的地址", size: 15, weight: .medium, align: .center)
        addressField.placeholderString = "例如 192.168.1.8"
        addressField.font = NSFont.monospacedDigitSystemFont(ofSize: 16, weight: .regular)
        addressField.alignment = .center
        addressField.wantsLayer = true
        addressField.layer?.cornerRadius = 8
        addressField.layer?.borderColor = NSColor.separatorColor.cgColor
        addressField.layer?.borderWidth = 1
        addressField.translatesAutoresizingMaskIntoConstraints = false
        addressField.target = self
        addressField.action = #selector(connectTapped)

        scanButton.tapAction = { [weak self] in self?.startScan() }
        scanSpinner.isIndeterminate = true
        scanSpinner.controlSize = .small
        scanSpinner.isHidden = true

        candidatesStack.orientation = .vertical
        candidatesStack.spacing = 6

        errorLabel.stringValue = ""
        errorLabel.isHidden = true

        container.addSubview(prompt)
        container.addSubview(addressField)
        container.addSubview(scanButton)
        container.addSubview(scanSpinner)
        container.addSubview(candidatesStack)
        container.addSubview(errorLabel)

        NSLayoutConstraint.activate([
            prompt.topAnchor.constraint(equalTo: container.topAnchor),
            prompt.centerXAnchor.constraint(equalTo: container.centerXAnchor),

            addressField.topAnchor.constraint(equalTo: prompt.bottomAnchor, constant: 14),
            addressField.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            addressField.widthAnchor.constraint(equalToConstant: 320),
            addressField.heightAnchor.constraint(equalToConstant: 34),

            scanButton.topAnchor.constraint(equalTo: addressField.bottomAnchor, constant: 12),
            scanButton.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            scanSpinner.centerYAnchor.constraint(equalTo: scanButton.centerYAnchor),
            scanSpinner.leadingAnchor.constraint(equalTo: scanButton.trailingAnchor, constant: 8),

            candidatesStack.topAnchor.constraint(equalTo: scanButton.bottomAnchor, constant: 12),
            candidatesStack.centerXAnchor.constraint(equalTo: container.centerXAnchor),

            errorLabel.topAnchor.constraint(greaterThanOrEqualTo: candidatesStack.bottomAnchor, constant: 10),
            errorLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            errorLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    private func stepThree() -> NSView {
        let container = NSView()
        connectSpinner.isIndeterminate = true
        connectSpinner.startAnimation(nil)
        connectSpinner.controlSize = .regular
        connectSpinner.style = .spinning
        connectSpinner.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(connectSpinner)

        statusLabel.stringValue = "正在连接电视…"
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(statusLabel)
        errorLabel.stringValue = ""
        errorLabel.isHidden = true
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(errorLabel)

        let retry = CapsuleButton("重试", style: .secondary)
        retry.tapAction = { [weak self] in self?.connectTapped() }
        retry.translatesAutoresizingMaskIntoConstraints = false
        retry.isHidden = true
        container.addSubview(retry)
        self.connectButton = retry

        NSLayoutConstraint.activate([
            connectSpinner.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            connectSpinner.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            statusLabel.topAnchor.constraint(equalTo: connectSpinner.bottomAnchor, constant: 14),
            statusLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            errorLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 10),
            errorLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            retry.topAnchor.constraint(equalTo: errorLabel.bottomAnchor, constant: 14),
            retry.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            retry.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
        ])
        return container
    }

    // MARK: 动作

    @objc private func closeTapped() { dismiss() }

    private func startScan() {
        scanButton.isHidden = true
        scanSpinner.isHidden = false
        scanSpinner.startAnimation(nil)
        candidatesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let scanning = UIUtil.label("正在寻找附近的电视…", size: 12, color: .secondaryLabelColor, align: .center)
        candidatesStack.addArrangedSubview(scanning)
        TVScanner.scan { [weak self] ips in
            guard let self = self else { return }
            self.scanSpinner.stopAnimation(nil)
            self.scanSpinner.isHidden = true
            self.scanButton.isHidden = false
            self.candidatesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            guard !ips.isEmpty else {
                let none = UIUtil.label("附近没有发现电视 · 也可以直接输入地址", size: 12, color: .secondaryLabelColor, align: .center)
                self.candidatesStack.addArrangedSubview(none)
                return
            }
            for ip in ips.prefix(4) {
                let b = NSButton(title: "\(ip) · 疑似电视", target: self, action: #selector(OnboardingOverlay.candidateTapped(_:)))
                b.isBordered = true
                b.bezelStyle = .rounded
                b.controlSize = .regular
                b.identifier = NSUserInterfaceItemIdentifier(ip)
                self.candidatesStack.addArrangedSubview(b)
            }
        }
    }

    @objc private func candidateTapped(_ sender: NSButton) {
        guard let ip = sender.identifier?.rawValue else { return }
        addressField.stringValue = ip
        connectTapped()
    }

    @objc private func connectTapped() {
        guard !connecting else { return }
        errorLabel.isHidden = true
        var raw = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        // 兼容用户粘贴的 ftp://host:port 形式（但界面永远不出现协议术语）
        raw = raw.replacingOccurrences(of: "ftp://", with: "")
        var host = raw
        var port = 2121
        if let idx = raw.firstIndex(of: ":") {
            host = String(raw[..<idx])
            port = Int(raw[raw.index(after: idx)...]) ?? 2121
        }
        guard !host.isEmpty else { return }
        let endpoint = FTPEndpoint(host: host, port: port)
        if stepIndex == 1 { showStep(2) }
        connectSpinner.startAnimation(nil)
        statusLabel.stringValue = "正在连接电视…"
        connectButton?.isHidden = true
        connecting = true
        coordinator.connect(endpoint: endpoint, name: "客厅电视") { [weak self] ok, error in
            guard let self = self else { return }
            self.connecting = false
            if ok {
                self.statusLabel.stringValue = "✓ 电视已就绪"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                    self?.dismiss()
                }
            } else {
                self.connectSpinner.stopAnimation(nil)
                self.errorLabel.stringValue = error ?? "连不上，请检查电视上的「远程管理」是否还开着"
                self.errorLabel.isHidden = false
                self.connectButton?.isHidden = false
            }
        }
    }
}
