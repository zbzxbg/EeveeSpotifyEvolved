import Foundation
import SwiftUI
import UIKit
import Orion
import ObjectiveC.runtime

// 「播放器控件换成本地字形」：把 Spotify 那三个控制键（上一首 / 播放暂停 / 下一首）的
// **图标换成 Apple Music 那套细字形**，按钮本身留着。
//
// ## 这不是"自绘一整排按钮" —— 这是 pw 的做法（照抄思路，代码自己写）
//
// spoti.pw v0.21.1（GPL-3.0，隔离副本 `.spot-ipa/spotipw-v0.21.1`）的 `PlayerControls.x` 原话：
//
// > The glyphs are drawn **over Spotify's controls rather than instead of them**: each button keeps
// > its action, its enabled state, its accessibility and the Gestures zones around it, and the glyph
// > takes no touches. … Spotify's icon under it goes **transparent** on every pass.
//
// 所以三步：**① 把按钮里原来那个图标视图设成透明（不是 hidden、不是移除）；
// ② 在我们的层上画一个自己的字形；③ 我们的层不吃触摸** —— 按钮的动作/状态/无障碍原样保留。
//
// ## 为什么用 `PlaybackControlsElementsUnit`
//
// 那是 Spotify 装这一排的容器（`dump-9.1.88.txt`：`_TtC20NowPlaying_ModesImpl28PlaybackControlsElementsUnit`），
// pw 也 hook 它。**但它只是"快一点的落点"，不是唯一落点**：本文件同时被
// `NPVScrollViewControllerHook`（已证明能跑）在进页面时调一次，两条路都走同一个 `apply`，
// 所以**万一这个 hook 被 Orion 拒了，功能照样装得上**（仓库纪律：类没覆写的方法不挂）。
//
// ## 三个按钮的判据是 **id**，不是类名
//
// `SPTNowPlayingPlayButton@64x64` / `SPTNowPlayingPreviousTrackButton` / `SPTNowPlayingNextTrackButton`
// —— 前两个在真机日志里出现过 23 次，第三个由 `dump` + `ProbePack` 佐证。
// 播放键底下那层**白色圆盘**（`MixedPlayButtonDecorationView`）也一并透明掉：照片 40/41 里
// Apple Music / kumone 都是**裸字形**，没有圆盘。
//
// ## 纪律
//
// * 只改**透明度**、只**加自己的子视图** ⇒ 关掉开关 = 把字形拿走 + 把透明度写回，天然可还原；
// * 三个 key 分工：`glyphKey`（我们叠的字形）/ `playStateKey`（上次画的是哪个字形）；
// * 字形尺寸照照片：跳过键 22pt、播放键 30pt（与歌词壳那三个键同一套，见 `AppleMusicLyricsPlaybackControl`）。
//
// 开关：扩展功能 → 听歌页 →「**播放键换成本地字形**」，**默认关**。日志 tag：`[NPVControls]`。
//
// ## ★ 2026-10-05 最终形状（日志 49 + 用户澄清）：**钉整颗按钮**，字形搬到按钮的兄弟层
//
// **用户报**：「点击暂停键会有闪烁」，日志 49 里仍然如此。
//
// **照片 52/53（用户提供的"Spotify 自己的暂停按钮"）**：暂停 = **白圆盘 + 深色三角**，
// 播放 = **白圆盘 + 深色两根竖条** ⇒ ★ **原生稳态一直是"白圆盘 + 深色字形"，两个状态都有**。
// （上一轮我按一句纠正推出的"原生稳态本来就是裸字形"**作废**。）
//
// **日志 49 的现场**（02:59:31–02:59:38）：
//
// ```
// [NPVControls] … 本拍把 1 处原生内容按回透明
// [NPVControls] … 本拍把 0 处原生内容按回透明
// [NPVControls] … 本拍把 1 处原生内容按回透明     ← 1/0/1/0 交替 20+ 次、持续 7 秒
// ```
//
// ⚠️ **用户 2026-10-05 澄清**：**那 7 秒他一直在快速按暂停键**。
// ⇒ 那不是"Spotify 自己每 0.25s 写回来一次"（我先前那条推论**作废**），
// 而是**每按一次就多出一层新图形**（pw：*"The holder Spotify crossfades a snapshot of the disc in
// when play turns to pause."*）。**我们永远追不上"它出生到我们钉住之间那一帧"** ——
// 逐叶子去"按回去"的打法，**天生慢一拍**。
//
// ### 现在的做法（结构性，不再追）
//
// | 步骤 | 做法 | 为什么 |
// |---|---|---|
// | ① | 把 `SPTNowPlayingPlayButton` / `Previous` / `Next` **三颗按钮整个 layer 钉住**（`pinInvisible`） | 之后 Spotify 往它们里面塞多少新图形（圆盘 / 原生字形 / 每按一次新建的快照 / 缓冲 spinner）**出生即不可见** ⇒ 那一帧的窗口从根上没有了 |
// | ② | 钉**只动 layer、不写 `alpha`** | 渲染看**呈现层**（被钉在 0 ⇒ 看不见）；命中判定看**模型值** `alpha`（一点没变 ⇒ 按钮照样收得到触摸）。这是播放/暂停还活着的前提 |
// | ③ | 我们的字形挂到**按钮的兄弟层**（`button.superview`），每拍按按钮的框重算 | 字形若还是按钮的子视图，会**跟着被钉没**。pw 把字形放进按钮内部是为了跟"按下回弹"，而按钮整层钉住之后那份回弹本来就看不见了 ⇒ 搬出来不损失任何可见的东西 |
// | ④ | 字形 `layer.zPosition = 1000` | 快照是**后插**进来的，`bringSubviewToFront` 只在我们跑到的那一拍生效；持续生效的只有 zPosition |
// | ⑤ | 新钉住一颗按钮时补一串位置复核（`armRehide`，0.05/0.15/0.35/0.6s） | 只为了让字形跟上按钮前几拍还没稳定的坐标；**不是**"把 alpha 按回去" |
//
// **还原**：撤钉（`removeAnimation`）+ 拿走字形。**原生一个字节都没改过**（我们从没写过 `alpha`）。
//
// ### 走过的弯路（留档，别再回去）
//
// * **按类名片段 `MixedPlayButtonDecorationView` 去透明"白圆盘"**：那是 `_TtC28EncoreConsumerMobile_BaseKit29…`，
//   是**容器**（没有"图形叶子"），`alpha` 写一次会被写回，而且**圆盘只是稳态那一半**；
// * **逐叶子递归 + `1.2×` 尺寸闸 + "alpha 已是 0 的也钉"**：逻辑越来越细，但**每一版都还是慢一拍**，
//   因为新图形不是同一批实例；
// * **"写 `alpha = 0` + 复查节拍硬按回去"**：日志 49 的 `1/0/1/0` 就是这么来的。
//
// ## pw 的对照（读 `PlayerControls.x` 得来，GPL-3.0 隔离副本）
//
// 先纠正一个容易记反的点：**pw 并没有"隐藏原生按钮、自己画一个按钮"**。它文件头原话是
// *"The glyphs are drawn **over** Spotify's controls **rather than instead of them**: each button
// keeps its action, its enabled state, its accessibility and the Gestures zones around it, and the
// glyph **takes no touches**."* —— 原生按钮一直留着、能收触摸，被抑制的只是它**画出来的东西**。
// **"调度依然走原生"这半你记对了** —— 而且 pw 正是靠 hook 原生按钮自己的动作方法来对齐时机。
//
// 它比我们多打的三处补丁（都已补上）：
//
//   ① ★ **点击那一刻就翻字形**（`playTapped` + `kTapTrust = 1.2`）。它的原话：
//      *"The player's state reaches the glyph **a beat after the tap** …, which read as a
//      **slow button**. Spotify's own disc turns at the touch."*
//      我们这边量得到的滞后：投影的 `pauseThreshold = 0.35s` **加**一个 0.3~0.5s 节拍
//      ⇒ 点一下暂停，字形最坏 **~0.85s** 才翻过来。现在由 `notePlayTapped()` 当场接管。
//   ② **crossfade 快照**：*"The holder Spotify crossfades a snapshot of the disc in when play
//      turns to pause."* —— 换状态时 Spotify 会**交叉淡入一张圆盘快照**，装在一个**恰好是纯
//      `UIView`** 的容器里。常规走查的 `1.2×` 尺寸闸**可能**放过它（pw 那段就**没有**尺寸闸）
//      ⇒ 对播放键的那类容器取消尺寸闸。
//   ③ **缓冲 spinner 立着时把我们的字形 alpha 压 0**（`spinnerShowing`）—— 否则"缓冲中"
//      会显示一个假的播放/暂停字形。
//
// ⚠️ **它的"认圆盘"判据不能照抄**：pw 是按**几何**认的（"按钮里那颗与按钮等大的 `UIImageView`"），
// 因为它的树（9.1.78）是 `PlayButtonView > CondensedButton(UIButton) > UIImageView 64x64`；
// 而 **9.1.88 的树里圆盘是 `MixedPlayButtonDecorationView`，和 `CondensedButton` 是兄弟**
// （日志 42/48 的 `[NPVTree]`）⇒ 照抄过去大概率就是它自己那句
// `logMissing(@"the play button's disc")`。所以我们仍按**自己的真机树**用类名判。

// MARK: - Hook（可选的加速落点）

struct NowPlayingControlsGroup: HookGroup {}
/// **单独一组**：这一组是"探测到才挂"的，不能和上面那组共用 —— 否则探测失败会把
/// 已经能跑的 `PlaybackControlsElementsUnit` 钩子一起关掉。
struct NowPlayingTapGroup: HookGroup {}

/// 探测/日志共用的选择器。放在**文件作用域**，让 hook 类里只留 Orion 认的那几样
/// （`typealias Group` / `targetName` / 覆写方法）—— 与仓库其它 hook 保持同一形状。
private let playButtonTapSelector = NSSelectorFromString("uiButtonTapped")

/// 播放键**被点的那一下** —— pw 的 `playTapped()` 靠它把字形"在触摸那一刻就翻过去"。
///
/// ⚠️ 这个选择器的来源是 **pw v0.21.1 的 `PlayerControls.x`**
/// （`%hook _TtC28EncoreConsumerMobile_BaseKit14PlayButtonView` + `- (void)uiButtonTapped`）。
/// 本仓库**没有在 9.1.88 上验证过它**（符号表查不到方法名），所以：
///   · 激活前用 `class_getInstanceMethod` 探测（见 `activateNowPlayingControls`）；
///   · 探测不到就整组不挂，绝不留给 Orion 报非致命错误；
///   · 那个类同时挂在迷你条 / 吸顶头 / 全屏歌词页上，所以**必须**在门面里按对象比对。
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
            // ★ 2026-10-07：**这一行在身份判断之前**。
            //   日志 51 里 `play button tapped —` **一行都没有**，而那一条只能证明
            //   "门面没收到"，分不出"用户没点"与"钩子根本没被调用"。
            //   这一行把两者分开：**有它、没有下面那条 = 钩子在跑、只是没认下这颗按钮**；
            //   **两条都没有 = 钩子没被调用**（那就要换落点，见 §3.4 ④）。
            NowPlayingControlsPlate.noteTapHookFired(from: hooked)
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

// MARK: - 门面

/// 「控制键换成本地字形」的门面。
///
/// ⚠️ **整个 enum 标 `@MainActor`**：它下面用的 `AppleMusicLyricsPlaybackProjection` 是
/// `@MainActor` 的，而所有入口（hook 的布局回合 / 进页面 apply / 复查节拍 / 设置页 binding）
/// 本来就都在主线程。不标的话编译器会逐行报"非隔离上下文里引用 MainActor 成员"
/// （2026-10-04 CI 抓到：`init(positionProvider:)` / `refresh()` / `isPlaying`）。
@MainActor
enum NowPlayingControlsPlate {

    static let logTag = "NPVControls"

    /// 三个按钮的 id（判据只有这一处）。`internal` 是因为上面那个 hook 也要用。
    static let previousButtonID = "SPTNowPlayingPreviousTrackButton"
    static let playButtonID = "SPTNowPlayingPlayButton"
    static let nextButtonID = "SPTNowPlayingNextTrackButton"

    /// 字形尺寸（照照片 40/41 的比例；与歌词壳那三键一致）。
    private static let skipGlyphSize: CGFloat = 22
    private static let playGlyphSize: CGFloat = 30

    /// 走查上限（本仓库纪律）。
    private static let maxNodes = 800

    /// 新钉住一颗按钮之后的**位置复核**（与 `MiniBarGlass.guardBurstDelays` 同一档）。
    /// ⚠️ 它现在**不是"把 alpha 按回去"**：钉是一次性的，此后不需要再碰；
    /// 这一串只是把我们的字形摆到那颗按钮的框上（按钮的坐标头几拍可能还没稳定）。
    private static let rehideBurstDelays: [Double] = [0.05, 0.15, 0.35, 0.6]
    private static var rehideBurstUntil: CFAbsoluteTime = 0

    private static var glyphKey: UInt8 = 0
    private static var playStateKey: UInt8 = 0

    // MARK: - 「不可见钉」

    /// 我们那条"钉住不可见"动画的 key。
    static let pinAnimationKey = "eevee-pin-invisible"

    /// 这个视图是不是已经被我们钉住了。
    static func isPinned(_ view: UIView) -> Bool {
        view.layer.animation(forKey: pinAnimationKey) != nil
    }

    /// 把视图**钉成不可见**：在它的 layer 上加一条 duration 极长、`isRemovedOnCompletion = false`
    /// 的 `opacity` 动画，把**呈现层**钉在 0。
    ///
    /// ## ★ 关键：**只动 layer，不写 `alpha`**
    ///
    /// | | 看的是哪一份 | 结果 |
    /// |---|---|---|
    /// | **渲染** | **呈现层**（被这条动画钉在 0） | 看不见 ✅ |
    /// | **命中判定** | **模型值** `alpha`（`hitTest` 读属性） | **一点没变** ✅ |
    ///
    /// ⇒ 既"看不见"又"碰得到"，而且**不需要记账还原 `alpha`**（撤掉动画就完全复原）。
    /// 这一条对播放键是必须的：那颗 `CondensedButton` **必须还能收触摸** ——
    /// pw 的 `PlayButtonView.uiButtonTapped` 就是由它发出去的；把它的 `alpha` 写成 0
    /// 会让 UIKit 的 hit-test 直接跳过它 ⇒ 播放/暂停就死了。
    ///
    /// ## 为什么不用"写 `alpha = 0` + 复查节拍硬按回去"
    ///
    /// 日志 49（02:59:31–02:59:38）里 `本拍把 1 处 / 0 处 …` 交替 20+ 次 ——
    /// 用户 2026-10-05 澄清：**那段时间他一直在快速按暂停键**。
    /// ⇒ 那不是"Spotify 自己每 0.25s 写回来一次"，而是**每按一次多出一层新的东西**：
    /// `1` = 这一拍新出现了一个要钉的，`0` = 没有。**病根是"它出生到我们钉住之间那一帧"**
    /// ~~"写模型值打不赢"~~（那条推论已作废）。
    ///
    /// 所以修法是两条一起：
    /// 1. **整颗按钮一起钉**（见 `refreshGlyphs`）：按钮的 layer 一旦钉住，
    ///    之后 Spotify 往里面塞多少新图形都**出生即不可见** ⇒ 那一帧的窗口从根上关掉；
    /// 2. **不写 `alpha`**：不去喂那场拉锯，也不破坏命中判定。
    ///
    /// ## pw 的解法（供对照）
    ///
    /// pw 用 `SGRSuppress`：把实例换成**运行时子类**、覆写 `setAlpha:` 一律转发 0
    /// （`PlayerControls.x` 原文：*"Play loses its white disc, a plain `UIImageView` the size of
    /// the button, **which SGRSuppress keeps transparent**"*）。我们不用它的三个理由：
    /// ① 纯公开 API，本机没有编译器，能少一处类型陷阱就少一处；
    /// ② ★ 它的 `subclassable()` 是 `strncmp(name,"_Tt",3) != 0 && !strchr(name,'.')`，
    ///    而我们的 `MixedPlayButtonDecorationView` 真名是 `_TtC28EncoreConsumerMobile_BaseKit29…`
    ///    （**`_Tt` 开头**）⇒ 照抄只会得到它那句 `cannot keep being suppressed, set once per call`；
    /// ③ 覆写 `setAlpha:` 会**连带改掉命中判定**（我们最不想要的那个副作用）。
    ///
    /// 还原 = `removeAnimation(forKey:)`（一行，见 `restore()`）。视图被销毁时动画随之消失。
    /// - Parameter force: 已经钉过时**要不要重申一次**（2026-10-06 新增，见下）。
    ///
    /// ## ★ 为什么必须能"重申"
    ///
    /// 旧代码是**一次性**的（`guard !isPinned(view) else { return }`，`pinButton` 也是），
    /// 于是这条钉一旦被谁盖掉或被删掉，**就再也没有任何一拍照看它**。
    ///
    /// 而日志 50 证明 Spotify **确实会写这些按钮的 `alpha`**：同一个类
    /// （`PlayButtonView`）在迷你条上的模型值是 `alpha=0.50`（`[Tree] #2..#5`，04:34:44–04:34:50）。
    /// UIKit 写 `alpha` 会往这一层加一条隐式 `opacity` 动画，而**同 keyPath 的
    /// `CABasicAnimation` 是"谁后加谁说话"** ⇒ 我们那条 `eevee-pin-invisible`
    /// 会被压在下面，那一帧原生内容就漏回来了 —— 这正是「暂停键一卡一卡的 / 会闪」的
    /// 头号嫌疑（H1）。重申 = 用同一个 key 再 `add` 一遍，把我们的动画重新排到最后。
    ///
    /// ⚠️ 重申**观感零影响**：`fromValue == toValue == 0`，呈现层一直是 0。
    /// 这一条只动呈现层，**依然一个字节都不写 `alpha`** ⇒ 命中判定不受影响。
    ///
    /// ⚠️ 但**不要无条件每拍重申**：`refreshGlyphs` 也会从
    /// `PlaybackControlsUnitHook.layoutSubviews` 跑，转场时那是**每帧 3 个**动画对象
    /// （独立只读复核指出）。所以只在"钉没了"或"有别人的 `opacity` 动画"时重申
    /// —— 两种情况都还盖得住：别人的动画只要还在，下一拍就一定看得见它。
    static func pinInvisible(_ view: UIView, force: Bool = false) {
        if !force, isPinned(view) { return }
        let pin = CABasicAnimation(keyPath: "opacity")
        pin.fromValue = 0
        pin.toValue = 0
        pin.duration = 1_000_000_000
        pin.isRemovedOnCompletion = false
        pin.fillMode = .forwards
        view.layer.add(pin, forKey: pinAnimationKey)
    }

    /// 每个被钉过的类名各报几次（第 1 / 2 / 10 / 100 次）。
    ///
    /// **为什么要报"第几次"**：日志 49 的 `1/0/1/0` 就是"每按一次多出一层"——
    /// 如果同一个类名被反复钉，说明它**每次都在被重建**，那就是还在闪的源头；
    /// 只报一次的话，这条判据就看不见。
    private static var pinnedClassCounts: [String: Int] = [:]

    private static func notePinnedClass(_ view: UIView) {
        let name = NSStringFromClass(type(of: view))
        let count = (pinnedClassCounts[name] ?? 0) + 1
        pinnedClassCounts[name] = count
        guard count == 1 || count == 2 || count == 10 || count == 100 else { return }
        // ⚠️ ★ 这一行原来**只报类名**，于是 2026-10-06 那次判读把
        // 「上一首 + 下一首」读成了"同一颗按钮被钉了两次 ⇒ 还有东西在每按一次重建"
        // —— 而那两颗按钮**共用同一个类**（`Encore.Button.Tertiary`）。
        // **类名不是身份，`accessibilityIdentifier` 才是。** 判据必须落在 id 上。
        writeDebugLog(
            "[\(logTag)] pinned \(name) id=\(view.accessibilityIdentifier ?? "-") (time \(count))"
        )
    }

    private static weak var lastUnit: UIView?
    /// 我们动过的按钮（**弱引用**）。
    ///
    /// ⚠️ 为什么要单独记：`restore()` 只认 `lastUnit` 的话，**关开关时用户多半在设置页**，
    /// 那一刻 `lastUnit` 可能已经是 nil ⇒ 播放键的 `alpha` 就永远停在我们写的 0
    ///（上一版只透明"图标叶子"，代价还小；这一版连**白圆盘**一起透明，漏还原就是"播放键没有圆底"）。
    private static let touchedButtons = NSHashTable<UIView>.weakObjects()
    /// 上一次上报的"找到几个按钮 / 隐掉几个叶子"——只在这两个数变了时才打日志
    /// （`refreshGlyphs` 在 hook 的每个布局回合都会跑，不能每次都打）。
    private static var lastReportedSignature: String = ""

    static var isEnabled: Bool { UserDefaults.nowPlayingControlGlyphs }

    // MARK: - 对外入口

    /// 从**任意一个**祖先视图（那一排的容器，或听歌页的根视图）把三个按钮找出来换掉。
    ///
    /// 三条调用路都走同一条实现：
    ///   1. `PlaybackControlsUnitHook.layoutSubviews`（快、准，且播放/暂停字形跟得住状态）；
    ///   2. `NPVScrollViewControllerHook` 的 appear（已证明能跑，兜底 —— 万一某版没这个 hook 也装得上）；
    ///   3. `DeclutterChrome` 的 0.3s 节拍（`reconcile`，负责"层被 Spotify 重排挤掉之后长回来"）。
    static func apply(to root: UIView) {
        guard isEnabled else {
            restore()
            return
        }
        guard root.window != nil else { return }

        let previous = findByIdentifier(previousButtonID, in: root)
        let play = findByIdentifier(playButtonID, in: root)
        let next = findByIdentifier(nextButtonID, in: root)

        guard previous != nil || play != nil || next != nil else { return }
        lastUnit = root

        refreshGlyphs(previous: previous, play: play, next: next)
    }

    /// 设置页切开关时叫一次：那一排还挂着就当场落地。
    static func reapply() {
        guard let root = lastUnit, root.window != nil else { return }
        apply(to: root)
    }

    /// 蹭 `DeclutterChrome` 的复查节拍：开关开着时保证三个字形还在、还对。
    ///
    /// 为什么需要：Spotify 换帧会重排那一排的 subviews（仓库里"我们被挤下去"的教训有好几处），
    /// 而按钮实例通常不换 —— 所以只要上次那个根还在窗口里，就地对一遍即可。
    /// 成本：没开开关 = 一次 bool 读；开着 = 一次 weak 读 + 一次播放状态刷新。
    @discardableResult
    static func reconcile() -> Bool {
        guard isEnabled else { return false }
        guard let root = lastUnit, root.window != nil else { return false }

        refreshGlyphs(
            previous: findByIdentifier(previousButtonID, in: root),
            play: findByIdentifier(playButtonID, in: root),
            next: findByIdentifier(nextButtonID, in: root)
        )
        return true
    }

    /// 把三个按钮的字形摆正（幂等）。hook 与节拍共用这一份。
    ///
    /// ## ★ 2026-10-05 重做：**钉整颗按钮**，字形搬到按钮的**兄弟层**
    ///
    /// 用户澄清（日志 49 的 `1/0/1/0` 那 7 秒）：**那段时间他一直在快速按暂停键**。
    /// ⇒ 那不是"Spotify 自己每 0.25s 写回一次"，而是**每按一次就多出一层新图形**
    /// （pw 说的那张 crossfade 快照），而我们**追不上"它出生到我们钉住之间那一帧"**
    /// —— 所以每按一次闪一下。
    ///
    /// 上一版是"逐个叶子/圆盘去钉"：**永远慢一拍**，因为新图形不是同一批实例。
    /// 现在改成**结构性的**：把 `SPTNowPlayingPlayButton` / `Previous` / `Next` 这**三颗按钮
    /// 整个 layer 钉住** —— 之后 Spotify 往它们里面塞多少新图形（圆盘 / 原生字形 / 每按一次
    /// 新建的快照 / 缓冲 spinner）**出生即不可见**。那一帧的窗口从根上没有了，不需要再"追"。
    ///
    /// 代价只有一个：我们的字形**不能再当按钮的子视图**（会跟着被钉没）⇒ 它挂到
    /// **按钮的兄弟层**上，每一拍照按钮的框重算位置（见 `placeGlyph`）。
    /// pw 把字形放进按钮内部是为了跟"按下回弹"，但按钮整层钉住之后那份回弹本来也看不见了
    /// —— 搬出来**不损失任何可见的东西**。
    ///
    /// ⚠️ `pinInvisible` **只动 layer、不写 `alpha`** ⇒ 三颗按钮**照样收得到触摸**
    /// （这是播放/暂停还活着的前提：pw 的 `PlayButtonView.uiButtonTapped` 是由按钮内部那颗
    /// `CondensedButton` 发出去的）。
    static func refreshGlyphs(previous: UIView?, play: UIView?, next: UIView?) {
        guard isEnabled else { return }

        var pinnedNow = 0
        var found = 0

        if let previous {
            touchedButtons.add(previous)
            if pinButton(previous) { pinnedNow += 1 }
            placeGlyph(in: previous, systemName: "backward.fill", size: skipGlyphSize)
            found += 1
        }
        if let next {
            touchedButtons.add(next)
            if pinButton(next) { pinnedNow += 1 }
            placeGlyph(in: next, systemName: "forward.fill", size: skipGlyphSize)
            found += 1
        }
        if let play {
            touchedButtons.add(play)
            lastPlayButton = play
            if pinButton(play) { pinnedNow += 1 }
            // pw 的同款补丁：缓冲 spinner 还立着时**把我们的字形藏起来** —— 否则"缓冲中"
            // 会显示一个假的播放/暂停字形，用户点完看到的就是"字形自己跳"。
            // （我们不动 spinner 的 `alpha`，所以 `spinnerShowing` 读到的还是原生值。）
            placeGlyph(
                in: play,
                systemName: playGlyphName(),
                size: playGlyphSize,
                hidden: spinnerShowing(in: play)
            )
            found += 1
        }

        guard found > 0 else { return }

        // 有新按钮被钉住（进页面 / 换页）⇒ 补一串位置复核，把字形摆到它的框上。
        // ⚠️ 这里**不再是"按回 alpha"**了：钉是一次性的，此后不需要再碰。
        if pinnedNow > 0 { armRehide() }

        let signature = "\(found)/\(pinnedNow)"
        guard lastReportedSignature != signature else { return }
        lastReportedSignature = signature
        writeDebugLog(
            "[\(logTag)] the three transport buttons now use local glyphs - found \(found) button(s), "
                + "newly pinned \(pinnedNow) this pass (native content is invisible from birth; button action/state/accessibility preserved)"
        )
    }

    /// 钉住一颗按钮。返回"这一拍是不是新钉的"（`refreshGlyphs` 拿它决定要不要补位置复核）。
    ///
    /// ★ 2026-10-06：不再"钉一次就再也不看"——**钉丢了、或者有别人的 `opacity` 动画压上来**
    /// 时会重申（见 `pinInvisible` 的 `force` 参数说明）。重申之后那条钉才是**持续有效**的，
    /// 而不是"曾经有效过"。
    private static func pinButton(_ button: UIView) -> Bool {
        let isNew = !isPinned(button)
        if isNew {
            notePinnedClass(button)
        } else {
            // 已经钉过 ⇒ 顺手看一眼这颗按钮身上有没有**别人的** `opacity` 动画（H1 的判据）。
            noteForeignOpacity(button)
        }
        // ★ 重申**只在能起作用的时候**做，见 `pinInvisible` 的 `force` 说明。
        //   无条件每拍重申也能work，但 `refreshGlyphs` 也会从
        //   `PlaybackControlsUnitHook.layoutSubviews` 跑 ⇒ 转场时是**每帧 3 个** `CABasicAnimation`，
        //   属于白花的开销（独立只读复核指出）。只在"钉没了"或"有别人的 opacity 动画"时重申，
        //   两种情况都还盖得住：别人的动画只要还在，我们下一拍就看得见它。
        let hasForeignAnimation = !(button.layer.animationKeys() ?? [])
            .filter { $0 != pinAnimationKey }
            .isEmpty
        if !isPinned(button) || hasForeignAnimation {
            pinInvisible(button, force: true)
        }
        return isNew
    }

    /// 这一拍我们检查那颗按钮时，它身上有没有**别人的** `opacity` 动画。
    ///
    /// ⚠️ **这只是一个"提示"，不是判决**（独立只读复核的原话）：
    ///   · 真阳性：UIStackView 增删 arranged subview / 有动画的布局回合都会加隐式
    ///     `"opacity"` 动画 —— 那种时候我们的钉确实可能被压在下面；
    ///   · 假阳性：一条**空转**的、或者早就加在我们之前的 `opacity` 动画也会命中；
    ///   · 假阴性：`alpha` 的**模型值**写（`UIView` 在动画块外写 `alpha` 不产生动画）根本不加动画。
    /// ⇒ 所以这一行只报**观察到的事实**，不替它下结论。
    /// **每个类名只报一次**（不刷屏纪律）。
    private static var foreignOpacityClasses = Set<String>()

    private static func noteForeignOpacity(_ view: UIView) {
        let foreign = view.layer.animationKeys()?.filter { $0 != pinAnimationKey } ?? []
        guard foreign.contains("opacity") else { return }
        let name = NSStringFromClass(type(of: view))
        guard foreignOpacityClasses.insert(name).inserted else { return }
        noteDiagnostic(
            .foreign,
            "\(name) has a foreign 'opacity' animation on its layer (alpha=\(String(format: "%.2f", view.alpha)), "
                + "other keys: \(foreign.joined(separator: ","))) - the pin was re-asserted over it"
        )
    }

    // MARK: - 判据日志（给"暂停键一卡一卡的"那条线取证用）

    /// 日志 50 里这条线**一行判据都没有**：字形换符号不报、字形跳位置不报、
    /// 钉被谁盖掉不报、`uiButtonTapped` 钩子有没有真的跑过也不报
    /// ⇒ 事后只剩猜想，分不开下面三条机理：
    ///
    /// * **H1 钉被盖掉**：Spotify 写 `alpha` ⇒ 它的隐式 `opacity` 动画盖住我们的钉 ⇒ 原生内容漏回来一帧；
    /// * **H2 硬切**：字形是 `glyph.image = …` 瞬时换图，整颗按钮又被钉成不可见 ⇒ 没有按下回弹、没有 crossfade；
    /// * **H3 位置跳步**：字形只在节拍上重排 ⇒ 卡片折叠 / 换歌时是**跳着**追上按钮的。
    ///
    /// 所以这一轮补三行只读判据（换符号 / 跳位置 / 钉被盖掉）+ 一行点击判据
    /// （后者同时是 §3.4 ④「三颗按钮还都能按」唯一能自动判的东西）。
    ///
    /// 判据通道。**每路一个预算**，不共用一个。
    ///
    /// ⚠️ 第一版是**一个共用预算**（120 行），独立只读复核指出它有个致命形状：
    /// `move` 那一路是**帧级**的（翻页/滚动动画一来，1 秒就能烧掉整份预算），
    /// 于是后面 `tap` 那一路**被静默丢掉** —— 而 `tap` 正是 §3.4 ④「三颗按钮还都能按」
    /// 唯一的自动判据。判据被静默丢掉，比没有判据更坏（会得到一条假绿灯）。
    /// 所以：`tap` 给足，`move` 收紧，并且**每一路用满时留一行自己的墓志铭**。
    private enum Diag: String {
        case tap, symbol, move, foreign

        var limit: Int {
            switch self {
            case .tap: return 200      // §3.4 ④ 的唯一判据 —— 一次会话里点不了这么多次
            case .symbol: return 120   // 换符号是我们要看的那条序列
            case .move: return 40      // 帧级，收紧
            case .foreign: return 8    // 每个类名最多一条，8 足够
            }
        }
    }

    private static var diagCounts: [Diag: Int] = [:]

    private static func noteDiagnostic(_ channel: Diag, _ message: String) {
        let used = diagCounts[channel] ?? 0
        guard used < channel.limit else { return }
        diagCounts[channel] = used + 1
        if used + 1 == channel.limit {
            writeDebugLog(
                "[\(logTag)] '\(channel.rawValue)' diagnostics reached their limit "
                    + "(\(channel.limit) lines) - further lines of this kind are suppressed"
            )
        }
        writeDebugLog("[\(logTag)] \(message)")
    }

    /// 这颗按钮的身份：优先 id（类名会重复，见 `notePinnedClass`）。
    private static func identifier(of view: UIView) -> String {
        view.accessibilityIdentifier ?? NSStringFromClass(type(of: view))
    }

    private static func frameText(_ frame: CGRect) -> String {
        "\(Int(frame.origin.x)),\(Int(frame.origin.y)),\(Int(frame.width)),\(Int(frame.height))"
    }

    /// 原生内容被写回之后的**短促重试**：排几次"幂等按回去"，**没人再写回就自然停下**。
    ///
    /// 与 `MiniBarGlass.armColorGuard()` 完全同一套纪律：**一次只排一轮、不叠加**
    /// （`rehideBurstUntil` 占位）—— 否则每次布局都排一次，就成了仓库纪律里禁止的变相轮询。
    ///
    /// ⚠️ 窗口取的是"最后一个 deadline"（0.6s），判定是 `>=` ⇒ **只要那一轮里还有东西被写回，
    /// 就会再排下一轮**（一轮 4 次 `asyncAfter`，最坏 0.6s 一轮）。这是**有意的**：
    /// Spotify 每换一次播放状态就重建那颗图形，"继续按"才对；真正停下来的条件是
    /// **没有东西可按**（`hiddenLeaves == 0` 那一拍一个 deadline 都不排）。
    /// `MiniBarGlass.armColorGuard()` 是同一个形状、同一个取舍（独立复核也确认了这一点）。
    private static func armRehide() {
        let now = CFAbsoluteTimeGetCurrent()
        guard now >= rehideBurstUntil else { return }
        rehideBurstUntil = now + (rehideBurstDelays.last ?? 0.6)

        for delay in rehideBurstDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                onMainThreadSync { _ = reconcile() }
            }
        }
    }

    /// 那个 id 的按钮（给 hook 用；走查有界）。
    static func button(_ identifier: String, in root: UIView) -> UIView? {
        findByIdentifier(identifier, in: root)
    }

    /// 关掉开关 / 离开页面：把字形拿走、把被我们透明掉的原生视图写回。
    ///
    /// ⚠️ **不依赖 `lastUnit` 还在**：它只在"听歌页还在"时才有值，而关开关时用户在设置页。
    /// 所以先按 `lastUnit` 找一遍，再把 `touchedButtons` 里其余的都收进来（去重）。
    static func restore() {
        var targets: [UIView] = []
        if let unit = lastUnit {
            for id in [previousButtonID, playButtonID, nextButtonID] {
                if let button = findByIdentifier(id, in: unit) { targets.append(button) }
            }
        }
        for button in touchedButtons.allObjects where !targets.contains(where: { $0 === button }) {
            targets.append(button)
        }
        guard !targets.isEmpty else { return }

        for button in targets {
            (objc_getAssociatedObject(button, &glyphKey) as? UIView)?.removeFromSuperview()
            objc_setAssociatedObject(button, &glyphKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            objc_setAssociatedObject(button, &playStateKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            // ★ 撤钉 = 完全复原。我们**从来没写过 alpha**（钉只动 layer），
            //   所以撤掉动画之后那颗按钮就是原样，不需要写回任何值。
            button.layer.removeAnimation(forKey: pinAnimationKey)
        }
        touchedButtons.removeAllObjects()
        lastUnit = nil
        lastPlayButton = nil
        lastReportedSignature = ""
        rehideBurstUntil = 0
        tapOverrideSymbol = nil
        tapOverrideUntil = 0
        displayedPlaySymbol = ""
        candidateSymbol = ""
        candidateCount = 0
        candidateSince = 0
        disagreeSince = 0
        pinnedClassCounts.removeAll()
        foreignOpacityClasses.removeAll()
        diagCounts.removeAll()
        writeDebugLog("[\(logTag)] restored (pins undone, our glyphs taken away; not a single byte of native was changed)")
    }

    // MARK: - 字形与"缓冲中"

    /// Spotify 自己的缓冲 spinner 还立着吗（pw 的 `spinnerShowing`）。
    ///
    /// pw 原文：*"A spinner that is still up this long after a state change is buffering,
    /// not a track starting."* 走查有界（深度 4）。
    /// ⚠️ 我们**不写** spinner 自己的 `alpha`（钉只动 layer），所以这里读到的还是原生的值。
    private static func spinnerShowing(in play: UIView) -> Bool {
        var showing = false
        func visit(_ view: UIView, depth: Int) {
            guard depth <= 4, !showing else { return }
            if !view.isHidden, view.alpha > 0.01,
               NSStringFromClass(type(of: view)).contains("SpinnerView") {
                showing = true
                return
            }
            for sub in view.subviews { visit(sub, depth: depth + 1) }
        }
        visit(play, depth: 0)
        return showing
    }

    /// 在**按钮的兄弟层**上叠一个我们自己的字形（**不吃触摸** —— 按钮的动作原样生效）。
    ///
    /// ★ **为什么不再是按钮的子视图**（2026-10-05 重做）：整颗按钮的 layer 被钉住了
    /// （见 `refreshGlyphs`），子视图会**跟着一起不可见**。所以字形挂在
    /// **`button.superview`**（那一排 `AutoLayoutStackView`）上，每一拍照按钮的框重算位置。
    /// 它是**非 arranged** 子视图（`addSubview` 而不是 `addArrangedSubview`），
    /// 所以 stack view 不会去布局它，`frame` 由我们说了算。
    ///
    /// 幂等：字形已经在、而且画的是对的符号 → 只对齐位置；否则换图。
    private static func placeGlyph(
        in button: UIView,
        systemName: String,
        size: CGFloat,
        hidden: Bool = false
    ) {
        let configuration = UIImage.SymbolConfiguration(pointSize: size, weight: .medium)
        guard let image = UIImage(systemName: systemName, withConfiguration: configuration) else { return }
        guard let host = button.superview else { return }

        let glyph: UIImageView
        if let existing = objc_getAssociatedObject(button, &glyphKey) as? UIImageView {
            glyph = existing
        } else {
            glyph = UIImageView()
            glyph.contentMode = .center
            glyph.isUserInteractionEnabled = false
            glyph.accessibilityIdentifier = "eevee-npv-transport-glyph"
            glyph.tintColor = .white
            // ★ **z 序不要靠 subview 顺序**：Spotify 换帧会重排 subviews，而
            //   `bringSubviewToFront` 只在我们跑到的那一拍生效，`zPosition` 是**持续生效**的。
            //   这是我们自己视图的属性，关开关时随字形一起消失，不欠还原。
            glyph.layer.zPosition = 1000
            objc_setAssociatedObject(button, &glyphKey, glyph, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }

        let last = objc_getAssociatedObject(button, &playStateKey) as? String
        if last != systemName {
            glyph.image = image.withRenderingMode(.alwaysTemplate)
            objc_setAssociatedObject(button, &playStateKey, systemName, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            // ★ 判据 ①（日志 50 里一行都没有）：字形**换符号**的每一次。
            //   H2（硬切）与"投影抖动/点击接管到期后回弹"全靠这条序列才分得开。
            //   ⚠️ 不写嵌套双引号字面量 —— 先算成变量（见 `NowPlayingLyricsPlate` 的说明）。
            let via = (systemName == tapOverrideSymbol) ? "tap-override" : "projection"
            let left = max(0, tapOverrideUntil - CFAbsoluteTimeGetCurrent())
            noteDiagnostic(
                .symbol,
                "glyph \(identifier(of: button)) symbol \(last ?? "none") -> \(systemName)"
                    + " (via \(via), isPlaying=\(projection.isPlaying),"
                    + " pos=\(String(format: "%.2f", projection.time))s,"
                    + " overrideLeft=\(String(format: "%.2f", left))s)"
            )
        }

        if glyph.superview !== host { host.addSubview(glyph) }
        // 位置 = 按钮的框（换算到 host 坐标，**用 convert 而不是 frame**：
        // 按钮可能正被 Spotify 按着做缩放/位移，那时 `frame` 未定义 —— 仓库纪律）。
        let target = button.convert(button.bounds, to: host)
        if glyph.frame != target {
            let was = glyph.frame
            glyph.autoresizingMask = []
            glyph.frame = target
            // ★ 判据 ②：字形**跳位置**的每一次（H3：只在节拍上重排 ⇒ 跳着追按钮）。
            //   只读、只在真的动过帧时打一行；这一路是**帧级**的，所以预算收得最紧（40 行）。
            noteDiagnostic(.move, "glyph \(identifier(of: button)) moved \(frameText(was)) -> \(frameText(target))")
        }
        // Spotify 的缓冲 spinner 立着时把我们的字形藏起来（pw 的做法）—— 见 `spinnerShowing`。
        let wantedAlpha: CGFloat = hidden ? 0 : 1
        if glyph.alpha != wantedAlpha { glyph.alpha = wantedAlpha }
        if host.subviews.last !== glyph {
            host.bringSubviewToFront(glyph)
        }
    }

    /// 现在该画"播放"还是"暂停"。
    ///
    /// 用仓库既有的 `AppleMusicLyricsPlaybackProjection`（它已经处理了"位置连续前进才算在播"这套
    /// 滞后判断，别处也用它），**不去猜 `isPaused` 这种未公开属性**。
    ///
    /// ⚠️ **必须只建一次并缓存**：`refresh()` 的判定是"相对上一次的锚点有没有前进"
    /// （`advanceAnchor` 为空时只记锚点、不给 `isPlaying = true`）—— 每次新建一个实例的话
    /// 它永远停在"暂停"，字形就永远画成 play。这个坑 `AppleMusicLyricsOverlayHost` 那边
    /// 也是靠缓存同一个 projection 避开的。
    ///
    /// ⚠️ 但**光靠它是慢的**：投影的 `pauseThreshold = 0.35s`（连续 0.35s 没前进才算暂停）
    /// 再加一个 0.3~0.5s 的节拍 ⇒ 点一下暂停后，字形最坏要 **~0.85s** 才翻过来。
    /// pw 的原话就是这一条：*"The player's state reaches the glyph a beat after the tap …, which
    /// read as a **slow button**. Spotify's own disc turns at the touch."*
    /// ⇒ 所以点击那一拍由 `notePlayTapped()` 直接接管（pw 的 `playTapped`），见 `playGlyphName`。
    private static let projection = AppleMusicLyricsPlaybackProjection {
        WordByWordPositionResolver.shared.currentPositionSeconds()
    }

    /// 点击后"先信用户"的窗口（pw 的 `kTapTrust = 1.2` 秒）。
    private static let tapTrust: CFAbsoluteTime = 1.2
    /// 点击后接管字形的目标符号；播放器状态跟上（或超时）即交还。
    private static var tapOverrideSymbol: String?
    private static var tapOverrideUntil: CFAbsoluteTime = 0
    /// 当前画在屏幕上的播放键符号（判决"这一下的目标态"要用它，不能用投影的值）。
    private static var displayedPlaySymbol: String = ""
    /// 听歌页那一颗播放键（迷你条 / 吸顶头 / 全屏歌词页挂的是同一个类，不能一起管）。
    private static weak var lastPlayButton: UIView?

    private static func playGlyphName() -> String {
        projection.refresh()
        let fromState = projection.isPlaying ? "pause.fill" : "play.fill"

        // ★ 点击那一刻已经把字形翻过去了（pw 的 `playTapped`）：播放器状态晚 ~0.35s + 一个节拍
        //   才跟上来，那段时间**以点击为准**（最多 1.2s）；一旦状态跟上、或窗口过期，就交还。
        if let override = tapOverrideSymbol {
            if CFAbsoluteTimeGetCurrent() >= tapOverrideUntil || fromState == override {
                tapOverrideSymbol = nil
            } else {
                displayedPlaySymbol = override
                return override
            }
        }
        return settled(fromState)
    }

    // MARK: - ★ 2026-10-07：字形的**粘滞判决**（日志 51 抓到的"暂停键一卡一卡的"）

    /// 投影说换，不代表**现在**就该换。
    ///
    /// ## 日志 51 的现场（同一秒内翻了两次，三对一模一样）
    ///
    /// ```
    /// glyph SPTNowPlayingPlayButton symbol pause.fill -> play.fill (via projection, isPlaying=false, pos=28.91s)
    /// glyph SPTNowPlayingPlayButton symbol play.fill -> pause.fill (via projection, isPlaying=true,  pos=29.38s)
    /// glyph … pause.fill -> play.fill (via projection, isPlaying=false, pos=32.34s)
    /// glyph … play.fill -> pause.fill (via projection, isPlaying=true,  pos=32.68s)
    /// ```
    ///
    /// 三对的位置差是 **0.47 / 0.34 / 0.48 秒**，而每一对的**前一半**都是
    /// `isPlaying=false` ⇒ **位置提供者在两次采样之间没有前进**。
    /// 采样来自 `DeclutterChrome` 那条 ≈0.5s 的节拍（外加 `layoutSubviews`），
    /// 而投影的 `pauseThreshold` 只有 **0.35s**：**采样间隔比阈值还长** ⇒
    /// **一次"没前进"就直接判暂停** ⇒ 字形闪一下，下一次采样又翻回来。
    /// 这就是"一卡一卡的"。
    ///
    /// ⚠️ 同理也**证伪了 H1**（钉被 Spotify 的 `opacity` 写回盖掉）：
    ///    日志 51 里 `has a foreign 'opacity' animation` **一行都没有**。
    ///
    /// ## 判据
    ///
    /// 新状态要**连续 `stableSamples` 次、并且持续 ≥ `stableSeconds`** 才允许换符号。
    /// 用户自己点的那一下**不受影响** —— `notePlayTapped` 的接管窗口是**立刻生效**的
    /// （`playGlyphName` 在它前面就 return 了）。
    private static let stableSamples = 2
    private static let stableSeconds: CFAbsoluteTime = 1.2

    /// ★ **分歧上限**（独立只读复核抓到的漏洞）：日志 51 那种"一直来回翻"的形态下，
    /// 每隔一次采样 `wanted` 就恰好等于**当前已画**的那个 ⇒ 候选被反复清零
    /// ⇒ `settled` **永远不提交**，字形会**无限期冻在**上一次提交的值上。
    /// 那等于把"闪"换成"错"，更糟。所以再加一条兜底：**分歧持续超过 `disagreeLimit`
    /// 就无条件采纳** —— 到那时"玩家真实状态"这件事已经不是粘滞能解决的了，
    /// 站在最新读数这一边比冻着强。
    private static let disagreeLimit: CFAbsoluteTime = 2.5
    private static var disagreeSince: CFAbsoluteTime = 0

    private static var candidateSymbol = ""
    private static var candidateSince: CFAbsoluteTime = 0
    private static var candidateCount = 0

    private static func settled(_ wanted: String) -> String {
        let now = CFAbsoluteTimeGetCurrent()

        // 还没画过任何符号（刚进页面）⇒ 直接采用，别让用户先看到一个空按钮。
        if displayedPlaySymbol.isEmpty {
            displayedPlaySymbol = wanted
            candidateSymbol = wanted
            candidateCount = 0
            disagreeSince = 0
            return wanted
        }

        // 和现在画的一样 ⇒ 什么都不用做，把候选与分歧计时都清掉。
        if wanted == displayedPlaySymbol {
            candidateSymbol = wanted
            candidateCount = 0
            disagreeSince = 0
            return displayedPlaySymbol
        }

        // 从这里往下：`wanted` 与屏幕上那个**不一致**。
        if disagreeSince == 0 { disagreeSince = now }
        if now - disagreeSince >= disagreeLimit {
            // 兜底：分歧太久了，站到最新读数这一边（别再冻着）。
            displayedPlaySymbol = wanted
            candidateSymbol = wanted
            candidateCount = 0
            disagreeSince = 0
            return wanted
        }

        // 换了一个新的候选 ⇒ 重新起算。
        if candidateSymbol != wanted {
            candidateSymbol = wanted
            candidateCount = 1
            candidateSince = now
            return displayedPlaySymbol
        }

        candidateCount += 1
        // `candidateSince > 0` 是防呆：万一候选与计时不同步，也绝不用一个陈旧的起点提前提交。
        guard candidateCount >= stableSamples,
              candidateSince > 0,
              now - candidateSince >= stableSeconds else {
            return displayedPlaySymbol
        }
        displayedPlaySymbol = wanted
        candidateSymbol = wanted
        candidateCount = 0
        disagreeSince = 0
        return wanted
    }

    /// `uiButtonTapped` 钩子**被调用了**（在"认不认这颗按钮"之前就报）。
    ///
    /// 为什么必须单独一条：日志 51 里 `play button tapped —` 一行都没有，而那一条只能证明
    /// "门面没收到"，分不出"用户没点"与"钩子没被调用"。这一条在身份判断**之前**打 ⇒
    /// 日志 52 里：**有它、没有 `play button tapped` = 钩子在跑、只是没认下这颗按钮**；
    /// **两条都没有 = 钩子根本没被调用**（`uiButtonTapped` 在 9.1.88 上"存在但不走这条路"）。
    static func noteTapHookFired(from button: UIView) {
        guard isEnabled else { return }
        noteDiagnostic(
            .tap,
            "uiButtonTapped fired on \(identifier(of: button))"
                + " (isOurPlayerButton=\(button.isDescendant(of: lastPlayButton ?? button)))"
        )
    }

    /// 那颗播放键**被点了**（`PlayButtonView.uiButtonTapped`，只认听歌页那一颗）。
    ///
    /// pw v0.21.1 `PlayerControls.x` 的做法逐字照搬其思路（代码自己写）：
    /// 把字形翻到"这一下的目标态"（当前显示的反面），当场落地，不等下一个布局回合；
    /// 之后由 `playGlyphName()` 在状态跟上时交还。
    static func notePlayTapped(from button: UIView) {
        guard isEnabled else { return }
        // 同一个类还挂在迷你条 / 吸顶头 / 全屏歌词页上 —— 只有我们记住的那一颗算数。
        // ⚠️ 2026-10-07：判据从**严格同一实例**放宽到"**互为祖先/后代**"。
        //    严格同一实例有个风险：万一 id 挂在子树里、而我们 hook 到的是外壳，
        //    接管窗口就会**永远不生效**（独立复核指出）。放宽之后仍然只认听歌页那一颗
        //    （迷你条那颗与它不是一条链），而 `isDescendant(of:)` 本来就包含"就是自己"。
        guard let play = lastPlayButton,
              button.isDescendant(of: play) || play.isDescendant(of: button) else { return }

        let current = displayedPlaySymbol.isEmpty ? playGlyphName() : displayedPlaySymbol
        let target = (current == "play.fill") ? "pause.fill" : "play.fill"
        tapOverrideSymbol = target
        tapOverrideUntil = CFAbsoluteTimeGetCurrent() + tapTrust
        displayedPlaySymbol = target

        // ★ 判据 ③（`§3.4 ④` 至今无法验收就是因为没有这一行）：
        //   **点击钩子真的在这颗键上跑过**。`uiButtonTapped` 在日志 49 只是"装上了"，
        //   "有没有被调用"从来没有过证据；而它同时是"三颗按钮还都能按"的自动化判据。
        noteDiagnostic(
            .tap,
            "play button tapped — glyph \(current) -> \(target)"
                + " (trust \(String(format: "%.1f", tapTrust))s)"
        )

        // 当场画上去（`reconcile` 找不到那一排时下一个节拍也会补上，最坏退回"慢一拍"）。
        _ = reconcile()
    }

    // MARK: - 查找

    /// 有界广度优先找 id（本仓库纪律：不给别人的视图树无界遍历）。
    private static func findByIdentifier(_ identifier: String, in root: UIView) -> UIView? {
        var visited = 0
        var queue: [UIView] = [root]

        while !queue.isEmpty, visited < maxNodes {
            let view = queue.removeFirst()
            visited += 1
            if view.accessibilityIdentifier == identifier { return view }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }
}

// MARK: - 接线

/// 装这一组 hook。
///
/// `layoutSubviews` 是 UIView **一定会被调用**的方法（不是可选方法），所以这里不存在
/// "类没覆写就 `Failed to hook method`"那条风险；但**类本身在不在**仍要先问一句
/// （`NSClassFromString`），不在就只打一行日志、不留给 Orion 报非致命错误 —— 仓库惯例。
///
/// ★ **第二条钩子走"探测再挂"**（`uiButtonTapped`）：那个选择器只出现在 pw 自己的
/// `objc-methods.txt` 里（pw 基线 9.1.78），而**我们的 `dump-9.1.88.txt` 证明不了它在不在**
/// —— 它的 `[selectors]` 桶连 `layoutSubviews` / `viewDidAppear:` 都没有，不是完整清单。
/// 所以先用 `class_getInstanceMethod` 探一次：探到才激活；探不到只打一行，
/// **功能不消失**，只是字形退回"跟布局回合 + 0.3s 节拍"（慢一拍）。
/// 这正是仓库里 SponsorBlock 探测 `addPlayerObserver:` 的同一套写法。
func activateNowPlayingControls() {
    if NSClassFromString(PlaybackControlsUnitHook.targetName) != nil {
        NowPlayingControlsGroup().activate()
        writeDebugLog("[NPVControls] hook installed (\(PlaybackControlsUnitHook.targetName))")
    } else {
        writeDebugLog(
            "[NPVControls] missing \(PlaybackControlsUnitHook.targetName)"
                + " - falling back to 'apply on page entry' (matched by button id, not class name)"
        )
    }

    if let cls = NSClassFromString(PlayButtonTapHook.targetName),
       class_getInstanceMethod(cls, playButtonTapSelector) != nil {
        NowPlayingTapGroup().activate()
        writeDebugLog(
            "[NPVControls] tap hook installed (\(PlayButtonTapHook.targetName).uiButtonTapped)"
                + " - the glyph flips right at the tap, without waiting for player state"
        )
    } else {
        writeDebugLog(
            "[NPVControls] no \(PlayButtonTapHook.targetName).uiButtonTapped"
                + " - glyphs only update on layout passes/ticks (one beat behind, functionality unaffected)"
        )
    }
}
