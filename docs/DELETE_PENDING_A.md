# 待删除清单 · Agent A（引擎）（开发完成后清理）

> 规则：开发期间**不删除任何本地文件**；临时产物记录于此，开发完成后一次性清理。

| 路径 | 说明 | 大小 | 创建日期 |
|---|---|---|---|
| `~/.pyenv (pip3 --user pyftpdlib)` | 本地 FTP 测试服务器依赖（E2E 用，`pip3 install --user --index-url https://pypi.org/simple pyftpdlib`，装的是官方源因为 pyenv 默认清华镜像不可达；pyftpdlib 2.2.0 / Python 3.8.5） | 小 | 2026-11-19 |
| `/tmp/mitv-e2e-*` | E2E 脚本工作目录（remote 服务器根 + local 客户端素材 + 服务器脚本/日志）；脚本全绿时自清理，失败时保留排查 | 小 | 2026-11-19 |
| `/tmp/mitv-smoke`、`/tmp/mitv-enc-check`、`/tmp/mitv-probe-src` | 引擎开发期的手工冒烟/编码行为验证目录（pyftpdlib GBK 配置实证、解析器探针源码） | 小 | 2026-11-19 |
| `/tmp/t-run.log`、`/tmp/probe_main.swift`、`/tmp/probe`、`/tmp/test-runner-dbg` | 逐项验证产生的临时文件 | 小 | 2026-11-19 |
| `build/`、`dist/`（本 worktree） | Makefile 构建产物 | 动态 | 2026-11-19 |

清理命令（开发完成后由主控执行）：
```bash
pip3 uninstall -y pyftpdlib
rm -rf /tmp/mitv-e2e-* /tmp/mitv-smoke /tmp/mitv-enc-check /tmp/mitv-probe-src \
       /tmp/t-run.log /tmp/probe_main.swift /tmp/probe /tmp/test-runner-dbg
```

> 备注：环境实测本机 APFS 拒绝非 UTF-8 字节文件名（EILSEQ），因此 E2E 用 pyftpdlib 的
> `encoding="gbk"` 配置模拟电视端（GBK 通道进出、服务端落盘自动转 UTF-8），
> 与真机"GBK 控制通道 + 自有存储"行为等价。详见 `docs/ENGINE_NOTES.md`。
