import AppKit
import Foundation

// MARK: - 空态大拖放区（第一印象，留白大方）

final class EmptyStateView: NSView {

    private let dashedBox = DashedBox()
    private let bigIcon = NSImageView()
    private let titleLabel = UIUtil.label("把照片和视频拖到这里", size: 22, weight: .semibold, align: .center)
    private let subLabel = UIUtil.label("送到客厅的电视上，马上就能看", size: 14, color: .secondaryLabelColor, align: .center)
    private let photoButton: CapsuleButton
    private let fileButton: CapsuleButton
    private let hintLabel = UIUtil.label("也可以把文件拖到 Dock 图标上 · 电视上的内容点「电视」查看",
                                         size: 12, color: .tertiaryLabelColor, align: .center)

    init(onPickPhotos: @escaping () -> Void, onPickFiles: @escaping () -> Void) {
        photoButton = CapsuleButton("从照片图库挑选", style: .primary)
        fileButton = CapsuleButton("从文件夹挑选", style: .secondary)
        super.init(frame: .zero)
        photoButton.tapAction = onPickPhotos
        fileButton.tapAction = onPickFiles

        wantsLayer = true
        let effect = UIUtil.visualEffect(material: .underWindowBackground)
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect, positioned: .below, relativeTo: nil)

        dashedBox.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dashedBox)

        bigIcon.image = Icons.dropBig
        bigIcon.contentTintColor = NSColor.controlAccentColor.withAlphaComponent(0.75)

        let centerStack = NSStackView(views: [bigIcon, titleLabel, subLabel, photoButton, fileButton])
        centerStack.orientation = .vertical
        centerStack.spacing = 14
        centerStack.setCustomSpacing(22, after: subLabel)
        centerStack.alignment = .centerX
        centerStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(centerStack)

        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hintLabel)

        NSLayoutConstraint.activate([
            effect.topAnchor.constraint(equalTo: topAnchor),
            effect.bottomAnchor.constraint(equalTo: bottomAnchor),
            effect.leadingAnchor.constraint(equalTo: leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: trailingAnchor),

            dashedBox.topAnchor.constraint(equalTo: topAnchor, constant: 22),
            dashedBox.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
            dashedBox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 26),
            dashedBox.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -26),

            centerStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            centerStack.centerYAnchor.constraint(equalTo: dashedBox.centerYAnchor, constant: -8),
            centerStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 60),
            centerStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -60),

            hintLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            hintLabel.bottomAnchor.constraint(equalTo: dashedBox.bottomAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) { fatalError("不支持") }
}

/// 虚线圆角大框（纯背景元素）
final class DashedBox: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 18, yRadius: 18)
        path.setLineDash([7, 7], count: 2, phase: 0)
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1.6
        path.stroke()
    }
}
