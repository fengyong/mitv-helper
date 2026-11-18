import AppKit

// MARK: - 应用入口（NSApplication 装配 + Dock 拖放入队）

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.regular)
app.mainMenu = AppDelegate.buildMainMenu()
app.run()
