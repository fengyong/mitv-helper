# MiTV Helper 深度 Review（第 4 轮）· 2026-11-22

- **对象**：main @ 13a5caf（build 4，直删重构 + G1/G2 + 上传目标目录合并后），全量源码 ~10,000 行（MiTVCore / MiTVEngine / MiTVApp / mitvctl）。
- **方法**：三轮走查——①引擎/核心层逐文件（协议正确性、错误映射、超时与线程契约）；②App 服务层逐文件（队列状态机、调度竞态、持久化、删除编排）；③UI 层逐文件（状态可见性、术语合规、交互手感）。随后对确认的缺陷直接修复并补测试。
- **验证基线**：修复前 `make test` 414 项全绿；修复后 430 项全绿 + `make typecheck` 通过 + build 5 真机路径冒烟（见 §3）。
- **约定**：本轮为「review + 直接优化」；未经同意不对真实电视实测（沿用既定边界），全部结论以代码与离线/Mock 证据支撑。

---

## 0. 总体评价

代码质量显著高于 11-19 首轮评审时：三轮评审的多数 D 系列问题已随直删重构与 G1/G2 修复闭合；协议层对 SwiFTP 怪癖（SIZE 拒绝含 `/`、450 泛化文本、MKD 随机开关）的错误映射是 fail-safe 方向；队列层对异步 hop 竞态（过期 inflight、已完成兄弟项盲区、批次通知重武装）防御完备。界面零术语原则执行到位（无 FTP/主机/端口字样），拖放/照片库/断线黄条/强确认删除的主路径完整。

本轮新发现集中在**「电视不在线」这一最高频故障模式的服务层语义**上：断线自动暂停的承诺在两个边界场景没有兑现（详见 A1/A2）。

---

## 1. 已修复（本轮 5 项）

### A1 · P1 · 启动恢复项不等连接就绪直接抢跑，电视离线时整队判失败

- **位置**：`Sources/MiTVApp/QueueService.swift` init（原恢复分支 `stateQ.async { notifyChange(); scheduleIfNeeded() }`）+ `Sources/MiTVApp/AppCoordinator.swift` connect 成功分支。
- **证据链**：`resumeOnStart=true` 时恢复项立即进入调度 → `beginTransfer` 对 stale endpoint 发起 LIST/上传；此时心跳尚未启动（`connect()` 的 `probeCapabilities` 未返回则 `heartbeat.start()` 不执行），断线黄条/自动暂停完全不在场。启动时电视关机（上次退出最常见的原因）→ 每项 6s 连接超时 → 全部落 `.failed`，用户面对一排「发送失败 · 连接电视失败」且无「全部重试」。同时恢复项的上传与能力探测并发建连，挤占嵌入式服务器的有限连接（缩略图层都因此限 2 路，见 `TVFileService.thumbMaxActive`）。
- **修复**：恢复存在待传项时置 `hold = .disconnected`（等待连接），`connect()` 成功后调用新增的 `queue.connectionReady()` 放行——顺带保证恢复上传在能力探测完成之后才开始。`autoResumeAfterReconnect()` 改为 `connectionReady(onlyIfHeld: true)` 的语义等价封装，心跳路径行为不变。
- **测试**：`testStartupWaitsForConnection`（预置 queue.json → 断言连接就绪前 0 次 upload/LIST、项保持 queued → `connectionReady()` 后完成）。
- **冒烟**：build 5 + 隔离数据目录（`MITV_DATA_DIR`）+ 不可达端点 192.0.2.1 两轮启动：遗留项始终 `queued`（queue.json 落盘验证），快照显示胶囊「连接不上 · 点此重连」、摘要「等待连接电视 · 连上后自动开始」。修复前该场景必为 failed。

### A2 · P2 · 连接类失败项重连后不自动重试，与「断线自动等待重连并从断点继续」原则相悖

- **位置**：`Sources/MiTVApp/QueueService.swift`（`finishWithEngineError` / `autoResumeAfterReconnect`）+ `Sources/MiTVApp/QueueModel.swift`（`QueueItem`）。
- **证据链**：心跳判掉线需连续 2 次 NOOP 失败（≥20s 窗口，`HeartbeatService.handleResult`）；窗口期内引擎 socket 超时先到 → `connectionFailed` → 项落 `.failed`。随后黄条出现、重连成功，`autoResumeAfterReconnect` 只恢复 `.paused && autoPaused`——failed 项无人接管，用户须逐项右键重试。产品原则 4（PRODUCT_DESIGN §3）明示「断线自动等待重连并从断点继续」。
- **修复**：`QueueItem` 新增 `connectionDropped: Bool?`（Optional，旧 queue.json 缺 key 解码为 nil，向后兼容已测）；`finishWithEngineError` 对 `EngineError.connectionFailed` 置位；`connectionReady` 把 `failed + connectionDropped` 的项按 `.retry` 重排（走既有 `remotePath != nil` 分支 → APPE 续传）。`QueueStateMachine.retry` 顺带清标记。非连接类失败（磁盘满/写拒绝）不自动重试，保留用户决策权。
- **测试**：`testReconnectAutoRetryDropped`（connectionFailed → 断线 → 重连 → 自动重试完成且 `resume=true`；ioError 失败 → 重连 → 不重试）。`testQueueItemCodableRoundTrip` 增补字段 round-trip + 旧 JSON 兼容断言。

### B1 · P2 · 队列页摘要在「全部暂停」时误显「全部完成」

- **位置**：`Sources/MiTVApp/QueueView.swift` reload 摘要分支。
- **证据链**：原逻辑 `busy(空) → active 无 isBusy 项 → snapshot 非空 → "全部完成"`。用户「全部暂停」、或断线暂停（`autoPauseForDisconnect` 对 queued 也暂停，全队无 isBusy 项）时，顶部摘要显示绿色完成语义，与卡片上的黄色暂停条直接矛盾。
- **修复**：摘要分支重排——优先识别 paused：任一 `autoPaused` →「电视连接不上 · 传输已暂停，重连后自动继续」；否则 →「已全部暂停」；queued 等待连接 →「等待连接电视 · 连上后自动开始」；其余才落「全部完成/队列为空」。冒烟快照已验证新文案（见 A1）。

### B3 · P3 · 批量删除无进度反馈

- **位置**：`Sources/MiTVApp/AppCoordinator.swift` deleteRemote（原 progress 回调传空闭包 `{ _, _, _ in }`）。
- **证据链**：`TVFileService.deleteEntries` 每项新建一个 FTP 连接做 DELE（嵌入式服务器 RTT + 建连成本），50 项删除约 10s+，期间只有开头一条「正在移除 50 项…」，用户感知为卡死。
- **修复**：progress 回调接入 toast，`total > 3` 且距上次 ≥1s 才更新（防刷屏）；完成 toast 自然替换进度 toast。

### B5 · P3 · 过期注释

- `Sources/MiTVApp/MockEngine.swift` MockEngineFactory 注释称「默认 true」，实际 `useMockEngine` 默认 false（`AppCoordinator.startup` 注册 + `EngineHolder` init）。已按事实改写。

---

## 2. 记录在案、本轮不改

| 项 | 位置 | 说明 | 不改的理由 |
|---|---|---|---|
| D9 · `utf8Filenames` 未接线 | `SwiftFTPEngine` 恒用 GBK Config | 探测位从未反馈到引擎编码 | 目标电视（SwiFTP）GBK 全通；切换 UTF-8 的收益仅限其他服务器，且需真机验证，风险大于收益 |
| `SmartRouting.remoteTarget` 大小写敏感 | `SmartRouting.swift:23` | `uniqued` 未传 `caseInsensitive`，与生产路径（`beginUpload`/`commitFallbackUpload` 均 caseInsensitive）不一致 | 仅测试引用、未接线生产；改动会动测试基线，收益为零，列为潜在误用点警示 |
| NSUserNotificationCenter deprecated | `AppCoordinator.postSystemNotification` | SDK 10.15 无替代 API | 平台约束，bundled 场景工作正常 |
| 向导昵称硬编码「客厅电视」 | `OnboardingOverlay.connectTapped` | 重连向导每次覆盖 tvName | v1 无改名入口属产品范围，非缺陷 |
| `MockEngine.download` 64MB 分支两臂相同 | `MockEngine.swift:189-193` | 死分支 | 仅测试引擎，无行为影响 |

---

## 3. 验证记录

| 项 | 结果 |
|---|---|
| `make test`（修复前基线） | 414 全绿 |
| `make test`（修复后） | **430 全绿**（新增 2 个测试函数 + round-trip/旧 JSON 断言） |
| `make typecheck` | 通过（AppKit/Photos/AVFoundation 全目标） |
| `make app` | build 5 产出 |
| 冒烟（`MITV_DATA_DIR` 隔离 + 不可达端点 + 预置遗留队列，两轮启动） | 遗留项保持 queued 不判失败；快照核对：胶囊/卡片/摘要/状态栏文案全部符合预期 |

## 4. 本轮改动清单

- `Sources/MiTVApp/QueueModel.swift` — `connectionDropped` 字段 + retry 清除
- `Sources/MiTVApp/QueueService.swift` — 启动恢复 hold、`connectionReady()`/`autoResumeAfterReconnect()` 重构（保留 `.user` hold 不被重连悄悄解除）、连接失败标记与自动重试
- `Sources/MiTVApp/AppCoordinator.swift` — connect 成功 → `queue.connectionReady()`；删除进度 toast
- `Sources/MiTVApp/QueueView.swift` — 摘要暂停态分支
- `Sources/MiTVApp/MockEngine.swift` — 注释修正
- `Sources/MiTVApp/BuildInfo.swift` — build 5
- `Tests/MiTVCoreTests/ServiceTests_B.swift` — `testStartupWaitsForConnection` / `testReconnectAutoRetryDropped` / Codable 兼容断言 / `InlineEngine.failUploadsError` 注入点
