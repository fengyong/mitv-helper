import AppKit
import Foundation

// MARK: - 自绘模板图标（macOS 10.15 无 SF Symbols API，全部手绘，单色随系统渲染）

enum Icons {

    static func make(_ size: CGFloat, _ draw: (CGFloat) -> Void) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        NSColor.black.setStroke()
        NSColor.black.setFill()
        draw(size)
        img.unlockFocus()
        img.isTemplate = true
        return img
    }

    static func path(_ block: (NSBezierPath) -> Void) {
        let p = NSBezierPath()
        block(p)
        p.stroke()
    }

    /// 照片：圆角框 + 山 + 太阳
    static let photo: NSImage = make(18) { s in
        let r = NSRect(x: 2, y: 2.5, width: s - 4, height: s - 5).insetBy(dx: 0.5, dy: 0.5)
        let p = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
        p.lineWidth = 1.4; p.stroke()
        let hill = NSBezierPath()
        hill.move(to: NSPoint(x: r.minX + 1.5, y: r.minY + 3))
        hill.line(to: NSPoint(x: r.minX + r.width * 0.42, y: r.minY + r.height * 0.55))
        hill.line(to: NSPoint(x: r.minX + r.width * 0.62, y: r.minY + r.height * 0.32))
        hill.line(to: NSPoint(x: r.maxX - 1.5, y: r.minY + 3))
        hill.lineWidth = 1.4; hill.stroke()
        let sun = NSBezierPath(ovalIn: NSRect(x: r.maxX - 7, y: r.maxY - 7, width: 3.6, height: 3.6))
        sun.fill()
    }

    /// 视频：圆角框 + 播放三角
    static let video: NSImage = make(18) { s in
        let r = NSRect(x: 2, y: 2.5, width: s - 4, height: s - 5).insetBy(dx: 0.5, dy: 0.5)
        let pr = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3); pr.lineWidth = 1.4; pr.stroke()
        let t = NSBezierPath()
        let cx = r.midX + 0.8, cy = r.midY
        t.move(to: NSPoint(x: cx - 2.6, y: cy + 3))
        t.line(to: NSPoint(x: cx + 2.6, y: cy))
        t.line(to: NSPoint(x: cx - 2.6, y: cy - 3))
        t.close()
        t.fill()
    }

    /// 电视：屏幕 + 支架
    static let tv: NSImage = make(18) { s in
        let r = NSRect(x: 2, y: 4.5, width: s - 4, height: s - 9.5).insetBy(dx: 0.5, dy: 0.5)
        let pv = NSBezierPath(roundedRect: r, xRadius: 2.5, yRadius: 2.5); pv.lineWidth = 1.4; pv.stroke()
        let stand = NSBezierPath()
        stand.move(to: NSPoint(x: r.midX, y: r.minY))
        stand.line(to: NSPoint(x: r.midX, y: r.minY - 2))
        stand.lineWidth = 1.4
        stand.stroke()
        let base = NSBezierPath()
        base.move(to: NSPoint(x: r.midX - 3.5, y: r.minY - 2.6))
        base.line(to: NSPoint(x: r.midX + 3.5, y: r.minY - 2.6))
        base.lineWidth = 1.4
        base.stroke()
    }

    /// 齿轮（设置）：圆环 + 齿
    static let gear: NSImage = make(18) { s in
        let c = NSPoint(x: s / 2, y: s / 2)
        for i in 0..<8 {
            let a = CGFloat(i) * .pi / 4
            let p = NSBezierPath()
            p.move(to: NSPoint(x: c.x + cos(a) * 4.2, y: c.y + sin(a) * 4.2))
            p.line(to: NSPoint(x: c.x + cos(a) * 7.2, y: c.y + sin(a) * 7.2))
            p.lineWidth = 2.2
            p.stroke()
        }
        let ring = NSBezierPath(ovalIn: NSRect(x: c.x - 3.6, y: c.y - 3.6, width: 7.2, height: 7.2))
        ring.lineWidth = 1.8
        ring.stroke()
    }

    static let folder: NSImage = make(18) { s in
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 2, y: 14))
        p.line(to: NSPoint(x: 6.5, y: 14))
        p.line(to: NSPoint(x: 8.5, y: 11.8))
        p.line(to: NSPoint(x: 16, y: 11.8))
        p.line(to: NSPoint(x: 16, y: 4))
        p.line(to: NSPoint(x: 2, y: 4))
        p.close()
        p.lineWidth = 1.4
        p.stroke()
        _ = s
    }

    static let film: NSImage = make(18) { s in
        let r = NSRect(x: 2.5, y: 3, width: s - 5, height: s - 6).insetBy(dx: 0.5, dy: 0.5)
        let pf = NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2); pf.lineWidth = 1.3; pf.stroke()
        for i in 1...2 {
            let y = r.minY + r.height * CGFloat(i) / 3.0
            let line = NSBezierPath()
            line.move(to: NSPoint(x: r.minX + 2, y: y))
            line.line(to: NSPoint(x: r.maxX - 2, y: y))
            line.lineWidth = 1.0
            line.stroke()
        }
    }

    /// 文档（.txt 等其他文件的兜底图标）
    static let doc: NSImage = make(18) { s in
        let r = NSRect(x: 4, y: 2.5, width: s - 8, height: s - 5).insetBy(dx: 0.5, dy: 0.5)
        let p = NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2)
        p.lineWidth = 1.3
        p.stroke()
        for i in 1...3 {
            let y = r.minY + r.height * CGFloat(i) / 4.0
            let line = NSBezierPath()
            line.move(to: NSPoint(x: r.minX + 2.5, y: y))
            line.line(to: NSPoint(x: r.maxX - 2.5, y: y))
            line.lineWidth = 1.0
            line.stroke()
        }
    }

    static let trash: NSImage = make(18) { s in
        let lid = NSBezierPath()
        lid.move(to: NSPoint(x: 3.5, y: 13.5)); lid.line(to: NSPoint(x: 14.5, y: 13.5))
        lid.lineWidth = 1.4; lid.stroke()
        let handle = NSBezierPath()
        handle.move(to: NSPoint(x: 7, y: 13.5)); handle.line(to: NSPoint(x: 7, y: 15.2))
        handle.line(to: NSPoint(x: 11, y: 15.2)); handle.line(to: NSPoint(x: 11, y: 13.5))
        handle.lineWidth = 1.2; handle.stroke()
        let body = NSBezierPath()
        body.move(to: NSPoint(x: 5, y: 13.2)); body.line(to: NSPoint(x: 5.8, y: 3.5))
        body.line(to: NSPoint(x: 12.2, y: 3.5)); body.line(to: NSPoint(x: 13, y: 13.2))
        body.lineWidth = 1.4; body.stroke()
        _ = s
    }

    static let chevronLeft: NSImage = make(16) { s in
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 9.5, y: 3))
        p.line(to: NSPoint(x: 5, y: s / 2))
        p.line(to: NSPoint(x: 9.5, y: 13))
        p.lineWidth = 1.8
        p.lineCapStyle = .round
        p.stroke()
    }

    static let check: NSImage = make(14) { _ in
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 3, y: 7.5))
        p.line(to: NSPoint(x: 6, y: 4.5))
        p.line(to: NSPoint(x: 11, y: 10.5))
        p.lineWidth = 1.8
        p.lineCapStyle = .round
        p.stroke()
    }

    static let pauseBars: NSImage = make(14) { _ in
        for x in [4.0, 8.4] {
            let p = NSBezierPath()
            p.move(to: NSPoint(x: x, y: 3)); p.line(to: NSPoint(x: x, y: 11))
            p.lineWidth = 2.0; p.lineCapStyle = .round; p.stroke()
        }
    }

    static let playTriangle: NSImage = make(14) { _ in
        let t = NSBezierPath()
        t.move(to: NSPoint(x: 4.5, y: 3))
        t.line(to: NSPoint(x: 11.5, y: 7))
        t.line(to: NSPoint(x: 4.5, y: 11))
        t.close()
        t.fill()
    }

    static let retry: NSImage = make(14) { s in
        let a = CGFloat(300) * .pi / 180
        let b = CGFloat(80) * .pi / 180
        let arc = NSBezierPath()
        arc.appendArc(withCenter: NSPoint(x: s / 2, y: s / 2), radius: 4.4,
                      startAngle: a, endAngle: b, clockwise: false)
        arc.lineWidth = 1.6
        arc.stroke()
        let tip = NSPoint(x: s / 2 + cos(b) * 4.4, y: s / 2 + sin(b) * 4.4)
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: tip.x - 1.5, y: tip.y + 1.6))
        arrow.line(to: tip)
        arrow.line(to: NSPoint(x: tip.x + 2.4, y: tip.y + 0.9))
        arrow.lineWidth = 1.6
        arrow.stroke()
    }

    static let xMark: NSImage = make(14) { s in
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 3.5, y: 3.5)); p.line(to: NSPoint(x: s - 3.5, y: s - 3.5))
        p.move(to: NSPoint(x: s - 3.5, y: 3.5)); p.line(to: NSPoint(x: 3.5, y: s - 3.5))
        p.lineWidth = 1.6; p.lineCapStyle = .round; p.stroke()
    }

    static let downloadTray: NSImage = make(16) { s in
        let tray = NSBezierPath()
        tray.move(to: NSPoint(x: 3, y: 4))
        tray.line(to: NSPoint(x: 3, y: 7))
        tray.line(to: NSPoint(x: 13, y: 7))
        tray.line(to: NSPoint(x: 13, y: 4))
        tray.lineWidth = 1.5; tray.stroke()
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: s / 2, y: 12.5)); arrow.line(to: NSPoint(x: s / 2, y: 6.2))
        arrow.lineWidth = 1.5; arrow.stroke()
        let head = NSBezierPath()
        head.move(to: NSPoint(x: s / 2 - 2.6, y: 8.6)); head.line(to: NSPoint(x: s / 2, y: 6))
        head.line(to: NSPoint(x: s / 2 + 2.6, y: 8.6))
        head.lineWidth = 1.5; head.stroke()
    }

    /// 空态大图标：托盘 + 下落箭头
    static let dropBig: NSImage = make(96) { s in
        let tray = NSBezierPath()
        tray.move(to: NSPoint(x: s * 0.18, y: s * 0.34))
        tray.line(to: NSPoint(x: s * 0.18, y: s * 0.5))
        tray.line(to: NSPoint(x: s * 0.82, y: s * 0.5))
        tray.line(to: NSPoint(x: s * 0.82, y: s * 0.34))
        tray.lineWidth = 4
        tray.lineJoinStyle = .round
        tray.stroke()
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: s / 2, y: s * 0.84))
        arrow.line(to: NSPoint(x: s / 2, y: s * 0.56))
        arrow.lineWidth = 4
        arrow.lineCapStyle = .round
        arrow.stroke()
        let head = NSBezierPath()
        head.move(to: NSPoint(x: s * 0.40, y: s * 0.66))
        head.line(to: NSPoint(x: s / 2, y: s * 0.56))
        head.line(to: NSPoint(x: s * 0.60, y: s * 0.66))
        head.lineWidth = 4
        head.lineCapStyle = .round
        head.stroke()
    }
}

// MARK: - 数字格式化（零术语：速度带「/秒」）

enum Fmt {
    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    static func speed(_ bps: Double) -> String? {
        guard bps > 0 else { return nil }
        let s = ByteCountFormatter.string(fromByteCount: Int64(bps), countStyle: .file)
        return s + "/秒"
    }

    static func eta(_ bytes: Int64, bps: Double) -> String? {
        guard bps > 0, bytes > 0 else { return nil }
        let seconds = Int(Double(bytes) / bps)
        switch seconds {
        case ..<60: return "剩 \(seconds) 秒"
        case ..<3600: return "剩 \(seconds / 60) 分钟"
        case ..<86400: return "剩 \(seconds / 3600) 小时\(seconds % 3600 / 60) 分"
        default: return "剩 \(seconds / 86400) 天"
        }
    }
}

// MARK: - 圆角按钮（primary / secondary / danger）

final class CapsuleButton: NSButton {

    enum Style { case primary, secondary, danger }
    var style: Style = .primary { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 7
    private var hovering = false

    init(_ title: String, style: Style = .primary, action: (() -> Void)? = nil) {
        self.tapAction = action
        self.style = style
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .texturedRounded
        isBordered = false
        setButtonType(.momentaryChange)
        target = self
        self.action = #selector(didTap)
        font = NSFont.systemFont(ofSize: 13, weight: .medium)
        contentTintColor = nil
        let ta = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .inVisibleRect, .activeInKeyWindow], owner: nil, userInfo: nil)
        addTrackingArea(ta)
    }

    var tapAction: (() -> Void)?

    required init?(coder: NSCoder) { fatalError("不支持") }

    @objc private func didTap() { tapAction?() }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: title.size(withAttributes: [.font: font!]).width + 32, height: 26)
    }

    override func draw(_ dirtyRect: NSRect) {
        let bg: NSColor
        let fg: NSColor
        switch style {
        case .primary:
            bg = NSColor.controlAccentColor.withAlphaComponent(hovering ? 0.88 : 1)
            fg = .white
        case .secondary:
            bg = hovering ? NSColor.quaternaryLabelColor.withAlphaComponent(0.5) : NSColor.quaternaryLabelColor.withAlphaComponent(0.25)
            fg = .labelColor
        case .danger:
            bg = NSColor.systemRed.withAlphaComponent(hovering ? 0.9 : 0.85)
            fg = .white
        }
        let path = NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)
        bg.setFill()
        path.fill()
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [.font: font!, .foregroundColor: fg, .paragraphStyle: para]
        let rect = bounds.insetBy(dx: 10, dy: 4)
        (title as NSString).draw(in: rect, withAttributes: attrs)
    }
}

// MARK: - 细进度条（自绘，accent 色）

final class ThinProgressBar: NSView {

    var fraction: Double = 0 { didSet { needsDisplay = true } }
    var barColor: NSColor = .controlAccentColor
    var trackColor: NSColor = NSColor.separatorColor

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("不支持") }

    override var intrinsicContentSize: NSSize { NSSize(width: 120, height: 4) }

    override func draw(_ dirtyRect: NSRect) {
        let h: CGFloat = 4
        let rect = NSRect(x: 0, y: (bounds.height - h) / 2, width: bounds.width, height: h)
        let track = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
        trackColor.setFill()
        track.fill()
        guard fraction > 0 else { return }
        let w = max(4, rect.width * CGFloat(min(1, fraction)))
        let fill = NSBezierPath(roundedRect: NSRect(x: 0, y: rect.minY, width: w, height: h), xRadius: 2, yRadius: 2)
        barColor.setFill()
        fill.fill()
    }
}

// MARK: - Toast（含可选「撤销」按钮）

final class ToastView: NSView {

    private let label = NSTextField(labelWithString: "")
    private var actionButton: NSButton?
    private var tapAction: (() -> Void)?
    private var dismissTimer: Timer?

    init(text: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 1
        self.tapAction = action
        label.stringValue = text
        label.font = NSFont.systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.lineBreakMode = .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        let leading = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16)
        if let actionTitle = actionTitle {
            let btn = NSButton(title: actionTitle, target: self, action: #selector(doAction))
            btn.bezelStyle = .rounded
            btn.isBordered = true
            btn.controlSize = .small
            btn.translatesAutoresizingMaskIntoConstraints = false
            btn.tapActionHolder = action
            addSubview(btn)
            actionButton = btn
            NSLayoutConstraint.activate([
                btn.centerYAnchor.constraint(equalTo: centerYAnchor),
                btn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                label.trailingAnchor.constraint(lessThanOrEqualTo: btn.leadingAnchor, constant: -10),
            ])
        } else {
            NSLayoutConstraint.activate([
                label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            ])
        }
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            leading,
            topAnchor.constraint(greaterThanOrEqualTo: label.topAnchor, constant: -8),
            bottomAnchor.constraint(greaterThanOrEqualTo: label.bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("不支持") }

    @objc private func doAction() {
        tapAction?()
        dismiss()
    }

    func scheduleAutoDismiss(after seconds: TimeInterval = 6) {
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.dismiss()
        }
    }

    func dismiss() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.removeFromSuperview()
        })
    }
}

/// NSButton 没有 target-action 闭包挂点，借 associated holder
private var toastActionKey: UInt8 = 0
extension NSButton {
    var tapActionHolder: (() -> Void)? {
        get { objc_getAssociatedObject(self, &toastActionKey) as? (() -> Void) }
        set { objc_setAssociatedObject(self, &toastActionKey, newValue, .OBJC_ASSOCIATION_COPY) }
    }
}

/// Toast 宿主：挂在主内容区顶部层级；无按钮时点击完全穿透
final class ToastHostView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !subviews.isEmpty else { return nil }
        let hit = super.hitTest(point)
        if let hit = hit, hit is NSButton { return hit }
        return nil
    }

    func show(_ toast: ToastView, in bounds: NSRect) {
        // 单条 toast：新 toast 顶掉旧的，避免叠影
        for sub in subviews {
            sub.removeFromSuperview()
        }
        let ideal = toast.fittingSize
        toast.frame = NSRect(x: bounds.midX - ideal.width / 2,
                             y: bounds.maxY - ideal.height - 18,
                             width: max(ideal.width, 120), height: max(ideal.height, 34))
        toast.alphaValue = 0
        addSubview(toast)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            toast.animator().alphaValue = 1
        }
    }
}

// MARK: - 通用小工具

enum UIUtil {

    static func visualEffect(material: NSVisualEffectView.Material, blending: NSVisualEffectView.BlendingMode = .behindWindow) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        return v
    }

    static func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
                      color: NSColor = .labelColor, align: NSTextAlignment = .left) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = NSFont.systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.alignment = align
        l.lineBreakMode = .byTruncatingTail
        return l
    }

    static func iconButton(_ image: NSImage, size: CGFloat = 26, action: (() -> Void)? = nil) -> NSButton {
        let b = NSButton(image: image, target: nil, action: nil)
        b.isBordered = false
        b.imagePosition = .imageOnly
        b.contentTintColor = .secondaryLabelColor
        b.setFrameSize(NSSize(width: size, height: size))
        if let action = action {
            b.target = ActionBox.shared
            ActionBox.shared.register(b, action)
            b.action = #selector(ActionBox.fire(_:))
        }
        return b
    }
}

/// 简易闭包-动作登记（NSButton target）
final class ActionBox: NSObject {
    static let shared = ActionBox()
    private var map: [ObjectIdentifier: (() -> Void)] = [:]
    func register(_ button: NSButton, _ action: @escaping () -> Void) {
        map[ObjectIdentifier(button)] = action
    }
    @objc func fire(_ sender: NSButton) {
        map[ObjectIdentifier(sender)]?()
    }
}
