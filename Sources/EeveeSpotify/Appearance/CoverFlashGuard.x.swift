import Orion
import UIKit

/// 换歌那一瞬间的「大封面闪一下」（照片 61）。
///
/// ## 现场（日志 53 + 照片 61）
///
/// 换歌时 contentlayer **换的是 cell**，也就是换了一个**新的封面对象**：
///
/// ```
/// 08:08:29  #14  10.CoverArtCellImpl@…,id=nowplaying-contentlayer-cell-5000          ← 可见
/// 08:08:35  #15  10.CoverArtCellImpl@…,id=nowplaying-contentlayer-cell-5000,hidden   ← 被我们按住了
/// 08:08:35  #15  10.CoverArtCellImpl@…,id=nowplaying-contentlayer-cell-5001          ← 新的，露着
/// ```
///
/// 而"按住封面"这条路（`NowPlayingLyricsPlate.keepNativeCoverHidden`）挂在
/// `DeclutterChrome` 那条 **≈0.3s 的复查节拍**上 ⇒ 新封面会**先露 0.3s**，然后才被按掉。
/// 照片 61 就是这个空档：原生封面（`24,163,366,366`，那时还只是 loading 占位）
/// 整张铺在歌词底下，而我们的缩略图与上移后的标题都已经就位。
///
/// ## 为什么是 hook，而不是"把节拍调快"
///
/// 0.3s **就是**空档本身 —— 轮询再快也只是把空档变小，而且违背仓库纪律
/// 「不新开定时器 / 不把既有节拍改成每帧」。这里要的是**事件**：
/// 封面自己被布局的那一刻。
///
/// ## 目标类的选择
///
/// `CreativeWorkCommons_CoverArtTiltKit.CoverArtTiltView`
/// （`dump-9.1.88.txt:11933`，真机 `[NPVTree]` 里每一份都有 `14.CoverArtTiltView@0,6,366,366`）：
/// 它就是**装封面那张图**的容器 —— pw v0.21.1 挑"正在显示的那张封面"用的也正是它
/// （见 `Tools/eevee-hookfinder/SPOTIPW_0211_PORT_ASSESSMENT.md` §2 的 14 个目标之一）。
/// 挂在它身上，比挂在 `Encore.ImageView`（全 App 到处都是）上精准得多。
///
/// ## 纪律
///
/// * hook 方法**不写 `@MainActor`**（Orion 的代码生成器按源码文本拼接，会拼出
///   `@MainActoroverride`）—— 用 `onMainThreadSync` 显式表达主线程（本仓库既有做法）；
/// * 真正的动作全在 `NowPlayingLyricsPlate.coverDidLayOut(from:)` 里：那里有门禁
///   （只在"我们确实铺着"时动）、自节流（50ms）与页面存活判据；
///   这里**只转发一个事件**，不改任何别人的视图。
struct CoverFlashGuardGroup: HookGroup {}

class CoverArtTiltLayoutHook: ClassHook<UIView> {
    typealias Group = CoverFlashGuardGroup
    static let targetName = "_TtC35CreativeWorkCommons_CoverArtTiltKit16CoverArtTiltView"

    func layoutSubviews() {
        orig.layoutSubviews()

        // ⚠️ 先把 `target` 取成局部量再进闭包（本仓库既有做法）：
        //    Orion 生成的那个属性挂在 hook 实例上，闭包是 `@escaping`，直接写 `self.target`
        //    会把 hook 实例一起捕获住。
        let tilt = self.target
        onMainThreadSync { NowPlayingLyricsPlate.coverDidLayOut(from: tilt) }
    }
}

/// 装这一组。目标类缺失就只打一行日志、不留给 Orion 报非致命错误（本仓库既有做法）。
///
/// ⚠️ **不按开关决定装不装**：这条 hook 只转发一个事件，门禁（"我们铺着吗"）在
/// `NowPlayingLyricsPlate.coverDidLayOut(from:)` 里 —— 而"用户中途把开关打开"是常态，
/// 装了再判比"按开关重装"稳（后者要处理卸载，仓库里没有先例）。
func activateCoverFlashGuard() {
    if NSClassFromString(CoverArtTiltLayoutHook.targetName) != nil {
        CoverFlashGuardGroup().activate()
        writeDebugLog("[CoverGuard] armed on \(CoverArtTiltLayoutHook.targetName)")
    } else {
        writeDebugLog(
            "[CoverGuard] missing \(CoverArtTiltLayoutHook.targetName)"
                + " — the track-change cover flash cannot be closed event-driven (falls back to the 0.3s tick)"
        )
    }
}
