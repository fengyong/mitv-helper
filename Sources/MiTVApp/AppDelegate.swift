import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    let coordinator = AppCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator.startup()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { coordinator.showWindow() }
        return true
    }

    /// 拖文件到 Dock 图标 → 启动并入队
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        coordinator.enqueueFilePaths(filenames)
    }

    // MARK: 菜单（最小集，快捷键齐全）

    static func buildMainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "关于 MiTV Helper", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let hideItem = appMenu.addItem(withTitle: "隐藏 MiTV Helper", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hideItem.target = NSApp
        appMenu.addItem(withTitle: "退出 MiTV Helper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let fileMenu = NSMenu(title: "文件")
        fileItem.submenu = fileMenu
        let choose = fileMenu.addItem(withTitle: "从照片图库挑选…", action: #selector(AppDelegate.menuChoosePhotos(_:)), keyEquivalent: "p")
        choose.keyEquivalentModifierMask = [.command, .shift]
        choose.target = self
        let chooseFiles = fileMenu.addItem(withTitle: "从文件夹挑选…", action: #selector(AppDelegate.menuChooseFiles(_:)), keyEquivalent: "o")
        chooseFiles.keyEquivalentModifierMask = [.command, .shift]
        chooseFiles.target = self

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let winItem = NSMenuItem()
        main.addItem(winItem)
        let winMenu = NSMenu(title: "窗口")
        winItem.submenu = winMenu
        winMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        return main
    }

    @objc func menuChoosePhotos(_ sender: Any?) { coordinator.openPhotoPicker() }
    @objc func menuChooseFiles(_ sender: Any?) { coordinator.openFilePicker() }
}
