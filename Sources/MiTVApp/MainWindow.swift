import AppKit
import Foundation

// MARK: - 根拖放视图（全窗口皆可落）

/// 注册 .fileURL 拖放；因为它是窗口根视图，列表态/浏览态/空态任何位置都能落。
final class RootDropView: NSView {

    var onFilesDropped: (([URL]) -> Void)?
    var dragActiveChanged: ((Bool) -> Void)?
    private var isDragging = false { didSet { needsDisplay = true; dragActiveChanged?(isDragging) } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError("不支持") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard hasFileURL(sender) else { return [] }
        isDragging = true
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        hasFileURL(sender) ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDragging = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender)
        isDragging = false
        guard !urls.isEmpty else { return false }
        onFilesDropped?(urls)
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        isDragging = false
    }

    private func hasFileURL(_ sender: NSDraggingInfo) -> Bool {
        !fileURLs(from: sender).isEmpty
    }

    private func fileURLs(from sender: NSDraggingInfo) -> [URL] {
        guard let items = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] else {
            return []
        }
        return items
    }

    /// 拖拽悬停时画一圈虚线高亮
    override func draw(_ dirtyRect: NSRect) {
        guard isDragging else { return }
        let rect = bounds.insetBy(dx: 10, dy: 10)
        let path = NSBezierPath(roundedRect: rect, xRadius: 16, yRadius: 16)
        path.setLineDash([8, 6], count: 2, phase: 0)
        NSColor.controlAccentColor.withAlphaComponent(0.85).setStroke()
        path.lineWidth = 3
        path.stroke()
        NSColor.controlAccentColor.withAlphaComponent(0.08).setFill()
        path.fill()
    }
}

// MARK: - 顶栏（状态胶囊 + 导航按钮）

final class HeaderBar: NSView {

    enum Nav: Int { case photos = 0, videos = 1, tv = 2 }

    let capsule = StatusCapsule()
    private(set) var navButtons: [NSButton] = []
    private var settingsButton: NSButton!
    var onNav: ((Nav) -> Void)?
    var onCapsuleTap: (() -> Void)?
    var onSettingsTap: (() -> Void)?

    init() {
        super.init(frame: .zero)
        setup()
    }
    required init?(coder: NSCoder) { fatalError("不支持") }

    private func setup() {
        wantsLayer = true
        let effect = UIUtil.visualEffect(material: .headerView)
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)

        capsule.translatesAutoresizingMaskIntoConstraints = false
        capsule.onTap = { [weak self] in self?.onCapsuleTap?() }
        addSubview(capsule)

        let titles: [(String, NSImage, Nav)] = [
            ("照片", Icons.photo, .photos),
            ("视频", Icons.video, .videos),
            ("电视", Icons.tv, .tv),
        ]
        var buttons: [NSButton] = []
        for (idx, t) in titles.enumerated() {
            let b = NSButton(title: t.0, target: self, action: #selector(navTapped(_:)))
            b.image = t.1
            b.imagePosition = .imageLeading
            b.isBordered = false
            b.setButtonType(.momentaryChange)
            b.font = NSFont.systemFont(ofSize: 13, weight: .medium)
            b.contentTintColor = .secondaryLabelColor
            b.tag = Nav(rawValue: idx)!.rawValue
            b.translatesAutoresizingMaskIntoConstraints = false
            addSubview(b)
            buttons.append(b)
        }
        navButtons = buttons

        settingsButton = NSButton(image: Icons.gear, target: self, action: #selector(settingsTapped))
        settingsButton.isBordered = false
        settingsButton.imagePosition = .imageOnly
        settingsButton.contentTintColor = .secondaryLabelColor
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(settingsButton)

        NSLayoutConstraint.activate([
            effect.topAnchor.constraint(equalTo: topAnchor),
            effect.bottomAnchor.constraint(equalTo: bottomAnchor),
            effect.leadingAnchor.constraint(equalTo: leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: trailingAnchor),

            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),

            capsule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            capsule.centerYAnchor.constraint(equalTo: centerYAnchor),

            settingsButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            settingsButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            settingsButton.widthAnchor.constraint(equalToConstant: 26),
            settingsButton.heightAnchor.constraint(equalToConstant: 26),

            navButtons[2].trailingAnchor.constraint(equalTo: settingsButton.leadingAnchor, constant: -16),
            navButtons[2].centerYAnchor.constraint(equalTo: centerYAnchor),
            navButtons[1].trailingAnchor.constraint(equalTo: navButtons[2].leadingAnchor, constant: -14),
            navButtons[1].centerYAnchor.constraint(equalTo: centerYAnchor),
            navButtons[0].trailingAnchor.constraint(equalTo: navButtons[1].leadingAnchor, constant: -14),
            navButtons[0].centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        highlightNav(.photos)
    }

    @objc private func navTapped(_ sender: NSButton) {
        guard let nav = Nav(rawValue: sender.tag) else { return }
        onNav?(nav)
    }

    @objc private func settingsTapped() { onSettingsTap?() }

    func highlightNav(_ nav: Nav) {
        for b in navButtons {
            let active = b.tag == nav.rawValue
            b.contentTintColor = active ? NSColor.controlAccentColor : .secondaryLabelColor
        }
    }
}

/// 状态胶囊：● 电视 · 已连接 / 连接不上 · 正在重试（第 N 次）/ 未连接电视
final class StatusCapsule: NSView {

    enum Look {
        case off, connecting, connected, lost
    }

    var onTap: (() -> Void)?
    private let dot = NSView()
    private let text = UIUtil.label("", size: 12, weight: .medium, color: .secondaryLabelColor)

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.25).cgColor
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(text)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            heightAnchor.constraint(equalToConstant: 24),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            text.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])
        let click = NSClickGestureRecognizer(target: self, action: #selector(tapped))
        addGestureRecognizer(click)
        setLook(.off, "未连接电视 · 点此连接")
    }

    required init?(coder: NSCoder) { fatalError("不支持") }

    @objc private func tapped() { onTap?() }

    func setLook(_ look: Look, _ message: String) {
        let color: NSColor
        switch look {
        case .off: color = .systemGray
        case .connecting: color = .systemOrange
        case .connected: color = .systemGreen
        case .lost: color = .systemYellow
        }
        dot.layer?.backgroundColor = color.cgColor
        text.stringValue = message
    }
}

// MARK: - 断线黄条（永不弹错误对话框，只显示这根黄条）

final class BannerView: NSView {

    private let spinner = NSProgressIndicator()
    private let label = UIUtil.label("", size: 12, weight: .medium, color: NSColor(red: 0.45, green: 0.32, blue: 0.02, alpha: 1))
    private var heightConstraint: NSLayoutConstraint!
    /// hide 的延迟收尾用 token 作废：show/hide 快速交替时旧的收尾不得隐藏新黄条
    private var hideToken = 0

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.24).cgColor
        spinner.isIndeterminate = true
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            heightConstraint,
            spinner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("不支持") }

    func show(_ text: String) {
        hideToken &+= 1 // 作废未决的 hide 收尾
        isHidden = false
        label.stringValue = text
        spinner.startAnimation(nil)
        heightConstraint.animator().constant = 32
    }

    func hide() {
        spinner.stopAnimation(nil)
        heightConstraint.animator().constant = 0
        let token = hideToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self, token == self.hideToken else { return }
            self.isHidden = true
        }
    }
}

// MARK: - 底部状态条

final class StatusBarView: NSView {

    private let leftLabel = UIUtil.label("就绪", size: 12, color: .secondaryLabelColor)
    private let rightLabel = UIUtil.label("", size: 12, color: .secondaryLabelColor)

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)
        leftLabel.translatesAutoresizingMaskIntoConstraints = false
        rightLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(leftLabel)
        addSubview(rightLabel)
        NSLayoutConstraint.activate([
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),
            leftLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            leftLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            rightLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            rightLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("不支持") }

    func set(left: String, right: String? = nil) {
        leftLabel.stringValue = left
        rightLabel.stringValue = right ?? "" // nil 必须清空，否则「排队 N 项」残留
    }
}
