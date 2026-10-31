// 清爽开关的 Orion 挂点 + 复核节拍。从 `DeclutterChrome.x.swift` 原样拆出。
import Foundation
import Orion
import UIKit
import ObjectiveC.runtime

struct HideMiniPlayerGroup: HookGroup {}
struct HideHomeHeaderGroup: HookGroup {}
struct HideTransportChromeGroup: HookGroup {}

/// 关联对象的键。file-scope 的 `var` 地址稳定，这是本仓库既有的写法
/// （见 `UpsellPopupBlocker.x.swift` 的 `upsellPopupAssociationKey`）。
class MiniPlayerBarHideHook: ClassHook<UIView> {
    typealias Group = HideMiniPlayerGroup
    static let targetName =
        "_TtC22NowPlaying_BarPageImplP33_CCC0D2EEA6D4725EECD8965E8C38C86D20TouchPassthroughView"

    func layoutSubviews() {
        orig.layoutSubviews()

        // 顺手登记：之后这个实例就被复查（`DeclutterChrome.reconcile`）持续盯着，
        // 即使它自己后来不再收到 layout 回合。
        DeclutterChrome.note(self.target, as: .miniBar)

        // 迷你播放条的**液态玻璃胶囊**（`MiniBarGlass.swift`）蹭的就是这个布局回调 ——
        // 同一个类上再挂一个 ClassHook 是没验证过的行为，所以那边只画、不钩。
        // 顺序无所谓：藏掉时它照样画（看不见而已），开关关掉它会自己撤掉并把底色还原。
        // ⚠️ hook 方法体是**非隔离**的（Orion 的代码生成器会把 `@MainActor` 拼坏，见
        // `LyricsChromeVisibility.swift` 顶上那段），所以这里必须套 `onMainThreadSync`。
        let host = self.target
        onMainThreadSync { MiniBarGlassPlate.apply(to: host) }

        DeclutterChrome.apply(
            wantHidden: DeclutterChrome.hideMiniPlayerBar,
            to: self.target,
            reportKey: "miniPlayer",
            reportMessage: "mini player bar hidden (TouchPassthroughView)"
        )
    }
}

/// 封面下那行跟唱歌词。
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

        // 只登记；**真正动手的是 `reconcile` 那条节拍里的 `applySingalongLine`**
        // —— 那条路手上有页面根，而这里只有这一行自己。
        DeclutterChrome.note(self.target, as: .singalong)
    }
}

/// 听歌页那排胶囊：「切换至视频」+「显示 / 隐藏歌词」。
///
/// ⚠️ 它是**通用类**（`Encore.Button.Primary`，全 App 都在用），所以判据只认**无障碍 id**
/// `lyrics-npv-switch-button` /
/// `nowplaying-npv-musicvideos-switch`。命中不了就什么都不做 —— 宁可漏，不可误伤别的按钮。
///
/// 为什么挂 `Encore.Button.Primary` 而不是"每 0.3s 找一遍"：这两颗是**会随播放内容出现**
/// 的（有 MV 的歌才出现「切换至视频」；歌词状态一变那颗胶囊就在 52pt / 104pt 之间重排），
/// 轮询永远慢半拍。挂在这里 ⇒ **它一布局就被按住**，用户看不到闪一下。
///
/// ⚠️ 照抄仓库既有写法：hook 方法体是**非隔离**的，而 `DeclutterChrome` 是纯 enum、
/// `notePillIfOurs` 不碰任何 `@MainActor` 类型 —— 与 `SingalongLyricsLineHideHook` 同一条路。
struct HideNowPlayingPillsGroup: HookGroup {}

class NowPlayingPillHideHook: ClassHook<UIView> {
    typealias Group = HideNowPlayingPillsGroup
    static let targetName = "_TtCCE16Encore_ButtonKitO16EncoreFoundation6Encore6Button7Primary"

    func layoutSubviews() {
        orig.layoutSubviews()

        DeclutterChrome.notePillIfOurs(self.target)
    }
}

/// 首页顶部那条（问候语 + 筛选胶囊）。
class HomeHeaderHideHook: ClassHook<UIView> {
    typealias Group = HideHomeHeaderGroup
    static let targetName =
        "_TtC19Home_FunkisPageImplP33_297EC57FD07AE9FCEAA7B66079FC278C14HomeHeaderView"

    func layoutSubviews() {
        orig.layoutSubviews()

        DeclutterChrome.note(self.target, as: .homeHeader)

        DeclutterChrome.apply(
            wantHidden: DeclutterChrome.hideHomeHeader,
            to: self.target,
            reportKey: "homeHeader",
            reportMessage: "home header hidden (HomeHeaderView)"
        )
    }
}

/// 传输控件那一排：设备按钮（自己）+ 加号按钮（同级的普通 UIButton）。
///
/// 挂在 `ConnectButtonView` 上，因为它是这一批里唯一有"专属类名 + 稳定 id"的节点；
/// 加号只能从它的兄弟里按 id 找（`Components.UI.AddToButton`）。
class TransportChromeHideHook: ClassHook<UIView> {
    typealias Group = HideTransportChromeGroup
    static let targetName = "_TtC23Connect_EntryPointsImpl17ConnectButtonView"

    func layoutSubviews() {
        orig.layoutSubviews()

        DeclutterChrome.apply(
            wantHidden: DeclutterChrome.hideConnectButton,
            to: self.target,
            reportKey: "connectButton",
            reportMessage: "connect button hidden (Components.ConnectButtonOutputSwitcher)"
        )

        guard let siblings = self.target.superview?.subviews else { return }

        for sibling in siblings where sibling !== self.target {
            guard sibling.accessibilityIdentifier == "Components.UI.AddToButton" else { continue }

            DeclutterChrome.apply(
                wantHidden: DeclutterChrome.hideAddToButton,
                to: sibling,
                reportKey: "addToButton",
                reportMessage: "add-to button hidden (Components.UI.AddToButton)"
            )
        }
    }
}

/// 复查的**宿主**。
///
/// 为什么是 `MainWindow`：真机树里它是 `0.MainWindow@0,0,414,896,id=spotify-main-window`，
/// 运行期名 `_TtC30ContainerUI_RootUIInternalImpl10MainWindow`；它在**每一份**转储里都在，
/// 而且每次布局都会走一遍 —— 拿它当节拍器，就不会再出现"目标被我们藏掉之后再没有 layout"
/// 这种死结。
struct DeclutterReconcileGroup: HookGroup {}

class DeclutterReconcileHook: ClassHook<UIView> {
    typealias Group = DeclutterReconcileGroup
    static let targetName = "_TtC30ContainerUI_RootUIInternalImpl10MainWindow"

    func layoutSubviews() {
        orig.layoutSubviews()
        DeclutterChrome.reconcile(in: self.target)
    }
}
