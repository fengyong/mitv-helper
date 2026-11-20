# 开发笔记 · 上传可指定存放位置（无人值守实现）

DEV-NOTES-STATUS: DONE

- 分支：`feat/upload-target`（自 main `7d7d8a5` 切出，未合并、未 push）
- 需求唯一依据：`docs/20261119_design_upload_target.md`（v2，D1–D7 闭合）
- 契约：`docs/ARCHITECTURE.md`——Swift 5.1（无 async/await / @main / resultBuilder）、GCD 回调、单模块编译（跨目录不写 import）、契约文件未动（`Sources/MiTVCore/*`、`Makefile`、`packaging/Info.plist` 零改动，无 [CONTRACT-REQUEST]）
- 无人值守纪律遵守：全程未提问；无权限拒绝/护栏拦截事件；无删除/reset/clean 破坏性操作；未跑 `make app`（`BuildInfo.swift` 零改动，构建号未自增）

## Commit 清单（main..feat/upload-target，7 个）

| hash | 内容 |
|---|---|
| `3095e3f` | feat: 存放位置持久化层——tv.json 双字段 + 队列项批级目标 |
| `b88e273` | feat: 队列两层目标解析与指定目录失效降级 |
| `b308b8e` | feat: 「选择存放位置」弹窗——模式单选 + 目录浏览 + 最近快切 + 新建文件夹按 mkdir 门控 |
| `3398378` | feat: 存放位置常驻 chip + 协调器装配（全局指定注入队列 / 入队落点 toast / 降级告知） |
| `fcc35fc` | feat: 浏览页「上传到这里」——当前浏览目录为批级目标 |
| `048b1cc` | feat: 设置页「存放位置」区块交互化（与 chip 同源） |
| `aceb015` | fix: 选择器三处走查实测缺陷——documentView 沉底/底行跨分支挂载/mkdir 门控被模式切换覆盖 |

## 自测结果

- `make test`：**392 checks 全绿**（基线 321 + 新增 71；现有用例零改动原样通过）
- `make typecheck`：**0 error**（仅 main 既有 2 条 `reason` 未用变量 warning）
- `make cli`：exit 0
- UI 离屏走查（Sources 直编 /tmp/mitv-walk/MiTVApp，未触 BuildInfo；`MITV_DATA_DIR` 隔离 ×5 目录 + `useMockEngine` + `MITV_AUTO`/`MITV_AUTO_ENQUEUE` + `MITV_SNAPSHOT`）：
  1. `s1` 智能分类 chip「存放位置：智能分类」✓
  2. `s2` 指定模式 chip「存到：庆余年2」（D4 末级名）✓
  3. `s3` 选择器智能模式初始态（浏览区隐藏、确认=使用智能分类）✓
  4. `s3f`/`s4d` mkdir=false 按钮隐藏 / mkdir=true 显示（D1 两态）✓；文件夹行、最近 chips、面包屑、返回、空态 ✓
  5. `s5b` 指定模式入队 toast「1 个文件即将存到 Movies」+ 卡片「将存到 Movies/」+ chip 三处同源落点（D3，边界 #11）✓
  6. `s6` 指定目录失效 → MKD 550 → 回根 + toast「指定的位置已不在电视上，文件已放到电视根目录」+ 卡片「将存到 电视根目录/」（D6 E2E）✓
  7. `s7` 浏览页右下角「上传到这里」常驻按钮、系统目录过滤正常 ✓
- 走查环境清理：`defaults delete MiTVApp useMockEngine` 已执行；快照证据保留在 `/tmp/mitv-walk/`；工作区无杂散改动

## 决策记录（设计未覆盖处，按 PRODUCT_DESIGN §3 原则自行决策）

| # | 决策 | 理由 |
|---|---|---|
| 1 | D3 toast 落点显示去开头斜杠的完整层级（`电视剧/庆余年2`；根目录「电视根目录」） | 文案表全局行写末级名、批级行写完整层级，两行有出入；取与队列卡片「将存到 X/」同源的完整层级，toast/chip tooltip/卡片三处一致且瞬时报文信息更全 |
| 2 | 选择器确认按钮随模式：智能分类 →「使用智能分类」；指定位置 →「使用此位置」 | 文案表的「使用此位置」作用于智能模式语义不通；不引入新概念 |
| 3 | MockEngine.makeDirectory 按 probeMatrix.mkdir 分支（false=原 550 语义不变；true 真建内存目录）+ `MITV_MOCK_MKDIR=1` 冒烟钩子 | 原实现无视矩阵恒失败，D1 两态与 MKD 兜底无法走查；真机语义零变化 |
| 4 | 「上传到这里」放浏览页**右下角**常驻 | 设计稿示意底部居中，与多选毛玻璃操作条（居中弹出）位置冲突；右下角不重叠、无选择时也可用 |
| 5 | 设置页「更改…」先收设置 sheet 再开选择器 | 一个窗口同时只挂一张 sheet；两者同源（D7）无并发诉求 |
| 6 | 降级告知每批至多一次（`fallbackNotifiedBatches` 会话级去重） | 防整批降级 toast 刷屏；已知边界：同批重试再次降级不重复提示（可接受，重试成功路径不受影响） |
| 7 | InlineEngine 增加 `listFailCounts` / `listCalls` 脚本参数 | 「首列失败 → MKD 重建 → 再列成功」需要按路径次数脚本；纯增量不影响既有用例 |
| 8 | 新增冒烟钩子 `MITV_AUTO=location`（打开选择器） | 与既有 `MITV_AUTO=picker/settings/browser` 同型，headless 快照走查依赖 |
| 9 | 选择器布局三缺陷修复（见 aceb015） | 走查实测发现，均为首版实现 bug 而非设计问题 |

## 遗留真机 / 人工验证项

**真机（需电视在场，`192.168.31.171:2121` SwiFTP）** —— 2026-11-20 回归结果见 `docs/ENGINE_NOTES.md` §6 与 `docs/ARCHITECTURE.md` §2
- ~~MKD 550 降级链路实测~~ 复测当前 U 盘 **MKD 允许**（根+嵌套均 257）→ 550 分支真机不可触发，由单测/mock 覆盖；降级链路 MKD 兜底真机可成功
- ~~真机 GBK 中文目录指定与上传往返~~ ✅ 实测过（`/电视剧` 列表解码+上传+下载 cmp 一致+引擎 GBK 删除）
- ~~真机 caps.mkdir=false 隐藏确认~~ 当前电视 mkdir=true → 按钮应**显示**（能力驱动正确）；false 态由 mock 走查覆盖
- ~~上传到这里批级落点真机核对~~ 协议层 ✅（mitvctl upload --to /电视剧 落盘核对）；App 批级 UI 落点仍待人工
- ~~新增待修 G1/G2~~ ✅ 已修（87e1679 / 8e1516b，2026-11-20）：SIZE CWD+裸名、450→ioError+补删 LIST 确认；真机复探与续传链路实测过

**人工（headless 快照覆盖不到的交互/观感）**
- chip 悬停 tooltip 完整层级（D4）；chip 点击打开选择器
- 选择器内交互：目录导航、最近 chips 点击跳转、新建文件夹输入→创建→进入、竞态失败 toast
- 上传到这里 NSOpenPanel 多选/整夹拖入流程；设置页「更改…/恢复智能分类」流程
- 深浅色两种外观下 chip/选择器观感
- 断连状态点 chip 的拦截 toast「先连接电视才能选择存放位置」
- 指定目录失效场景下入队 toast 被降级 toast 顶替的观感（预期行为：更紧急的消息胜出）

**V1.1 备忘（设计稿 defer 项）**：卡片级改位置（D2）、「上传到这里」照片图库入口（D5）。

## 看门狗记录

- 巡检自动化「上传目标目录实现看门狗」（每 15 分钟）全程无接管（heartbeat 持续刷新，无中断发生）
- 收工：本文件状态置 DONE → 删除 `/tmp/mitv-watchdog-lock` → 主会话删除巡检自动化
