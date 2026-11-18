# 待删除清单（开发完成后清理）

> 规则：开发期间**不删除任何本地文件**；临时产物记录于此，开发完成后一次性清理。

| 路径 | 说明 | 大小 | 创建日期 |
|---|---|---|---|
| `mitv-helper-glm53flash/.tools/swift-5.9.2-RELEASE-osx.pkg` | swift.org 官方工具链安装包（免 root 提取用） | ~1.03 GB | 2026-11-18 |
| `mitv-helper-glm53flash/.tools/toolchain/` | 上述 pkg 解包产物（编译用工具链） | ~2.5 GB | 2026-11-18 |
| `~/.pyenv (pip3 --user pyftpdlib)` | 本地 FTP 测试服务器依赖（E2E 测试用，装在用户 Python 目录） | 小 | 2026-11-18 |
| `/tmp/mitv-e2e-*` | E2E 测试临时目录（远端模拟目录树） | 小 | 2026-11-18 |
| `mitv-helper-glm53flash/.build/` | SwiftPM 构建产物 | 动态 | 2026-11-18 |
| `mitv-helper-glm53flash/dist/` | .app 打包输出 | 动态 | 2026-11-18 |

清理命令（开发完成后由主控执行）：
```bash
rm -rf /Users/fengyong/drax-glm/mitv-helper-glm53flash/.tools
pip3 uninstall -y pyftpdlib
rm -rf /tmp/mitv-e2e-*
```

## 集成阶段新增（2026-11-19）

| 路径 | 说明 |
|---|---|
| `/tmp/mitv-e2e-test.bin` 等真机测试文件 | mitvctl 真机验收产物（已从电视删除） |
| `/tmp/mitv-full.bin` `/tmp/mitv-half.bin` `/tmp/mitv-remote-verify.bin` | APPE 续传真机验证产物 |
| `/tmp/mitv-app-run.log` `/tmp/mitv-app-upload.log` | App 集成冒烟日志 |
| `/tmp/mitv-e2e-img.jpg` `/tmp/mitv-e2e-clip.mp4` | App 上传验收测试媒体 |
| `~/Library/Application Support/MiTVHelper/` | 运行时配置（App 正常使用位置，不清理；`tv.json` 由演示预置改为真实电视端点） |
