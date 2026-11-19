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
    /// 列表请求序号：晚到的旧回调不得冲掉当前视图（慢网络下进回收站会被冲空，review D5）
    private var loadEpoch = 0

    // 视图
    private let backButton: NSButton
    /// 面包屑 = 可点击的路径段按钮（点任意一段直接跳到该层目录）
    private let breadcrumb: NSStackView = {
        let s = NSStackView()
        s.orientation = .horizontal
        s.spacing = 4
        s.alignment = .centerY
        return s
    }()
    /// 返回按钮显隐时同步更新（约束常量不能在 init 一次性求值）
    private var breadcrumbLeading: NSLayoutConstraint!
    /// 刷新按钮跟随右侧可见按钮让位（浏览态=回收站入口，回收站态=清空按钮）
    private var refreshToTrashChip: NSLayoutConstraint!
    private var refreshToEmptyTrash: NSLayoutConstraint!
    private let trashChip: CapsuleButton
    private let emptyTrashButton: CapsuleButton
    private let refreshButton: NSButton
    private let spinner = NSProgressIndicator()
    /// 空态/错误态文案（多行居中；错误时写原因与重连指引）
    private let emptyLabel: NSTextField = {
        let l = UIUtil.label("这个文件夹是空的", size: 14, color: .secondaryLabelColor, align: .center)
        l.lineBreakMode = .byWordWrapping
        l.usesSingleLineMode = false
        l.maximumNumberOfLines = 0
        l.preferredMaxLayoutWidth = 460
        return l
    }()
    private let collection = NSCollectionView()
    private let scroll = NSScrollView()
    private let actionBar = GlassActionBar()

    private var keyMonitor: Any?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        self.files = coordinator.files
        backButton = NSButton(image: Icons.chevronLeft, target: nil, action: nil)
        trashChip = CapsuleButton("回收站", style: .secondary)
        emptyTrashButton = CapsuleButton("清空回收站", style: .danger)
        refreshButton = NSButton(image: Icons.retry, target: nil, action: nil)
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
        breadcrumbLeading = breadcrumb.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16)

        trashChip.tapAction = { [weak self] in self?.enterTrash() }
        trashChip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(trashChip)

        emptyTrashButton.tapAction = { [weak self] in self?.emptyTrashTapped() }
        emptyTrashButton.isHidden = true
        emptyTrashButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyTrashButton)

        refreshButton.isBordered = false
        refreshButton.imagePosition = .imageOnly
        refreshButton.contentTintColor = .secondaryLabelColor
        refreshButton.target = self
        refreshButton.action = #selector(refreshTapped)
        refreshButton.toolTip = "重新读取当前目录"
        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(refreshButton)

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

            breadcrumbLeading,
            breadcrumb.topAnchor.constraint(equalTo: topAnchor, constant: 14),

            trashChip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            trashChip.centerYAnchor.constraint(equalTo: breadcrumb.centerYAnchor),

            emptyTrashButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            emptyTrashButton.centerYAnchor.constraint(equalTo: breadcrumb.centerYAnchor),

            refreshButton.centerYAnchor.constraint(equalTo: breadcrumb.centerYAnchor),
            refreshButton.widthAnchor.constraint(equalToConstant: 22),
            refreshButton.heightAnchor.constraint(equalToConstant: 22),

            spinner.trailingAnchor.constraint(equalTo: refreshButton.leadingAnchor, constant: -10),
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

        refreshToTrashChip = refreshButton.trailingAnchor.constraint(equalTo: trashChip.leadingAnchor, constant: -12)
        refreshToEmptyTrash = refreshButton.trailingAnchor.constraint(equalTo: emptyTrashButton.leadingAnchor, constant: -12)
        refreshToTrashChip.isActive = true
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
        loadEpoch += 1
        let epoch = loadEpoch
        spinner.startAnimation(nil)
        files.list(path) { [weak self] result in
            guard let self = self else { return }
            guard epoch == self.loadEpoch else { return } // 过期回调（用户已进回收站/已换目录）
            self.spinner.stopAnimation(nil)
            switch result {
            case .success(let entries):
                // 隐藏文件/系统目录对普通用户无意义，不展示；回收站本体（. 开头）同样被隐藏，由「回收站」入口呈现
                let visible = BrowseFilter.filter(entries)
                self.entries = visible
                self.trashRecords = []
                self.selected = self.selected.intersection(Set(visible.map { $0.path }))
                self.validateSelection()
            case .failure(let error):
                self.entries = []
                self.trashRecords = []
                // 连接类失败把原因和出路写进空态（toast 会被后续提示顶掉，空态才是可靠的主提示）
                self.emptyLabel.stringValue = "暂时读不到电视文件\n\n\(error.localizedDescription)\n请确认电视上的「远程管理」还开着，点左上角状态可重连"
                self.emptyLabel.isSelectable = false
                self.emptyLabel.isHidden = false
                self.coordinator.showToast("暂时读不到电视文件")
            }
            self.refreshChrome()
            self.collection.reloadData()
            self.updateActionBar()
        }
    }

    /// 回收站视图（用本地记账还原列表）
    private func enterTrash() {
        guard coordinator.trashStore.count > 0 else {
            // 空回收站也要清视图状态（review D3）：否则还原后残留幽灵列表，再点还原误报失败
            coordinator.showToast("回收站是空的")
            trashRecords = []
            selected = []
            anchorIndex = nil
            refreshChrome()
            collection.reloadData()
            updateActionBar()
            return
        }
        loadEpoch += 1 // 作废在途目录列表回调（防冲掉回收站视图）
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
        // 面包屑（零术语：只显示目录名）。注意顺序：先更新 backButton 显隐，再按新状态让位，
        // 否则约束读到的是旧值（等于把「一次性求值」bug 换了个地方重演）
        breadcrumb.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if isTrashMode {
            breadcrumb.addArrangedSubview(crumbButton("电视", target: ""))
            breadcrumb.addArrangedSubview(crumbSeparator())
            breadcrumb.addArrangedSubview(UIUtil.label("回收站", size: 13, weight: .semibold))
            backButton.isHidden = false
        } else {
            breadcrumb.addArrangedSubview(crumbButton("电视", target: "/"))
            var prefix = ""
            for c in path.split(separator: "/").map(String.init) {
                prefix += "/" + c
                breadcrumb.addArrangedSubview(crumbSeparator())
                breadcrumb.addArrangedSubview(crumbButton(c, target: prefix))
            }
            backButton.isHidden = path == "/"
        }
        breadcrumbLeading.constant = backButton.isHidden ? 16 : 46
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
        emptyTrashButton.isHidden = !isTrashMode || trashRecords.isEmpty
        refreshToTrashChip.isActive = !isTrashMode
        refreshToEmptyTrash.isActive = isTrashMode
        emptyLabel.isHidden = isTrashMode ? !trashRecords.isEmpty : !entries.isEmpty
    }

    /// 面包屑段按钮：identifier 存目标路径（"" = 退出回收站回浏览态）
    private func crumbButton(_ title: String, target: String) -> NSButton {
        let b = NSButton(title: title, target: self, action: #selector(crumbTapped(_:)))
        b.isBordered = false
        b.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        b.contentTintColor = .labelColor
        b.identifier = NSUserInterfaceItemIdentifier(target)
        return b
    }

    private func crumbSeparator() -> NSTextField {
        UIUtil.label("/", size: 13, color: .tertiaryLabelColor)
    }

    @objc private func crumbTapped(_ sender: NSButton) {
        let target = sender.identifier?.rawValue ?? ""
        clearSelection()
        if target.isEmpty {
            reload() // 回收站 → 回当前浏览目录
        } else if target != path || isTrashMode {
            reload(path: target)
        }
    }

    @objc private func refreshTapped() {
        if isTrashMode { enterTrash() } else { reload() }
    }

    /// 清空回收站：不可逆操作，先弹系统确认（sheet），确认后永久删除全部记账文件
    private func emptyTrashTapped() {
        let count = coordinator.trashStore.count
        guard count > 0, let window = window else { return }
        let alert = NSAlert()
        alert.messageText = "清空回收站？"
        alert.informativeText = "将永久删除电视上的 \(count) 个文件（共 \(Fmt.bytes(coordinator.trashStore.totalBytes))），此操作无法撤销。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "永久删除")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self = self, response == .alertFirstButtonReturn else { return }
            self.files.emptyTrash(progress: { _, _, _ in }) { deleted, failed in
                if deleted > 0 { self.coordinator.showToast("已永久删除 \(deleted) 项") }
                if failed > 0 { self.coordinator.showToast("有 \(failed) 项删除失败，仍留在回收站") }
                self.enterTrash()
            }
        }
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

    // MARK: 方向键网格导航

    /// 按 GridLayout 参数估算列数（左右边距 20、间距 14、最小宽 116）
    private var gridColumns: Int {
        let usable = collection.bounds.width - 40 + 14
        return max(1, Int(usable / (116 + 14)))
    }

    private func moveSelection(by delta: Int, extend: Bool) {
        let count = isTrashMode ? trashRecords.count : entries.count
        guard count > 0 else { return }
        let cols = gridColumns
        var target: Int
        if let anchor = anchorIndex {
            target = anchor + delta
        } else {
            target = delta > 0 ? 0 : count - 1
        }
        if abs(delta) == 1 {
            // 横向：跳过目录等不可选项
            while target >= 0 && target < count && itemID(at: target) == nil { target += delta }
        } else {
            // 纵向：夹取到边界后，落点不可选时取该行最近的可选项
            target = min(max(target, 0), count - 1)
            if itemID(at: target) == nil {
                let rowStart = (target / cols) * cols
                let rowEnd = min(rowStart + cols, count)
                var best: Int?
                for i in rowStart..<rowEnd where itemID(at: i) != nil {
                    if best == nil || abs(i - target) < abs(best! - target) { best = i }
                }
                guard let b = best else { return }
                target = b
            }
        }
        guard target >= 0, target < count, itemID(at: target) != nil else { return }
        if extend { rangeSelect(to: target) } else { singleSelect(at: target) }
        collection.scrollToItems(at: [IndexPath(item: target, section: 0)], scrollPosition: .nearestVerticalEdge)
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
        coordinator.downloadEntries(entries) { [weak self] didStart in
            // 用户取消保存目录面板时保留选择（review E2），可重选目录或改主意
            if didStart { self?.clearSelection() }
        }
    }

    func deleteSelected() {
        if isTrashMode {
            coordinator.showToast("回收站里的项目请用「还原」取回，或用右上角「清空回收站」永久删除")
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

    func restoreSelected() {
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

    /// 撤销还原后的刷新：回收站视图重拉本地记账，浏览态重拉远端目录（review D2）
    func reloadAfterRestore() {
        if isTrashMode {
            enterTrash()
        } else {
            reload()
        }
    }

    /// 冒烟：进入第一个目录（验证面包屑让位 + 返回按钮可点）；等列表返回再进
    func smokeEnterFirstDirectory() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self, let dir = self.entries.first(where: { $0.isDirectory }) else { return }
            self.enter(dir)
        }
    }

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
                guard let self = self,
                      event.window === self.window, // 只拦本窗口的按键，别吞掉 sheet 里的 Esc
                      self.superview != nil,
                      !self.coordinator.hasModalOverlay, // 确认浮层/向导在场时不拦（review D4：⌫ 叠框/Esc 吞掉）
                      self.window?.attachedSheet == nil, // 系统 sheet（清空确认/保存面板）在场时不拦
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
                // 方向键在网格里移动选择（⇧ 扩展范围）；旧实现只有 ⌘A/Esc/⌫，键盘完全无法导航
                let cols = self.gridColumns
                let deltas: [UInt16: Int] = [123: -1, 124: 1, 125: cols, 126: -cols]
                if let delta = deltas[event.keyCode] {
                    self.moveSelection(by: delta, extend: flags.contains(.shift))
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
            cell.configureTrash(record: record, selected: selected.contains(record.id), files: files,
                                onSelect: { [weak self] in self?.toggleSelect(at: index) },
                                onShift: { [weak self] in self?.rangeSelect(to: index) },
                                onSingle: { [weak self] in self?.singleSelect(at: index) })
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
    private var onSingle: (() -> Void)?
    private var isTrashItem = false
    private var isDirectoryItem = false
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

        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .inVisibleRect, .activeInKeyWindow], owner: self, userInfo: nil)
        container.addTrackingArea(tracking)
    }

    func configure(entry: FTPFileEntry, selected: Bool, browser: TVBrowserView, files: TVFileService, index: Int) {
        // 单元格复用：旧条目还在下载缩略图就取消（滚动的网格会复用单元格，
        // 不取消则滚过的每张图都在后台继续下完，连接数随滚动距离线性增长）
        if identifierKey != entry.path {
            files.cancelThumbnail(forPath: identifierKey)
        }
        identifierKey = entry.path
        nameLabel.stringValue = entry.name
        subLabel.stringValue = entry.isDirectory ? "文件夹" : Fmt.bytes(entry.size ?? 0)

        onSelect = { browser.toggleSelect(at: index) }
        onShift = { browser.rangeSelect(to: index) }
        onSingle = { browser.singleSelect(at: index) }
        isTrashItem = false
        isDirectoryItem = entry.isDirectory
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
        if !entry.isDirectory && entry.kind != .other {
            files.fetchThumbnail(entry) { [weak self] img in
                guard let self = self else { return }
                if self.identifierKey == entry.path {
                    if let img = img {
                        self.thumbView.image = img
                        self.thumbView.contentTintColor = nil
                    } else {
                        self.thumbView.image = LocalThumbnailLoader.fallbackIcon(for: entry.kind)
                        self.thumbView.contentTintColor = .quaternaryLabelColor
                    }
                }
            }
        }
        setSelected(selected)
    }

    func configureTrash(record: TrashStore.Record, selected: Bool, files: TVFileService, onSelect: @escaping () -> Void, onShift: @escaping () -> Void, onSingle: @escaping () -> Void) {
        if identifierKey != record.id {
            files.cancelThumbnail(forPath: identifierKey)
        }
        identifierKey = record.id
        nameLabel.stringValue = record.name
        let parent = (record.originalPath as NSString).deletingLastPathComponent
        subLabel.stringValue = parent == "/" ? "原位置：根目录" : "原位置：\(parent)"
        thumbView.image = LocalThumbnailLoader.fallbackIcon(for: MediaKind.of(fileName: record.name))
        thumbView.contentTintColor = .quaternaryLabelColor
        self.onSelect = onSelect
        self.onShift = onShift
        self.onSingle = onSingle
        isTrashItem = true
        isDirectoryItem = false
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
        if flags.contains(.control) {
            // Ctrl+单击 = 右键菜单（macOS 惯例）
            if !checkMark.isChecked { onSingle?() }
            if let menu = menu(for: event) {
                NSMenu.popUpContextMenu(menu, with: event, for: view)
            }
            return
        }
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

    override func rightMouseDown(with event: NSEvent) {
        if let menu = menu(for: event) {
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        }
    }

    // 右键菜单：未选中先单选该项（已多选则保留多选，操作作用于整个选择）
    // 注：NSCollectionViewItem 是 NSViewController，menu(for:) 非父类方法，不能标 override
    func menu(for event: NSEvent) -> NSMenu? {
        if !checkMark.isChecked { onSingle?() }
        let menu = NSMenu()
        let item: NSMenuItem
        if isTrashItem {
            item = NSMenuItem(title: "还原", action: #selector(menuRestore), keyEquivalent: "")
        } else if isDirectoryItem {
            item = NSMenuItem(title: "打开", action: #selector(menuOpen), keyEquivalent: "")
        } else {
            item = NSMenuItem(title: "删除", action: #selector(menuDelete), keyEquivalent: "")
        }
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func menuOpen() { onDouble?() }

    // 右键：删除（委托浏览器处理）
    @objc private func menuDelete() {
        browserFromResponderChain()?.deleteSelected()
    }

    @objc private func menuRestore() {
        browserFromResponderChain()?.restoreSelected()
    }

    private func browserFromResponderChain() -> TVBrowserView? {
        var responder: NSResponder? = view.nextResponder
        while let r = responder {
            if let browser = r as? TVBrowserView { return browser }
            responder = r.nextResponder
        }
        return nil
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
        restoreBtn.isHidden = true
        closeBtn.isBordered = false
        closeBtn.imagePosition = .imageOnly
        closeBtn.contentTintColor = .secondaryLabelColor
        closeBtn.target = self
        closeBtn.action = #selector(closeTapped)

        // 按钮进 NSStackView：隐藏的按钮自动退出布局，不再需要宽度占位/三元约束技巧
        let buttonRow = NSStackView(views: [restoreBtn, downloadBtn, deleteBtn, closeBtn])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(buttonRow)

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
            label.trailingAnchor.constraint(lessThanOrEqualTo: buttonRow.leadingAnchor, constant: -8),

            buttonRow.centerYAnchor.constraint(equalTo: centerYAnchor),
            buttonRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
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
