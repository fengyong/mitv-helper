# DELETE_PENDING_B —— Agent B 新建临时文件清单（按规约追加，勿改动他人条目）

> 规约：禁止删除本地文件；新建临时文件记录于此。合并收尾时由主控统一裁决去留。

## 代码内符号链接（Tests/MiTVCoreTests/，随分支提交）

- `Tests/MiTVCoreTests/QueueModel.swift` → `../../Sources/MiTVApp/QueueModel.swift`
- `Tests/MiTVCoreTests/QueueService.swift` → `../../Sources/MiTVApp/QueueService.swift`
- `Tests/MiTVCoreTests/SmartRouting.swift` → `../../Sources/MiTVApp/SmartRouting.swift`
- `Tests/MiTVCoreTests/SoftDeletePolicy.swift` → `../../Sources/MiTVApp/SoftDeletePolicy.swift`
- `Tests/MiTVCoreTests/TVStore.swift` → `../../Sources/MiTVApp/TVStore.swift`

**原因**：Makefile 的 `test` 目标只编译 `$(CORE) $(TESTS)`，不含 `Sources/MiTVApp`；
B 的 DoD 要求 ServiceTests_B 覆盖队列状态机/智能分流/软删除决策/TVStore round-trip（都是真实实现）。
用符号链接让测试目标编译这几个纯逻辑文件（make 的 wildcard 会匹配指向存在文件的符号链接）。
**[CONTRACT-REQUEST]**（已随 commit 提出）：请在主控合并时把 `$(wildcard Sources/MiTVApp/*.swift)` 中
的这几个纯逻辑文件（或加一个 `TESTABLE` 变量）纳入 `build/test-runner` 的依赖与编译列表；
完成后上述符号链接即可删除（届时此文件条目作废）。

## /tmp 临时产物（不进仓库）

- `/tmp/tr1` `/tmp/tr2` `/tmp/tr3` `/tmp/tr1.err` `/tmp/tr2.err` `/tmp/tr3.typescript` —— 崩溃定位用的手工编译产物，可删
- `/tmp/mitv-smoke-*.png` —— GUI 冒烟截屏（验证记录，可删）
- `/tmp/mitv-thumb-cache-*` —— 浏览态缩略图临时缓存（可删）

## 运行时数据（不在仓库内，仅为记录）

- `~/Library/Application Support/MiTVHelper/`（tv.json / queue.json / trash.json / Staging/）—— app 正常运行数据
- `~/Library/Caches/MiTVHelper/`（Thumbs/）—— 浏览缩略图缓存
