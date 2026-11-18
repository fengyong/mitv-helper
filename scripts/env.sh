#!/bin/bash
# 构建环境（系统 Swift 5.1 + CLT 10.15 SDK，官方匹配对，编译快）。
# 用法：source scripts/env.sh   之后可直接 make
export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk"
export MITV_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "构建环境：swift 5.1 (系统) / SDK 10.15 / 模块缓存 /tmp/mitv-modcache-51"
echo "提示：首次编译 AppKit 模块约 90 秒（已缓存），之后秒级。"
