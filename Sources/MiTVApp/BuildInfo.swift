import Foundation

/// 构建号：每次 `make app` / `make appbundle` 编译前由 Makefile 自增（+1），
/// 显示在主窗口底部状态栏，用于一眼确认当前安装/运行的是哪次构建。
/// 初始值 0；首次构建后为 1。
let appBuildNumber = 4
