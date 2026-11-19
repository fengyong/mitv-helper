import AppKit
import Foundation
import Photos
import CoreServices

// MARK: - 照片图库选择器（Photos 框架自建网格：授权 → 相机胶卷 → 倒序 → 多选 → 导出原图）

final class PhotoPickerController: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout, NSWindowDelegate {

    /// 来源页签：最近（相机胶卷倒序）/ 视频（只看视频）/ 相册（照片 App 的相册与文件夹）
    private enum PickerMode: Int { case recent = 0, videos = 1, albums = 2 }

    private var window: NSWindow?
    private var onDone: ([URL]) -> Void
    private var onClose: (() -> Void)

    private var assets: PHFetchResult<PHAsset>?
    private var selected: Set<String> = []      // localIdentifier
    private var anchorIndex: Int?
    private var exporting = false
    /// 导出进行中关闭选择器 = 取消：剩余资产不再导出，已导出的也不入队
    private var exportCanceled = false

    // 相册导航
    private var mode: PickerMode = .recent
    /// 当前相册/文件夹列表（相册页签的集合层级内容）
    private var collections: [PHCollection] = []
    /// true = 网格显示集合列表（相册/文件夹）；false = 显示资产
    private var showingCollections = false
    /// 相册导航栈（push 相册/文件夹；顶层为空）
    private var albumStack: [PHCollection] = []

    private let collection = NSCollectionView()
    private let scroll = NSScrollView()
    private let bar = GlassActionBar()
    private let emptyLabel = UIUtil.label("照片图库里还没有内容", size: 14, color: .secondaryLabelColor, align: .center)
    private let spinner = NSProgressIndicator()
    private let authButton = CapsuleButton("允许访问照片", style: .primary)
    private let authHint = UIUtil.label("需要先允许访问照片图库，才能挑选要发送的照片和视频", size: 13, color: .secondaryLabelColor, align: .center)
    private var authorizedAccess = false
    /// 授权被拒（denied/restricted）：系统不会再弹授权框，按钮改为引导去系统设置
    private var permissionDenied = false
    private var activeObserver: NSObjectProtocol?

    // 顶部来源页签 + 相册面包屑
    private var sourceButtons: [CapsuleButton] = []
    private let backButton = NSButton(image: Icons.chevronLeft, target: nil, action: nil)
    private let crumbLabel = UIUtil.label("", size: 13, weight: .medium)
    /// crumb 左缘约束随返回按钮显隐更新（不能 init 一次性求值）
    private var crumbLeading: NSLayoutConstraint!

    init(onDone: @escaping ([URL]) -> Void, onClose: @escaping () -> Void) {
        self.onDone = onDone
        self.onClose = onClose
        super.init()
    }

    func present(asSheetOf parent: NSWindow) {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                           styleMask: [.titled, .closable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.title = "从照片图库挑选"
        win.titlebarAppearsTransparent = true
        win.delegate = self
        self.window = win

        let root = UIUtil.visualEffect(material: .windowBackground, blending: .withinWindow)
        root.translatesAutoresizingMaskIntoConstraints = false
        win.contentView = root

        spinner.isIndeterminate = true
        spinner.controlSize = .small
        spinner.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(spinner)

        authHint.isHidden = true
        authHint.lineBreakMode = .byWordWrapping
        authHint.maximumNumberOfLines = 0
        authHint.preferredMaxLayoutWidth = 560
        authHint.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(authHint)
        authButton.isHidden = true
        authButton.tapAction = { [weak self] in
            guard let self = self else { return }
            if self.permissionDenied {
                // 直达「隐私与安全性 → 照片」面板；授权后回到 App 会自动重查（didBecomeActive）
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
                    NSWorkspace.shared.open(url)
                }
            } else {
                self.requestAccessAndLoad()
            }
        }
        authButton.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(authButton)

        let layout = NSCollectionViewGridLayout()
        layout.minimumItemSize = NSSize(width: 96, height: 96)
        layout.maximumItemSize = NSSize(width: 140, height: 140)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.margins = NSEdgeInsets(top: 12, left: 14, bottom: 70, right: 14)
        collection.collectionViewLayout = layout
        collection.backgroundColors = [.clear]
        collection.dataSource = self
        collection.delegate = self
        collection.isSelectable = true
        collection.register(PhotoCell.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier("PhotoCell"))
        collection.register(AlbumCell.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier("AlbumCell"))

        // 来源页签：最近 / 视频 / 相册
        let sourceBar = NSStackView()
        sourceBar.orientation = .horizontal
        sourceBar.spacing = 8
        sourceBar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sourceBar)
        let tabs: [(String, PickerMode)] = [("最近", .recent), ("视频", .videos), ("相册", .albums)]
        for (title, m) in tabs {
            let b = CapsuleButton(title, style: m == .recent ? .primary : .secondary)
            b.tag = m.rawValue
            b.tapAction = { [weak self] in self?.switchMode(m) }
            sourceBar.addArrangedSubview(b)
            sourceButtons.append(b)
        }

        // 相册导航（相册页签进入集合后才可见）
        backButton.isBordered = false
        backButton.imagePosition = .imageOnly
        backButton.contentTintColor = .secondaryLabelColor
        backButton.target = self
        backButton.action = #selector(goBackAlbum)
        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.isHidden = true
        root.addSubview(backButton)
        crumbLabel.textColor = .secondaryLabelColor
        crumbLabel.translatesAutoresizingMaskIntoConstraints = false
        crumbLabel.isHidden = true
        root.addSubview(crumbLabel)
        crumbLeading = crumbLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        root.addSubview(scroll)

        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.isHidden = true
        root.addSubview(bar)
        bar.configureAsPhotoPicker(addAction: { [weak self] in self?.exportSelected() })
        bar.onClose = { [weak self] in self?.close() }
        bar.isHidden = false // 常驻底部：未选择时也能点 ✕ 关闭

        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            sourceBar.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            sourceBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),

            backButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            backButton.centerYAnchor.constraint(equalTo: crumbLabel.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 24),
            backButton.heightAnchor.constraint(equalToConstant: 24),

            crumbLeading,
            crumbLabel.centerYAnchor.constraint(equalTo: sourceBar.centerYAnchor),
            crumbLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -14),

            scroll.topAnchor.constraint(equalTo: sourceBar.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            spinner.topAnchor.constraint(equalTo: root.topAnchor, constant: 56),
            spinner.centerXAnchor.constraint(equalTo: root.centerXAnchor),

            authHint.topAnchor.constraint(equalTo: root.topAnchor, constant: 76),
            authHint.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            authButton.topAnchor.constraint(equalTo: authHint.bottomAnchor, constant: 16),
            authButton.centerXAnchor.constraint(equalTo: root.centerXAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),

            bar.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
        ])

        parent.beginSheet(win) { [weak self] _ in
            guard let self = self else { return }
            self.onClose()
            self.window = nil
        }
        // 用户去系统设置改授权后回到 App：自动重查，不用手动再点一次
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, self.permissionDenied, self.window != nil else { return }
            self.requestAccessAndLoad()
        }
        requestAccessAndLoad()
    }

    func close() {
        window?.sheetParent?.endSheet(window!)
    }

    func windowWillClose(_ notification: Notification) {
        if exporting { exportCanceled = true }
        if let obs = activeObserver {
            NotificationCenter.default.removeObserver(obs)
            activeObserver = nil
        }
        onClose()
        window = nil
    }

    // MARK: 授权与取数

    private func requestAccessAndLoad() {
        spinner.startAnimation(nil)
        PHPhotoLibrary.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.spinner.stopAnimation(nil)
                // rawValue 4 = limited（macOS 11+ 的「选中照片」授权，SDK 10.15 无此枚举）：同样可用
                if status == .authorized || status.rawValue == 4 {
                    self.authorizedAccess = true
                    self.permissionDenied = false
                    self.authHint.isHidden = true
                    self.authButton.isHidden = true
                    self.applyMode(self.mode)
                } else {
                    self.authorizedAccess = false
                    self.permissionDenied = (status == .denied || status == .restricted)
                    self.authHint.isHidden = false
                    self.authHint.stringValue = self.permissionDenied
                        ? "照片图库访问被拒绝。请到「系统设置 → 隐私与安全性 → 照片」里允许 MiTV Helper，然后回到这里"
                        : "需要先允许访问照片图库，才能挑选要发送的照片和视频"
                    self.authButton.isHidden = false
                    self.authButton.title = self.permissionDenied ? "打开系统设置" : "允许访问照片"
                    self.emptyLabel.isHidden = false
                    self.emptyLabel.stringValue = "还没有允许访问照片图库"
                }
            }
        }
    }

    // MARK: 来源页签与相册导航

    private func switchMode(_ m: PickerMode) {
        guard m != mode else { return }
        mode = m
        albumStack.removeAll()
        collections.removeAll()
        for b in sourceButtons {
            b.style = (b.tag == m.rawValue) ? .primary : .secondary
        }
        applyMode(m)
    }

    /// 按当前模式加载数据并刷新网格
    private func applyMode(_ m: PickerMode) {
        spinner.startAnimation(nil)
        // 主线程快照导航状态：后台队列不得读 albumStack（UI 状态，主线程随时可改）
        let albumParent = albumStack.last
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            switch m {
            case .recent:
                let options = PHFetchOptions()
                options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                var fetched: PHFetchResult<PHAsset>?
                let cameraRoll = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumUserLibrary, options: nil)
                if let cam = cameraRoll.firstObject {
                    fetched = PHAsset.fetchAssets(in: cam, options: options)
                }
                if fetched == nil || fetched!.count == 0 {
                    fetched = PHAsset.fetchAssets(with: options)
                }
                DispatchQueue.main.async { self?.setAssets(fetched, crumb: nil) }
            case .videos:
                let options = PHFetchOptions()
                options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                let fetched = PHAsset.fetchAssets(with: .video, options: options)
                DispatchQueue.main.async { self?.setAssets(fetched, crumb: nil) }
            case .albums:
                let list = albumParent.map { Self.children(of: $0) } ?? Self.topLevelCollections()
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.spinner.stopAnimation(nil)
                    self.collections = list
                    self.showingCollections = true
                    self.assets = nil
                    self.refreshNavChrome()
                    self.emptyLabel.isHidden = !self.collections.isEmpty
                    self.emptyLabel.stringValue = "还没有相册"
                    self.collection.reloadData()
                }
            }
        }
    }

    /// 顶层：用户相册 + 文件夹 + 「个人收藏」，按名字排序
    private static func topLevelCollections() -> [PHCollection] {
        var out: [PHCollection] = []
        let userAlbums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        for i in 0..<userAlbums.count { out.append(userAlbums.object(at: i)) }
        let folders = PHCollectionList.fetchCollectionLists(with: .folder, subtype: .any, options: nil)
        for i in 0..<folders.count { out.append(folders.object(at: i)) }
        let favorites = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumFavorites, options: nil)
        for i in 0..<favorites.count { out.append(favorites.object(at: i)) }
        return out.sorted { ($0.localizedTitle ?? "") < ($1.localizedTitle ?? "") }
    }

    /// 文件夹的直接子项（相册/子文件夹）
    private static func children(of list: PHCollection) -> [PHCollection] {
        guard let folder = list as? PHCollectionList else { return [] }
        let children = PHCollectionList.fetchCollections(in: folder, options: nil)
        var out: [PHCollection] = []
        for i in 0..<children.count { out.append(children.object(at: i)) }
        return out.sorted { ($0.localizedTitle ?? "") < ($1.localizedTitle ?? "") }
    }

    private func setAssets(_ fetched: PHFetchResult<PHAsset>?, crumb: String?) {
        spinner.stopAnimation(nil)
        assets = fetched
        showingCollections = false
        anchorIndex = nil // 资产列表切换后旧下标失效（防 ⇧ 范围选错乱）
        refreshNavChrome(crumb: crumb)
        emptyLabel.isHidden = (fetched?.count ?? 0) > 0
        emptyLabel.stringValue = "这个相册是空的"
        collection.reloadData()
    }

    private func refreshNavChrome(crumb: String? = nil) {
        let inAlbumNav = mode == .albums
        backButton.isHidden = !inAlbumNav || albumStack.isEmpty
        crumbLabel.isHidden = !inAlbumNav
        crumbLeading.constant = backButton.isHidden ? 14 : 8
        if let c = crumb {
            crumbLabel.stringValue = c
        } else if let top = albumStack.last {
            crumbLabel.stringValue = top.localizedTitle ?? ""
        } else {
            crumbLabel.stringValue = ""
        }
    }

    /// 点相册/文件夹：文件夹下钻，相册显示资产
    func albumTapped(at index: Int) {
        guard index < collections.count else { return }
        let tapped = collections[index]
        if let assetCollection = tapped as? PHAssetCollection {
            albumStack.append(assetCollection)
            spinner.startAnimation(nil)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let options = PHFetchOptions()
                options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                let fetched = PHAsset.fetchAssets(in: assetCollection, options: options)
                DispatchQueue.main.async { self?.setAssets(fetched, crumb: assetCollection.localizedTitle) }
            }
        } else if let folder = tapped as? PHCollectionList {
            albumStack.append(folder)
            spinner.startAnimation(nil)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let sub = Self.children(of: folder)
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.spinner.stopAnimation(nil)
                    self.collections = sub
                    self.showingCollections = true
                    self.assets = nil
                    self.refreshNavChrome(crumb: folder.localizedTitle)
                    self.emptyLabel.isHidden = !sub.isEmpty
                    self.emptyLabel.stringValue = "这个文件夹是空的"
                    self.collection.reloadData()
                }
            }
        }
    }

    @objc private func goBackAlbum() {
        guard mode == .albums, !albumStack.isEmpty else { return }
        albumStack.removeLast()
        spinner.startAnimation(nil)
        let parent = albumStack.last // 主线程快照，后台不再读 albumStack
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let list: [PHCollection]
            let crumb: String?
            if let top = parent {
                list = Self.children(of: top)
                crumb = top.localizedTitle
            } else {
                list = Self.topLevelCollections()
                crumb = ""
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.spinner.stopAnimation(nil)
                self.collections = list
                self.showingCollections = true
                self.assets = nil
                self.refreshNavChrome(crumb: crumb)
                self.emptyLabel.isHidden = !list.isEmpty
                self.emptyLabel.stringValue = "这个文件夹是空的"
                self.collection.reloadData()
            }
        }
    }

    // MARK: 选择

    private func toggle(at index: Int, shift: Bool) {
        guard let assets = assets, index < assets.count else { return }
        let asset = assets.object(at: index)
        if shift, let anchor = anchorIndex, let anchorAsset = self.asset(at: anchor) {
            // ⇧ 范围选
            selected.removeAll()
            selected.insert(anchorAsset.localIdentifier)
            let lo = min(anchor, index), hi = max(anchor, index)
            for i in lo...hi {
                if let a = self.asset(at: i) { selected.insert(a.localIdentifier) }
            }
        } else if selected.contains(asset.localIdentifier) {
            selected.remove(asset.localIdentifier)
        } else {
            selected.insert(asset.localIdentifier)
        }
        anchorIndex = index
        for case let cell as PhotoCell in collection.visibleItems() {
            cell.setSelected(selected.contains(cell.assetIdentifier))
        }
        updateBar()
    }

    private func asset(at index: Int) -> PHAsset? {
        guard let assets = assets, index >= 0, index < assets.count else { return nil }
        return assets.object(at: index)
    }

    private func updateBar() {
        bar.isHidden = false // 选择器模式常驻（浏览器模式才按选中显隐）
        bar.setPhotoPickerCount(selected.count)
    }

    // MARK: 导出原图 → StagingStore

    private func exportSelected() {
        guard !exporting, !selected.isEmpty else { return }
        exporting = true
        exportCanceled = false
        // 直接按 localIdentifier 集合导出（exportOne 内部再 fetch 单个资产）：
        // 用户可跨页签/相册勾选，不受当前显示列表限制
        let ids: [String] = Array(selected)
        guard !ids.isEmpty else { exporting = false; return }
        let stagedRoot = StagingStore()
        var urls: [URL] = []
        var failed = 0
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("mitv-export-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        bar.setExportProgress("正在导出 0/\(ids.count)…")

        func finish() {
            try? FileManager.default.removeItem(at: tmpDir)
            exporting = false
            if exportCanceled { return } // 用户已关闭选择器：不入队、不提示
            let done = urls
            selected.removeAll()
            updateBar()
            if done.isEmpty {
                if failed > 0 {
                    (NSApp.delegate as? AppDelegate)?.coordinator.showToast("导出没有成功（可能正在从 iCloud 下载原件，稍后再试）")
                }
            } else {
                if failed > 0 {
                    (NSApp.delegate as? AppDelegate)?.coordinator.showToast("已导出 \(done.count) 项 · \(failed) 项没有成功（可能正在从 iCloud 下载原件，稍后可重试）")
                }
                close()
                onDone(done)
            }
        }

        func exportOne(_ i: Int) {
            guard i < ids.count else { finish(); return }
            if exportCanceled { finish(); return }
            let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [ids[i]], options: nil)
            guard let asset = fetch.firstObject else { failed += 1; exportOne(i + 1); return }
            bar.setExportProgress("正在导出 \(i + 1)/\(ids.count)…")

            let resources = PHAssetResource.assetResources(for: asset)
            guard let resource = bestResource(for: asset, resources: resources) else {
                failed += 1 // 个别资产同步中/iCloud 异常会返回空资源列表（review S3）
                exportOne(i + 1)
                return
            }
            // 保留原文件名（review D1）：电视上按名字可辨认；重名由 StagingStore.uniquedURL 顺延
            let originalName = resource.originalFilename
            let ext = PhotoPickerController.extension(for: resource)
            let safeBase = originalName.isEmpty ? "export-\(i)" : (originalName as NSString).deletingPathExtension
            let safeExt = (originalName as NSString).pathExtension.isEmpty ? ext : (originalName as NSString).pathExtension
            let tmpFile = tmpDir.appendingPathComponent("\(safeBase).\(safeExt)")
            // 同名资产（不同相册的 IMG_0001.HEIC 等）：writeData 要求目标不存在，
            // 上一份已 stage 拷贝走但 tmp 还在 → 先清掉，否则第二份起全部失败
            try? FileManager.default.removeItem(at: tmpFile)
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true // iCloud 原件
            PHAssetResourceManager.default().writeData(for: resource, toFile: tmpFile, options: options) { error in
                DispatchQueue.main.async {
                    if self.exportCanceled { finish(); return }
                    guard error == nil else {
                        failed += 1
                        try? FileManager.default.removeItem(at: tmpFile)
                        exportOne(i + 1)
                        return
                    }
                    stagedRoot.stage(from: tmpFile) { result in
                        try? FileManager.default.removeItem(at: tmpFile)
                        if self.exportCanceled { finish(); return }
                        switch result {
                        case .success(let url): urls.append(url)
                        case .failure: failed += 1
                        }
                        exportOne(i + 1)
                    }
                }
            }
        }
        exportOne(0)
    }

    /// 原文件资源：照片 fullSizePhoto>photo；视频 fullSizeVideo>video；排除 Live Photo 配对视频。空资源列表返回 nil
    private func bestResource(for asset: PHAsset, resources: [PHAssetResource]) -> PHAssetResource? {
        if asset.mediaType == .video {
            return resources.first { $0.type == .fullSizeVideo }
                ?? resources.first { $0.type == .video }
                ?? resources.first
        }
        return resources.first { $0.type == .fullSizePhoto }
            ?? resources.first { $0.type == .photo }
            ?? resources.first
    }

    static func `extension`(for resource: PHAssetResource) -> String {
        let original = resource.originalFilename
        if original.contains(".") {
            let ext = (original as NSString).pathExtension.lowercased()
            if !ext.isEmpty { return ext }
        }
        let uti = resource.uniformTypeIdentifier as CFString
        if let ext = UTTypeCopyPreferredTagWithClass(uti, kUTTagClassFilenameExtension)?.takeRetainedValue() {
            return ext as String
        }
        return resource.type == .fullSizeVideo || resource.type == .video ? "mov" : "heic"
    }

    // MARK: - 数据源

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        showingCollections ? collections.count : (assets?.count ?? 0)
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let index = indexPath.item
        if showingCollections {
            let cell = collectionView.makeItem(withIdentifier: NSUserInterfaceItemIdentifier("AlbumCell"), for: indexPath) as! AlbumCell
            guard index < collections.count else { return cell }
            let c = collections[index]
            let isFolder = !(c is PHAssetCollection)
            cell.configure(title: c.localizedTitle ?? "未命名", isFolder: isFolder, index: index, controller: self)
            return cell
        }
        let cell = collectionView.makeItem(withIdentifier: NSUserInterfaceItemIdentifier("PhotoCell"), for: indexPath) as! PhotoCell
        guard let assets = assets, index < assets.count else { return cell }
        let asset = assets.object(at: index)
        cell.configure(asset: asset, index: index, controller: self)
        cell.setSelected(selected.contains(asset.localIdentifier))
        return cell
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        DispatchQueue.main.async { collectionView.deselectAll(nil) }
    }

    fileprivate func cellTapped(index: Int, shift: Bool) {
        toggle(at: index, shift: shift)
    }

    fileprivate func albumCellTapped(index: Int) {
        albumTapped(at: index)
    }
}

// MARK: - 相册/文件夹格（相册页签的集合列表用）

final class AlbumCell: NSCollectionViewItem {

    private var index = 0
    private weak var controller: PhotoPickerController?
    private let iconView = NSImageView()
    private let titleLabel = UIUtil.label("", size: 12, align: .center)

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 108))
        view = container
        container.wantsLayer = true
        container.layer?.cornerRadius = 8

        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = 8
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(iconView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(titleLabel)

        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            iconView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 64),
            iconView.heightAnchor.constraint(equalToConstant: 56),

            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 6),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
            titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
            titleLabel.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -4),
        ])
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .inVisibleRect, .activeInKeyWindow], owner: self, userInfo: nil)
        container.addTrackingArea(tracking)
    }

    func configure(title: String, isFolder: Bool, index: Int, controller: PhotoPickerController) {
        self.index = index
        self.controller = controller
        titleLabel.stringValue = title
        iconView.image = isFolder ? Icons.folder : Icons.photo
        iconView.contentTintColor = NSColor.systemTeal.withAlphaComponent(0.75)
    }

    override func mouseDown(with event: NSEvent) {
        controller?.albumCellTapped(index: index)
    }
}

// MARK: - 照片格

final class PhotoCell: NSCollectionViewItem {

    var assetIdentifier: String = ""
    private var index = 0
    private weak var controller: PhotoPickerController?
    private let photoImageView = NSImageView()
    private let videoBadge = UIUtil.label("", size: 10, color: .white)
    private let checkMark = CheckboxCircle()
    private var requestID: PHImageRequestID?
    private var hover = false

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 96, height: 96))
        view = container
        container.wantsLayer = true
        container.layer?.cornerRadius = 8

        photoImageView.imageScaling = .scaleProportionallyUpOrDown
        photoImageView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(photoImageView)
        videoBadge.wantsLayer = true
        videoBadge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        videoBadge.layer?.cornerRadius = 4
        videoBadge.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(videoBadge)
        checkMark.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(checkMark)

        NSLayoutConstraint.activate([
            photoImageView.topAnchor.constraint(equalTo: container.topAnchor),
            photoImageView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            photoImageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            photoImageView.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            videoBadge.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -5),
            videoBadge.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -5),

            checkMark.topAnchor.constraint(equalTo: container.topAnchor, constant: 5),
            checkMark.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -5),
            checkMark.widthAnchor.constraint(equalToConstant: 20),
            checkMark.heightAnchor.constraint(equalToConstant: 20),
        ])
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .inVisibleRect, .activeInKeyWindow], owner: self, userInfo: nil)
        container.addTrackingArea(tracking)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        if let id = requestID { PHImageManager.default().cancelImageRequest(id) }
        requestID = nil
        photoImageView.image = nil
        videoBadge.stringValue = ""
        videoBadge.isHidden = true
    }

    func configure(asset: PHAsset, index: Int, controller: PhotoPickerController) {
        self.index = index
        self.controller = controller
        assetIdentifier = asset.localIdentifier

        if asset.mediaType == .video {
            let seconds = Int(asset.duration.rounded())
            videoBadge.stringValue = seconds >= 60 ? "\(seconds / 60) 分\(seconds % 60) 秒" : "\(seconds) 秒"
            videoBadge.isHidden = false
        }
        let scale = (view.window?.backingScaleFactor ?? 2)
        let target = CGSize(width: 400 * scale, height: 400 * scale)
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic // 先低清后高清，两段更新
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast
        requestID = PHImageManager.default().requestImage(for: asset, targetSize: target,
                                                          contentMode: .aspectFill, options: options) { [weak self] image, _ in
            DispatchQueue.main.async {
                guard let self = self, self.assetIdentifier == asset.localIdentifier else { return }
                if let img = image {
                    self.photoImageView.image = img
                }
            }
        }
    }

    func setSelected(_ selected: Bool) {
        checkMark.setChecked(selected, visible: selected || hover)
        view.layer?.backgroundColor = selected
            ? NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
            : NSColor.clear.cgColor
        view.layer?.borderWidth = selected ? 2 : 0
        view.layer?.borderColor = NSColor.controlAccentColor.cgColor
    }

    override func mouseEntered(with event: NSEvent) {
        hover = true
        if !checkMark.isChecked { checkMark.setChecked(false, visible: true) }
    }

    override func mouseExited(with event: NSEvent) {
        hover = false
        checkMark.setChecked(checkMark.isChecked, visible: checkMark.isChecked)
    }

    override func mouseDown(with event: NSEvent) {
        let shift = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.shift)
        controller?.cellTapped(index: index, shift: shift)
    }
}
