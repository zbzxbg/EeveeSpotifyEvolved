import Foundation
import UIKit

/// 一次性「**探针包**」：把"只有装一次机才知道"的只读事实**一次问完**。
///
/// ## 为什么要集中在一个文件里
///
/// 本仓库一次「编译 → 装机 → 抓日志」≈ 几十分钟，而很多决定只依赖**只读事实**
/// （"这个类在不在"就够了）。散着放就得一次问一个、装一次机问一遍。
/// 集中在这里 ⇒ **一次装机全部拿到**；查完之后整块删掉即可（不承载任何功能）。
///
/// ## 开关
///
/// 就是「调试 → 启用日志记录」—— `writeDebugLog` 自己会挡（见 `Tweak.x.swift`），
/// 所以普通用户的日志里看不到它。**不需要新开关**。
///
/// ## 它回答什么
///
/// spoti.pw **v0.21.1**（GPL-3.0，可复用；≥v0.22.0 是 PolyForm，绝不碰）的播放页/手势
/// 一共 hook 了 14 个类，另外有 3 个类它用到、但我们在 9.1.88 的 dump 里**没查到**。
/// 这一行把"哪些还搬得动"一次说清 —— 见
/// `Tools/eevee-hookfinder/SPOTIPW_0211_PORT_ASSESSMENT.md` §2。
enum ProbePack {

    static let logTag = "Probe"

    /// 本轮的标记：日志里看到它就说明这份构建带探针包。
    private static let marker = "probe-pack v1"

    /// pw 在**播放页**上 hook 的 13 个类（v0.21.1，逐个来自它每个 `.x` 的 `SGRequireClasses`）。
    private static let pwPlayerTargets: [String] = [
        "_TtC12Element_List18CollectionViewCell",
        "_TtC21NowPlaying_ScrollImpl23NPVScrollViewController",
        "_TtC21NowPlaying_ScrollImpl27NPVBackgroundViewController",
        "_TtC35NowPlaying_ContentLayerPlatformImpl24AccessibleCollectionView",
        "_TtC35CreativeWorkCommons_CoverArtTiltKit16CoverArtTiltView",
        "_TtC22Lyrics_NPVContainerKit19LyricsContainerView",
        "_TtC20NowPlaying_ModesImpl18HeaderElementsUnit",
        "_TtC20NowPlaying_ModesImpl18FooterElementsUnit",
        "_TtC20NowPlaying_ModesImpl19DurationElementUnit",
        "_TtC20NowPlaying_ModesImpl20FloatingElementsUnit",
        "_TtC20NowPlaying_ModesImpl23InformationElementsUnit",
        "_TtC20NowPlaying_ModesImpl28PlaybackControlsElementsUnit",
        "_TtC28EncoreConsumerMobile_BaseKit14PlayButtonView",
        "_TtC19NowPlaying_ViewImpl24NowPlayingViewController",
    ]

    /// ★ 三条**没查到**的（9.1.88 的 `dump-9.1.88.txt` 里没有），各自卡着一条功能线：
    ///   · `SPTBarOverlayPresentationTransition` —— morph 转场（pw `PlayerMorph.x` 的唯一目标）
    ///   · `SPTBarInteractivePresentationController` —— pw 注释里"下拉关闭挂在这条列表的
    ///     pan recogniser 上"的那个类（我们的"一屏"是**绕过**它做的，所以要确认它还在不在）
    ///   · `SPTNowPlayingPlaybackControllerImplementation` —— pw 手势层拿播放控制用的类
    ///     （⚠️ 我们已经在同类问题上栽过：`SPTPlayerServiceImplementation` 在 9.1.86 上不存在，
    ///     导致 `SponsorBlockSkipper` 静默失效）
    private static let pwUnverifiedTargets: [String] = [
        "SPTBarOverlayPresentationTransition",
        "SPTBarInteractivePresentationController",
        "SPTNowPlayingPlaybackControllerImplementation",
    ]

    /// 每次启动跑一次。**只打日志，什么都不要改**。
    static func runOnce() {
        writeDebugLog("[\(logTag)] \(marker) — 开始一次性自检")

        report(pwPlayerTargets, label: "pw 播放页目标")
        report(pwUnverifiedTargets, label: "pw 用到但 dump 里没查到的")
    }

    /// 一行说清"这批类里哪几个不在"。**清单为空也要打**（"全在"本身是结论）。
    private static func report(_ names: [String], label: String) {
        var missing: [String] = []
        for name in names where NSClassFromString(name) == nil {
            missing.append(name)
        }

        let head = "[\(logTag)] \(label)：\(names.count) 个，在 \(names.count - missing.count) 个"
        guard !missing.isEmpty else {
            writeDebugLog(head + "，缺 0 个 — 全部可搬")
            return
        }
        writeDebugLog(head + "，**缺 \(missing.count) 个** — " + missing.joined(separator: ", "))
    }
}
