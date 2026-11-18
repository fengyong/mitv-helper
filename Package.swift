// ⚠️ SUPERSEDED — 本项目改用 Makefile 构建（见 Makefile）。此文件保留仅为记录，勿使用勿修改。
// 原因：swift.org 5.9 工具链与 CLT 10.15 SDK 模块不匹配（编译病态慢）；系统 Swift 5.1 与 SDK 匹配、秒级。
// swift-tools-version:5.9
// MiTV Helper — MiTVCore（引擎/模型/编解码）+ MiTVApp（macOS 客户端）+ mitvctl（无头 CLI 测试工具）
import PackageDescription

let package = Package(
    name: "MiTVHelper",
    platforms: [
        .macOS(.v10_15)
    ],
    targets: [
        // 共享核心：契约文件（Models / TransferEngine / NameCodec）由主控维护，agent 不得改动
        .target(name: "MiTVCore"),
        // 传输引擎实现（Agent A 所有）
        .target(name: "MiTVEngine", dependencies: ["MiTVCore"]),
        // macOS 客户端 UI + 应用服务层（Agent B 所有）
        .target(name: "MiTVApp", dependencies: ["MiTVCore", "MiTVEngine"]),
        // 无头 CLI：引擎端到端冒烟（Agent A 所有）
        .target(name: "mitvctl", dependencies: ["MiTVCore", "MiTVEngine"]),
        .testTarget(name: "MiTVCoreTests", dependencies: ["MiTVCore"]),
    ]
)
