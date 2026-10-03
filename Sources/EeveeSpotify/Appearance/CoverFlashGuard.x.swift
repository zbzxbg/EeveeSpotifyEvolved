import Orion
import UIKit

/// 换歌那一瞬间的「大封面闪一下」（照片 61 → 还没好 → 照片 64）。
///
/// ## 现场（日志 53/54 + 照片 61/64）
///
/// 换歌时 contentlayer **换的是 cell**，也就是换了一个**新的封面对象**：
///
/// ```
/// 08:08:29  #14  10.CoverArtCellImpl@…,id=nowplaying-contentlayer-cell-5000          ← 可见
/// 08:08:35  #15  10.CoverArtCellImpl@…,id=nowplaying-contentlayer-cell-5000,hidden   ← 被我们按住了
/// 08:08:35  #15  10.CoverArtCellImpl@…,id=nowplaying-contentlayer-cell-5001          ← 新的，露着
/// ```
///
/// 而"按住封面"那条路（`NowPlayingLyricsPlate.keepNativeCoverHidden`）挂在
/// `DeclutterChrome` 那条 **≈0.3s 的复查节拍**上，动作又是"**再找一遍**哪张是当前封面"
/// ⇒ 新封面**先露**，而且换歌那一瞬间"找封面"的判据还常常挑中**旧那张**（照片 64 的现场：
/// 原生大封面是**新歌**的图，我们的缩略图却还是**上一首**的）。
///
/// ## 为什么是 hook，而不是"把节拍调快"
///
/// 0.3s **就是**空档本身 —— 轮询再快也只是把空档变小，而且违背仓库纪律
/// 「不新开定时器 / 不把既有节拍改成每帧」。这里要的是**事件**：封面自己被布局的那一刻。
///
/// ## 目标类的选择
///
/// `CreativeWorkCommons_CoverArtTiltKit.CoverArtTiltView`
/// （`dump-9.1.88.txt:11933`，真机 `[NPVTree]` 里每一份都有 `14.CoverArtTiltView@0,6,366,366`）：
/// 它就是**装封面那张图**的容器 —— pw v0.21.1 挑"正在显示的那张封面"用的也正是它
/// （`.spotify-ipa/spotipw-v0.21.1/tweak/Sources/Redesigned/Player/PlayerArtwork.x`：
/// `%hook CoverArtTiltView` → `inCoverCell(tilt)` → `coverIn(tilt)`）。
/// 挂在它身上，比挂在 `Encore.ImageView`（全 App 到处都是）上精准得多。
///
/// ## 纪律
///
/// * hook 方法**不写 `@MainActor`**（Orion 的代码生成器按源码文本拼接，会拼出
///   `@MainActoroverride`）—— 用 `onMainThreadSync` 显式表达主线程（本仓库既有做法）；
/// * 真正的动作全在 `NowPlayingLyricsPlate.coverDidLayOut(from:)` 里，而且是**局部的**：
///   门禁（tilt 在窗口里、够大、祖先里有 `CoverArtCellImpl`）+ 只对"和 tilt 等大的那个直接子视图"
///   写 `alpha = 0`（pw 的 `coverIn(tilt)`）。**不走整树搜索**，所以不必节流、也不会挑错对象。
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
