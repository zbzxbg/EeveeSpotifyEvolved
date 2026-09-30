import Foundation
import Orion
import UIKit

/// 清爽开关：把 Spotify 自己画的三块"非内容"隐藏掉。
///
/// 目标类名**不是猜的**，来自 2026-09-30 的真机视图树转储 + 9.1.86 符号转储：
///
///   真机树里的形状                                    运行期名（`targetName`）
///   `5.TouchPassthroughView@0,749,414,64`           → `_TtC22NowPlaying_BarPageImplP33_CCC0D2EEA6D4725EECD8965E8C38C86D20TouchPassthroughView`
///     正好贴在标签栏上方（749 + 64 = 标签栏顶 813），里面才是 `id=SPTNowPlayingBar`
///   `12.TabBarGradientView@0,-112,414,195`          → `_TtC23NavigationUI_TabBarImpl18TabBarGradientView`
///   `5.LimitedExperienceIndicatorBar@0,896,414,0`   → `_TtC44LimitedExperienceIndicator_MessageBarRuntime29LimitedExperienceIndicatorBar`
///
/// ⚠️ 只**藏**、不**显**：`isHidden = true` 只在开关打开时写，关掉时什么都不做。
/// 理由是 Spotify 自己在来回切这几处的 `isHidden` —— 真机树里同一个
/// `TouchPassthroughView` 一次是 `hidden`、一次不是（取决于有没有在播放）。
/// 如果"关"也写回去，就会把 Spotify 的隐藏覆盖成显示，出现空条。
/// 代价：关掉开关后要等 Spotify 自己下次更新（切歌 / 重进页面）才恢复，重启一定恢复。
struct HideMiniPlayerGroup: HookGroup {}
struct HideTabBarFadeGroup: HookGroup {}
struct HideFreeTierGroup: HookGroup {}

enum DeclutterChrome {

    static var hideMiniPlayerBar: Bool { UserDefaults.hideMiniPlayerBar }
    static var hideTabBarFade: Bool { UserDefaults.hideTabBarFade }
    static var hideFreeTierBar: Bool { UserDefaults.hideFreeTierBar }

    private static var reported: Set<String> = []

    /// 每个开关只报一次：证明 hook 真的跑到了，并说明藏的是哪一个。
    /// 和 AMOLED 那边同一个道理 —— 验收靠日志，不靠眼睛。
    static func reportOnce(_ key: String, _ message: String) {
        guard !reported.contains(key) else { return }
        reported.insert(key)
        writeDebugLog("[Declutter] \(message)")
    }
}

/// 迷你播放条（标签栏上方那条）。藏的是它的 host：
/// host 的 frame 正好等于 bar 区域（414x64），藏它才不会留一条空白。
class MiniPlayerBarHideHook: ClassHook<UIView> {
    typealias Group = HideMiniPlayerGroup
    static let targetName =
        "_TtC22NowPlaying_BarPageImplP33_CCC0D2EEA6D4725EECD8965E8C38C86D20TouchPassthroughView"

    func layoutSubviews() {
        orig.layoutSubviews()

        guard DeclutterChrome.hideMiniPlayerBar, !self.target.isHidden else { return }

        self.target.isHidden = true
        DeclutterChrome.reportOnce("miniPlayer", "mini player bar hidden (TouchPassthroughView)")
    }
}

/// 标签栏上方那层渐隐（内容滚到标签栏下面时的遮罩）。
class TabBarFadeHideHook: ClassHook<UIView> {
    typealias Group = HideTabBarFadeGroup
    static let targetName = "_TtC23NavigationUI_TabBarImpl18TabBarGradientView"

    func layoutSubviews() {
        orig.layoutSubviews()

        guard DeclutterChrome.hideTabBarFade, !self.target.isHidden else { return }

        self.target.isHidden = true
        DeclutterChrome.reportOnce("tabBarFade", "tab bar fade hidden (TabBarGradientView)")
    }
}

/// free-tier 提示条。
class FreeTierBarHideHook: ClassHook<UIView> {
    typealias Group = HideFreeTierGroup
    static let targetName =
        "_TtC44LimitedExperienceIndicator_MessageBarRuntime29LimitedExperienceIndicatorBar"

    func layoutSubviews() {
        orig.layoutSubviews()

        guard DeclutterChrome.hideFreeTierBar, !self.target.isHidden else { return }

        self.target.isHidden = true
        DeclutterChrome.reportOnce("freeTier", "free tier indicator bar hidden")
    }
}

func activateDeclutterChrome() {
    // 三个 group 各自按"类在不在"决定装不装（本仓库既有做法）：目标类缺失时 Orion
    // 会报一条非致命错误，不如自己先判掉，日志也更干净。
    if NSClassFromString(MiniPlayerBarHideHook.targetName) != nil {
        HideMiniPlayerGroup().activate()
    } else {
        writeDebugLog("[Declutter] missing \(MiniPlayerBarHideHook.targetName) — mini player hook inactive")
    }

    if NSClassFromString(TabBarFadeHideHook.targetName) != nil {
        HideTabBarFadeGroup().activate()
    } else {
        writeDebugLog("[Declutter] missing \(TabBarFadeHideHook.targetName) — tab bar fade hook inactive")
    }

    if NSClassFromString(FreeTierBarHideHook.targetName) != nil {
        HideFreeTierGroup().activate()
    } else {
        writeDebugLog("[Declutter] missing \(FreeTierBarHideHook.targetName) — free tier hook inactive")
    }

    writeDebugLog(
        "[Declutter] installed (miniPlayer="
            + "\(DeclutterChrome.hideMiniPlayerBar ? "ON" : "OFF")"
            + " tabBarFade=\(DeclutterChrome.hideTabBarFade ? "ON" : "OFF")"
            + " freeTier=\(DeclutterChrome.hideFreeTierBar ? "ON" : "OFF"))"
    )
}
