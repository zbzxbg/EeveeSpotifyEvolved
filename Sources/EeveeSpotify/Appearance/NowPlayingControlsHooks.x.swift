// 播放器控件的 Orion 挂点与触摸目标。从 `NowPlayingControlsPlate.swift` 原样拆出。
import Foundation
import SwiftUI
import UIKit
import Orion
import ObjectiveC.runtime

struct NowPlayingControlsGroup: HookGroup {}
/// **单独一组**：这一组是"探测到才挂"的，不能和上面那组共用 —— 否则探测失败会把
/// 已经能跑的 `PlaybackControlsElementsUnit` 钩子一起关掉。
struct NowPlayingTapGroup: HookGroup {}

/// 播放键那个类上的 `uiButtonTapped` 钩子（**探测到才挂**，见 `installTapTargetIfNeeded`）。
///
/// ⚠️ 实测在 9.1.88 上**从不触发**：真正生效的是挂在播放键内部 `UIControl` 上的
/// `NowPlayingPlayTapTarget` 那条。留着它只是多一次 `class_getInstanceMethod` 探测的代价。
class PlayButtonTapHook: ClassHook<UIView> {
    typealias Group = NowPlayingTapGroup
    static var targetName = "_TtC28EncoreConsumerMobile_BaseKit14PlayButtonView"

    /// ⚠️ hook 方法**不能**标 `@MainActor`（Orion 的代码生成器按源码文本拼接，会拼出
    /// `@MainActoroverride`）—— 成文规矩见 `LyricsChromeVisibility.swift`。
    func uiButtonTapped() {
        orig.uiButtonTapped()
        let hooked = self.target
        onMainThreadSync {
            guard NowPlayingControlsPlate.isEnabled else { return }
            // **这一行在身份判断之前**。
            // 而那一条只能证明
            // "门面没收到"。这一行把"看到了但没认下"与"根本没看到"分开。
            // ⚠️ 实测：这条路（`uiButtonTapped`）在 9.1.88 上**从不触发** ——
            // 真正生效的是 `installTapTargetIfNeeded` 挂在内部 `UIControl` 上的那条。
            NowPlayingControlsPlate.noteTapSeen(from: hooked)
            NowPlayingControlsPlate.notePlayTapped(from: hooked)
        }
    }
}

/// 这一排的容器。**只做一件事**：每次它布局完，把字形摆正 + 跟着播放状态换播放/暂停字形。
///
/// 为什么挂它而不是只靠 0.3s 节拍：播放键的字形要跟着**播放状态**变，而状态由用户点按钮触发
/// —— 点完紧接着就是这个容器的一次布局回合，挂在这里比节拍准。
/// （`layoutSubviews` 是 UIView 一定会被 UIKit 调用的方法，不存在"类没覆写"那条风险。）
class PlaybackControlsUnitHook: ClassHook<UIView> {
    typealias Group = NowPlayingControlsGroup
    static var targetName = "_TtC20NowPlaying_ModesImpl28PlaybackControlsElementsUnit"

    func layoutSubviews() {
        orig.layoutSubviews()

        // ⚠️ hook 方法**不能**标 `@MainActor`（Orion 的代码生成器按源码文本拼接，
        // 会拼出 `@MainActoroverride` 这种非法属性 —— 成文规矩见 `LyricsChromeVisibility.swift`）。
        // 布局回合本来就在主线程，用仓库既有的 `onMainThreadSync` 把这件事显式表达出来：
        // 已是主线程 ⇒ 同步执行（不改时序），万一不是 ⇒ 异步派发而不是崩。
        onMainThreadSync {
            guard NowPlayingControlsPlate.isEnabled else { return }
            let unit = self.target
            NowPlayingControlsPlate.refreshGlyphs(
                previous: NowPlayingControlsPlate.button(NowPlayingControlsPlate.previousButtonID, in: unit),
                play: NowPlayingControlsPlate.button(NowPlayingControlsPlate.playButtonID, in: unit),
                next: NowPlayingControlsPlate.button(NowPlayingControlsPlate.nextButtonID, in: unit)
            )
        }
    }
}

/// 挂在播放键内部 `UIControl` 上的触摸目标（真正生效的那条点击路）。
///
/// ⚠️ `@MainActor` 必须留着：它回调的 `NowPlayingControlsPlate` 整个是 main-actor
/// 隔离的，而 `onMainThreadSync` 里的 `MainActor.assumeIsolated` 也要求闭包在 main actor 上。
@MainActor
final class NowPlayingPlayTapTarget: NSObject {

    static let shared = NowPlayingPlayTapTarget()

    @objc func tapped() {
        onMainThreadSync { NowPlayingControlsPlate.notePlayTappedFromControl() }
    }
}

// MARK: - 接线
//
// 装这一组 hook。
//
// `layoutSubviews` 是 UIView **一定会被调用**的方法（不是可选方法），所以这里不存在
// "类没覆写就 `Failed to hook method`"那条风险；但**类本身在不在**仍要先问一句
// （`NSClassFromString`），不在就只打一行日志、不留给 Orion 报非致命错误 —— 仓库惯例。
//
// **第二条钩子走"探测再挂"**（`uiButtonTapped`）：那个选择器只出现在 pw 自己的
// `objc-methods.txt` 里（pw 基线 9.1.78），而**我们的 证明不了它在不在**
// —— 它的 `[selectors]` 桶连 `layoutSubviews` / `viewDidAppear:` 都没有，不是完整清单。
// 所以先用 `class_getInstanceMethod` 探一次：探到才激活；探不到只打一行，
// **功能不消失**，只是字形退回"跟布局回合 + 0.3s 节拍"（慢一拍）。
// 这正是仓库里 SponsorBlock 探测 `addPlayerObserver:` 的同一套写法。
