import AppKit
import Foundation
import Photos
import CoreServices

// MARK: - 照片图库选择器（Photos 框架自建网格：授权 → 相机胶卷 → 倒序 → 多选 → 导出原图）

final class PhotoPickerController: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout, NSWindowDelegate {

    private var window: NSWindow?
    private var onDone: ([URL]) -> Void
    private var onClose: (() -> Void)

    private var assets: PHFetchResult<PHAsset>?
    private var selected: Set<String> = []      // localIdentifier
    private var anchorIndex: Int?
    private var exporting = false

    private let collection = NSCollectionView()
    private let scroll = NSScrollView()
    private let bar = GlassActionBar()
    private let emptyLabel = UIUtil.label("照片图库里还没有内容", size: 14, color: .secondaryLabelColor, align: .center)
    private let spinner = NSProgressIndicator()
    private let authButton = CapsuleButton("允许访问照片", style: .primary)
    private let authHint = UIUtil.label("需要先允许访问照片图库，才能挑选要发送的照片和视频", size: 13, color: .secondaryLabelColor, align: .center)
    private var authorizedAccess = false

    init(onDone: @escaping ([URL]) -> Void, onClose: @escaping () -> Void) {
        self.onDone = onDone
        self.onClose = onClose
        super.init()
    }

    func present(asSheetOf parent: NSWindow) {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                           styleMask: [.titled, .fullSizeContentView],
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
        authHint.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(authHint)
        authButton.isHidden = true
        authButton.tapAction = { [weak self] in self?.requestAccessAndLoad() }
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

        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            spinner.topAnchor.constraint(equalTo: root.topAnchor, constant: 40),
            spinner.centerXAnchor.constraint(equalTo: root.centerXAnchor),

            authHint.topAnchor.constraint(equalTo: root.topAnchor, constant: 60),
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
        requestAccessAndLoad()
    }

    func close() {
        window?.sheetParent?.endSheet(window!)
    }

    func windowWillClose(_ notification: Notification) {
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
                if status == .authorized {
                    self.authorizedAccess = true
                    self.authHint.isHidden = true
                    self.authButton.isHidden = true
                    self.loadCameraRoll()
                } else {
                    self.authorizedAccess = false
                    self.authHint.isHidden = false
                    self.authButton.isHidden = false
                    self.emptyLabel.isHidden = false
                    self.emptyLabel.stringValue = "还没有允许访问照片图库"
                }
            }
        }
    }

    private func loadCameraRoll() {
        spinner.startAnimation(nil)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)] // 按日期倒序
            var fetched: PHFetchResult<PHAsset>?
            let cameraRoll = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumUserLibrary, options: nil)
            if let cam = cameraRoll.firstObject {
                fetched = PHAsset.fetchAssets(in: cam, options: options)
            }
            if fetched == nil || fetched!.count == 0 {
                fetched = PHAsset.fetchAssets(with: options)
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.spinner.stopAnimation(nil)
                self.assets = fetched
                self.emptyLabel.isHidden = (fetched?.count ?? 0) > 0
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
        bar.isHidden = selected.isEmpty
        bar.setPhotoPickerCount(selected.count)
    }

    // MARK: 导出原图 → StagingStore

    private func exportSelected() {
        guard !exporting, let assets = assets else { return }
        exporting = true
        var ids: [String] = []
        for i in 0..<assets.count {
            let a = assets.object(at: i)
            if selected.contains(a.localIdentifier) { ids.append(a.localIdentifier) }
        }
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
            let done = urls
            selected.removeAll()
            updateBar()
            if done.isEmpty {
                if failed > 0 {
                    (NSApp.delegate as? AppDelegate)?.coordinator.showToast("导出没有成功（可能正在从 iCloud 下载原件，稍后再试）")
                }
            } else {
                close()
                onDone(done)
            }
        }

        func exportOne(_ i: Int) {
            guard i < ids.count else { finish(); return }
            let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [ids[i]], options: nil)
            guard let asset = fetch.firstObject else { exportOne(i + 1); return }
            bar.setExportProgress("正在导出 \(i + 1)/\(ids.count)…")

            let resources = PHAssetResource.assetResources(for: asset)
            let resource = bestResource(for: asset, resources: resources)
            let ext = PhotoPickerController.extension(for: resource)
            let tmpFile = tmpDir.appendingPathComponent("export-\(i).\(ext)")
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true // iCloud 原件
            PHAssetResourceManager.default().writeData(for: resource, toFile: tmpFile, options: options) { error in
                DispatchQueue.main.async {
                    guard error == nil else {
                        failed += 1
                        exportOne(i + 1)
                        return
                    }
                    stagedRoot.stage(from: tmpFile) { result in
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

    /// 原文件资源：照片 fullSizePhoto>photo；视频 fullSizeVideo>video；排除 Live Photo 配对视频
    private func bestResource(for asset: PHAsset, resources: [PHAssetResource]) -> PHAssetResource {
        if asset.mediaType == .video {
            return resources.first { $0.type == .fullSizeVideo }
                ?? resources.first { $0.type == .video }
                ?? resources.first!
        }
        return resources.first { $0.type == .fullSizePhoto }
            ?? resources.first { $0.type == .photo }
            ?? resources.first!
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
        assets?.count ?? 0
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let cell = collectionView.makeItem(withIdentifier: NSUserInterfaceItemIdentifier("PhotoCell"), for: indexPath) as! PhotoCell
        let index = indexPath.item
        guard let assets = assets, index < assets.count else { return cell }
        let asset = assets.object(at: index)
        cell.configure(asset: asset, index: index, controller: self)
        cell.setSelected(selected.contains(asset.localIdentifier))
        return cell
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPath: Set<IndexPath>) {
        DispatchQueue.main.async { collectionView.deselectAll(nil) }
    }

    fileprivate func cellTapped(index: Int, shift: Bool) {
        toggle(at: index, shift: shift)
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
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .inVisibleRect, .activeInKeyWindow], owner: nil, userInfo: nil)
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
