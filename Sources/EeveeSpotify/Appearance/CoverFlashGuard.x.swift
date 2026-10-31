import Orion
import UIKit

/// 换歌那一瞬间原生大封面会闪一下：contentlayer 换的是 cell，也就是换了一个新的封面对象。
/// 「按住封面」那条路（`NowPlayingLyricsPlate.keepNativeCoverHidden`）挂在 `DeclutterChrome`
/// 的 ≈0.3s 复查节拍上，动作又是"再找一遍哪张是当前封面"，所以新封面先露，
/// 且换歌那一瞬间的判据常挑中旧那张（原生大封面已是新歌，我们的缩略图还是上一首）。
///
/// 因此改成事件驱动：在封面容器 `CoverArtTiltView` 的 `layoutSubviews` 里直接通知。
/// 不把节拍调快 —— 0.3s 就是空档本身，轮询再快也只是把空档变小，
/// 而且违背「不新开定时器 / 不把既有节拍改成每帧」的纪律。
///
/// 目标类选 `CoverArtTiltView` 而非 `Encore.ImageView`：前者就是装封面那张图的容器
/// （真机树里每份都是 `14.CoverArtTiltView@0,6,366,366`），后者全 App 到处都是。
///
/// 坑：hook 方法不能写 `@MainActor` —— Orion 的代码生成器按源码文本拼接会拼出
/// `@MainActoroverride`，主线程用 `onMainThreadSync` 显式表达（本仓库既有做法）。
struct CoverFlashGuardGroup: HookGroup {}

/// 封面容器的布局事件源：挂在这里比挂 `Encore.ImageView` 精准得多。
class CoverArtTiltLayoutHook: ClassHook<UIView> {
    typealias Group = CoverFlashGuardGroup
    static let targetName = "_TtC35CreativeWorkCommons_CoverArtTiltKit16CoverArtTiltView"

    /// 转发布局事件。判定与写 alpha 全在 `coverDidLayOut(from:)` 里：门禁（tilt 在窗口里、
    /// 够大、祖先里有 `CoverArtCellImpl`）+ 只对与 tilt 等大的那个直接子视图写 `alpha = 0`。
    /// 不走整树搜索，所以不必节流、也不会挑错对象。
    func layoutSubviews() {
        orig.layoutSubviews()

        // 先把 `target` 取成局部量再进闭包：Orion 生成的那个属性挂在 hook 实例上，
        // 闭包是 `@escaping`，直接写 `self.target` 会把 hook 实例一起捕获住。
        let tilt = self.target
        onMainThreadSync {
            NowPlayingLyricsPlate.coverDidLayOut(from: tilt)
            // 换歌换了一个新的封面对象，当场把它摆到满屏那个位置：不等下一拍，
            // 否则会闪一下 366pt 的原生封面。
            NowPlayingIOS27.coverDidLayOut(from: tilt)
        }
    }
}

/// 装这一组。目标类缺失就只打一行日志、不留给 Orion 报非致命错误。
///
/// 不按开关决定装不装：这条 hook 只转发一个事件，门禁在
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
