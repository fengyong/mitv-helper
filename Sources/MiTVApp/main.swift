import AppKit
import Foundation

// 骨架占位：由 UI Agent 整体替换为实现版应用入口。
let app = NSApplication.shared
app.setActivationPolicy(.regular)
print("MiTVApp skeleton — UI pending")
