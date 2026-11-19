# MiTV Helper · 架构与并行开发契约（ARCHITECTURE.md）

> 本文件是**并行开发的唯一协调依据**。两个 Agent 在各自 worktree 内按本契约开发；契约文件由主控（glm53flash 分支）维护，Agent 不得修改。
> 产品背景与界面设计见 `docs/PRODUCT_DESIGN.md`（rev2 实测修正版）。

---

## 0. 硬性规约（每个 Agent 必读）

1. **工作目录**：只在自己的 worktree 分支工作，绝不触碰其他 worktree / 主检出。
   - Agent A → `/Users/fengyong/drax-glm/mitv-helper-engine`（分支 `glm53flash-engine`）
   - Agent B → `/Users/fengyong/drax-glm/mitv-helper-ui`（分支 `glm53flash-ui`）
2. **禁止删除本地文件**。新建临时文件记录到 `docs/DELETE_PENDING_<A|B>.md`（追加，不改动他人条目）。
3. **完成一部分就 commit**（小步提交，信息格式：`engine: xxx` / `ui: xxx` / `core: xxx`）。禁止 force push，禁止 rebase 他人分支。
4. **契约文件不可改**（见 §3 所有权表）。若契约不满足需求，**不要自行修改**——把需要的变更写进自己的 commit message 末尾 `[CONTRACT-REQUEST] ...`，主控会统一裁决。
5. **每次编译用 `make`**（见 §1）。第一次 `make` 前必须 `source scripts/env.sh`（或直接 make，Makefile 内置了 SDK 与模块缓存路径）。
6. 编译慢（首次 AppKit 模块图 ~90s，之后秒级）——**批量改代码再编译**，不要每写一行就 make。

---

## 1. 环境与构建（已定案，不要另起炉灶）

| 项 | 决定 |
|---|---|
| 编译器 | **系统 Swift 5.1**（`/usr/bin/swiftc`，CLT 自带，与 SDK 10.15 官方匹配） |
| SDK | `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk`（10.15） |
| 目标 | `x86_64-apple-macos10.15`（运行机为 macOS 13.7 Intel） |
| 构建 | **Makefile**（不用 SwiftPM/Xcode；Makefile 已定：`make` = cli+test+app） |
| 模块缓存 | `/tmp/mitv-modcache-51`（Makefile 已带 `-Xcc -fmodules-cache-path`，勿改路径，共享缓存） |
| 语言限制 | **Swift 5.1：无 async/await、无 resultBuilder、无 @main**。一律 GCD + 回调。 |
| 可用框架 | Foundation / AppKit / Network / Photos / AVFoundation（SDK 10.15 内的版本） |
| ⚠️ 没有 | SF Symbols API（macOS 11+ 才有 `NSImage(systemSymbolName:)`）→ 图标用 `NSImage(named:)` 10.15 名字集或自绘；PHPickerViewController（macOS 11+ SDK 声明）→ 照片选择用 **Photos 框架自建网格**（PHPhotoLibrary + PHImageManager + PHAssetResource） |
| 测试 | **轻量自研 runner**（`Tests/MiTVCoreTests/main.swift`，非 XCTest）：`make test`，新套件注册进 `allSuites` 数组 |

**重要**：Makefile 把相关目录的源文件**一次性合并编译为单模块**（如 app 目标 = MiTVCore + MiTVEngine + MiTVApp 源文件一个 swiftc 命令）。所以**跨目录不需要 import**，直接使用类型即可；也不要在自己目录里写 `import MiTVCore`（会编译失败，单模块内无需 import）。

## 2. 电视实测事实（mimo 分支协议级实测，产品设计据此修正）

服务器：SwiFTP 6.0.33 @ `192.168.31.171:2121`，匿名可登录。

| 探测项 | 实测 | 结论 |
|---|---|---|
| REST | **502** | 偏移续传不可用；续传 = SIZE 校验 + APPE 追加 |
| APPE | ✅ 已验证 | STOR 前半 + APPE 后半 = 完整文件 |
| MKD | **550** | 不能建目录 → 目标只能用已有目录：视频 `Movies/`、图片 `Pictures/`、否则根 |
| STOR 现有子目录 | ✅ | 智能分流可行 |
| 文件名编码 | **GBK 全通**（中文/`[]`/空格/全角标点）；UTF-8 写入成功但电视端乱码 | 控制通道与文件名默认 GBK（GB18030 超集），探测通过 UTF-8 才切换 |
| EPSV | ❌ 仅 PASV | 数据连接只用 PASV |
| SIZE | ✅ | 可校验 |
| 大文件 | 5.4GB 无碍 | 无 4GB 限制 |
| DELE / RNFR / RNTO / MLSD | **未实测**（真机响应文本谱待回归） | 引擎已实现；首连探测决定删除策略：DELE 可用→直删+强确认，不可用→禁用（2026-11-19 产品决策：软删除废弃，见 §7） |

## 3. 模块地图与所有权（并行不相交）

| 目录/文件 | 所有者 | 说明 |
|---|---|---|
| `Sources/MiTVCore/*`（Models / TransferEngine / NameCodec） | **主控（契约）** | 两个 Agent 只读，不得修改 |
| `Makefile`、`packaging/Info.plist`、`scripts/env.sh`、`.gitignore` | **主控（契约）** | 只读 |
| `Tests/MiTVCoreTests/main.swift`（runner + NameCodecTests） | 主控 | Agent 可在**自己新文件**里加套件，runner 注册行可以追加（允许追加那一行，其余不动） |
| `Sources/MiTVEngine/**` + `Sources/mitvctl/**` | **Agent A** | FTP 引擎 + 能力探测 + 无头 CLI |
| `Sources/MiTVApp/**` | **Agent B** | AppKit UI + 应用服务层（含 Mock 引擎） |
| `docs/DELETE_PENDING_A.md` / `_B.md` | A / B 各自 | 临时文件清单 |
| `scripts/ftp_e2e.sh`（若 A 需要）、`docs/ENGINE_NOTES.md`（A 的实现笔记）、`docs/UI_NOTES.md`（B 的） | A / B 各自 | 新增文件放自己目录 |

**测试套件归属**：A 的引擎测试写到 `Tests/MiTVCoreTests/EngineTests_A.swift`；B 的服务层测试写到 `Tests/MiTVCoreTests/ServiceTests_B.swift`。各自在 main.swift 的 `allSuites` 数组**追加一行**（唯一允许触碰 contract 文件的点；合并冲突找我裁决）。

## 4. 共享契约摘要（详情读源文件）

- `FTPEndpoint`（host/port/user/password）、`FTPFileEntry`（path/name/isDirectory/size/modified）
- `TransferProgress`（bytes/totalBytes/bytesPerSecond/fraction）、`TransferPhase`（UI 状态机）
- `Capabilities`（8 个布尔探测位）、`EngineError`、`TransferHandle`（cancel()）
- `NameCodec`（GBK 编码判断、emoji 替换、重名顺延）
- `protocol TransferEngine`：ping/list/upload/download/**downloadPrefix**（2026-11-19 契约修订：读远端前 N 字节，重名判定用）/delete/move/makeDirectory/size/probeCapabilities，**全部回调式**，回调统一主队列；progress ≥100ms 节流
- `protocol TransferEngineFactory`：注入用

## 5. Agent A · 传输引擎（Sources/MiTVEngine + Sources/mitvctl）

**目标**：自研最小 FTP 客户端，覆盖契约全部方法 + 能力探测 + 无头 CLI，与本地 FTP 服务器端到端打通（含中文名、APPE 续传、删除/改名）。

**实现建议**（可自行判断，但 PASV/GBK 约束不可违背）：
- 网络：**POSIX BSD socket + 阻塞 I/O 放后台 DispatchQueue**（比 Network.framework 更可控），`SO_RCVTIMEO/SO_SNDTIMEO` 做超时；控制连接一条 + PASV 数据连接按需
- 控制通道编码：发命令前用 `NameCodec.gbkEncoding` 编码（UTF-8 探测通过时切换）；LIST 响应按同样编码解码
- LIST 解析：unix `ls -l` 风格 + Windows 风格兜底 + "无 size" 容错；`MLSD` 探测通过则优先
- 上传循环：读 256KB 块 → STOR/APPE socket 写 → 检查 `handle.isCanceled` → 节流 progress；下载对称
- APPE 续传（resume=true）：先 `SIZE remote`，>0 且 ≤ 本地大小 → seek 本地文件到该偏移 + `APPE`；否则整传
- `probeCapabilities`：对远端根做全部 8 项探测，临时文件用 `mitv-probe-*` 前缀，**结束后清理**（探测 DELE/RNTO 用的测试文件也删掉）
- 断线重连属于服务层（Agent B 心跳+退避），引擎只保证「每次调用自建连接、干净失败」

**mitvctl CLI**（无头验证，主控集成时要用）：
```
mitvctl ping   --host H [--port P]
mitvctl probe  --host H                 # 打印能力矩阵 JSON
mitvctl list   --host H --path /Movies
mitvctl upload --host H --file F --to /Movies/a.mp4 [--resume] [--progress]
mitvctl download --host H --from /Movies/a.mp4 --to F
mitvctl delete --host H --path P
mitvctl move   --host H --from A --to B
mitvctl mkdir  --host H --path P
```
退出码 0 成功；错误打印到 stderr 退出非零。

**E2E 测试（必须）**：写 `scripts/ftp_e2e.sh`：用 pip 安装 pyftpdlib（`pip3 install --user pyftpdlib`，网络可用；装完记录进 DELETE_PENDING_A.md），在 `127.0.0.1:2122` 起一个**允许删除/改名/MKD**的匿名 FTP 服务器（工作目录 /tmp/mitv-e2e-<pid>/remote，预置含中文名的文件），跑 `mitvctl` 全命令冒烟 + 中文文件名 + APPE 续传模拟（STOR 一半、SIZE 校验、APPE 补齐、结果与原文件 diff 一致）。脚本退出码代表结果。
**注意**：pyftpdlib 不支持 GBK 文件名场景——GBK 编码发送的文件名在 pyftpdlib 看来是原始字节，路径含这些字节即可往返，用 `curl` 命令行验证一次读回名字一致即可，不强求 pyftpdlib 侧解码正确。
**EngineTests_A.swift**：离线单测（LIST 解析、PASV 响应解析、命令编码、APPE 偏移计算、进度节流），不依赖网络。

**DoD**：`make test`（含 A 套件）全绿 + `make cli` 通过 + `scripts/ftp_e2e.sh` 全绿 + 至少 5 个小步 commit。

## 6. Agent B · AppKit UI + 服务层（Sources/MiTVApp）

**目标**：完整可运行的 Mac 客户端（对 Mock 引擎），实现产品设计的全部界面与交互，上传队列状态机 + 持久化 + 照片选择器 + 拖拽 + 浏览/多选删除。

**结构建议**（可自行拆文件，全部放 Sources/MiTVApp/）：
- `main.swift`：NSApplication 装配（替换现有 stub）+ AppDelegate（application(_:openFiles:) 收 Dock 拖放的文件 → QueueService）
- `UI/MainWindow.swift`：880×560 NSWindow，`NSVisualEffectView`（.sidebar 材料）打底；三态容器（空态拖放区 / 队列卡片流 / 电视文件浏览网格）用 NSViewController 切换
- `UI/DropZoneView.swift`：空态大拖放区（虚线圆角框、一句话引导），`registerForDraggedTypes([.fileURL])`，全窗口皆可落
- `UI/QueueView.swift` + `UI/QueueCardView.swift`：缩略图（照片 NSImage / 视频 AVAssetImageGenerator 首帧）+ 文件名 + 自绘细进度条（accent 色）+ 速度/剩余时间 + 悬停操作（暂停/取消/重试）；完成 10s 收进「已完成」折叠组
- `UI/PhotoPickerView.swift`：Photos 框架自建网格（PHPhotoLibrary 授权 → PHAssetCollection cameraRoll → PHFetchOptions 按 creationDate 倒序 → NSCollectionView 网格，PHImageManager.requestImage 400px 缩略）；多选（⌘点击/框选/悬停勾选）；「添加 N 张」→ PHAssetResource 导出**原文件**到 StagingStore（iCloud 原件 `isNetworkAccessAllowed=true`），导出进度可见
- `UI/FilePickerView.swift`：NSOpenPanel 封装（默认 ~/Downloads，记住上次目录；选文件夹时递归展开媒体文件）
- `UI/TVBrowserView.swift`：电视 U 盘网格（图标+名字，按目录层级浏览返回）；多选（同交互）；底部毛玻璃操作条 `已选 N 项 · X MB [下载] [删除] ✕`；删除走 §7 直删+强确认；可选「删除前先下载到本地」兜底
- `UI/OnboardingView.swift`：三步首连向导（§产品文档 6.2）；`UI/SettingsView.swift`：一页设置
- `Services/TVStore.swift`：endpoint + capabilities + 上次目录持久化（`~/Library/Application Support/MiTVHelper/`，JSON 原子写）
- `Services/QueueService.swift`：任务状态机（queued/connecting/running/paused/failed/completed/canceled）、并发 2（OperationQueue maxConcurrentOperationCount）、持久化（JSON，每次变更原子写、启动恢复）、重试（失败项右键重试）
- `Services/HeartbeatService.swift`：10s NOOP，两连失败 → 掉线（黄条 + 队列暂停）→ 指数退避重连 5s/15s/30s…120s 封顶，重连成功恢复队列
- `Services/PickService.swift`、`Services/StagingStore.swift`、`Services/TVFileService.swift`（浏览/删除/删除前先下载编排）
- `Testing/MockEngine.swift` + `Testing/MockFactory.swift`：实现 TransferEngine 协议——可脚本化：list 返回预置目录树（含中文名文件）、upload 按 4MB/s 假进度走完全程、delete/move 落内存记账、probe 返回「GBK + APPE + 无 MKD + rename 可用」矩阵。**App 默认用 Mock（UserDefaults 键 `useMockEngine`，默认 true）**，主控集成时切真实引擎。
- 智能分流（上传前定目标路径）：查远端列表（engine.list "/"）→ 视频→`/Movies/<GB名>`、图片→`/Pictures/<GB名>`、都没有→`/<GB名>`；卡片显示「将存到 …」。命名策略（2026-11-19 定案）：原名尽可能保留，特殊字符替换 "-"；远端同名 → 比尺寸 + 前 10MB 指纹，相同文件跳过上传，不同文件改名 `原名-<md5前8>.ext`（判定不了保守改名，不覆盖）

**AppKit 手法约束**（无 SwiftUI）：NSVisualEffectView 毛玻璃；自绘进度条（NSView draw + NSSetDisplaysWhenDrawing）；动画 NSAnimationContext；深浅色自适应跟系统；留白大方；**绝不出现 FTP/端口/主机等术语**。
**DoD**：`make app` 编译通过 + `make test`（含 B 套件）全绿 + 启动后三态可切（Mock 下可见完整流程）+ 队列持久化重开恢复 + ServiceTests_B 覆盖（状态机/分流/删除决策 hard-disabled/持久化 round-trip）+ 至少 5 个小步 commit。

## 7. 删除决策表（B 的 TVFileService 按 Capabilities 分支；2026-11-19 产品决策：直删，软删除/回收站/撤销废弃）

| Capabilities.deleteFile | 行为 |
|---|---|
| true | 直删 DELE + 强确认文案「永久删除，无法撤销」+ 可选「删除前先下载到本地」兜底（取回登记持久化，取回全成功后自动续删；未全成功暂停删除并提示） |
| false | 删除按钮禁用 + 提示「这台电视不支持删除」 |

`SoftDeletePolicy.trashRoot` / `prefixTag` 仅保留为**旧版本残留的浏览过滤**（旧版软删除残留仍可能在电视上，浏览页隐藏）；不再新写回收站、无撤销。DELE 无关键词响应映射 ioError（fail-safe：文件可能还在，不误计已删）。

## 8. 优先级（用户明示）

**高**：连接/向导、拖拽入队、照片选择、上传+进度、GBK 原名、智能分流、多选删除、浏览。
**低（本轮不做深度）**：断点续传的完整 UI/状态恢复（引擎侧 APPE 支持保留即可，UI 只需不破坏）。
**不做**：格式转码、自动发现、旧版回收站残留自动清理（现仅浏览过滤）。

## 9. 集成计划（主控负责，agents 完成后）

1. merge 两分支 → glm53flash（契约文件无冲突预期；main.swift allSuites 追加行冲突主控手工合并）
2. MiTVApp 工厂切换：默认 `useMockEngine=false` 接 SwiftFTPEngine
3. `make` 全绿 → `make appbundle` → `open dist/MiTVHelper.app` 冒烟
4. `mitvctl` 对 pyftpdlib E2E → （用户在场时）对真实电视 192.168.31.171:2121 实测
5. 收尾：DELETE_PENDING 合并、修订记录、最终 commit
