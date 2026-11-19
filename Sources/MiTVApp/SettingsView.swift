import AppKit
import Foundation

// MARK: - 设置（只有一页，sheet 呈现）

final class SettingsController: NSObject, NSWindowDelegate {

    unowned let coordinator: AppCoordinator
    private var window: NSWindow?
    private var onClose: (() -> Void)?

    private let demoToggle = NSButton(checkboxWithTitle: "演示模式（使用内置模拟电视，无需真实设备）", target: nil, action: nil)
    private let notifyToggle = NSButton(checkboxWithTitle: "全部发送完成后通知我", target: nil, action: nil)
    private let soundToggle = NSButton(checkboxWithTitle: "完成时播放提示音", target: nil, action: nil)
    private let concurrencyPopup = NSPopUpButton()
    private let tvInfoLabel = UIUtil.label("", size: 12, color: .secondaryLabelColor)

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        super.init()
    }

    func present(asSheetOf parent: NSWindow, onClose: @escaping () -> Void) {
        self.onClose = onClose
        // .closable 必须有：否则没有关闭按钮，Esc 也不会触发关闭
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 400),
                           styleMask: [.titled, .closable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.title = "设置"
        win.titlebarAppearsTransparent = true
        win.delegate = self
        self.window = win

        let root = UIUtil.visualEffect(material: .windowBackground, blending: .withinWindow)
        root.translatesAutoresizingMaskIntoConstraints = false
        win.contentView = root

        // 内容可能超出一屏：包一层滚动
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        root.addSubview(scroll)

        let title = UIUtil.label("设置", size: 18, weight: .semibold)

        let tvTitle = UIUtil.label("电视", size: 13, weight: .semibold, color: .secondaryLabelColor)
        let reconnect = CapsuleButton("重新连接向导", style: .secondary)
        reconnect.tapAction = { [weak self] in
            self?.closeSheet()
            self?.coordinator.showOnboarding()
        }

        let queueTitle = UIUtil.label("发送", size: 13, weight: .semibold, color: .secondaryLabelColor)
        let concLabel = UIUtil.label("同时发送文件数", size: 13)
        for (i, n) in [1, 2, 3].enumerated() {
            concurrencyPopup.addItem(withTitle: "\(n) 个")
            concurrencyPopup.item(at: i)?.representedObject = n
        }
        let cur = max(1, UserDefaults.standard.integer(forKey: "concurrency"))
        concurrencyPopup.selectItem(at: [1, 2, 3].firstIndex(of: cur) ?? 1)
        concurrencyPopup.target = self
        concurrencyPopup.action = #selector(concurrencyChanged)

        let pathTitle = UIUtil.label("存放位置", size: 13, weight: .semibold, color: .secondaryLabelColor)
        let pathText = UIUtil.label("视频放进电视的 Movies 文件夹，照片放进 Pictures 文件夹，\n其他放在电视 U 盘根目录。重名文件自动顺延编号。",
                                    size: 12, color: .secondaryLabelColor)
        pathText.lineBreakMode = .byWordWrapping

        let engineTitle = UIUtil.label("连接方式", size: 13, weight: .semibold, color: .secondaryLabelColor)
        demoToggle.target = self
        demoToggle.action = #selector(demoChanged)
        demoToggle.state = EngineHolder.shared.isMock ? .on : .off
        demoToggle.font = NSFont.systemFont(ofSize: 12)
        notifyToggle.target = self
        notifyToggle.action = #selector(notifyChanged)
        notifyToggle.state = UserDefaults.standard.bool(forKey: "notifyOnComplete") ? .on : .off
        soundToggle.target = self
        soundToggle.action = #selector(soundChanged)
        soundToggle.state = UserDefaults.standard.bool(forKey: "soundOnComplete") ? .on : .off

        let doneButton = CapsuleButton("完成", style: .primary)
        doneButton.tapAction = { [weak self] in self?.closeSheet() }

        let stack = NSStackView(views: [
            title,
            tvTitle, tvInfoLabel, reconnect,
            queueTitle, concLabel, concurrencyPopup,
            pathTitle, pathText,
            engineTitle, demoToggle, notifyToggle, soundToggle,
            doneButton,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(16, after: title)
        stack.setCustomSpacing(16, after: reconnect)
        stack.setCustomSpacing(16, after: concurrencyPopup)
        stack.setCustomSpacing(16, after: pathText)
        stack.setCustomSpacing(16, after: soundToggle)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack
        pathText.preferredMaxLayoutWidth = 418 // 滚动视图内换行标签需要显式宽度

        let name = coordinator.store.state.tvName ?? "电视"
        let addr = coordinator.store.endpoint?.display ?? "未连接"
        tvInfoLabel.stringValue = "当前：\(name) · \(addr)"

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 32),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),

            // 文档视图钉住顶/左/右（宽度=可视宽度），高度随内容自由伸展 → 垂直可滚
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor, constant: 2),
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
        ])

        parent.beginSheet(win) { [weak self] _ in
            guard let self = self else { return }
            self.onClose?()
            self.window = nil
        }
    }

    private func closeSheet() {
        guard let w = window else { return }
        w.sheetParent?.endSheet(w)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
        window = nil
    }

    @objc private func concurrencyChanged() {
        guard let n = concurrencyPopup.selectedItem?.representedObject as? Int else { return }
        UserDefaults.standard.set(n, forKey: "concurrency")
        coordinator.queue.setConcurrency(n)
    }

    @objc private func demoChanged() {
        let mock = demoToggle.state == .on
        EngineHolder.shared.switchTo(mock: mock)
        // 重新探测（Mock 立即成功；真实引擎交由向导处理）
        if let endpoint = coordinator.store.endpoint {
            coordinator.connect(endpoint: endpoint, silent: true)
        }
        coordinator.showToast(mock ? "已切换为演示模式" : "已切换为连接真实电视")
    }

    @objc private func notifyChanged() {
        UserDefaults.standard.set(notifyToggle.state == .on, forKey: "notifyOnComplete")
    }

    @objc private func soundChanged() {
        UserDefaults.standard.set(soundToggle.state == .on, forKey: "soundOnComplete")
    }
}

// MARK: - 删除确认浮层（§7.5 第二层安全）

final class ConfirmOverlay: NSView {

    private var onConfirm: ((Bool) -> Void)?
    private var isHard = false
    /// disabled 策略（电视不支持删除）：确认按钮只做提示关闭，不触发删除流程
    private var notifyOnly = false
    private var downloadFirst = false
    /// 浮层移除后回调（协调器用它清 confirmOverlay 引用，否则键盘监听守卫永真）
    var dismissCompletion: (() -> Void)?

    private let titleLabel = UIUtil.label("", size: 16, weight: .semibold, align: .center)
    private let subLabel = UIUtil.label("", size: 13, color: .secondaryLabelColor, align: .center)
    private let thumbsRow = NSStackView()
    private let confirmButton = CapsuleButton("", style: .danger)
    private let cancelButton = CapsuleButton("取消", style: .secondary)
    private let downloadCheck = NSButton(checkboxWithTitle: "删除前先下载到本地", target: nil, action: nil)
    private let card = NSView()

    static func show(entries: [FTPFileEntry], strategy: DeleteStrategy, in parent: NSView,
                     onConfirm: @escaping (Bool) -> Void) -> ConfirmOverlay {
        let overlay = ConfirmOverlay()
        overlay.configure(entries: entries, strategy: strategy, onConfirm: onConfirm)
        overlay.frame = parent.bounds
        overlay.autoresizingMask = [.width, .height]
        parent.addSubview(overlay, positioned: .above, relativeTo: nil)
        return overlay
    }

    private func configure(entries: [FTPFileEntry], strategy: DeleteStrategy, onConfirm: @escaping (Bool) -> Void) {
        self.onConfirm = onConfirm
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.3).cgColor

        let files = entries.filter { !$0.isDirectory }
        let total = files.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        card.wantsLayer = true
        card.layer?.cornerRadius = 16
        card.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        card.layer?.borderColor = NSColor.separatorColor.cgColor
        card.layer?.borderWidth = 0.5
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        thumbsRow.orientation = .horizontal
        thumbsRow.spacing = 8
        thumbsRow.alignment = .centerY
        for entry in files.prefix(5) {
            let iv = NSImageView()
            iv.wantsLayer = true
            iv.layer?.cornerRadius = 6
            iv.layer?.masksToBounds = true
            iv.image = LocalThumbnailLoader.fallbackIcon(for: entry.kind)
            iv.contentTintColor = .quaternaryLabelColor
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.widthAnchor.constraint(equalToConstant: 40).isActive = true
            iv.heightAnchor.constraint(equalToConstant: 40).isActive = true
            thumbsRow.addArrangedSubview(iv)
        }
        if files.count > 5 {
            thumbsRow.addArrangedSubview(UIUtil.label("…等 \(files.count) 项", size: 12, color: .secondaryLabelColor))
        }

        switch strategy {
        case .soft:
            isHard = false
            titleLabel.stringValue = "移到电视回收站？"
            subLabel.stringValue = "已选 \(files.count) 项 · 共 \(Fmt.bytes(total))\n随时可以撤销"
            confirmButton.title = "移到回收站"
            confirmButton.style = .primary
            downloadCheck.isHidden = true
        case .hard:
            isHard = true
            titleLabel.stringValue = "永久删除？"
            subLabel.stringValue = "已选 \(files.count) 项 · 共 \(Fmt.bytes(total))\n这台电视不支持回收站，删除后无法撤销"
            confirmButton.title = "永久删除，无法撤销"
            confirmButton.style = .danger
            downloadCheck.isHidden = false
            downloadCheck.target = self
            downloadCheck.action = #selector(toggleDownloadFirst)
        case .disabled:
            isHard = true
            notifyOnly = true
            titleLabel.stringValue = "这台电视不支持删除"
            subLabel.stringValue = "电视没有开放删除能力，请直接在电视上操作"
            confirmButton.title = "知道了"
            confirmButton.style = .secondary
            downloadCheck.isHidden = true
        }

        cancelButton.tapAction = { [weak self] in self?.dismiss() }
        confirmButton.tapAction = { [weak self] in
            guard let self = self else { return }
            if self.notifyOnly {
                self.dismiss()
                return
            }
            let download = self.isHard && self.downloadCheck.state == .on
            self.dismiss()
            self.onConfirm?(download)
        }

        buildLayout()
    }

    private func buildLayout() {
        for v in [titleLabel, subLabel, thumbsRow, confirmButton, cancelButton, downloadCheck] {
            v.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(v)
        }
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 440),

            titleLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 26),
            titleLabel.centerXAnchor.constraint(equalTo: card.centerXAnchor),

            subLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            subLabel.centerXAnchor.constraint(equalTo: card.centerXAnchor),

            thumbsRow.topAnchor.constraint(equalTo: subLabel.bottomAnchor, constant: 16),
            thumbsRow.centerXAnchor.constraint(equalTo: card.centerXAnchor),

            downloadCheck.topAnchor.constraint(equalTo: thumbsRow.bottomAnchor, constant: 14),
            downloadCheck.centerXAnchor.constraint(equalTo: card.centerXAnchor),

            cancelButton.topAnchor.constraint(equalTo: downloadCheck.isHidden ? thumbsRow.bottomAnchor : downloadCheck.bottomAnchor, constant: 20),
            cancelButton.trailingAnchor.constraint(equalTo: card.centerXAnchor, constant: -8),
            cancelButton.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -24),

            confirmButton.centerYAnchor.constraint(equalTo: cancelButton.centerYAnchor),
            confirmButton.leadingAnchor.constraint(equalTo: card.centerXAnchor, constant: 8),
        ])
    }

    @objc private func toggleDownloadFirst() {
        downloadFirst = downloadCheck.state == .on
    }

    private func dismiss() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.removeFromSuperview()
            self?.dismissCompletion?()
        })
    }

    /// 冒烟辅助：自动点确认按钮
    func smokeAutoConfirm(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.confirmButton.tapAction?()
        }
    }
}
