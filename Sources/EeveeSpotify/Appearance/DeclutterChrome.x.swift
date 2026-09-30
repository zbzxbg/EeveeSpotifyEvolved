import Foundation
import Orion
import UIKit
import ObjectiveC.runtime

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
/// ⚠️ 可撤销但**只管自己**：Spotify 自己在来回切这几处的 `isHidden`（真机树里同一个
/// `TouchPassthroughView` 一次是 `hidden`、一次不是 —— 取决于有没有在播放）。
/// 所以：
///   · 开关打开 → 藏，并**用关联对象记住"这一层是我藏的"**；
///   · 开关关掉 → 只撤回**我们**藏的那一次，Spotify 自己藏的一律不碰。
/// 第一版没有这条，结果是"关掉开关它也不回来"（用户以为坏了）—— 现在关掉即恢复。
struct HideMiniPlayerGroup: HookGroup {}
struct HideTabBarFadeGroup: HookGroup {}
struct HideFreeTierGroup: HookGroup {}

/// 关联对象的键。file-scope 的 `var` 地址稳定，这是本仓库既有的写法
/// （见 `UpsellPopupBlocker.x.swift` 的 `upsellPopupAssociationKey`）。
private var declutterHiddenByUsKey: UInt8 = 0

private func wasHiddenByUs(_ view: UIView) -> Bool {
    (objc_getAssociatedObject(view, &declutterHiddenByUsKey) as? NSNumber)?.boolValue == true
}

private func markHiddenByUs(_ view: UIView) {
    objc_setAssociatedObject(
        view,
        &declutterHiddenByUsKey,
        NSNumber(value: true),
        .OBJC_ASSOCIATION_RETAIN_NONATOMIC
    )
}

private func clearHiddenByUs(_ view: UIView) {
    objc_setAssociatedObject(view, &declutterHiddenByUsKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
}

enum DeclutterChrome {

    static var hideMiniPlayerBar: Bool { UserDefaults.hideMiniPlayerBar }
    static var hideTabBarFade: Bool { UserDefaults.hideTabBarFade }
    static var hideFreeTierBar: Bool { UserDefaults.hideFreeTierBar }

    /// 封面与歌名之间那一行"跟唱单行歌词"。
    ///
    /// 为什么它上面显示的是**我们的**歌词：`NgzhwmSettingsViewModel.isOfficialLyricsHidden`
    /// 是**数据层**的开关（取不到我们的词时用占位 payload 顶掉 Spotify 的歌词），它不隐藏
    /// 视图。反过来，我们供给的歌词会被 Spotify **自己的**视图渲染 —— 包括这个跟唱单行
    /// 视图。所以那一行不是"挂错了"，而是"Spotify 的壳 + 我们的字"。
    ///
    /// 真机证据（日志 6 的 NPV 转储）：
    ///   `22.CoverArtTiltView@15,0,335,335`            ← 封面
    ///   `22.LyricsContainerView@0,335,366,120`        ← 就在封面正下方
    ///   `23.LyricsView@0,0,366,120,id=singalong-lyrics-view`
    ///
    /// 默认**关**：用户说过那一行本身不是问题（他反馈的是"逐词歌词开、更好的逐词歌词关"
    /// 时逐行歌词挂错地方，已修在 `InlineLyricsHostLocator`）。这个开关只留作选择。
    static var hideSingalongLine: Bool { UserDefaults.hideSingalongLine }

    private static var reported: Set<String> = []

    /// 每个开关只报一次：证明 hook 真的跑到了，并说明藏的是哪一个。
    /// 和 AMOLED 那边同一个道理 —— 验收靠日志，不靠眼睛。
    static func reportOnce(_ key: String, _ message: String) {
        guard !reported.contains(key) else { return }
        reported.insert(key)
        writeDebugLog("[Declutter] \(message)")
    }

    /// 藏 / 撤销，两个方向都幂等。
    ///
    /// 关键区别在"谁藏的"：`isHidden == true` 可能是 Spotify 自己写的（没在播放时
    /// 迷你条本来就不显示）。所以撤销只针对被我们打过标的那些视图。
    static func apply(
        wantHidden: Bool,
        to view: UIView,
        reportKey: String,
        reportMessage: String
    ) {
        if wantHidden {
            guard !view.isHidden else { return }

            view.isHidden = true
            markHiddenByUs(view)
            reportOnce(reportKey, reportMessage)
            return
        }

        guard wasHiddenByUs(view) else { return }

        view.isHidden = false
        clearHiddenByUs(view)
        writeDebugLog("[Declutter] \(reportKey) restored")
    }
}

/// 迷你播放条（标签栏上方那条，用户照片里就是它）。藏的是它的 host：
/// host 的 frame 正好等于 bar 区域（414x64），藏它才不会留一条空白。
class MiniPlayerBarHideHook: ClassHook<UIView> {
    typealias Group = HideMiniPlayerGroup
    static let targetName =
        "_TtC22NowPlaying_BarPageImplP33_CCC0D2EEA6D4725EECD8965E8C38C86D20TouchPassthroughView"

    func layoutSubviews() {
        orig.layoutSubviews()

        DeclutterChrome.apply(
            wantHidden: DeclutterChrome.hideMiniPlayerBar,
            to: self.target,
            reportKey: "miniPlayer",
            reportMessage: "mini player bar hidden (TouchPassthroughView)"
        )
    }
}

/// 标签栏上方那层渐隐（内容滚到标签栏下面时的遮罩）。
class TabBarFadeHideHook: ClassHook<UIView> {
    typealias Group = HideTabBarFadeGroup
    static let targetName = "_TtC23NavigationUI_TabBarImpl18TabBarGradientView"

    func layoutSubviews() {
        orig.layoutSubviews()

        DeclutterChrome.apply(
            wantHidden: DeclutterChrome.hideTabBarFade,
            to: self.target,
            reportKey: "tabBarFade",
            reportMessage: "tab bar fade hidden (TabBarGradientView)"
        )
    }
}

/// free-tier 提示条。
class FreeTierBarHideHook: ClassHook<UIView> {
    typealias Group = HideFreeTierGroup
    static let targetName =
        "_TtC44LimitedExperienceIndicator_MessageBarRuntime29LimitedExperienceIndicatorBar"

    func layoutSubviews() {
        orig.layoutSubviews()

        DeclutterChrome.apply(
            wantHidden: DeclutterChrome.hideFreeTierBar,
            to: self.target,
            reportKey: "freeTier",
            reportMessage: "free tier indicator bar hidden"
        )
    }
}

/// 封面下那行跟唱歌词。
///
/// ⚠️ 它是**通用类**（`Lyrics_TextComponentImpl.LyricsView`），别的地方也可能用同一类，
/// 所以判据只认那个 id：`accessibilityIdentifier == "singalong-lyrics-view"`
/// （真机树实测值）。命中不了就什么都不做 —— 宁可漏，不可误伤别处的歌词视图。
///
/// 已知局限：只藏视图本身，**120pt 的槽位可能还在**（容器 `LyricsContainerView` 是
/// Spotify 的布局，动它有把歌词卡一起弄坏的风险）。真机如果看出空档，再单独处理。
struct HideSingalongLineGroup: HookGroup {}

class SingalongLyricsLineHideHook: ClassHook<UIView> {
    typealias Group = HideSingalongLineGroup
    static let targetName = "_TtC24Lyrics_TextComponentImpl10LyricsView"

    func layoutSubviews() {
        orig.layoutSubviews()

        guard self.target.accessibilityIdentifier == "singalong-lyrics-view" else { return }

        DeclutterChrome.apply(
            wantHidden: DeclutterChrome.hideSingalongLine,
            to: self.target,
            reportKey: "singalongLine",
            reportMessage: "singalong single-line lyrics hidden (id=singalong-lyrics-view)"
        )
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

    if NSClassFromString(SingalongLyricsLineHideHook.targetName) != nil {
        HideSingalongLineGroup().activate()
    } else {
        writeDebugLog("[Declutter] missing \(SingalongLyricsLineHideHook.targetName) — singalong hook inactive")
    }

    writeDebugLog(
        "[Declutter] installed (miniPlayer="
            + "\(DeclutterChrome.hideMiniPlayerBar ? "ON" : "OFF")"
            + " tabBarFade=\(DeclutterChrome.hideTabBarFade ? "ON" : "OFF")"
            + " freeTier=\(DeclutterChrome.hideFreeTierBar ? "ON" : "OFF")"
            + " singalongLine=\(DeclutterChrome.hideSingalongLine ? "ON" : "OFF"))"
    )
}
