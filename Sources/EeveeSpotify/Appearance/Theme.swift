import EeveeSpotifyC
import Foundation
import UIKit

/// 「主题」换色：**AMOLED 纯黑 + 强调色**（移植自上游 `Pages/Theme.swift`）。
///
/// 机制全在 C 侧（`Sources/EeveeSpotifyC/ColorSwap.m`，原样移植）：它不改任何具体控件，
/// 而是在**颜色出生点**把 Spotify 自己的两种设计 token 换掉 ——
///   · 底色灰（#121212 那一档中性深灰）→ **纯黑**（保留 alpha）；
///   · 品牌绿（#1ED760 / #1DB954）→ 用户选的强调色（同比例缩放，深绿变体跟着走）。
///
/// 为什么必须重启：`Theme.launchAmoled` / `launchAccent` 是**启动时的快照**，而且 C 侧用
/// `dispatch_once` 装 swizzle（装一次不再重装）⇒ 设置页那颗开关下面配了 `RestartSection`。
///
/// ⚠️ **别和我们删掉的那个 AMOLED 搞混**：2026-10-02 删的 `amoledEnabled`（"深色栏底色"）
/// 只给旧设计语言的导航/标签栏涂底，在新设计语言下是纯空操作。**这个不是那个** ——
/// 键名也刻意换成新的（`amoledTheme`），免得设备上存量的旧值把纯黑主题悄悄打开。
///
/// ⚠️ 它会**全局**换色：我们自己那套玻璃/plates 里的中性深灰也会一起变黑（多半正是想要的，
/// 但可能压平分层）⇒ 真机验收时若发现某处对比度没了，关掉开关即可回滚。
enum Theme {

    static let spotifyGreen: Int = 0x1ED760

    /// 启动时的快照（`activateTheme` 与设置页的「立即重启」判定都读它）。
    static let launchAmoled = UserDefaults.amoledTheme
    static let launchAccent = UserDefaults.accentColorRGB

    /// 强调色（没设过就是 Spotify 绿）。
    static var accent: UIColor { color(accentOrGreen(launchAccent)) }

    static func accentOrGreen(_ rgb: Int) -> Int { rgb >= 0 ? rgb : spotifyGreen }

    static func color(_ rgb: Int) -> UIColor {
        UIColor(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }

    /// `UIColor` → `0xRRGGBB`（喂给 C 侧）。
    static func rgb(of color: UIColor) -> Int {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Int(round(min(max(r, 0), 1) * 255)) << 16)
            | (Int(round(min(max(g, 0), 1) * 255)) << 8)
            | Int(round(min(max(b, 0), 1) * 255))
    }
}

func activateTheme() {
    // 两颗都关着 = 一个 swizzle 都不装（零开销）。
    guard Theme.launchAmoled || Theme.launchAccent >= 0 else { return }

    let start = CFAbsoluteTimeGetCurrent()
    let swaps = EeveeInstallColorSwaps(Theme.launchAmoled, Theme.launchAccent)
    let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
    let accent = Theme.launchAccent >= 0
        ? String(format: "#%06X", Theme.launchAccent)
        : "default (Spotify green)"

    writeDebugLog(
        "[Theme] AMOLED \(Theme.launchAmoled ? "ON" : "off")"
            + ", accent \(accent)"
            + ", \(swaps) swap point(s) installed"
            + " (\(String(format: "%.2f", elapsed)) ms)"
    )

    // 30 秒后再报一次**实际命中数**：证明确实有颜色被换掉了，而不是"swizzle 装上了但没生效"。
    // （AMOLED 与强调色各看各的计数：灰底变黑 / 绿变强调色。）
    DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
        var grey = 0, green = 0, uiColor = 0
        EeveeColorSwapStats(&grey, &green, &uiColor)
        writeDebugLog(
            "[Theme] first 30s: \(grey) surface(s) → black"
                + ", \(green) layer green(s) → accent"
                + ", \(uiColor) UIColor green(s) → accent"
        )
    }
}
