import AppKit
import Foundation

// MARK: - 「选择存放位置」弹窗（sheet 呈现；设计稿 docs/20261119_design_upload_target.md v2 §5.2）
// 模式单选：智能分类（默认，现状不变）/ 指定位置（目录浏览选定，可为根目录）。
// 最近使用快切（上限 5）+ 新建文件夹（仅 caps.mkdir=true 显示，D1：真机 MKD 550 隐藏，不摆必失败按钮）。
// 数据源复用 TVFileService.list（目录优先排序）+ BrowseFilter（隐藏系统目录）。零术语。

/// 翻转坐标的竖排 stack：作为 scroll.documentView 时短内容也锚定可视区顶部
/// （非翻转 documentView 内容沉底，走查实测发现）
private final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

final class DirPickerController: NSObject, NSWindowDelegate {

    /// 确认回调：nil = 智能分类；非 nil = 指定目录（可为 "/" 根目录）
    var onPicked: ((String?) -> Void)?
    /// sheet 关闭回调（协调器据此清引用）
    var onClose: (() -> Void)?
    private unowned let coordinator: AppCoordinator
    private var window: NSWindow?

    // 模式选择
    private let smartRadio: NSButton
    private let customRadio: NSButton
    private let smartHint = UIUtil.label("视频放进 Movies 文件夹，照片放进 Pictures 文件夹，其他放根目录",
                                         size: 11, color: .secondaryLabelColor)
    private let customHint = UIUtil.label("所有文件放进下面选定的文件夹", size: 11, color: .secondaryLabelColor)

    // 目录浏览
    private var path = "/"
    private var dirs: [FTPFileEntry] = []
    /// 列表请求序号：晚到的旧回调不得冲掉当前视图（与浏览页同一防护）
    private var loadEpoch = 0
    private let backButton: NSButton
    private let breadcrumb: NSStackView
    private let scroll = NSScrollView()
    private let dirListStack = FlippedStackView()
    private let emptyLabel: NSTextField
    private let spinner = NSProgressIndicator()
    private let recentTitle = UIUtil.label("最近使用", size: 11, color: .tertiaryLabelColor)
    private let recentRow: NSStackView
    private let newFolderButton: CapsuleButton
    private let currentLabel = UIUtil.label("", size: 12, color: .secondaryLabelColor)
    private let cancelButton: CapsuleButton
    private let confirmButton: CapsuleButton

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        smartRadio = NSButton(radioButtonWithTitle: "智能分类", target: nil, action: nil)
        customRadio = NSButton(radioButtonWithTitle: "指定位置", target: nil, action: nil)
        backButton = NSButton(image: Icons.chevronLeft, target: nil, action: nil)
        breadcrumb = NSStackView()
        emptyLabel = UIUtil.label("这个目录里没有文件夹", size: 13, color: .secondaryLabelColor, align: .center)
        recentRow = NSStackView()
        newFolderButton = CapsuleButton("新建文件夹", style: .secondary)
        cancelButton = CapsuleButton("取消", style: .secondary)
        confirmButton = CapsuleButton("使用此位置", style: .primary)
        super.init()
    }

    // MARK: 呈现

    func present(asSheetOf parent: NSWindow) {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 640),
                           styleMask: [.titled, .closable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.title = "选择存放位置"
        win.titlebarAppearsTransparent = true
        win.delegate = self
        self.window = win
        win.contentView = buildLayout()

        // 初始模式与所在目录 = 当前全局设置
        if let dir = coordinator.store.state.customUploadDir {
            customRadio.state = .on
            path = dir
        } else {
            smartRadio.state = .on
        }
        rebuildRecent()
        applyModeVisibility()
        listCurrent()

        parent.beginSheet(win) { [weak self] _ in
            guard let self = self else { return }
            self.onClose?()
            self.window = nil
        }
    }

    func closeSheet() {
        guard let w = window else { return }
        w.sheetParent?.endSheet(w)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
        window = nil
    }

    // MARK: 布局

    @discardableResult
    private func buildLayout() -> NSView {
        smartRadio.target = self
        smartRadio.action = #selector(radioChanged(_:))
        smartRadio.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        customRadio.target = self
        customRadio.action = #selector(radioChanged(_:))
        customRadio.font = NSFont.systemFont(ofSize: 13, weight: .medium)

        // 浏览区（模式为「指定位置」时可见）
        backButton.isBordered = false
        backButton.imagePosition = .imageOnly
        backButton.contentTintColor = .secondaryLabelColor
        backButton.target = self
        backButton.action = #selector(goBack)
        backButton.isHidden = true

        breadcrumb.orientation = .horizontal
        breadcrumb.spacing = 4
        breadcrumb.alignment = .centerY

        dirListStack.orientation = .vertical
        dirListStack.alignment = .leading
        dirListStack.spacing = 2
        // 作为 scroll.documentView：必须交给 Auto Layout（钉顶/左/右、高度随内容伸展），
        // 否则 autoresizing frame 与 contentView 约束打架，列表整块不渲染（走查实测发现）
        dirListStack.translatesAutoresizingMaskIntoConstraints = false

        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        scroll.documentView = dirListStack
        // 文档视图钉住顶/左/右，高度随内容伸展（与设置页同一手法）
        dirListStack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor, constant: 4).isActive = true
        dirListStack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor, constant: 4).isActive = true
        dirListStack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor, constant: -4).isActive = true

        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.usesSingleLineMode = false
        emptyLabel.maximumNumberOfLines = 0
        emptyLabel.preferredMaxLayoutWidth = 420
        spinner.isIndeterminate = true
        spinner.controlSize = .small

        recentRow.orientation = .horizontal
        recentRow.spacing = 6
        recentRow.alignment = .centerY

        newFolderButton.tapAction = { [weak self] in self?.newFolderTapped() }
        // D1：仅 caps.mkdir=true 显示（真机 SwiFTP MKD 550 → 隐藏）
        newFolderButton.isHidden = coordinator.store.capabilities?.mkdir != true

        cancelButton.tapAction = { [weak self] in self?.closeSheet() }
        confirmButton.tapAction = { [weak self] in self?.confirmTapped() }

        let browserSection = NSView()
        browserSection.translatesAutoresizingMaskIntoConstraints = false
        // 无固有尺寸的普通 view 交给 NSStackView 排布会被压缩：显式定高 + 强 hugging
        //（内链高度 = 最近 16+6+chips 26 + 12+面包屑 18 + 6+列表 220 + 12+底行 26 = 342）
        browserSection.heightAnchor.constraint(equalToConstant: 342).isActive = true
        browserSection.setContentHuggingPriority(.required, for: .vertical)
        browserSection.setContentCompressionResistancePriority(.required, for: .vertical)

        // 取消/确认也排在 section 底行（此前 buttonsRow 与 currentLabel 跨分支双重挂载，
        // 把底行布局搅乱——走查实测发现）
        let content = NSStackView(views: [
            UIUtil.label("选择存放位置", size: 18, weight: .semibold),
            smartRadio, smartHint,
            customRadio, customHint,
            browserSection,
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 6
        // 标题后留白（setCustomSpacing 需要 view 引用，取 content 第一个 arranged）
        if let titleView = content.arrangedSubviews.first {
            content.setCustomSpacing(16, after: titleView)
        }
        content.setCustomSpacing(18, after: customHint)
        content.translatesAutoresizingMaskIntoConstraints = false

        let root = UIUtil.visualEffect(material: .windowBackground, blending: .withinWindow)
        root.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)

        // 浏览区内部（手排：面包屑 + 列表 + 底行[新建文件夹 · 当前所在 · 取消 · 使用此位置]）
        let sectionViews = [recentTitle, recentRow, backButton, breadcrumb, scroll, emptyLabel, spinner,
                            newFolderButton, currentLabel, cancelButton, confirmButton]
        for v in sectionViews {
            v.translatesAutoresizingMaskIntoConstraints = false
            browserSection.addSubview(v)
        }

        let sectionWidth: CGFloat = 476
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 30),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -30),
            content.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -24),

            browserSection.widthAnchor.constraint(equalToConstant: sectionWidth),

            recentTitle.topAnchor.constraint(equalTo: browserSection.topAnchor),
            recentTitle.leadingAnchor.constraint(equalTo: browserSection.leadingAnchor),
            recentRow.topAnchor.constraint(equalTo: recentTitle.bottomAnchor, constant: 6),
            recentRow.leadingAnchor.constraint(equalTo: browserSection.leadingAnchor),
            recentRow.trailingAnchor.constraint(lessThanOrEqualTo: browserSection.trailingAnchor),

            backButton.leadingAnchor.constraint(equalTo: browserSection.leadingAnchor),
            backButton.centerYAnchor.constraint(equalTo: breadcrumb.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 22),
            backButton.heightAnchor.constraint(equalToConstant: 22),

            breadcrumb.topAnchor.constraint(equalTo: recentRow.bottomAnchor, constant: 12),
            breadcrumb.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 6),

            scroll.topAnchor.constraint(equalTo: breadcrumb.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: browserSection.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: browserSection.trailingAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 220),

            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            spinner.trailingAnchor.constraint(equalTo: browserSection.trailingAnchor, constant: -4),
            spinner.centerYAnchor.constraint(equalTo: breadcrumb.centerYAnchor),

            newFolderButton.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 12),
            newFolderButton.leadingAnchor.constraint(equalTo: browserSection.leadingAnchor),
            newFolderButton.bottomAnchor.constraint(equalTo: browserSection.bottomAnchor),

            currentLabel.centerYAnchor.constraint(equalTo: newFolderButton.centerYAnchor),
            currentLabel.leadingAnchor.constraint(equalTo: newFolderButton.trailingAnchor, constant: 12),
            currentLabel.trailingAnchor.constraint(lessThanOrEqualTo: cancelButton.leadingAnchor, constant: -12),

            confirmButton.centerYAnchor.constraint(equalTo: newFolderButton.centerYAnchor),
            confirmButton.trailingAnchor.constraint(equalTo: browserSection.trailingAnchor),
            cancelButton.centerYAnchor.constraint(equalTo: newFolderButton.centerYAnchor),
            cancelButton.trailingAnchor.constraint(equalTo: confirmButton.leadingAnchor, constant: -10),
        ])

        // 手排布局下 smartHint/customHint 需要换行宽度
        smartHint.preferredMaxLayoutWidth = sectionWidth
        customHint.preferredMaxLayoutWidth = sectionWidth
        smartHint.lineBreakMode = .byWordWrapping
        customHint.lineBreakMode = .byWordWrapping
        currentLabel.lineBreakMode = .byTruncatingTail
        return root
    }

    // MARK: 模式切换

    @objc private func radioChanged(_ sender: NSButton) {
        if sender === smartRadio {
            smartRadio.state = .on
            customRadio.state = .off
        } else {
            customRadio.state = .on
            smartRadio.state = .off
        }
        applyModeVisibility()
    }

    private func applyModeVisibility() {
        let custom = customRadio.state == .on
        for v in [recentTitle, recentRow, backButton, breadcrumb, scroll] {
            v.isHidden = !custom
        }
        // 新建文件夹可见性 = 指定模式 且 caps.mkdir（D1）；不放进上面的模式列表——
        // 模式切换不得越权改写能力门控（走查实测发现：mkdir=false 也被顶成可见）
        newFolderButton.isHidden = !custom || coordinator.store.capabilities?.mkdir != true
        spinner.isHidden = !custom
        if custom {
            emptyLabel.isHidden = !dirs.isEmpty
        } else {
            emptyLabel.isHidden = true
        }
        // 文案随模式走：智能分类 = 恢复默认；指定位置 = 作用于当前所在目录
        confirmButton.title = custom ? "使用此位置" : "使用智能分类"
    }

    // MARK: 目录浏览

    private func listCurrent() {
        loadEpoch += 1
        let epoch = loadEpoch
        spinner.startAnimation(nil)
        coordinator.files.list(path) { [weak self] result in
            guard let self = self else { return }
            guard epoch == self.loadEpoch else { return } // 过期回调（用户已换目录）
            self.spinner.stopAnimation(nil)
            switch result {
            case .success(let entries):
                // 只显示文件夹：先过系统项过滤，再取目录
                self.dirs = BrowseFilter.filter(entries).filter { $0.isDirectory }
                self.emptyLabel.stringValue = "这个目录里没有文件夹"
                self.emptyLabel.isHidden = !self.dirs.isEmpty
            case .failure:
                self.dirs = []
                self.emptyLabel.stringValue = "暂时读不到电视文件夹\n请确认电视上的「远程管理」还开着"
                self.emptyLabel.isHidden = false
            }
            self.refreshChrome()
            self.rebuildDirList()
        }
    }

    private func refreshChrome() {
        breadcrumb.arrangedSubviews.forEach { $0.removeFromSuperview() }
        breadcrumb.addArrangedSubview(crumbButton("电视根目录", target: "/"))
        var prefix = ""
        for c in path.split(separator: "/").map(String.init) {
            prefix += "/" + c
            breadcrumb.addArrangedSubview(crumbSeparator())
            breadcrumb.addArrangedSubview(crumbButton(c, target: prefix))
        }
        backButton.isHidden = path == "/"
        currentLabel.stringValue = "当前所在：\(displayPath(path))"
    }

    private func crumbButton(_ title: String, target: String) -> NSButton {
        let b = NSButton(title: title, target: self, action: #selector(crumbTapped(_:)))
        b.isBordered = false
        b.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        b.contentTintColor = .labelColor
        b.identifier = NSUserInterfaceItemIdentifier(target)
        return b
    }

    private func crumbSeparator() -> NSTextField {
        UIUtil.label("/", size: 12, color: .tertiaryLabelColor)
    }

    @objc private func crumbTapped(_ sender: NSButton) {
        enter(path: sender.identifier?.rawValue ?? "/")
    }

    @objc private func goBack() {
        guard path != "/" else { return }
        let parent = (path as NSString).deletingLastPathComponent
        enter(path: parent.isEmpty ? "/" : parent)
    }

    private func enter(path newPath: String) {
        path = newPath
        listCurrent()
    }

    private func rebuildDirList() {
        dirListStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for d in dirs {
            let b = NSButton(title: d.name, target: self, action: #selector(dirTapped(_:)))
            b.isBordered = false
            b.image = Icons.folder
            b.imagePosition = .imageLeading
            b.font = NSFont.systemFont(ofSize: 13)
            b.contentTintColor = .secondaryLabelColor
            b.identifier = NSUserInterfaceItemIdentifier(d.path)
            dirListStack.addArrangedSubview(b)
        }
    }

    @objc private func dirTapped(_ sender: NSButton) {
        enter(path: sender.identifier?.rawValue ?? "/")
    }

    private func rebuildRecent() {
        recentRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let recents = coordinator.store.state.recentUploadDirs ?? []
        for r in recents {
            let b = CapsuleButton(r == "/" ? "电视根目录" : (r as NSString).lastPathComponent, style: .secondary)
            b.toolTip = displayPath(r)
            b.tapAction = { [weak self] in self?.enter(path: r) }
            recentRow.addArrangedSubview(b)
        }
        let empty = recents.isEmpty
        recentTitle.isHidden = empty
        recentRow.isHidden = empty
    }

    // MARK: 新建文件夹（D1：仅 caps.mkdir=true 显示；竞态失败如实提示）

    @objc private func newFolderTapped() {
        guard let win = window else { return }
        let alert = NSAlert()
        alert.messageText = "新建文件夹"
        alert.informativeText = "在「\(displayPath(path))」里新建文件夹"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        input.stringValue = "新建文件夹"
        alert.accessoryView = input
        alert.addButton(withTitle: "创建")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = input
        alert.beginSheetModal(for: win) { [weak self] resp in
            guard resp == .alertFirstButtonReturn else { return }
            self?.createFolder(input.stringValue)
        }
    }

    private func createFolder(_ rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let target = path == "/" ? "/" + name : path + "/" + name
        coordinator.files.makeDirectory(target) { [weak self] error in
            guard let self = self else { return }
            if error == nil {
                self.enter(path: target)
            } else {
                // 探测后能力变化（或设备拒绝）的竞态：如实提示，不假装成功（D1）
                self.coordinator.showToast("这台电视不支持在电视上新建文件夹")
            }
        }
    }

    // MARK: 确认

    private func confirmTapped() {
        onPicked?(customRadio.state == .on ? path : nil)
        closeSheet()
    }

    /// 界面显示名：去开头斜杠的完整层级；根目录叫「电视根目录」
    private func displayPath(_ p: String) -> String {
        p == "/" ? "电视根目录" : String(p.dropFirst())
    }
}
