import AppKit
import Foundation

/// 中央协调器：装配窗口三态、服务层、心跳黄条、toast/确认浮层/向导/设置。
/// 永不弹错误对话框——连接问题只用黄条与胶囊表达。
final class AppCoordinator: NSObject {

    // MARK: - 服务

    let store = TVStore()
    let trashStore = TrashStore()
    let staging = StagingStore()
    let picks = PickService()

    lazy var queue = QueueService(
        engineProvider: { EngineHolder.shared.engine() },
        endpointProvider: { [weak self] in self?.store.endpoint },
        capabilitiesProvider: { [weak self] in self?.store.capabilities },
        persistenceDirectory: TVStore.defaultDirectory(),
        concurrency: UserDefaults.standard.integer(forKey: "concurrency") == 0
            ? 2 : UserDefaults.standard.integer(forKey: "concurrency"))

    lazy var heartbeat = HeartbeatService(
        engineProvider: { EngineHolder.shared.engine() },
        endpointProvider: { [weak self] in self?.store.endpoint })

    lazy var files = TVFileService(
        engineProvider: { EngineHolder.shared.engine() },
        endpointProvider: { [weak self] in self?.store.endpoint },
        capabilitiesProvider: { [weak self] in self?.store.capabilities },
        trashStore: trashStore)

    // MARK: - 视图

    let window = AppCoordinator.buildWindow()
    private let rootDrop = RootDropView()
    private let header: HeaderBar
    private let banner = BannerView()
    private let content = NSView()
    private let statusBar = StatusBarView()
    private let toastHost = ToastHostView()

    private lazy var emptyView = EmptyStateView(
        onPickPhotos: { [weak self] in self?.openPhotoPicker() },
        onPickFiles: { [weak self] in self?.openFilePicker() })
    private lazy var queueView = QueueView(coordinator: self)
    private lazy var browserView = TVBrowserView(coordinator: self)

    enum Mode { case home, browser }
    private(set) var mode: Mode = .home
    private var heartbeatStatus: HeartbeatService.Status = .off
    private var connecting = false
    private var yellowBannerUp = false
    private var photoPicker: PhotoPickerController?
    private var onboarding: OnboardingOverlay?
    var confirmOverlay: ConfirmOverlay? // 冒烟自动化需要访问；正常流程不受影响
    private var settingsController: SettingsController?
    /// 「删除前先下载」的批次登记：batchId → (待删文件, 完成回调)。整批取回成功后才执行删除
    private var pendingDeleteBatches: [String: (files: [FTPFileEntry], after: () -> Void)] = [:]

    /// 确认浮层/首连向导是否在场（浏览器键盘监听据此让路，review D4）
    var hasModalOverlay: Bool { onboarding != nil || confirmOverlay != nil }

    // MARK: - Init

    override init() {
        header = HeaderBar()
        super.init()
        assembleWindow()
        header.onNav = { [weak self] nav in self?.handleNav(nav) }
        header.onCapsuleTap = { [weak self] in self?.capsuleTapped() }
        header.onSettingsTap = { [weak self] in self?.openSettings() }
    }

    private static func buildWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 560),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "MiTV Helper"
        w.minSize = NSSize(width: 720, height: 480)
        w.titlebarAppearsTransparent = true
        w.center()
        return w
    }

    private func assembleWindow() {
        rootDrop.frame = NSRect(x: 0, y: 0, width: 880, height: 560)
        rootDrop.autoresizingMask = [.width, .height]
        window.contentView = rootDrop

        header.translatesAutoresizingMaskIntoConstraints = false
        banner.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        toastHost.translatesAutoresizingMaskIntoConstraints = false
        rootDrop.addSubview(header)
        rootDrop.addSubview(banner)
        rootDrop.addSubview(content)
        rootDrop.addSubview(statusBar)
        rootDrop.addSubview(toastHost)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: rootDrop.topAnchor),
            header.leadingAnchor.constraint(equalTo: rootDrop.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: rootDrop.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 54),

            banner.topAnchor.constraint(equalTo: header.bottomAnchor),
            banner.leadingAnchor.constraint(equalTo: rootDrop.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: rootDrop.trailingAnchor),

            content.topAnchor.constraint(equalTo: banner.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: rootDrop.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: rootDrop.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: rootDrop.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: rootDrop.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: rootDrop.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 30),

            toastHost.leadingAnchor.constraint(equalTo: rootDrop.leadingAnchor),
            toastHost.trailingAnchor.constraint(equalTo: rootDrop.trailingAnchor),
            toastHost.topAnchor.constraint(equalTo: banner.bottomAnchor),
            toastHost.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
        ])

        rootDrop.onFilesDropped = { [weak self] urls in
            self?.enqueueFileURLs(urls)
        }
    }

    // MARK: - 启动

    func startup() {
        UserDefaults.standard.register(defaults: [
            "useMockEngine": false,
            "notifyOnComplete": true,
            "soundOnComplete": true,
            "concurrency": 2,
        ])

        queue.onChanged = { [weak self] in self?.handleQueueChanged() }
        queue.onBatchCompleted = { [weak self] batchId, ok, bad in
            self?.handleBatchCompleted(batchId: batchId, ok: ok, bad: bad)
        }
        heartbeat.onStatus = { [weak self] status in self?.handleHeartbeat(status) }

        showState(emptyView)
        showWindow()
        refreshHeader()
        updateStatusBar() // 启动即渲染状态栏（构建号从首帧可见，不等连接完成）

        if let endpoint = store.endpoint, store.state.onboardingDone {
            connect(endpoint: endpoint, silent: true)
        } else {
            showOnboarding()
        }
        if queue.snapshot().isEmpty == false {
            showState(queueView)
            queueView.reload()
        }
        runSmokeHooksIfNeeded()
    }

    /// 退出前：停调度 + 强制原子写队列（重启后断点续传）
    func prepareForTermination() {
        heartbeat.stop()
        queue.suspendForShutdown()
    }

    // MARK: - 冒烟辅助（GUI 自动化受限时用环境变量驱动；不影响正常使用）

    private func runSmokeHooksIfNeeded() {
        let env = ProcessInfo.processInfo.environment
        // 快照钩子独立于其他钩子（仅冒烟验证用，不影响正常使用）
        if let snapPath = env["MITV_SNAPSHOT"] {
            let delay = Double(env["MITV_SNAPSHOT_DELAY"] ?? "3.0") ?? 3.0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.writeSnapshot(to: snapPath)
                self?.prepareForTermination()
                exit(0)
            }
        }
        if let files = env["MITV_AUTO_ENQUEUE"], !files.isEmpty {
            let urls = files.split(separator: ",").map { URL(fileURLWithPath: String($0)) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.enqueueFileURLs(urls)
            }
        }
        if env["MITV_AUTO_DROP"] == "1" {
            (EngineHolder.shared.engine() as? MockEngine)?.failNextPingCount = 3
        }
        guard let auto = env["MITV_AUTO"] else { return }
        if auto == "picker" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.openPhotoPicker()
            }
        }
        if auto == "settings" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.openSettings()
            }
        }
        if auto == "browser" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.setMode(.browser)
                if let sel = env["MITV_AUTO_SEL"], let n = Int(sel), n > 0 {
                    self?.browserView.smokeSelectFirstFiles(n)
                }
                if env["MITV_AUTO_CONFIRM"] == "1" {
                    self?.browserView.smokeConfirmSelected()
                }
                if env["MITV_AUTO_ENTER"] == "1" {
                    self?.browserView.smokeEnterFirstDirectory()
                }
            }
        }
        if auto == "browser" {
            if env["MITV_AUTO_DELETE"] == "1" {
                self.browserView.smokeDeleteFirstFile()
            }
            if env["MITV_AUTO_UNDO"] == "1" {
                self.browserView.smokeUndoAll()
            }
        }
        if auto == "queue" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.setMode(.home)
            }
        }
    }

    /// 离屏渲染窗口内容为 PNG（不依赖屏幕录制权限）；主窗口有 sheet 时一并渲染（sheet 是独立窗口）
    private func writeSnapshot(to path: String) {
        if let content = window.contentView, let png = Self.renderPNG(view: content) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
        for w in NSApp.windows where w.sheetParent === window {
            guard let content = w.contentView, let png = Self.renderPNG(view: content) else { continue }
            let sheetPath = path + ".sheet.png"
            try? png.write(to: URL(fileURLWithPath: sheetPath))
        }
    }

    private static func renderPNG(view: NSView) -> Data? {
        let scale: CGFloat = 2
        let size = view.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(size.width * scale),
                                         pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - 状态切换（三态容器）

    private func showState(_ view: NSView) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            ctx.allowsImplicitAnimation = true
            for sub in content.subviews { sub.removeFromSuperview() }
            view.frame = content.bounds
            view.autoresizingMask = [.width, .height]
            content.addSubview(view)
        }, completionHandler: nil)
    }

    private func handleNav(_ nav: HeaderBar.Nav) {
        switch nav {
        case .photos: openPhotoPicker()
        case .videos: openFilePicker()
        case .tv: setMode(.browser)
        }
    }

    private func capsuleTapped() {
        if store.endpoint == nil || !store.state.onboardingDone {
            showOnboarding()
        } else if case .lost = heartbeatStatus {
            heartbeat.checkNow()
        } else if heartbeatStatus == .off, let ep = store.endpoint {
            // 启动探测失败等场景（心跳未运行）：手动重连一次
            header.capsule.setLook(.connecting, "正在连接电视…")
            connect(endpoint: ep) { [weak self] ok, error in
                if !ok {
                    self?.showToast("还是连不上：\(error ?? "请确认电视上的「远程管理」还开着")")
                }
            }
        }
    }

    func setMode(_ newMode: Mode) {
        switch newMode {
        case .browser:
            guard store.endpoint != nil, store.state.onboardingDone else {
                showOnboarding()
                return
            }
            mode = .browser
            header.highlightNav(.tv)
            showState(browserView)
            browserView.reloadIfNeeded()
        case .home:
            mode = .home
            header.highlightNav(.photos)
            if queue.snapshot().isEmpty {
                showState(emptyView)
            } else {
                showState(queueView)
                queueView.reload()
            }
        }
        updateStatusBar()
    }

    private func handleQueueChanged() {
        if mode == .home {
            let has = queue.snapshot().isEmpty == false
            let current = content.subviews.first
            if has && (current === emptyView) {
                showState(queueView)
            } else if !has && (current === queueView) {
                showState(emptyView)
            } else if has && current === queueView {
                queueView.reload()
            }
        }
        updateStatusBar()
    }

    private func updateStatusBar() {
        let items = queue.snapshot()
        let busy = items.filter { $0.phase == .connecting || $0.phase == .running }
        let queued = items.filter { $0.phase == .queued }
        let speed = busy.reduce(0.0) { $0 + $1.bytesPerSecond }
        // 状态栏右侧常显构建号，一眼确认当前运行的是哪次 build
        let buildTag = "build \(appBuildNumber)"
        let right = queued.isEmpty ? buildTag : "\(buildTag) · 排队 \(queued.count) 项"
        if !busy.isEmpty {
            let totalLeft = busy.reduce(Int64(0)) { $0 + max(0, ($1.sizeBytes - $1.bytes)) }
            var text = "正在发送 \(busy.count) 项"
            if let eta = Fmt.eta(totalLeft, bps: speed) { text += " · \(eta)" }
            statusBar.set(left: text, right: right)
        } else if heartbeatStatus == .connected {
            statusBar.set(left: "就绪 · 电视已连接", right: right)
        } else if case .lost = heartbeatStatus {
            statusBar.set(left: "电视连接不上 · 正在等待重连", right: right)
        } else {
            statusBar.set(left: "就绪", right: right)
        }
    }

    // MARK: - 连接流程

    func connect(endpoint: FTPEndpoint, name: String? = nil, silent: Bool = false,
                 completion: ((Bool, String?) -> Void)? = nil) {
        guard !connecting else { completion?(false, nil); return }
        connecting = true
        header.capsule.setLook(.connecting, "正在连接电视…")
        EngineHolder.shared.engine().probeCapabilities(endpoint) { [weak self] result in
            guard let self = self else { return }
            self.connecting = false
            switch result {
            case .success(let caps):
                self.store.update {
                    $0.endpoint = endpoint
                    $0.capabilities = caps
                    if let n = name, !n.isEmpty { $0.tvName = n }
                    $0.onboardingDone = true
                }
                self.heartbeatStatus = .connected
                self.heartbeat.start()
                self.refreshHeader()
                self.updateStatusBar()
                if !silent { self.showToast("已连接电视") }
                completion?(true, nil)
            case .failure(let error):
                self.heartbeatStatus = .off
                self.refreshHeader()
                completion?(false, error.localizedDescription)
            }
        }
    }

    private func handleHeartbeat(_ status: HeartbeatService.Status) {
        heartbeatStatus = status
        switch status {
        case .connected:
            if yellowBannerUp {
                yellowBannerUp = false
                banner.hide()
                queue.autoResumeAfterReconnect()
                showToast("电视已重新连接")
            }
        case .lost(let attempt):
            yellowBannerUp = true
            banner.show("电视连接不上 · 正在重试（第 \(attempt) 次）… 文件已自动暂停")
            queue.autoPauseForDisconnect()
        case .off:
            if yellowBannerUp { yellowBannerUp = false; banner.hide() }
        }
        refreshHeader()
        updateStatusBar()
    }

    private func refreshHeader() {
        let name = store.state.tvName ?? "电视"
        switch heartbeatStatus {
        case .connected:
            header.capsule.setLook(.connected, "\(name) · 已连接")
        case .lost(let attempt):
            header.capsule.setLook(.lost, "\(name) · 连接不上，正在重试（第 \(attempt) 次）")
        case .off:
            header.capsule.setLook(.off, store.endpoint == nil ? "未连接电视 · 点此连接" : "\(name) · 连接不上 · 点此重连")
        }
        if mode == .browser, heartbeatStatus == .off, store.endpoint != nil {
            // 掉线时浏览态停留但列表不可操作（由浏览器自己展示空态）
        }
    }

    // MARK: - 入队

    func enqueueFilePaths(_ paths: [String]) {
        enqueueFileURLs(paths.map { URL(fileURLWithPath: $0) })
    }

    func enqueueFileURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        // 与文件面板同路径：文件夹递归展开成媒体文件（否则整夹拖入会被当 .other 全部忽略）
        var expanded: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                expanded.append(contentsOf: PickService.expandFolder(url))
            } else {
                expanded.append(url)
            }
        }
        let result = PickService.filterMedia(expanded)
        guard !result.media.isEmpty else {
            showToast(expanded.count != urls.count ? "文件夹里没有可发送的照片或视频" : "这些文件不是照片或视频")
            return
        }
        guard store.endpoint != nil, store.state.onboardingDone else {
            showToast("先连接电视，再把文件拖进来")
            showOnboarding()
            return
        }
        if result.ignored > 0 { showToast("已忽略 \(result.ignored) 个不支持的项目") }
        queue.addUploads(result.media)
        setMode(.home)
    }

    /// 照片选择器导出完成 → 入队
    func enqueueStaged(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        queue.addUploads(urls)
        setMode(.home)
    }

    private func handleBatchCompleted(batchId: String, ok: Int, bad: Int) {
        // 「删除前先下载」的批次：整批取回成功才执行删除，失败则中止（数据安全兜底）
        if let pending = pendingDeleteBatches.removeValue(forKey: batchId) {
            if bad == 0 {
                deleteRemote(pending.files, after: pending.after)
            } else {
                showToast("取回没有全部成功，已取消删除 · 可重试取回后再删")
                pending.after()
            }
            return
        }
        let isDownload = queue.snapshot().first { $0.batchId == batchId }?.direction == .download
        if ok > 0 {
            showToast(isDownload ? "已把 \(ok) 个文件取回到本地" : "已把 \(ok) 个文件送到电视")
            if UserDefaults.standard.bool(forKey: "soundOnComplete") {
                NSSound(named: NSSound.Name("Glass"))?.play()
            }
            if UserDefaults.standard.bool(forKey: "notifyOnComplete") {
                let body = isDownload ? "\(ok) 个文件已保存到本地" : "\(ok) 个文件已送到电视"
                postSystemNotification(title: isDownload ? "取回完成" : "发送完成", body: body)
            }
            NSApp.requestUserAttention(.informationalRequest)
            bounceWindow()
        }
        if bad > 0 {
            showToast(isDownload ? "有 \(bad) 个文件取回失败，可在列表里重试" : "有 \(bad) 个文件发送失败，可在列表里重试")
        }
    }

    private func bounceWindow() {
        let frame = window.frame
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            window.animator().setFrame(frame.offsetBy(dx: 0, dy: 12), display: false)
        }, completionHandler: { [weak self] in
            guard let self = self else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                self.window.animator().setFrame(frame, display: true)
            }
        })
    }

    func postSystemNotification(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = NSUserNotificationCenter.default
        let note = NSUserNotification()
        note.title = title
        note.informativeText = body
        center.deliver(note)
    }

    // MARK: - Toast

    func showToast(_ text: String, undo: (() -> Void)? = nil) {
        let toast = ToastView(text: text, actionTitle: undo == nil ? nil : "撤销", action: undo)
        toastHost.show(toast, in: toastHost.bounds)
        toast.scheduleAutoDismiss(after: undo == nil ? 4.5 : 8)
    }

    // MARK: - 各入口

    func openPhotoPicker() {
        guard store.endpoint != nil, store.state.onboardingDone else { showOnboarding(); return }
        if photoPicker != nil { return }
        let picker = PhotoPickerController(onDone: { [weak self] staged in
            self?.enqueueStaged(staged)
            self?.photoPicker = nil
        }, onClose: { [weak self] in
            self?.photoPicker = nil
        })
        photoPicker = picker
        picker.present(asSheetOf: window)
    }

    func openFilePicker() {
        guard store.endpoint != nil, store.state.onboardingDone else { showOnboarding(); return }
        picks.chooseMedia(on: window) { [weak self] media, ignored in
            guard let self = self else { return }
            if !media.isEmpty {
                self.queue.addUploads(media)
                self.setMode(.home)
            }
            if ignored > 0 { self.showToast("已忽略 \(ignored) 个不支持的项目") }
        }
    }

    func showOnboarding() {
        guard onboarding == nil else { return }
        let overlay = OnboardingOverlay(coordinator: self)
        onboarding = overlay
        overlay.present(in: rootDrop) { [weak self] in
            self?.onboarding = nil
        }
    }

    func openSettings() {
        guard settingsController == nil else { return }
        let s = SettingsController(coordinator: self)
        settingsController = s
        s.present(asSheetOf: window) { [weak self] in
            self?.settingsController = nil
        }
    }

    /// 删除确认浮层（软删除/直删/不支持 三种文案，见 §7）
    func confirmDelete(_ entries: [FTPFileEntry], completion: @escaping () -> Void) {
        let strategy = files.currentStrategy()
        let overlay = ConfirmOverlay.show(entries: entries, strategy: strategy, in: rootDrop) { [weak self] downloadFirst in
            guard let self = self else { return }
            self.performDelete(entries, downloadFirst: downloadFirst, after: completion)
        }
        overlay.dismissCompletion = { [weak self] in self?.confirmOverlay = nil }
        confirmOverlay = overlay
    }

    private func performDelete(_ entries: [FTPFileEntry], downloadFirst: Bool, after: @escaping () -> Void) {
        let filesToDelete = entries.filter { !$0.isDirectory }
        guard !filesToDelete.isEmpty else { after(); return }

        if downloadFirst {
            // 降级兜底：先把文件全部取回本地，整批取回成功后才真正删除（失败则中止，不再先删后赌）
            picks.chooseFolder(on: window) { [weak self] dir in
                guard let self = self, let dir = dir else { after(); return }
                let items = self.queue.addDownloads(filesToDelete, toDirectory: dir)
                guard let batchId = items.first?.batchId else { after(); return }
                self.pendingDeleteBatches[batchId] = (filesToDelete, after)
                self.setMode(.home)
                self.showToast("先把 \(items.count) 项取回本地 · 全部成功后才会删除")
            }
            return
        }
        deleteRemote(filesToDelete, after: after)
    }

    private func deleteRemote(_ filesToDelete: [FTPFileEntry], after: @escaping () -> Void) {
        let total = filesToDelete.count
        showToast("正在移除 \(total) 项…")
        files.deleteEntries(filesToDelete, progress: { _, _, _ in }) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let outcome):
                if !outcome.records.isEmpty {
                    // 软删除：可撤销（部分失败也如实说明）
                    var text = "已删除 \(outcome.records.count) 项 · 随时可撤销"
                    if !outcome.failedNames.isEmpty {
                        text = "已删除 \(outcome.records.count) 项 · \(outcome.failedNames.count) 项没有成功 · 可撤销"
                    }
                    self.showToast(text, undo: { [weak self] in
                        self?.files.restore(outcome.records,
                                            progress: { _, _, _ in }) { restored, failed in
                            guard let self = self else { return }
                            if restored > 0 { self.showToast("已还原 \(restored) 项") }
                            if failed > 0 { self.showToast("有 \(failed) 项还原失败") }
                            // 撤销后刷新界面（review D2）：不刷的话文件已回来但列表缺失，用户会以为撤销失败
                            if self.mode == .browser {
                                self.browserView.reloadAfterRestore()
                            }
                        }
                    })
                } else if outcome.failedNames.isEmpty {
                    self.showToast("已永久删除 \(total) 项")
                } else if outcome.failedNames.count < total {
                    self.showToast("已永久删除 \(total - outcome.failedNames.count) 项 · \(outcome.failedNames.count) 项没有成功")
                } else {
                    self.showToast("删除没有完成：\(outcome.failedNames.joined(separator: "、"))")
                }
            case .failure(let error):
                self.showToast("删除没有完成：\(error.localizedDescription)")
            }
            after()
        }
    }

    // MARK: - 浏览态下载

    func downloadEntries(_ entries: [FTPFileEntry], completion: ((Bool) -> Void)? = nil) {
        guard !entries.isEmpty else { completion?(false); return }
        picks.chooseFolder(on: window) { [weak self] dir in
            guard let self = self, let dir = dir else { completion?(false); return }
            self.queue.addDownloads(entries, toDirectory: dir)
            self.setMode(.home)
            self.showToast("已加入取回队列 \(entries.count) 项")
            completion?(true)
        }
    }
}
