# MiTV Helper 构建系统（无 Xcode；系统 Swift 5.1 + CLT 10.15 SDK，官方匹配对）
# 用法：make / make app / make cli / make test / make appbundle / make clean
# 注意：不要删除 build/ 之外的任何东西；临时文件记录在 docs/DELETE_PENDING.md

SDK        := /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
SWIFT      := /usr/bin/swiftc
TARGET     := x86_64-apple-macos10.15
MODULECACHE := /tmp/mitv-modcache-51
FLAGS      := -sdk $(SDK) -target $(TARGET) -Xcc -fmodules-cache-path=$(MODULECACHE) -O -enable-testing
FLAGS_DEBUG:= -sdk $(SDK) -target $(TARGET) -Xcc -fmodules-cache-path=$(MODULECACHE) -g -DDEBUG -enable-testing

CORE   := $(wildcard Sources/MiTVCore/*.swift)
ENGINE := $(wildcard Sources/MiTVEngine/*.swift)
APP    := $(wildcard Sources/MiTVApp/*.swift)
CLI    := $(wildcard Sources/mitvctl/*.swift)
TESTS  := $(wildcard Tests/MiTVCoreTests/*.swift)
# ServiceTests_B 直测的服务层纯逻辑文件（正式纳入替代临时符号链接方案）
APP_SERVICE := Sources/MiTVApp/QueueModel.swift Sources/MiTVApp/QueueService.swift \
               Sources/MiTVApp/SmartRouting.swift Sources/MiTVApp/SoftDeletePolicy.swift \
               Sources/MiTVApp/BrowseFilter.swift Sources/MiTVApp/ThumbCacheStore.swift \
               Sources/MiTVApp/TVStore.swift

.PHONY: all app cli test appbundle clean typecheck

all: cli test app

# 无头 CLI（引擎端到端冒烟）
cli: build/mitvctl

build/mitvctl: $(CORE) $(ENGINE) $(CLI)
	@mkdir -p build
	$(SWIFT) $(FLAGS) -module-name mitvctl $(CORE) $(ENGINE) $(CLI) -framework Network -framework Foundation -o $@

# macOS 客户端
app: build/MiTVApp

build/MiTVApp: $(CORE) $(ENGINE) $(APP)
	@mkdir -p build
	$(SWIFT) $(FLAGS) -module-name MiTVApp $(CORE) $(ENGINE) $(APP) \
	  -framework AppKit -framework AVFoundation -framework Photos -framework Network -o $@

# 测试（轻量自研 runner，不用 XCTest；失败非零退出）
# 注：测试目标需编译 $(ENGINE)（EngineTests_A）与 $(APP_SERVICE)（ServiceTests_B）——单模块合并编译
test: build/test-runner
	./build/test-runner

build/test-runner: $(CORE) $(ENGINE) $(TESTS) $(APP_SERVICE)
	@mkdir -p build
	$(SWIFT) $(FLAGS) -module-name MiTVTests $(CORE) $(ENGINE) $(TESTS) $(APP_SERVICE) -framework Foundation -o $@

# 快速类型检查（不产出二进制，CI 心跳用）
typecheck:
	$(SWIFT) $(FLAGS_DEBUG) -module-name MiTVApp $(CORE) $(ENGINE) $(APP) -framework AppKit -framework AVFoundation -framework Photos -framework Network -typecheck

# .app 打包（ad-hoc 签名：TCC 归属 Info.plist 权限文案必需，否则照片库授权直接 SIGABRT）
appbundle: app
	@mkdir -p dist/MiTVHelper.app/Contents/MacOS dist/MiTVHelper.app/Contents/Resources
	cp packaging/Info.plist dist/MiTVHelper.app/Contents/Info.plist
	printf 'APPL????' > dist/MiTVHelper.app/Contents/PkgInfo
	cp build/MiTVApp dist/MiTVHelper.app/Contents/MacOS/MiTVHelper
	codesign --force --deep --sign - dist/MiTVHelper.app 2>/dev/null || \
	  echo "警告：codesign 失败，照片库授权可能被 TCC 拒绝"
	@echo "dist/MiTVHelper.app 就绪 — open dist/MiTVHelper.app"

clean:
	rm -rf build
