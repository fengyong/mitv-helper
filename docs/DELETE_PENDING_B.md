# DELETE_PENDING_B —— Agent B 新建临时文件清单（按规约追加，勿改动他人条目）

> 规约：禁止删除本地文件；新建临时文件记录于此。合并收尾时由主控统一裁决去留。

## 1. 代码内符号链接（Tests/MiTVCoreTests/，随分支提交）

- `Tests/MiTVCoreTests/QueueModel.swift` → `../../Sources/MiTVApp/QueueModel.swift`
- `Tests/MiTVCoreTests/QueueService.swift` → `../../Sources/MiTVApp/QueueService.swift`
- `Tests/MiTVCoreTests/SmartRouting.swift` → `../../Sources/MiTVApp/SmartRouting.swift`
- `Tests/MiTVCoreTests/SoftDeletePolicy.swift` → `../../Sources/MiTVApp/SoftDeletePolicy.swift`
- `Tests/MiTVCoreTests/TVStore.swift` → `../../Sources/MiTVApp/TVStore.swift`

**原因**：Makefile 的 `test` 目标只编译 `$(CORE) $(TESTS)`，不含 `Sources/MiTVApp`；
B 的 DoD 要求 ServiceTests_B 覆盖队列状态机/智能分流/软删除决策/TVStore round-trip（都是真实实现）。
用符号链接让测试目标编译这几个纯逻辑文件（make 的 wildcard 会匹配指向存在文件的符号链接，已验证）。

**[CONTRACT-REQUEST]**（已随 commit 提出）：请在主控合并时把 `Sources/MiTVApp/` 下的这几个纯逻辑文件
（QueueModel / QueueService / SmartRouting / SoftDeletePolicy / TVStore）纳入 `build/test-runner`
的依赖与编译列表；完成后上述符号链接即可删除（届时本节条目作废）。

## 2. 冒烟辅助设施（留在代码里，不影响正常使用）

AppCoordinator 里的环境变量钩子（`MITV_*`），用于无头/无辅助权限环境下的 GUI 自动验证：
`MITV_SNAPSHOT`（离屏渲染窗口为 PNG，走 AppKit cacheDisplay，不依赖屏幕录制权限）、
`MITV_AUTO=browser`、`MITV_AUTO_SEL`、`MITV_AUTO_CONFIRM`、`MITV_AUTO_DELETE`、
`MITV_AUTO_UNDO_INPLACE`、`MITV_AUTO_UNDO`、`MITV_AUTO_ENQUEUE`、`MITV_AUTO_DROP`（心跳断线演练）。
不带这些环境变量时行为与正常使用完全一致。可随冒烟收尾移除。

## 3. /tmp 临时产物（不进仓库，可删）

- `/tmp/mitv-smoke/` —— 冒烟工作目录：样例媒体文件（big1.mp4/big2.mkv/pic.jpg）、
  截图 01-onboarding / 02-empty / 03-queue-running / 04-completed / 04b-collapsed /
  05a-before-kill / 05b-restored / 06-browser / 07-selected / 08-confirm /
  10-deleted-toast / 11-undone / 12-undo-inplace / 13-banner / 14-trash-chip、
  full-probe.png（screencapture 失败探针）、tv.json.seeded、各 applog/sample 日志
- `/tmp/guitest.swift` `/tmp/guitest` `/tmp/mainclass/` `/tmp/t.swift` `/tmp/tr1` `/tmp/tr2` `/tmp/tr3`
  `/tmp/tr*.err` `/tmp/tr3.typescript` —— Swift 5.1 行为验证与崩溃定位用的手工编译产物，可删

## 4. 运行时数据（不在仓库内，仅为记录；删除后应用回到首次运行状态）

- `~/Library/Application Support/MiTVHelper/`（tv.json / queue.json / trash.json / Staging/）
  注意：冒烟时预置了演示版 tv.json（endpoint=192.168.31.171 + onboardingDone=true），
  想让用户走真实首连向导，删掉该 tv.json 即可
- `~/Library/Caches/MiTVHelper/Thumbs/` —— 浏览缩略图缓存（可删，自动重建）

## 5. 冒烟结论（验证记录）

- `make test`：NameCodecTests + ServiceTests_B 共 94 checks 全绿
- `make typecheck` / `make app` / `make appbundle` 全部通过
- `open dist/MiTVHelper.app` 启动正常、退出干净（进程确认）
- 状态链路截图验证：向导 → 空态 → 队列假进度（速度/剩余/智能分流 Movies/）→ 完成折叠组 →
  kill -9 后重启队列恢复（queue.json 断点字节保留）→ 浏览网格 → 多选+毛玻璃操作条 →
  删除确认浮层（软删除文案）→ 删除 toast+回收站角标 → 同进程撤销还原 → 断线黄条+胶囊重试计数
- 本机 screencapture 无「屏幕录制」权限（TCC），改用 AppKit cacheDisplay 离屏截图方案（见 §2）
