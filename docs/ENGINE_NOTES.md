# MiTVEngine 实现笔记（Agent A）

> 面向主控与后续维护者：SwiftFTPEngine 的关键设计决策、实测发现与已知边界。
> 契约见 `docs/ARCHITECTURE.md` §5；接口以 `Sources/MiTVCore/TransferEngine.swift` 为准（未改动）。

## 1. 结构

| 文件 | 内容 |
|---|---|
| `FTPSocket.swift` | POSIX BSD socket 封装：非阻塞 connect + poll 做连接超时；SO_RCVTIMEO/SO_SNDTIMEO 做读写超时；SO_NOSIGPIPE；半关（SHUT_WR）通知上传结束。只用 Foundation/Darwin，**未 import AppKit / Network.framework**（CLI 目标约束） |
| `FTPControlConnection.swift` | 控制连接（GBK 编码、多行响应 `ddd-` 容错、严格 PASV）、`FTPPASVParser`、`FTPErrorMapper`（550/530/502/421 → EngineError 规约映射）、`FTPPath` 工具 |
| `ListParser.swift` | `FTPListParser`（unix ls-l 为主，Windows 兜底，裸文件名/无日期/多空格名容错）+ `FTPMLSDParser` |
| `TransferPlanner.swift` | `FTPTransferPlanner.resumeOffset`（APPE 续传偏移纯函数）+ `FTPProgressThrottler`（≥100ms 节流） |
| `SwiftFTPEngine.swift` | TransferEngine 契约全实现；256KB 块传输；每块检查 `handle.isCanceled`；completion/onProgress 一律 `DispatchQueue.main.async` |
| `CapabilityProbe.swift` | 8 项探测；临时文件 `mitv-probe-*` 前缀、结束全清（DELE×N + RMD 兜底）；单项失败不中断探测 |

## 2. 关键决策

- **连接模型**：每次引擎调用自建控制连接、用完 QUIT（契约「干净失败」）；断线重连归服务层（Agent B 心跳）。
- **编码**：控制通道与文件名**恒定 GBK（windowsCP936）发信道**。`Capabilities.utf8Filenames=true` 只作为信息上报（契约方法签名无编码参数，引擎不缓存探测结果——若未来要按探测结果切换，需要 [CONTRACT-REQUEST] 增加 API）。
- **续传**：`resume=true` → 先 SIZE；远端 >0 且 ≤ 本地 → 本地 seek + APPE；APPE 被拒（502）自动回退整传（发生在 150 之前，未发数据，安全）。REST 仅探测用，绝不用于续传。
- **list**：MLSD 优先（精确 size/mtime），失败（502/500/550）自动回退 LIST。
- **取消**：数据连接先关，服务器自行终止（426 留在控制缓冲，QUIT 时吸收），以 `EngineError.aborted` 收尾；取消后服务器侧保留已传部分，恰好是 APPE 续传的续点。
- **downloadPrefix（契约修订 2026-11-19）**：RETR 后读够 maxBytes 即断数据连接（不等 EOF、不校验 226，426 由 QUIT 吸收）——服务层上传重名的「相同文件」判定用（比对前 10MB 指纹）。
- **重名策略（服务层规约，2026-11-19）**：净化名（GBK 可表示 + 文件系统安全字符，风险字符→"-"，去尾部空格/点）→ 远端同名先比尺寸再比前 10MB 指纹（小文件即全文件 md5）→ 相同文件跳过上传；不同文件改名 `原名-<md5前8>.ext`；判定不了（前缀拉取失败）保守改名，绝不覆盖；同名/顺延判定一律大小写不敏感（U 盘多为 FAT/exFAT）。已知边界：前 10MB 相同且尺寸相同的不同文件会误判跳过（现实概率极低，卡片有「已跳过」提示兜底）。
- **progress**：≥100ms 节流 + 成功结束强制一次最终进度；速度为 0.6/0.4 平滑的滑动采样。

## 3. 实测发现（本机，影响 E2E 设计）

1. **本机 APFS 拒绝非 UTF-8 字节文件名**（OS 层 EILSEQ，Errno 92）——GBK 字节名无法直接落盘，与电视端行为（自有存储可收 GBK 字节）不同。
2. **pyftpdlib 2.2.0 默认 `unicode_errors="replace"`** 且命令解码编码可配。E2E 用 `handler.encoding="gbk"`：引擎发 GBK 字节 → 服务端解码为真实中文 → os 层按 UTF-8 落盘 → LIST 再按 GBK 编码返回。与真机「GBK 控制通道 + 服务端自有存储」语义等价，GBK 往返（上传/列表/下载/SIZE/APPE/改名）全程字节级验证通过。
3. 老 Swift 5.1 `-O` 曾出现越界读引发的段错误（`outlined init with copy of FTPFileEntry` + swift_retain 崩溃），根因是解析器对首字符为 `b` 的裸文件名行（如 `backup.mp4`）误判为块设备导致数组越界——已修（单 token 行/首字符非类型位 → 裸文件名分支）。`-O` 构建现已稳定全绿。

## 4. 错误映射规约（实现于 FTPErrorMapper）

| 服务器响应 | EngineError |
|---|---|
| 550/553 + "permission/denied/not allowed/forbidden" | permissionDenied |
| 550/553 + "not found/no such/…"/读路径默认 | remoteNotFound |
| 550/553 + 写操作默认（STOR/APPE/MKD/RNTO/RMD） | permissionDenied（如 SwiFTP MKD 550） |
| 550/553 + DELE 无关键词 | ioError（文件可能还在；落 remoteNotFound 会被补删 tolerateMissing 误计删成功） |
| 530/531 | authFailed |
| 500/501/502/504 | unsupported(cmd) |
| 421/425/426/其余 4xx | connectionFailed |
| 552 | ioError（存储超限） |
| 其余 5xx | protocolError(code, text) |

## 5. 已知边界 / 遗留

- 探测 `utf8Filenames` 与 GBK 恒定发送的矛盾：真机 SwiFTP 上 UTF-8 试写读回**会**通过（服务器按字节透传），但电视端播放器按 GBK 显示会乱码——按契约「探测通过才切换」实现，**引擎默认恒 GBK**，故实际不受影响；该探测位由服务层自行解读。
- 550 的 remoteNotFound vs permissionDenied 靠响应文本关键词判别，遇到非英文响应可能落入默认分支。DELE 的默认分支为 ioError（fail-safe：补删宁可保留登记重试，不误报已删）；读路径默认仍 remoteNotFound。
- 断点续传只覆盖单文件内偏移（SIZE+APPE）；队列级状态恢复归 UI/服务层（V1 优先级低）。
- Makefile test 目标追加了 `$(ENGINE)`（见 commit 068bdc7 的 [CONTRACT-REQUEST]）：EngineTests_A 需要引擎纯逻辑源码参与单模块编译。

## 6. 验证状态

- `make test`：83 项检查全绿（NameCodec + EngineTests_A，`-O` 构建）。
- `make cli` / `make typecheck`：通过。
- `scripts/ftp_e2e.sh`：34/34 全绿（两连跑确认稳定），全绿时自清理工作目录。
- 手工冒烟：对 GBK 模式 pyftpdlib 完整跑过 ping/probe/list/upload(--progress)/download/resume/delete/move/mkdir 与错误路径（550 映射、退出码）。
- 真机（192.168.31.171:2121 SwiFTP）未验证——需要电视在场，留给主控集成阶段。
- 真机回归（2026-11-20，电视在场）：ping/probe、GBK 中文目录 `/电视剧` 列表+上传+下载字节级往返、引擎 GBK 删除、MKD 根+嵌套、APPE 真实追加（MITVBBBB）、探针零残留——全过。响应谱：DELE 成功 250 "File successfully deleted"；DELE 缺失 **450** "Error deleting file"；RNFR 缺失 450；LIST/STOR 缺目录 550 "Can't CWD to invalid directory"；SIZE 缺对象 550 nonexistent；SIZE 含 `/` 路径 550 traversal。
- **G1/G2 待修**（真机发现，见 ARCHITECTURE §2）：SIZE 发绝对路径真机恒 550 → sizeCommand/appeResume 误探 false、续传降级整传；DELE/RNFR 失败 450 映射 connectionFailed → tolerateMissing 真机失效。修复前真机续传与补删容忍不可用。
