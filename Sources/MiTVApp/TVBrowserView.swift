import AppKit
import Foundation

// MARK: - 电视文件浏览态（网格 + 多选 + 毛玻璃操作条）

final class TVBrowserView: NSView {

    unowned let coordinator: AppCoordinator
    private let files: TVFileService

    // 浏览状态
    private var path = "/"
    private var entries: [FTPFileEntry] = []
    private var trashRecords: [TrashStore.Record] = []
    private var isTrashMode = false
    private var selected: Set<String> = []
    private var anchorIndex: Int?
    private var loadedOnce = false

    // 视图
    private let backButton: NSButton
    private let breadcrumb = UIUtil.label("电视", size: 13, weight: .semibold)
    private let trashChip: CapsuleButton
    private let spinner = NSProgressIndicator()
    private let emptyLabel = UIUtil.label("这个文件夹是空的", size: 14, color: .secondaryLabelColor, align: .center)
    private let collection = NSCollectionView()
    private let scroll = NSScrollView()
    private let actionBar = GlassActionBar()

    private var keyMonitor: Any?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        self.files = coordinator.files
        backButton = NSButton(image: Icons.chevronLeft, target: nil, action: nil)
        trashChip = CapsuleButton("回收站", style: .secondary)
        super.init(frame: .zero)
        setup()
    }
    required init?(coder: NSCoder) { fatalError("不支持") }

    deinit { if let m = keyMonitor { NSEvent.removeMonitor(m) } }

    private func setup() {
        wantsLayer = true
        let effect = UIUtil.visualEffect(material: .underWindowBackground)
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect, positioned: .below, relativeTo: nil)

        backButton.isBordered = false
        backButton.imagePosition = .imageOnly
        backButton.contentTintColor = .secondaryLabelColor
        backButton.target = self
        backButton.action = #selector(goBack)
        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.isHidden = true
        addSubview(backButton)

        breadcrumb.translatesAutoresizingMaskIntoConstraints = false
        addSubview(breadcrumb)

        trashChip.tapAction = { [weak self] in self?.enterTrash() }
        trashChip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(trashChip)

        spinner.isIndeterminate = true
        spinner.controlSize = .small
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)

        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyLabel)

        let layout = NSCollectionViewGridLayout()
        layout.minimumItemSize = NSSize(width: 116, height: 138)
        layout.maximumItemSize = NSSize(width: 160, height: 160)
        layout.minimumInteritemSpacing = 14
        layout.minimumLineSpacing = 18
        layout.margins = NSEdgeInsets(top: 14, left: 20, bottom: 76, right: 20)
        collection.collectionViewLayout = layout
        collection.backgroundColors = [.clear]
        collection.dataSource = self
        collection.delegate = self
        collection.isSelectable = true
        collection.allowsEmptySelection = true
        collection.register(TVFileCell.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier("TVFileCell"))

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        addSubview(scroll)

        actionBar.translatesAutoresizingMaskIntoConstraints = false
        actionBar.isHidden = true
        addSubview(actionBar)
        actionBar.onDownload = { [weak self] in self?.downloadSelected() }
        actionBar.onDelete = { [weak self] in self?.deleteSelected() }
        actionBar.onRestore = { [weak self] in self?.restoreSelected() }
        actionBar.onClose = { [weak self] in self?.clearSelection() }

        NSLayoutConstraint.activate([
            effect.topAnchor.constraint(equalTo: topAnchor),
            effect.bottomAnchor.constraint(equalTo: bottomAnchor),
            effect.leadingAnchor.constraint(equalTo: leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: trailingAnchor),

            backButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            backButton.centerYAnchor.constraint(equalTo: breadcrumb.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 24),
            backButton.heightAnchor.constraint(equalToConstant: 24),

            breadcrumb.leadingAnchor.constraint(equalTo: leadingAnchor, constant: backButton.isHidden ? 16 : 46),
            breadcrumb.topAnchor.constraint(equalTo: topAnchor, constant: 14),

            trashChip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            trashChip.centerYAnchor.constraint(equalTo: breadcrumb.centerYAnchor),

            spinner.trailingAnchor.constraint(equalTo: trashChip.leadingAnchor, constant: -12),
            spinner.centerYAnchor.constraint(equalTo: breadcrumb.centerYAnchor),

            scroll.topAnchor.constraint(equalTo: breadcrumb.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            actionBar.centerXAnchor.constraint(equalTo: centerXAnchor),
            actionBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
    }

    // MARK: 数据

    func reloadIfNeeded() {
        guard !loadedOnce else { return }
        reload()
    }

    func reload(path newPath: String? = nil) {
        loadedOnce = true
        if let p = newPath { path = p; coordinator.store.setLastRemotePath(p) }
        isTrashMode = false
        spinner.startAnimation(nil)
        files.list(path) { [weak self] result in
            guard let self = self else { return }
            self.spinner.stopAnimation(nil)
            switch result {
            case .success(let entries):
                // 隐藏回收站本体与前缀回收文件（由「回收站」入口呈现）
                let visible = entries.filter { e in
                    !e.name.hasPrefix(".MITV-Trash")
                }
                self.entries = visible
                self.trashRecords = []
                self.selected = self.selected.intersection(Set(visible.map { $0.path }))
                self.validateSelection()
            case .failure(let error):
                self.entries = []
                self.coordinator.showToast("暂时读不到电视文件：\(error.localizedDescription)")
            }
            self.refreshChrome()
            self.collection.reloadData()
            self.updateActionBar()
        }
    }

    /// 回收站视图（用本地记账还原列表）
    private func enterTrash() {
        guard coordinator.trashStore.count > 0 else {
            coordinator.showToast("回收站是空的")
            return
        }
        isTrashMode = true
        spinner.stopAnimation(nil)
        trashRecords = coordinator.trashStore.records.sorted { $0.deletedAt > $1.deletedAt }
        entries = []
        selected = []
        anchorIndex = nil
        refreshChrome()
        collection.reloadData()
        updateActionBar()
    }

    private func refreshChrome() {
        // 面包屑（零术语：只显示目录名）
        if isTrashMode {
            breadcrumb.stringValue = "电视 / 回收站"
            backButton.isHidden = false
        } else {
            let comps = path.split(separator: "/").map(String.init)
            var text = "电视"
            for c in comps { text += " / " + c }
            breadcrumb.stringValue = text
            backButton.isHidden = path == "/"
        }
        // 回收站入口（根目录且本地有记账）
        if !isTrashMode {
            let n = coordinator.trashStore.count
            if n > 0 {
                trashChip.isHidden = false
                trashChip.title = "回收站 · \(n) 项 · \(Fmt.bytes(coordinator.trashStore.totalBytes))"
            } else {
                trashChip.isHidden = true
            }
        } else {
            trashChip.isHidden = true
        }
        emptyLabel.isHidden = isTrashMode ? !trashRecords.isEmpty : !entries.isEmpty
    }

    @objc private func goBack() {
        clearSelection()
        if isTrashMode {
            reload()
        } else if path != "/" {
            let parent = (path as NSString).deletingLastPathComponent
            reload(path: parent.isEmpty ? "/" : parent)
        }
    }

    func enter(_ entry: FTPFileEntry) {
        clearSelection()
        reload(path: entry.path)
    }

    // MARK: 选择（Finder 手感：单击单选 / ⌘切换 / ⇧范围 / 悬停勾选 / ⌘A 全选 / Esc 清空）

    var selectableCount: Int {
        isTrashMode ? trashRecords.count : entries.filter { !$0.isDirectory }.count
    }

    /// 全量数组下标 → 可选中项 ID。目录不可选返回 nil；越界（列表已刷新后的陈旧点击）返回 nil。
    /// 修复：单元格闭包传的是 entries 全量下标（含目录），此前误按纯文件数组取值导致错位与越界崩溃。
    private func itemID(at index: Int) -> String? {
        if isTrashMode {
            guard trashRecords.indices.contains(index) else { return nil }
            return trashRecords[index].id
        }
        guard entries.indices.contains(index) else { return nil }
        let entry = entries[index]
        return entry.isDirectory ? nil : entry.path
    }

    /// 纯文件（或回收站记录）的 ID 集——全选与校验用，避免下标空间混用
    private var selectableIDs: [String] {
        isTrashMode ? trashRecords.map { $0.id } : entries.filter { !$0.isDirectory }.map { $0.path }
    }

    func toggleSelect(at index: Int) {
        guard let id = itemID(at: index) else { return }
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        anchorIndex = index
        refreshSelectionUI()
    }

    func singleSelect(at index: Int) {
        guard let id = itemID(at: index) else { return }
        selected = [id]
        anchorIndex = index
        refreshSelectionUI()
    }

    func rangeSelect(to index: Int) {
        guard let anchor = anchorIndex else { singleSelect(at: index); return }
        let lo = min(anchor, index)
        let hi = max(anchor, index)
        selected = Set((lo...hi).compactMap { itemID(at: $0) })
        refreshSelectionUI()
    }

    func selectAll() {
        selected = Set(selectableIDs)
        refreshSelectionUI()
    }

    func clearSelection() {
        selected = []
        anchorIndex = nil
        refreshSelectionUI()
    }

    private func validateSelection() {
        selected = selected.intersection(Set(selectableIDs))
    }

    private func refreshSelectionUI() {
        for case let cell as TVFileCell in collection.visibleItems() {
            cell.setSelected(selected.contains(cell.identifierKey))
        }
        updateActionBar()
    }

    private func selectedEntries() -> [FTPFileEntry] {
        entries.filter { selected.contains($0.path) && !$0.isDirectory }
    }

    private func selectedRecords() -> [TrashStore.Record] {
        trashRecords.filter { selected.contains($0.id) }
    }

    private func updateActionBar() {
        if isTrashMode {
            let records = selectedRecords()
            actionBar.isHidden = records.isEmpty
            if !records.isEmpty {
                actionBar.configureTrash(count: records.count)
            }
        } else {
            let entries = selectedEntries()
            actionBar.isHidden = entries.isEmpty
            if !entries.isEmpty {
                let total = entries.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
                let strategy = files.currentStrategy()
                actionBar.configure(count: entries.count, bytes: total, canDelete: strategy != .disabled)
            }
        }
    }

    // MARK: 操作

    private func downloadSelected() {
        let entries = selectedEntries()
        guard !entries.isEmpty else { return }
        clearSelection()
        coordinator.downloadEntries(entries)
    }

    func deleteSelected() {
        if isTrashMode {
            coordinator.showToast("回收站里的项目请用「还原」取回，或在电视上清理")
            return
        }
        let entries = selectedEntries()
        guard !entries.isEmpty else { return }
        coordinator.confirmDelete(entries) { [weak self] in
            guard let self = self else { return }
            self.clearSelection()
            self.reload()
        }
    }

    private func restoreSelected() {
        let records = selectedRecords()
        guard !records.isEmpty else { return }
        files.restore(records, progress: { _, _, _ in }) { [weak self] restored, failed in
            guard let self = self else { return }
            if restored > 0 { self.coordinator.showToast("已还原 \(restored) 项") }
            if failed > 0 { self.coordinator.showToast("有 \(failed) 项还原失败") }
            self.enterTrash()
        }
    }

    // MARK: 冒烟辅助（仅供自动化验证交互路径）

    func smokeSelectFirstFiles(_ n: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self = self else { return }
            let filesOnly = self.entries.filter { !$0.isDirectory }
            self.selected = Set(filesOnly.prefix(n).map { $0.path })
            self.anchorIndex = 0
            self.collection.reloadData()
            self.updateActionBar()
        }
    }

    func smokeConfirmSelected() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self, !self.selected.isEmpty else { return }
            self.coordinator.confirmDelete(self.selectedEntries()) { [weak self] in
                self?.clearSelection()
                self?.reload()
            }
        }
    }

    /// 冒烟：选第一个文件 → 确认浮层 → 自动确认 → （配合 MITV_AUTO_UNDO 在下次启动撤销）
    func smokeDeleteFirstFile() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self = self else { return }
            let files = self.entries.filter { !$0.isDirectory }
            guard let first = files.first else { return }
            self.selected = [first.path]
            self.anchorIndex = 0
            self.collection.reloadData()
            self.updateActionBar()
            self.coordinator.confirmDelete([first]) { [weak self] in
                self?.clearSelection()
                self?.reload()
            }
            self.coordinator.confirmOverlay?.smokeAutoConfirm(after: 1.0)
            // 同进程内自动撤销（Mock 树是进程内存态，跨进程无法还原）
            if ProcessInfo.processInfo.environment["MITV_AUTO_UNDO_INPLACE"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
                    guard let self = self else { return }
                    let records = self.coordinator.trashStore.records
                    guard !records.isEmpty else { NSLog("MITV-SMOKE inplace-undo: no records"); return }
                    self.coordinator.files.restore(records, progress: { _, _, _ in }) { restored, failed in
                        NSLog("MITV-SMOKE inplace-undo restored=%d failed=%d", restored, failed)
                        self.clearSelection()
                        self.reload()
                    }
                }
            }
        }
    }

    /// 冒烟：把 trash.json 里的记录全部还原（验证撤销链路）
    func smokeUndoAll() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self else { return }
            let records = self.coordinator.trashStore.records
            guard !records.isEmpty else {
                NSLog("MITV-SMOKE undo: no records")
                return
            }
            self.files.restore(records, progress: { _, _, _ in }) { restored, failed in
                NSLog("MITV-SMOKE undo restored=%d failed=%d", restored, failed)
                self.enterTrashRefreshIfInTrash()
            }
        }
    }

    private func enterTrashRefreshIfInTrash() {
        if isTrashMode { enterTrash() }
    }

    // MARK: 键盘（⌘A / Esc / ⌫）

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self = self, self.window != nil,
                      self.superview != nil,
                      !(self.window?.firstResponder is NSTextView) else { return event }
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if flags == [.command], event.charactersIgnoringModifiers == "a" {
                    self.selectAll()
                    return nil
                }
                if event.keyCode == 53 { // Esc
                    self.clearSelection()
                    return nil
                }
                if event.keyCode == 51, !self.selected.isEmpty { // ⌫
                    self.deleteSelected()
                    return nil
                }
                return event
            }
        } else if window == nil, let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
    }
}

// MARK: - 数据源

extension TVBrowserView: NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        isTrashMode ? trashRecords.count : entries.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let cell = collectionView.makeItem(withIdentifier: NSUserInterfaceItemIdentifier("TVFileCell"), for: indexPath) as! TVFileCell
        let index = indexPath.item
        if isTrashMode {
            let record = trashRecords[index]
            cell.configureTrash(record: record, selected: selected.contains(record.id),
                                onSelect: { [weak self] in self?.toggleSelect(at: index) },
                                onShift: { [weak self] in self?.rangeSelect(to: index) })
        } else {
            let entry = entries[index]
            cell.configure(entry: entry,
                            selected: selected.contains(entry.path),
                            browser: self,
                            files: files,
                            index: index)
        }
        return cell
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPath: IndexPath) {
        DispatchQueue.main.async { collectionView.deselectAll(nil) }
    }
}

// MARK: - 网格单元

final class TVFileCell: NSCollectionViewItem {

    var identifierKey: String = ""
    private let thumbView = NSImageView()
    private let nameLabel = UIUtil.label("", size: 12, align: .center)
    private let subLabel = UIUtil.label("", size: 10, color: .tertiaryLabelColor, align: .center)
    private let checkMark = CheckboxCircle()
    private var onSelect: (() -> Void)?
    private var onShift: (() -> Void)?
    private var onDouble: (() -> Void)?
    private var hoverCheckbox = false

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 116, height: 138))
        view = container
        container.wantsLayer = true
        container.layer?.cornerRadius = 10

        thumbView.wantsLayer = true
        thumbView.layer?.cornerRadius = 9
        thumbView.layer?.masksToBounds = true
        thumbView.imageScaling = .scaleProportionallyUpOrDown
        thumbView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(thumbView)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(nameLabel)
        subLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(subLabel)

        checkMark.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(checkMark)

        NSLayoutConstraint.activate([
            thumbView.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            thumbView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            thumbView.widthAnchor.constraint(equalToConstant: 96),
            thumbView.heightAnchor.constraint(equalToConstant: 84),

            nameLabel.topAnchor.constraint(equalTo: thumbView.bottomAnchor, constant: 6),
            nameLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
            nameLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),

            subLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1),
            subLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
            subLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
            subLabel.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -4),

            checkMark.topAnchor.constraint(equalTo: thumbView.topAnchor, constant: 5),
            checkMark.trailingAnchor.constraint(equalTo: thumbView.trailingAnchor, constant: -5),
            checkMark.widthAnchor.constraint(equalToConstant: 20),
            checkMark.heightAnchor.constraint(equalToConstant: 20),
        ])

        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .inVisibleRect, .activeInKeyWindow], owner: nil, userInfo: nil)
        container.addTrackingArea(tracking)
    }

    func configure(entry: FTPFileEntry, selected: Bool, browser: TVBrowserView, files: TVFileService, index: Int) {
        identifierKey = entry.path
        nameLabel.stringValue = entry.name
        subLabel.stringValue = entry.isDirectory ? "文件夹" : Fmt.bytes(entry.size ?? 0)

        onSelect = { browser.toggleSelect(at: index) }
        onShift = { browser.rangeSelect(to: index) }
        onDouble = { [weak browser] in
            if entry.isDirectory { browser?.enter(entry) }
        }

        // 缩略图 / 图标
        if entry.isDirectory {
            thumbView.image = Icons.folder
            thumbView.contentTintColor = NSColor.systemTeal.withAlphaComponent(0.75)
            thumbView.imageScaling = .scaleProportionallyDown
        } else {
            thumbView.image = LocalThumbnailLoader.fallbackIcon(for: entry.kind)
            thumbView.contentTintColor = .quaternaryLabelColor
        }
        if !entry.isDirectory && entry.kind == .image {
            files.fetchThumbnail(entry) { [weak self] img in
                guard let self = self else { return }
                if self.identifierKey == entry.path {
                    if let img = img {
                        self.thumbView.image = img
                    } else {
                        self.thumbView.image = LocalThumbnailLoader.fallbackIcon(for: .image)
                        self.thumbView.contentTintColor = .quaternaryLabelColor
                    }
                }
            }
        }
        setSelected(selected)
    }

    func configureTrash(record: TrashStore.Record, selected: Bool, onSelect: @escaping () -> Void, onShift: @escaping () -> Void) {
        identifierKey = record.id
        nameLabel.stringValue = record.name
        subLabel.stringValue = "原位置：\((record.originalPath as NSString).deletingLastPathComponent.replacingOccurrences(of: "/", with: ""))"
        thumbView.image = LocalThumbnailLoader.fallbackIcon(for: MediaKind.of(fileName: record.name))
        thumbView.contentTintColor = .quaternaryLabelColor
        self.onSelect = onSelect
        self.onShift = onShift
        onDouble = nil
        setSelected(selected)
    }

    func setSelected(_ selected: Bool) {
        checkMark.setChecked(selected, visible: selected || hoverCheckbox)
        view.layer?.backgroundColor = selected
            ? NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor
            : NSColor.clear.cgColor
        view.layer?.borderWidth = selected ? 1.5 : 0
        view.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.55).cgColor
    }

    override func mouseEntered(with event: NSEvent) {
        hoverCheckbox = true
        if !checkMark.isChecked { checkMark.setChecked(false, visible: true) }
    }

    override func mouseExited(with event: NSEvent) {
        hoverCheckbox = false
        checkMark.setChecked(checkMark.isChecked, visible: checkMark.isChecked)
    }

    override func mouseDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.shift) {
            onShift?()
        } else if flags.contains(.command) {
            onSelect?()
        } else {
            onSelect?() // 单击也勾选（触屏/双键更直觉）；配合 ⌘/⇧ 与 Finder 手感一致
        }
    }

    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 2 { onDouble?() }
    }

    // 右键：删除（委托浏览器处理）
    @objc private func menuDelete() {
        var responder: NSResponder? = view.nextResponder
        while let r = responder {
            if let browser = r as? TVBrowserView {
                browser.deleteSelected()
                return
            }
            responder = r.nextResponder
        }
    }
}

/// 勾选圆圈（悬停浮现，选中填充 accent）
final class CheckboxCircle: NSView {

    private(set) var isChecked = false
    private var shown = false

    func setChecked(_ checked: Bool, visible: Bool) {
        isChecked = checked
        shown = visible
        needsDisplay = true
        isHidden = !visible
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1.5, dy: 1.5)
        let circle = NSBezierPath(ovalIn: rect)
        if isChecked {
            NSColor.controlAccentColor.setFill()
            circle.fill()
            // 对勾
            let check = NSBezierPath()
            check.move(to: NSPoint(x: rect.midX - 4.5, y: rect.midY + 0.5))
            check.line(to: NSPoint(x: rect.midX - 1.2, y: rect.midY - 3.5))
            check.line(to: NSPoint(x: rect.midX + 4.5, y: rect.midY + 3.8))
            NSColor.white.setStroke()
            check.lineWidth = 2
            check.lineCapStyle = .round
            check.stroke()
        } else {
            NSColor.white.withAlphaComponent(0.9).setFill()
            circle.fill()
            NSColor.separatorColor.setStroke()
            circle.lineWidth = 1.2
            circle.stroke()
        }
    }
}

// MARK: - 底部毛玻璃操作条（已选 N 项 · X MB [下载][删除] ✕）

final class GlassActionBar: NSView {

    var onDownload: (() -> Void)?
    var onDelete: (() -> Void)?
    var onRestore: (() -> Void)?
    var onClose: (() -> Void)?

    private let effect = UIUtil.visualEffect(material: .popover)
    private let label = UIUtil.label("", size: 13, weight: .medium)
    private let downloadBtn = CapsuleButton("下载", style: .primary)
    private let deleteBtn = CapsuleButton("删除", style: .danger)
    private let restoreBtn = CapsuleButton("还原", style: .primary)
    private let closeBtn: NSButton

    init() {
        closeBtn = NSButton(image: Icons.xMark, target: nil, action: nil)
        super.init(frame: .zero)
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.borderColor = NSColor.separatorColor.cgColor
        effect.layer?.borderWidth = 0.5
        effect.layer?.shadowColor = NSColor.black.cgColor
        effect.layer?.shadowOpacity = 0.18
        effect.layer?.shadowRadius = 8
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)

        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        for b in [downloadBtn, deleteBtn, restoreBtn] as [NSView] {
            b.translatesAutoresizingMaskIntoConstraints = false
            addSubview(b)
        }
        restoreBtn.isHidden = true
        closeBtn.isBordered = false
        closeBtn.imagePosition = .imageOnly
        closeBtn.contentTintColor = .secondaryLabelColor
        closeBtn.target = self
        closeBtn.action = #selector(closeTapped)
        closeBtn.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeBtn)

        downloadBtn.tapAction = { [weak self] in self?.onDownload?() }
        deleteBtn.tapAction = { [weak self] in self?.onDelete?() }
        restoreBtn.tapAction = { [weak self] in self?.onRestore?() }

        NSLayoutConstraint.activate([
            effect.topAnchor.constraint(equalTo: topAnchor),
            effect.bottomAnchor.constraint(equalTo: bottomAnchor),
            effect.leadingAnchor.constraint(equalTo: leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: trailingAnchor),

            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: restoreBtn.leadingAnchor, constant: -8),

            restoreBtn.centerYAnchor.constraint(equalTo: centerYAnchor),
            downloadBtn.centerYAnchor.constraint(equalTo: centerYAnchor),
            deleteBtn.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeBtn.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            deleteBtn.trailingAnchor.constraint(equalTo: closeBtn.leadingAnchor, constant: -10),
            downloadBtn.trailingAnchor.constraint(equalTo: deleteBtn.leadingAnchor, constant: -10),
            restoreBtn.trailingAnchor.constraint(equalTo: downloadBtn.leadingAnchor, constant: -10),
            restoreBtn.isHidden ? restoreBtn.widthAnchor.constraint(equalToConstant: 0) : restoreBtn.widthAnchor.constraint(greaterThanOrEqualToConstant: 10),
        ])

        heightAnchor.constraint(greaterThanOrEqualToConstant: 46).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("不支持") }

    func configure(count: Int, bytes: Int64, canDelete: Bool) {
        label.stringValue = "已选 \(count) 项 · \(Fmt.bytes(bytes))"
        deleteBtn.isHidden = !canDelete
        downloadBtn.isHidden = false
        restoreBtn.isHidden = true
        if !canDelete {
            // 措辞温和、零指责
            label.stringValue += "（这台电视不支持删除）"
        }
    }

    func configureTrash(count: Int) {
        label.stringValue = "回收站已选 \(count) 项"
        deleteBtn.isHidden = true
        downloadBtn.isHidden = true
        restoreBtn.isHidden = false
    }

    // MARK: 照片选择器复用（主按钮 = 「添加 N 张」）

    func configureAsPhotoPicker(addAction: (() -> Void)?) {
        downloadBtn.title = "添加照片"
        downloadBtn.tapAction = addAction
        deleteBtn.isHidden = true
        restoreBtn.isHidden = true
        label.stringValue = "已选 0 张"
    }

    func setPhotoPickerCount(_ n: Int) {
        if n == 0 {
            label.stringValue = "已选 0 张"
        } else {
            label.stringValue = "已选 \(n) 张照片和视频"
        }
        downloadBtn.title = n > 0 ? "添加 \(n) 张" : "添加照片"
        downloadBtn.isHidden = false
        deleteBtn.isHidden = true
        restoreBtn.isHidden = true
        setExportProgress(nil)
    }

    private var exportText: String?
    func setExportProgress(_ text: String?) {
        exportText = text
        if let t = text {
            label.stringValue = t
            downloadBtn.isHidden = true
            deleteBtn.isHidden = true
            restoreBtn.isHidden = true
        } else {
            downloadBtn.isHidden = false
        }
        needsLayout = true
    }

    @objc private func closeTapped() { onClose?() }
}
