# ── 最低部署版本：17.4（2026-10-31 从 16.1 提上来）──────────────────────────
# README 的「System Requirements」写的是 **Minimum: iOS 17.4 / Recommended: iOS 26**。
#
# 为什么提到 17.4：
#   · **歌词系统翻译**用的是 Apple 的 `Translation.framework`，它**从 17.4 才有**。
#     最低版本低于它时，`import Translation` 的自动链接会让 iOS 16 / 17.0–17.3 的机器
#     **一启动就崩**（dyld: Library not loaded），只能靠 `-weak_framework` + 关掉自动链接
#     硬撑 —— 那套参数本身又是构建期的风险。把门槛提到 17.4，框架一定在，
#     强链接就是安全的，构建参数也回到最朴素的样子。
#   · 17.4 之前的系统占比已经很低，而本仓库的外观特性大量依赖 iOS 26 的新材质。
#
# 连带后果，心里有数即可：
#   · iOS 14 / 15 / 16 / 17.0–17.3 的机器装不了（`control` 的 `firmware` 会挡住）；
#   · `EeveeSpotify.hookTarget` 里 `.lastAvailableiOS14`（Spotify 8.9.8）那一档事实上成了死路，
#     留着无害，将来清理时一起删；
#   · `#available(iOS 18.0, *)` / `#available(iOS 26.0, *)` 那些门禁**仍然必须留**
#     （18 > 17.4，26 > 17.4）—— 尤其是 `TranslationSession` 的初始化器是 iOS 18 的。
TARGET := iphone:clang:latest:17.4
INSTALL_TARGET_PROCESSES = Spotify
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = EeveeSpotify

REPO_SLUG ?= $(shell git remote get-url origin 2>/dev/null | sed -E 's|.*github\.com[:/]([^/]+/[^/.]+)(\.git)?$$|\1|')
REPO_SLUG_FINAL := $(if $(REPO_SLUG),$(REPO_SLUG),zbzxbg/EeveeSpotifyEvolved)

BRANCH_NAME ?= $(shell git rev-parse --abbrev-ref HEAD 2>/dev/null)
BRANCH_NAME_FINAL := $(if $(BRANCH_NAME),$(BRANCH_NAME),Master)

$(shell mkdir -p Sources/EeveeSpotify/Generated)
$(shell printf 'enum GeneratedConfig {\n    static let repoSlug = "%s"\n    static let branchName = "%s"\n}\n' "$(REPO_SLUG_FINAL)" "$(BRANCH_NAME_FINAL)" > Sources/EeveeSpotify/Generated/RepoSlug.swift)

EeveeSpotify_FILES = $(shell find Sources/EeveeSpotify -name '*.swift') $(shell find Sources/EeveeSpotifyC -name '*.m' -o -name '*.c' -o -name '*.mm' -o -name '*.cpp')
EeveeSpotify_SWIFTFLAGS = -ISources/EeveeSpotifyC/include -Osize
EeveeSpotify_EXTRA_FRAMEWORKS = EeveeSwiftProtobuf
EeveeSpotify_CFLAGS = -fobjc-arc -ISources/EeveeSpotifyC/include -Os

# ── 系统翻译：Translation.framework 现在是**强链接**（最低版本 17.4 起它一定在）──
# `Sources/EeveeSpotify/Lyrics/OnDeviceLyricsTranslation.swift` 里有 `import Translation`。
# 2026-10-31 把最低部署版本提到 17.4 之前，这里曾经要 `-weak_framework Translation` +
# `-Xfrontend -disable-autolink-framework`：否则 iOS 16 / 17.0–17.3 上 dyld 找不到
# 这个框架，**App 一启动就崩**。门槛提上去之后那两行**故意删掉了** ——
# 留着反而多一层构建期风险，而且弱链接会把"框架真的缺了"这件事藏起来。
# ⚠️ 如果将来把 `TARGET` 调回 17.4 以下，这两行必须一起加回来：
#     EeveeSpotify_SWIFTFLAGS += -Xfrontend -disable-autolink-framework -Xfrontend Translation
#     EeveeSpotify_LDFLAGS += -weak_framework Translation

# ── 越狱路径支持（libroot / roothide）───────────────────────────────────────
# RootHide's compatibility implementation of libroot resolves jailbreak paths
# through libroothide at runtime. Rootless builds continue to use libroot.
#
# NO_JBROOT=1 把这块整个关掉 —— 见下面「无越狱路径依赖」一节。
NO_JBROOT ?= 0

ifeq ($(NO_JBROOT),1)
EeveeSpotify_CFLAGS += -DNO_JBROOT
else ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
EeveeSpotify_SWIFTFLAGS += -D ROOTHIDE
EeveeSpotify_LDFLAGS += -lroothide -Xlinker -rpath -Xlinker @loader_path/.jbroot/Library/Frameworks
else
EeveeSpotify_LDFLAGS += -lroot
endif

# ── 无越狱路径依赖：NO_JBROOT=1 ─────────────────────────────────────────────
#     make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless NO_JBROOT=1
#
# 为什么需要：IPA 里注入的那份 EeveeSpotify.dylib 是从这个 deb 里掏出来的，
# 而 TrollStore / 侧载设备上的 Spotify **不在**越狱环境里 —— 没有 /var/jb。
# libroot 是**加载期**依赖（LC_LOAD_DYLIB /var/jb/usr/lib/libroot.dylib），
# dyld 解析不到就 dlopen 失败：注入完 App 直接起不来，日志里往往只有一句
# dlerror，极难定位。实测 rootless 方案打出来的 IPA 就是这个下场。
#
# 关掉之后 EeveeJBRootPath() 退化成原样返回（Sources/EeveeSpotifyC/Tweak.m）。
# 功能不受影响：BundleHelper 先找 main bundle，只有找不到才去越狱路径兜底。
#
# ⚠️ 这样编出来的 deb **不能**给越狱用户装（少了 libroot 的路径解析）。
#    工作流里它只当「dylib 的来源」，不发布；越狱包由 builddeb.yml 另出。
# ⚠️ 同理，roothide 方案（-lroothide）也不能拿来出 IPA。

# Sideload compatibility (keychain redirect, group containers, CloudKit) is
# handled out-of-process by modules/zxPluginsInject — LC-injected via ipapatch
# in build-ipa-local.sh and the GitHub workflow. No flags needed here.

# ── 打包依赖：`control` 里的 ${ORION} 是 **theos 的占位符**，不是本仓库的变量 ──
# `control` 结尾写的是 `Depends: ${ORION}, firmware (>= 17.4)`。这里的 ${ORION}
# **不由本 Makefile 定义**（全仓库 grep `ORION =` 会是零命中，那是正常的），
# 它在 `make package` 时由 theos 自己替换：
#
#   $(THEOS)/makefiles/package/deb.mk
#     _THEOS_DEB_ORION_DEPENDS := dev.theos.orion (>= 1.0.0)
#     sed -e 's/\${ORION}/$(_THEOS_DEB_ORION_DEPENDS)/g; …'
#
# ⇒ 最终 deb 的 Depends 是 `dev.theos.orion (>= 1.0.0), firmware (>= 17.4)`。
# 同一机制还有 ${LIBSWIFT} / ${LIBSWIFT_VERSION}。**不要**把 ORION 定义成本地
# 变量 —— 那会变成普通 make 变量替换，反而绕过 theos 的版本约束。
#
# 为什么必须有这条依赖：本 tweak 链着 Orion.framework（Swift 侧 `import Orion`，
# ObjC 侧 `#import <Orion/Orion.h>`），越狱设备上要装 Orion 运行时才能加载。
# Orion 包名是 `dev.theos.orion12` / `dev.theos.orion14`，两者都声明
# `Provides: dev.theos.orion` ⇒ 依赖虚拟名 `dev.theos.orion` 即可跨 iOS 版本。
# 包从 theos 源装：https://repo.theos.dev/
#
# ⚠️ 别把这段说明写进 `control`：theos 的 sed 管道只删 Version / Architecture /
#    空行，`#` 注释会被原样带进 DEBIAN/control，破坏字段解析。要写就写在这里。
#
# ⚠️ `EeveeSwiftProtobuf.framework` 走的是另一条路：它由 internal-stage 拷进
#    deb（见下），**不**通过 ${…} 占位符声明依赖。

include $(THEOS_MAKE_PATH)/tweak.mk

internal-stage::
	# Bundle EeveeSwiftProtobuf.framework into the package. Renamed from
	# SwiftProtobuf so the @objc class names don't collide with the
	# SwiftProtobuf statically embedded in SpotifyShared.framework.
	mkdir -p $(THEOS_STAGING_DIR)/Library/Frameworks
	cp -r $(THEOS)/lib/iphone/$(or $(THEOS_PACKAGE_SCHEME),rootless)/EeveeSwiftProtobuf.framework $(THEOS_STAGING_DIR)/Library/Frameworks/

# Build EeveeSwiftProtobuf.framework from apple/swift-protobuf source. Run
# this once before `make package`. Re-run if SWIFTPROTOBUF_VERSION changes
# or `swift --version` jumps a major.
build-eeveeswiftprotobuf:
	bash Tools/SwiftProtobufBuild/build-eeveeswiftprotobuf.sh
