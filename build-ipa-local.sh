#!/usr/bin/env bash
# Local IPA build — the local counterpart of the two CI workflows:
#   .github/workflows/build-ipa-with-orion.yml          (no patch)
#   .github/workflows/build-ipa-with-orion-patched.yml  (patched)
# Produces an IPA you can sign with Sideloadly/AltStore/TrollStore.
#
# Pipeline:
#   1. Build EeveeSwiftProtobuf.framework from apple/swift-protobuf source
#      (renamed module — see Tools/SwiftProtobufBuild/).
#   2. theos `make package FINALPACKAGE=1 NO_JBROOT=1` — produces .deb with
#      EeveeSpotify.dylib + EeveeSpotify.bundle + framework. NO_JBROOT=1 keeps
#      libroot (/var/jb/...) out of the dylib: this deb is only a dylib source,
#      and a load-time libroot dependency crashes the app on TrollStore.
#   3. Build zxPluginsInject.dylib — sideload compat shim (keychain redirect,
#      group containers, CloudKit stub). LC-injected via ipapatch in step 7.
#   4. Extract the deb to get dylib + bundle + framework.
#   5. cyan inject those into the vanilla IPA → Outputs/IPAS/<name>.ipa (no patch)
#   6. Build EeveeLiveActivity.appex — the Live Activity widget (lock screen +
#      Dynamic Island), via Scripts/build-live-activity-appex.sh: plain swiftc,
#      no Xcode project. It stays UNSIGNED — this script only produces unsigned
#      IPAs and the signing tool on the user's side has to cover nested PlugIns
#      too. Needs an iOS SDK; without one the widget is skipped with a warning.
#   7. copy that, then ipapatch LC-inject zxPluginsInject into main exec + every
#      appex → Outputs/IPAS/<name>-patched.ipa  ← TrollStore / sideload: this one
#   8. Embed the appex in both, add NSSupportsLiveActivities /
#      NSMotionUsageDescription to the host Info.plist, strip Watch.app.
#
# Requires: theos, cyan (pyzule-rw), ipapatch, dpkg, ldid, plutil.

set -euo pipefail

VANILLA_IPA="${1:-}"
[ -n "$VANILLA_IPA" ] && [ -f "$VANILLA_IPA" ] || {
    echo "usage: $0 <path/to/Spotify-vanilla.ipa>" >&2
    exit 1
}

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

[ -n "${THEOS:-}" ] || { [ -d "$HOME/theos" ] && export THEOS="$HOME/theos" || { echo "THEOS not set"; exit 1; }; }

VERSION=$(grep -E '^Version:' control | awk '{print $2}')
SPOT_VERSION=$(unzip -p "$VANILLA_IPA" 'Payload/Spotify.app/Info.plist' \
    | plutil -extract CFBundleShortVersionString raw - 2>/dev/null || echo "unknown")
OUT_DIR="Outputs/IPAS"
OUT_IPA="$OUT_DIR/EeveeSpotify-${VERSION}-${SPOT_VERSION}.ipa"
mkdir -p "$OUT_DIR"

color() { printf '\033[1;32m==> %s\033[0m\n' "$*"; }

color "1/8  EeveeSwiftProtobuf.framework"
chmod +x Tools/SwiftProtobufBuild/build-eeveeswiftprotobuf.sh
Tools/SwiftProtobufBuild/build-eeveeswiftprotobuf.sh

color "2/8  theos make package"
# NO_JBROOT=1：这份 deb 只当 dylib 的来源，不发布。TrollStore / 侧载设备上
# 没有 /var/jb，而 libroot 是加载期依赖，链上它 App 会直接起不来。
THEOS_PACKAGE_SCHEME=rootless NO_JBROOT=1 make package FINALPACKAGE=1
DEB_FILE=$(ls -t packages/com.eevee.spotify_*.deb 2>/dev/null | head -1)
[ -n "$DEB_FILE" ] || { echo "deb not produced"; exit 1; }

color "3/8  zxPluginsInject.dylib"
chmod +x Tools/build-zxpi.sh
Tools/build-zxpi.sh >/dev/null

color "4/8  extract deb"
DEB_EXTRACT="$REPO_DIR/Outputs/deb-extract"
rm -rf "$DEB_EXTRACT"; mkdir -p "$DEB_EXTRACT"
dpkg-deb -R "$DEB_FILE" "$DEB_EXTRACT"
DYLIB_SRC=$(find "$DEB_EXTRACT" -name 'EeveeSpotify.dylib' | head -1)
BUNDLE_SRC=$(find "$DEB_EXTRACT" -type d -name 'EeveeSpotify.bundle' | head -1)
FRAMEWORK_SRC=$(find "$DEB_EXTRACT" -type d -name 'EeveeSwiftProtobuf.framework' | head -1)
[ -n "$DYLIB_SRC" ] || { echo "dylib not in deb"; exit 1; }

color "5/8  cyan inject"
INJECT=("$DYLIB_SRC")
[ -n "$FRAMEWORK_SRC" ] && INJECT+=("$FRAMEWORK_SRC")
[ -n "$BUNDLE_SRC" ]    && INJECT+=("$BUNDLE_SRC")
rm -f "$OUT_IPA"
# 最低 OS 版本跟随工程底线（根目录 Makefile 的 `TARGET`）。`cyan -m` 是把**输出 IPA 的
# MinimumOSVersion** 盖成这个值，而 tweak 的 dylib 是按 `TARGET` 编译的：这里写低了就会
# 出现"装得上、但 dyld 加载不了那个 dylib"的静默失效（`TARGET` 提到 17.4 之后，
# `Translation.framework` 是强链接，低版本系统上根本不存在这个框架）。
cyan -i "$VANILLA_IPA" -o "$OUT_IPA" -f "${INJECT[@]}" -c 9 -m 17.4 -du

color "6/8  Live Activity appex"
# 组件用 Scripts/build-live-activity-appex.sh 编：纯 swiftc，不需要 Xcode 工程，也不需要
# App Intents 元数据处理器（v1 没有按钮/意图）。宿主 Info.plist 取自 vanilla IPA，组件的
# 版本号与标识都跟着这一份宿主走。
# **故意 fail-soft**：编不出来不该让整份 IPA 作废 —— 只告警，包照出，只是没有实时活动。
# 二进制不签名：本脚本只产未签名 IPA，签名由用户侧工具完成，它必须连 PlugIns 一起签。
LIVEACTIVITY_APPEX=""
HOST_PLIST_TMP="$REPO_DIR/Outputs/host-Info.plist"
if unzip -p "$VANILLA_IPA" 'Payload/Spotify.app/Info.plist' > "$HOST_PLIST_TMP" 2>/dev/null \
   && bash "$REPO_DIR/Scripts/build-live-activity-appex.sh" "$HOST_PLIST_TMP" "$REPO_DIR/Outputs/liveactivity-appex"; then
    LIVEACTIVITY_APPEX="$REPO_DIR/Outputs/liveactivity-appex/EeveeLiveActivity.appex"
    echo "appex: $LIVEACTIVITY_APPEX"
else
    echo "!! 没能编出 EeveeLiveActivity.appex —— 两份包都不带实时活动组件"
fi

color "7/8  ipapatch LC-inject zxPluginsInject (patched copy)"
# 先复制再注入：$OUT_IPA 保持"无 patch"那份（tweak 本体），另一个文件才带
# zxPluginsInject。TrollStore / 侧载装 *-patched.ipa。
PATCHED_IPA="${OUT_IPA%.ipa}-patched.ipa"
cp -f "$OUT_IPA" "$PATCHED_IPA"
ipapatch --input "$PATCHED_IPA" --inplace --noconfirm --dylib packages/zxPluginsInject.dylib

color "8/8  Live Activity appex + host plist keys in both IPAs"
# Belt-and-suspenders: cyan -du strips appex/Watch but verify. 两份都要查。
cd "$OUT_DIR"
for IPA in "$(basename "$OUT_IPA")" "$(basename "$PATCHED_IPA")"; do
    rm -rf Payload
    unzip -q "$IPA"
    NEEDS_REZIP=0

    if [ -d "Payload/Spotify.app/Watch" ]; then
        rm -rf Payload/Spotify.app/Watch
        NEEDS_REZIP=1
        echo "已剔除 Watch.app: $IPA"
    fi

    # ★ 液态玻璃开关（**默认开 = 现在的新基线**）。见 Tools/eevee-hookfinder/FLAGS_9186_DESIGN.md。
    # Spotify 自己在 Info.plist 里写了 UIDesignRequiresCompatibility=true —— 那是在要求
    # iOS 26 用**兼容模式**跑它，于是整个 App 不进新设计语言。删掉这个键，界面就进入
    # 新设计语言（导航栏是 SwiftUI Platter、标签栏系统玻璃）—— 2026-10-01 用户实测通过，
    # 从那以后就是这份构建的默认。
    # 想回 Spotify 原来的外观：`ALLOW_LIQUID_GLASS=0 ./build-ipa-local.sh …`（不用改代码）。
    if [ "${ALLOW_LIQUID_GLASS:-1}" = "1" ] && [ -f "Payload/Spotify.app/Info.plist" ]; then
        plutil -remove UIDesignRequiresCompatibility Payload/Spotify.app/Info.plist 2>/dev/null || true
        NEEDS_REZIP=1
        echo "★ 已去掉 UIDesignRequiresCompatibility（ALLOW_LIQUID_GLASS=1）: $IPA"
    fi

    # 实时活动：把组件和宿主 Info.plist 的两个键补上，再重新打包（必须在 zip 之前）。
    # 组件二进制不签名：本脚本只产未签名 IPA，签名由用户侧工具完成，它必须连 PlugIns 一起签。
    # 失败只告警：没有实时活动的包照样能装能跑。
    if [ -n "$LIVEACTIVITY_APPEX" ] && [ -d "$LIVEACTIVITY_APPEX" ]; then
        mkdir -p Payload/Spotify.app/PlugIns
        rm -rf Payload/Spotify.app/PlugIns/EeveeLiveActivity.appex
        cp -R "$LIVEACTIVITY_APPEX" Payload/Spotify.app/PlugIns/EeveeLiveActivity.appex
        echo "已嵌入 EeveeLiveActivity.appex（未签名）: $IPA"
    else
        echo "!! 没有 EeveeLiveActivity.appex 可嵌入，这份包不带实时活动组件: $IPA"
    fi
    NEEDS_REZIP=1

    # ActivityKit：宿主自己必须声明支持实时活动，否则 App 侧 start() 直接抛错。
    # AirPods 头部手势要读运动数据，缺这条用途说明会被系统拒绝，而不是静默失败。
    plutil -insert NSSupportsLiveActivities -bool true Payload/Spotify.app/Info.plist 2>/dev/null \
        || plutil -replace NSSupportsLiveActivities -bool true Payload/Spotify.app/Info.plist \
        || echo "!! 没能给宿主 Info.plist 设置 NSSupportsLiveActivities: $IPA"
    plutil -insert NSMotionUsageDescription -string "Used for head-gesture track controls on supported headphones." Payload/Spotify.app/Info.plist 2>/dev/null \
        || plutil -replace NSMotionUsageDescription -string "Used for head-gesture track controls on supported headphones." Payload/Spotify.app/Info.plist \
        || echo "!! 没能给宿主 Info.plist 设置 NSMotionUsageDescription: $IPA"

    [ "$NEEDS_REZIP" = "1" ] && zip -qry "$IPA" Payload
    rm -rf Payload
done
cd - >/dev/null

# ipapatch / zip 之后仍有若干条目是"数据描述符"写法（本地头里 csize/usize 为 0）：
# 桌面解压与 zipfile 读得动，但 LCSign 这类按本地头走查的工具会直接报"无法打开 zip"。
# 两份都重写成标准写法（顺序 / 时间戳 / 权限位不变），之后再交给你签名。
color "Normalize the IPA zips (no streaming entries)"
if command -v python3 >/dev/null 2>&1; then
    NORMALIZE_PY=python3
elif command -v python >/dev/null 2>&1; then
    NORMALIZE_PY=python
else
    NORMALIZE_PY=""
fi
if [ -n "$NORMALIZE_PY" ]; then
    "$NORMALIZE_PY" "$REPO_DIR/Scripts/normalize-ipa.py" "$OUT_IPA" "$PATCHED_IPA" \
        || echo "!! 规范化失败 —— 这两份包可能仍带流式条目（某些签名工具会报无法打开）"
else
    echo "!! 没有 python3/python，跳过规范化：产物可能仍带流式条目"
fi

color "Done"
ls -lh "$OUT_IPA" "$PATCHED_IPA"
cat <<'EOF'
  <name>.ipa          = 无 patch（tweak 本体：Orion + dylib + bundle + framework）
  <name>-patched.ipa  = 多一个 LC 注入的 zxPluginsInject（keychain / group / CloudKit 垫片）
                        → TrollStore / Sideloadly / AltStore 装这份
  两份都不依赖越狱路径（NO_JBROOT=1）；RootHide 越狱请装 roothide 的 .deb。
EOF
