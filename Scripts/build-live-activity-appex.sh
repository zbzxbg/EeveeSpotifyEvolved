#!/usr/bin/env bash
# Builds the Live Activity widget as a WidgetKit .appex with plain swiftc - no .xcodeproj,
# no xcodebuild, and no App Intents metadata processor (the widget has no intents in v1).
#
#   Scripts/build-live-activity-appex.sh <host Info.plist> <out dir>
#
# Writes <out dir>/EeveeLiveActivity.appex and prints its path. Its bundle id is derived from the
# host's so it always stays a child of the app that owns it (com.spotify.client ->
# com.spotify.client.eevee-liveactivity), and its version fields come from the host as well.
#
# The appex binary is deliberately left UNSIGNED. This repo only ever produces unsigned IPAs; the
# user signs the finished IPA on their side (LCSign), and that signing has to cover nested PlugIns.
#
# Needs an iOS SDK and the Swift toolchain only ("xcrun --sdk iphoneos"), i.e. Xcode or
# Command Line Tools selected with xcode-select / DEVELOPER_DIR. Without them the script exits
# non-zero with a message instead of leaving a half-built bundle behind: the callers in the IPA
# pipelines treat that as "ship the IPA without the widget", not as a failed build.
set -euo pipefail

HOST_PLIST="${1:?usage: $0 <host Info.plist> <out dir>}"
OUT="${2:?usage: $0 <host Info.plist> <out dir>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ATTRIBUTES="$ROOT/Sources/EeveeSpotify/LiveActivity/NowPlayingActivityAttributes.swift"
WIDGET="$ROOT/Sources/LiveActivityExtension/LiveActivityWidget.swift"

NAME=EeveeLiveActivity
APPEX="$OUT/$NAME.appex"
# ActivityKit and the Dynamic Island appear in iOS 16.1; 17.0 is a round floor above that. A nested
# appex may sit below the host's MinimumOSVersion - the host's own floor is still what decides which
# devices run it.
DEPLOY=17.0

[ -f "$HOST_PLIST" ] || {
    echo "error: host Info.plist not found: $HOST_PLIST" >&2
    exit 1
}
[ -f "$ATTRIBUTES" ] || {
    echo "error: shared attributes not found: $ATTRIBUTES" >&2
    exit 1
}
[ -f "$WIDGET" ] || {
    echo "error: widget source not found: $WIDGET" >&2
    exit 1
}

# Fail with a readable message here rather than producing a bundle nobody can load.
if ! SDK="$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)"; then
    echo "error: no iOS SDK - 'xcrun --sdk iphoneos --show-sdk-path' failed." >&2
    echo "error: install Xcode (or the iOS platform) and point xcode-select / DEVELOPER_DIR at it." >&2
    exit 1
fi
if [ -z "$SDK" ] || [ ! -d "$SDK" ]; then
    echo "error: 'xcrun --sdk iphoneos --show-sdk-path' returned no usable directory: '$SDK'" >&2
    exit 1
fi
if ! SWIFTC="$(xcrun --find swiftc 2>/dev/null)" || [ -z "$SWIFTC" ]; then
    echo "error: no swiftc on the selected toolchain - 'xcrun --find swiftc' failed." >&2
    echo "error: install Xcode (or the Swift toolchain) and point xcode-select / DEVELOPER_DIR at it." >&2
    exit 1
fi

HOST_BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw -o - "$HOST_PLIST")"
HOST_SHORT_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$HOST_PLIST")"
HOST_VERSION="$(plutil -extract CFBundleVersion raw -o - "$HOST_PLIST")"
[ -n "$HOST_BUNDLE_ID" ] || {
    echo "error: $HOST_PLIST has no CFBundleIdentifier" >&2
    exit 1
}
[ -n "$HOST_SHORT_VERSION" ] && [ -n "$HOST_VERSION" ] || {
    echo "error: $HOST_PLIST has no CFBundleShortVersionString / CFBundleVersion" >&2
    exit 1
}

# A child of the host's id: the system only loads a PlugIn whose id is prefixed by its host's, and
# ".eevee-liveactivity" keeps us clear of the id Spotify itself would use for its own widget.
APPEX_BUNDLE_ID="$HOST_BUNDLE_ID.eevee-liveactivity"

rm -rf "$APPEX"
mkdir -p "$APPEX"

# The shared attributes file is compiled into this module too: that is how ActivityKit pairs the
# app's activities with this widget - both sides must see the same attribute type.
echo "==> $NAME.appex  ($APPEX_BUNDLE_ID, iOS $DEPLOY)"
"$SWIFTC" -O -wmo -parse-as-library \
    -sdk "$SDK" -target "arm64-apple-ios$DEPLOY" -module-name "$NAME" \
    -framework Foundation -framework SwiftUI -framework WidgetKit -framework ActivityKit \
    -Xlinker -e -Xlinker _NSExtensionMain \
    -o "$APPEX/$NAME" "$ATTRIBUTES" "$WIDGET"

[ -f "$APPEX/$NAME" ] || {
    echo "error: swiftc produced no $NAME binary at $APPEX/$NAME" >&2
    exit 1
}

cat > "$APPEX/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>Spotify</string>
	<key>CFBundleExecutable</key>
	<string>$NAME</string>
	<key>CFBundleIdentifier</key>
	<string>$APPEX_BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$NAME</string>
	<key>CFBundlePackageType</key>
	<string>XPC!</string>
	<key>CFBundleShortVersionString</key>
	<string>$HOST_SHORT_VERSION</string>
	<key>CFBundleSupportedPlatforms</key>
	<array>
		<string>iPhoneOS</string>
	</array>
	<key>CFBundleVersion</key>
	<string>$HOST_VERSION</string>
	<key>DTPlatformName</key>
	<string>iphoneos</string>
	<key>MinimumOSVersion</key>
	<string>$DEPLOY</string>
	<key>NSExtension</key>
	<dict>
		<key>NSExtensionPointIdentifier</key>
		<string>com.apple.widgetkit-extension</string>
	</dict>
	<key>UIDeviceFamily</key>
	<array>
		<integer>1</integer>
		<integer>2</integer>
	</array>
	<key>UIRequiredDeviceCapabilities</key>
	<array>
		<string>arm64</string>
	</array>
</dict>
</plist>
PLIST

# Binary so the bundle matches what Xcode would ship and what the IPA carries everywhere else.
plutil -convert binary1 "$APPEX/Info.plist"

echo "    $APPEX"
