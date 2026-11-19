import AppKit
import Foundation

// MARK: - 队列视图（传输态核心界面）

final class QueueView: NSView {

    unowned let coordinator: AppCoordinator
    private var cards: [String: QueueCardView] = [:]
    private var groupExpanded = false
    private var refreshTimer: Timer?
    private var lastSnapshot: [QueueItem] = []

    private let summaryLabel = UIUtil.label("", size: 13, weight: .medium, color: .secondaryLabelColor)
    private let scroll = NSScrollView()
    private let stack = FlippedStack()
    private let pauseAllButton: CapsuleButton
    private let clearButton: CapsuleButton
    private let totalsLabel = UIUtil.label("", size: 12, color: .secondaryLabelColor)
    private let groupHeader = QueueGroupHeader()

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        pauseAllButton = CapsuleButton("全部暂停", style: .secondary)
        clearButton = CapsuleButton("清空已完成", style: .secondary)
        super.init(frame: .zero)
        setup()
    }
    required init?(coder: NSCoder) { fatalError("不支持") }

    deinit { refreshTimer?.invalidate() }

    private func setup() {
        wantsLayer = true
        let effect = UIUtil.visualEffect(material: .underWindowBackground)
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect, positioned: .below, relativeTo: nil)

        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(summaryLabel)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        scroll.documentView = stack
        addSubview(scroll)

        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 16, bottom: 10, right: 16)
        groupHeader.isHidden = true
        groupHeader.onToggle = { [weak self] expanded in
            self?.groupExpanded = expanded
            self?.reload()
        }
        groupHeader.onClear = { [weak self] in
            self?.coordinator.queue.clearFinished()
            self?.reload()
        }

        totalsLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(totalsLabel)

        pauseAllButton.tapAction = { [weak self] in self?.togglePauseAll() }
        pauseAllButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pauseAllButton)
        clearButton.tapAction = { [weak self] in
            self?.coordinator.queue.clearFinished()
            self?.reload()
        }
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clearButton)

        NSLayoutConstraint.activate([
            effect.topAnchor.constraint(equalTo: topAnchor),
            effect.bottomAnchor.constraint(equalTo: bottomAnchor),
            effect.leadingAnchor.constraint(equalTo: leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: trailingAnchor),

            summaryLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            summaryLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),

            scroll.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: totalsLabel.topAnchor, constant: -8),

            totalsLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            totalsLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            totalsLabel.centerYAnchor.constraint(equalTo: pauseAllButton.centerYAnchor),

            clearButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            clearButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            pauseAllButton.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -10),
            pauseAllButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.reload()
            }
        } else {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }

    private func togglePauseAll() {
        let snapshot = coordinator.queue.snapshot()
        let busy = snapshot.contains { $0.isBusy }
        if busy {
            coordinator.queue.pauseAllByUser()
            pauseAllButton.title = "全部继续"
        } else {
            coordinator.queue.resumeAllByUser()
            pauseAllButton.title = "全部暂停"
        }
        reload()
    }

    /// 由协调器在队列变化时调用
    func reload() {
        let snapshot = coordinator.queue.snapshot()
        lastSnapshot = snapshot

        // 活动项：非终态 + 终态但 10 秒内的（完成停留）+ 失败常驻
        let active = snapshot.filter { item in
            if !item.phase.isTerminal { return true }
            if item.phase == .failed { return true }
            guard let finished = item.finishedAt else { return false }
            return Date().timeIntervalSince(finished) < 10
        }
        let grouped = snapshot.filter { $0.phase == .completed || $0.phase == .canceled }
            .filter { item in
                guard let finished = item.finishedAt else { return false }
                return Date().timeIntervalSince(finished) >= 10
            }

        // 顶部摘要
        let busy = active.filter { $0.phase == .connecting || $0.phase == .running }
        let speed = busy.reduce(0.0) { $0 + $1.bytesPerSecond }
        if !busy.isEmpty {
            let left = busy.reduce(Int64(0)) { $0 + max(0, $1.sizeBytes - $1.bytes) }
            let ups = busy.filter { $0.direction == .upload }.count
            let verb = ups == busy.count ? "正在发送" : (ups == 0 ? "正在取回" : "正在传输")
            var text = "\(verb) \(busy.count) 项"
            if let spd = Fmt.speed(speed), speed > 0 { text += " · \(spd)" }
            if let eta = Fmt.eta(left, bps: speed) { text += " · \(eta)" }
            summaryLabel.stringValue = text
        } else if active.contains(where: { $0.isBusy }) {
            summaryLabel.stringValue = "等待电视连接，全部暂停中…"
        } else {
            summaryLabel.stringValue = snapshot.isEmpty ? "队列为空" : "全部完成"
        }

        // 复用/新建卡片
        var usedIds = Set<String>()
        var views: [NSView] = []
        for item in active {
            let card = cards[item.id] ?? {
                let c = QueueCardView(coordinator: coordinator)
                cards[item.id] = c
                return c
            }()
            card.update(item)
            usedIds.insert(item.id)
            views.append(card)
        }
        // 回收不再展示的卡片
        for (id, card) in cards where !usedIds.contains(id) {
            card.removeFromSuperview()
            cards.removeValue(forKey: id)
        }

        groupHeader.isHidden = grouped.isEmpty
        if !grouped.isEmpty {
            let done = grouped.filter { $0.phase == .completed }.count
            let canceled = grouped.count - done
            var text = "已完成 \(done) 项"
            if canceled > 0 { text += " · 已取消 \(canceled) 项" }
            groupHeader.configure(text: text, expanded: groupExpanded)
            views.append(groupHeader) // 折叠组标题插在活动卡片与历史卡片之间
            if groupExpanded {
                for item in grouped {
                    let card = cards[item.id] ?? {
                        let c = QueueCardView(coordinator: coordinator)
                        cards[item.id] = c
                        return c
                    }()
                    card.update(item)
                    usedIds.insert(item.id)
                    views.append(card)
                }
            }
        }

        stack.setViews(views)

        // 底部汇总
        let total = snapshot.count
        let doneAll = snapshot.filter { $0.phase == .completed }.count
        let queued = snapshot.filter { $0.phase == .queued }.count
        let totalBytes = snapshot.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let sentBytes = snapshot.reduce(Int64(0)) { $0 + $1.bytes }
        var pct = totalBytes > 0 ? Int(Double(sentBytes) / Double(totalBytes) * 100) : 0
        pct = min(100, max(0, pct))
        totalsLabel.stringValue = "总进度 \(pct)% · 完成 \(doneAll)" + (queued > 0 ? " · 排队 \(queued)" : "") + (total == 0 ? "" : " · 共 \(total) 项")
        clearButton.isHidden = snapshot.filter { $0.phase.isTerminal }.isEmpty
        let anyBusy = snapshot.contains { $0.isBusy }
        // 全部终态时没有可暂停/继续的对象，按钮隐藏（否则「全部继续」点了没反应）
        pauseAllButton.isHidden = !snapshot.contains { !$0.phase.isTerminal }
        pauseAllButton.title = anyBusy ? "全部暂停" : "全部继续"
    }
}

/// 翻转坐标的纵向堆栈容器
final class FlippedStack: NSView {
    var spacing: CGFloat = 8 { didSet { layoutSubviews() } }
    var edgeInsets = NSEdgeInsets() { didSet { layoutSubviews() } }
    private var subviewsList: [NSView] = []
    private var boundsObserver: NSObjectProtocol?

    var documentViewHeight: CGFloat { bounds.height }

    func setViews(_ views: [NSView]) {
        subviewsList.forEach { $0.removeFromSuperview() }
        subviewsList = views
        views.forEach { addSubview($0) }
        layoutSubviews()
    }

    override var isFlipped: Bool { true }

    // 窗口缩放时裁剪视图宽度变化不会触发 documentView 重排（旧实现要等下一秒定时器才跟上）
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let old = boundsObserver {
            NotificationCenter.default.removeObserver(old)
            boundsObserver = nil
        }
        guard let clip = superview else { return }
        clip.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            self?.layoutSubviews()
        }
    }

    deinit {
        if let old = boundsObserver { NotificationCenter.default.removeObserver(old) }
    }

    private func layoutSubviews() {
        guard let sup = superview else { return }
        var y = edgeInsets.top
        let w = max(sup.bounds.width - edgeInsets.left - edgeInsets.right, 200)
        for v in subviewsList {
            let h = v.fittingSize.height
            v.frame = NSRect(x: edgeInsets.left, y: y, width: w, height: h)
            y += h + spacing
        }
        let total = max(y - spacing + edgeInsets.bottom, sup.bounds.height)
        frame = NSRect(x: 0, y: sup.bounds.height - total, width: sup.bounds.width, height: total)
    }
}

/// 「已完成」折叠组标题
final class QueueGroupHeader: NSView {

    var onToggle: ((Bool) -> Void)?
    var onClear: (() -> Void)?
    private let label = UIUtil.label("", size: 12, weight: .medium, color: .secondaryLabelColor)
    private let chevron = NSImageView()
    private let clearBtn: CapsuleButton
    private var expanded = false

    init() {
        clearBtn = CapsuleButton("清空", style: .secondary)
        super.init(frame: .zero)
        let click = NSClickGestureRecognizer(target: self, action: #selector(toggle))
        addGestureRecognizer(click)
        chevron.image = Icons.chevronLeft
        chevron.contentTintColor = .secondaryLabelColor
        chevron.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chevron)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        clearBtn.tapAction = { [weak self] in self?.onClear?() }
        clearBtn.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clearBtn)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            clearBtn.trailingAnchor.constraint(equalTo: trailingAnchor),
            clearBtn.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("不支持") }

    func configure(text: String, expanded: Bool) {
        label.stringValue = text
        self.expanded = expanded
        chevron.animator().frameCenterRotation = expanded ? -90 : 180
    }

    @objc private func toggle() {
        expanded.toggle()
        onToggle?(expanded)
    }
}

// MARK: - 队列卡片

final class QueueCardView: NSView {

    unowned let coordinator: AppCoordinator
    private var item: QueueItem?
    private var hovering = false
    private let thumb = NSImageView()
    private let nameLabel = UIUtil.label("", size: 13, weight: .medium)
    private let destLabel = UIUtil.label("", size: 11, color: .secondaryLabelColor)
    private let progress = ThinProgressBar()
    private let statusLabel = UIUtil.label("", size: 11, color: .secondaryLabelColor)
    private let actionsStack = NSStackView()
    private let doneBadge = NSImageView()

    private var actionButtons: [NSButton] = []

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 78))
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.75).cgColor
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
        layer?.borderWidth = 1

        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 8
        thumb.layer?.masksToBounds = true
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.translatesAutoresizingMaskIntoConstraints = false
        addSubview(thumb)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)
        destLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(destLabel)
        progress.translatesAutoresizingMaskIntoConstraints = false
        addSubview(progress)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)

        actionsStack.orientation = .horizontal
        actionsStack.spacing = 4
        actionsStack.translatesAutoresizingMaskIntoConstraints = false
        actionsStack.alphaValue = 0
        addSubview(actionsStack)

        doneBadge.image = Icons.check
        doneBadge.contentTintColor = .systemGreen
        doneBadge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(doneBadge)

        NSLayoutConstraint.activate([
            thumb.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            thumb.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumb.widthAnchor.constraint(equalToConstant: 54),
            thumb.heightAnchor.constraint(equalToConstant: 54),

            nameLabel.leadingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: 12),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),

            destLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            destLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            destLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),

            progress.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            progress.topAnchor.constraint(equalTo: destLabel.bottomAnchor, constant: 5),
            progress.heightAnchor.constraint(equalToConstant: 4),
            progress.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            statusLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            statusLabel.topAnchor.constraint(equalTo: progress.bottomAnchor, constant: 4),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -40),

            actionsStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            actionsStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            doneBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            doneBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .inVisibleRect, .activeInKeyWindow], owner: self, userInfo: nil)
        addTrackingArea(tracking)
    }

    required init?(coder: NSCoder) { fatalError("不支持") }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.12
            actionsStack.animator().alphaValue = 1
        }
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.12
            actionsStack.animator().alphaValue = 0
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { handleDoubleClick() }
    }

    override var fittingSize: NSSize { NSSize(width: 300, height: 78) }

    // MARK: 状态渲染

    func update(_ item: QueueItem) {
        self.item = item
        nameLabel.stringValue = item.displayName

        // 缩略图
        if let img = LocalThumbnailLoader.shared.cached(forPath: item.localPath, kind: item.kind) {
            thumb.image = img
        } else {
            thumb.image = nil
            thumb.image = LocalThumbnailLoader.fallbackIcon(for: item.kind)
            thumb.contentTintColor = .quaternaryLabelColor
            LocalThumbnailLoader.shared.thumbnail(forPath: item.localPath, kind: item.kind) { [weak self] img in
                guard let self = self, let img = img else { return }
                if self.item?.id == item.id {
                    self.thumb.image = img
                }
            }
        }

        // 目标提示（智能分流结果）
        switch item.direction {
        case .upload:
            if let dir = item.remoteDir {
                // 保留层级分隔（旧实现把所有斜杠删掉，/Movies/2024 显示成 Movies2024）
                let name = dir == "/" ? "电视根目录" : String(dir.dropFirst())
                destLabel.stringValue = "将存到 \(name)/"
            } else {
                destLabel.stringValue = " "
            }
        case .download:
            let parent = (item.localPath as NSString).deletingLastPathComponent
            destLabel.stringValue = "取回到 \((parent as NSString).abbreviatingWithTildeInPath)"
        }
        if item.needsNameMapping {
            destLabel.stringValue += "（已自动兼容命名）"
        }

        // 进度与状态行
        switch item.phase {
        case .queued:
            progress.isHidden = false
            progress.fraction = item.sizeBytes > 0 ? Double(item.bytes) / Double(item.sizeBytes) : 0
            progress.barColor = .separatorColor
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.stringValue = "排队中 · \(Fmt.bytes(item.sizeBytes))"
        case .connecting:
            progress.isHidden = false
            progress.fraction = item.sizeBytes > 0 ? Double(item.bytes) / Double(item.sizeBytes) : 0
            progress.barColor = .controlAccentColor
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.stringValue = "正在连接电视…"
        case .running:
            progress.isHidden = false
            progress.barColor = .controlAccentColor
            progress.fraction = item.sizeBytes > 0 ? Double(item.bytes) / Double(item.sizeBytes) : 0
            var parts: [String] = []
            if item.sizeBytes > 0 {
                parts.append("\(Int(progress.fraction * 100))%")
            }
            if let s = Fmt.speed(item.bytesPerSecond) { parts.append(s) }
            if item.sizeBytes > item.bytes, let eta = Fmt.eta(item.sizeBytes - item.bytes, bps: item.bytesPerSecond) {
                parts.append(eta)
            }
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.stringValue = parts.joined(separator: " · ")
        case .paused:
            progress.isHidden = false
            progress.barColor = .systemYellow
            progress.fraction = item.sizeBytes > 0 ? Double(item.bytes) / Double(item.sizeBytes) : 0
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.stringValue = item.autoPaused
                ? "电视连接不上 · 暂停中（已传 \(Fmt.bytes(item.bytes))）"
                : "已暂停 · 已传 \(Fmt.bytes(item.bytes))"
        case .failed:
            progress.isHidden = false
            progress.barColor = .systemRed
            progress.fraction = item.sizeBytes > 0 ? Double(item.bytes) / Double(item.sizeBytes) : 0
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = (item.direction == .download ? "取回失败 · " : "发送失败 · ")
                + (item.failureReason ?? "未知原因")
        case .completed:
            progress.isHidden = false
            progress.fraction = 1
            progress.barColor = .systemGreen
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.stringValue = item.skippedReason
                ?? (item.direction == .upload ? "已送到电视" : "已保存到本地")
        case .canceled:
            progress.isHidden = false
            progress.fraction = item.sizeBytes > 0 ? Double(item.bytes) / Double(item.sizeBytes) : 0
            progress.barColor = .separatorColor
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.stringValue = "已取消"
        }

        doneBadge.isHidden = item.phase != .completed
        rebuildActions(for: item)
    }

    private func rebuildActions(for item: QueueItem) {
        actionButtons.forEach { $0.removeFromSuperview() }
        actionButtons = []
        func add(_ img: NSImage, _ tip: String, action: @escaping () -> Void) {
            let b = UIUtil.iconButton(img, size: 24, action: action)
            b.toolTip = tip
            b.contentTintColor = .secondaryLabelColor
            actionsStack.addArrangedSubview(b)
            actionButtons.append(b)
        }
        switch item.phase {
        case .connecting, .running:
            add(Icons.pauseBars, "暂停") { [weak self] in
                if let id = self?.item?.id { self?.coordinator.queue.pause(id: id) }
            }
            add(Icons.xMark, "取消") { [weak self] in
                if let id = self?.item?.id { self?.coordinator.queue.cancel(id: id) }
            }
        case .paused:
            add(Icons.playTriangle, "继续") { [weak self] in
                if let id = self?.item?.id { self?.coordinator.queue.resume(id: id) }
            }
            add(Icons.xMark, "取消") { [weak self] in
                if let id = self?.item?.id { self?.coordinator.queue.cancel(id: id) }
            }
        case .queued:
            add(Icons.xMark, "取消") { [weak self] in
                if let id = self?.item?.id { self?.coordinator.queue.cancel(id: id) }
            }
        case .failed:
            add(Icons.retry, "重试") { [weak self] in
                if let id = self?.item?.id { self?.coordinator.queue.retry(id: id) }
            }
            add(Icons.xMark, "移除") { [weak self] in
                if let id = self?.item?.id { self?.coordinator.queue.remove(id: id) }
            }
        case .completed:
            add(Icons.folder, "在 Finder 中显示") { [weak self] in self?.revealLocal() }
        case .canceled:
            add(Icons.retry, "重新发送") { [weak self] in
                if let id = self?.item?.id { self?.coordinator.queue.retry(id: id) }
            }
        }
        actionsStack.isHidden = actionButtons.isEmpty
    }

    private func handleDoubleClick() {
        if item?.phase == .completed { revealLocal() }
    }

    private func revealLocal() {
        guard let item = item else { return }
        let path = item.localPath
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } else {
            coordinator.showToast("本地文件已不在原位置")
        }
    }

    // MARK: 右键菜单

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let item = item else { return super.menu(for: event) }
        let menu = NSMenu()
        switch item.phase {
        case .connecting, .running:
            menu.addItem(withTitle: "暂停", action: #selector(menuPause), keyEquivalent: "").target = self
            menu.addItem(withTitle: "取消", action: #selector(menuCancel), keyEquivalent: "").target = self
        case .paused:
            menu.addItem(withTitle: "继续", action: #selector(menuResume), keyEquivalent: "").target = self
            menu.addItem(withTitle: "取消", action: #selector(menuCancel), keyEquivalent: "").target = self
        case .failed:
            menu.addItem(withTitle: "重试", action: #selector(menuRetry), keyEquivalent: "").target = self
            menu.addItem(withTitle: "移除", action: #selector(menuRemove), keyEquivalent: "").target = self
        case .completed:
            menu.addItem(withTitle: "在 Finder 中显示", action: #selector(menuReveal), keyEquivalent: "").target = self
        case .canceled:
            menu.addItem(withTitle: "重新发送", action: #selector(menuRetry), keyEquivalent: "").target = self
        case .queued:
            menu.addItem(withTitle: "取消", action: #selector(menuCancel), keyEquivalent: "").target = self
        }
        if let remote = item.remoteName, remote != item.displayName {
            menu.addItem(.separator())
            menu.addItem(withTitle: "电视上的名字：\(remote)", action: nil, keyEquivalent: "")
        }
        return menu
    }

    @objc private func menuPause() { if let id = item?.id { coordinator.queue.pause(id: id) } }
    @objc private func menuResume() { if let id = item?.id { coordinator.queue.resume(id: id) } }
    @objc private func menuCancel() { if let id = item?.id { coordinator.queue.cancel(id: id) } }
    @objc private func menuRetry() { if let id = item?.id { coordinator.queue.retry(id: id) } }
    @objc private func menuRemove() { if let id = item?.id { coordinator.queue.remove(id: id) } }
    @objc private func menuReveal() { revealLocal() }
}
