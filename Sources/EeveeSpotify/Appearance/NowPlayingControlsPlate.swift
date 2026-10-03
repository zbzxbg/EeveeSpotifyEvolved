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
// * 三个 key 分工：`alphaKey`（我们透明掉的原生图标）/ `glyphKey`（我们叠的字形）/ `playStateKey`（上次画的是哪个字形）；
// * 字形尺寸照照片：跳过键 22pt、播放键 30pt（与歌词壳那三个键同一套，见 `AppleMusicLyricsPlaybackControl`）。
//
// 开关：扩展功能 → 听歌页 →「**播放键换成本地字形**」，**默认关**。日志 tag：`[NPVControls]`。
//
// ## ★ 2026-10-03 修（日志 48 + 照片 49/50 判读）：播放键"点一下暂停就换一张脸"
//
// **用户报**：「点击暂停键会有闪烁」。
//
// **照片取证**（同一台机、同一首 `Starboy`）：
//   * 照片 49（播放中）：按钮 = **纯白圆盘（Ø≈63pt）+ 深色暂停横条** —— 这是**原生**的样子；
//   * 照片 50（暂停）：按钮 = **一个裸白三角（≈24×27pt），没有圆盘** —— 这是**我们的字形**。
//   ⇒ 点一下暂停，整颗按钮在白圆盘与裸三角之间**整个换脸**。
//
// **病根（本文件里的一处自相矛盾）**：`hideNativeContent(of: play, excludingClassFragment:)`
// 传的是 `playDiscClassFragment`，而 `visit` 命中那个片段时是 **`return`（整棵子树跳过）** ——
// 于是：播放中，原生白圆盘**和**圆盘里的原生暂停横条一直没被透明掉（我们的白字形画在白圆盘上
// = 看不见）⇒ 与原生一模一样；暂停时圆盘不画 ⇒ 露出我们的白三角。
// （文件上面那段注释写的却是"白圆盘也一并透明掉"——**注释与实现不一致**，这就是那个 bug。）
//
// **修法两条**：
//   1. 白圆盘改成**自己 `alpha = 0`（记账，关开关时写回）**，然后**继续往下走**把里面的
//      原生图形也透明掉 ⇒ 三个键在两种状态下都画成同一套裸字形，换脸这条路从根上断掉。
//      （`alpha = 0` 不会让按钮失去触摸：命中判定落在 `PlayButtonView` 自己身上。）
//   2. 原生内容被写回时排一轮**短促重试**（`armRehide`，与 `MiniBarGlass.armColorGuard` 同一套
//      纪律：只排一轮、不叠加）。日志 48 里同一项在 `0/1` 之间反复横跳就是这个"写回"，
//      而重试原来只靠 0.5s 的复查节拍 ⇒ 最坏 ~0.5s 能看到原生图形闪回来。
//
// ## ★ 2026-10-05 补：把 pw 那边**我们漏掉的三处**补上（读 `PlayerControls.x` 得来，GPL-3.0）
//
// 先纠正一个容易记反的点：**pw 并没有"隐藏原生按钮、自己画一个按钮"**。它文件头原话是
// *"The glyphs are drawn **over** Spotify's controls **rather than instead of them**: each button
// keeps its action, its enabled state, its accessibility and the Gestures zones around it, and the
// glyph **takes no touches**."* —— 原生按钮一直留着、能收触摸，被抑制的只是它**画出来的东西**
// （prev/next 抑制 `SPTEncoreIconView`；play 抑制那颗"和按钮等大的 `UIImageView` 圆盘"）。
// **"调度依然走原生"这半你记对了** —— 而且 pw 正是靠 hook 原生按钮自己的动作方法来对齐时机。
//
// 它比我们多打的三处补丁（本轮全部补上）：
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

    /// 三个按钮与"白圆盘"的 id（判据只有这一处）。`internal` 是因为上面那个 hook 也要用。
    static let previousButtonID = "SPTNowPlayingPreviousTrackButton"
    static let playButtonID = "SPTNowPlayingPlayButton"
    static let nextButtonID = "SPTNowPlayingNextTrackButton"
    /// 播放键底下那圈白色。**它必须一起透明掉** —— 理由见文件头"2026-10-03 修"那一段。
    private static let playDiscClassFragment = "MixedPlayButtonDecorationView"

    /// 字形尺寸（照照片 40/41 的比例；与歌词壳那三键一致）。
    private static let skipGlyphSize: CGFloat = 22
    private static let playGlyphSize: CGFloat = 30

    /// 走查上限（本仓库纪律）。
    private static let maxNodes = 800

    /// 原生内容被写回之后的短促重试（与 `MiniBarGlass.guardBurstDelays` 同一档）。
    private static let rehideBurstDelays: [Double] = [0.05, 0.15, 0.35, 0.6]
    private static var rehideBurstUntil: CFAbsoluteTime = 0

    private static var alphaKey: UInt8 = 0
    private static var glyphKey: UInt8 = 0
    private static var playStateKey: UInt8 = 0

    /// 我们透明掉的那一层 + **它当时的 alpha**。
    ///
    /// ⚠️ 为什么要连原值一起记（独立复核点出来的）：`restore()` 原来一律写 `alpha = 1`，
    /// 而这一版**把白圆盘也纳入了透明范围** —— 圆盘在"暂停那一档"本来可能就不是 1
    ///（照片 50 里它根本没画）。一律写 1 等于**把一颗本来不该亮的装饰层强行点亮**。
    /// 记原值 ⇒ 关开关时写回它自己的样子。
    private final class HiddenView {
        let view: UIView
        let alpha: CGFloat
        init(_ view: UIView) {
            self.view = view
            self.alpha = view.alpha
        }
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
    static func refreshGlyphs(previous: UIView?, play: UIView?, next: UIView?) {
        guard isEnabled else { return }

        var hiddenLeaves = 0
        var found = 0

        if let previous {
            touchedButtons.add(previous)
            hiddenLeaves += hideNativeContent(of: previous, discClassFragment: nil)
            placeGlyph(in: previous, systemName: "backward.fill", size: skipGlyphSize)
            found += 1
        }
        if let next {
            touchedButtons.add(next)
            hiddenLeaves += hideNativeContent(of: next, discClassFragment: nil)
            placeGlyph(in: next, systemName: "forward.fill", size: skipGlyphSize)
            found += 1
        }
        if let play {
            touchedButtons.add(play)
            lastPlayButton = play
            hiddenLeaves += hideNativeContent(
                of: play,
                discClassFragment: playDiscClassFragment,
                snapshotHostsUnlimitedSize: true
            )
            // pw 的同款补丁：缓冲 spinner 还立着时**把我们的字形藏起来** —— 否则"缓冲中"
            // 会显示一个假的播放/暂停字形，用户点完看到的就是"字形自己跳"。
            placeGlyph(
                in: play,
                systemName: playGlyphName(),
                size: playGlyphSize,
                hidden: spinnerShowing(in: play)
            )
            found += 1
        }

        guard found > 0 else { return }

        // ★ 有东西被写回来了 ⇒ 排一轮短促重试把它幂等地按回去。
        //   没有这一条时，重试只靠 `DeclutterChrome` 的 0.5s 复查节拍 ⇒ 最坏约 0.5s
        //   能看到原生图形闪回来（用户报的"闪烁"里就有这一半）。
        //   没有东西要按（`hiddenLeaves == 0`）时**一个 deadline 都不排**。
        if hiddenLeaves > 0 { armRehide() }

        let signature = "\(found)/\(hiddenLeaves)"
        guard lastReportedSignature != signature else { return }
        lastReportedSignature = signature
        writeDebugLog(
            "[\(logTag)] 三个控制键已换成本地字形 — 找到 \(found) 个按钮、"
                + "本拍把 \(hiddenLeaves) 处原生内容按回透明（按钮的动作/状态/无障碍保留）"
        )
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

            let restored = (objc_getAssociatedObject(button, &alphaKey) as? [HiddenView]) ?? []
            for item in restored { item.view.alpha = item.alpha }
            objc_setAssociatedObject(button, &alphaKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            objc_setAssociatedObject(button, &playStateKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        touchedButtons.removeAllObjects()
        lastUnit = nil
        lastPlayButton = nil
        lastReportedSignature = ""
        rehideBurstUntil = 0
        tapOverrideSymbol = nil
        tapOverrideUntil = 0
        displayedPlaySymbol = ""
        writeDebugLog("[\(logTag)] 已还原（原生图标透明度写回、我们的字形已拿走）")
    }

    // MARK: - 我们"换字形"的那两手

    /// 把按钮里**原来画图标的那一层**设成透明（pw 的同款做法：透明而不是 hidden ——
    /// hidden 会让某些 Encore 布局把它当成"没有内容"而重排）。
    ///
    /// ⚠️ **必须递归到底**（2026-10-04 真机教训）：第一版只透明了按钮的**直接子视图**，
    /// 而 Spotify 的图标画在**更深几层**（`Tertiary > UIView > StackView > StackView > SPTEncoreIconView`
    /// —— pw 的注释里就写着这个形状），结果我们的字形虽然装上了（日志 44 的树里三个
    /// `id=eevee-npv-transport-glyph` 都在），**原生图标照样显示在最上面**：
    /// 我们透明掉的是中间那几层容器，图标自己在更下面、完全不受影响。
    ///
    /// 规则：
    /// * **只动叶子**（没有子视图的视图）—— 容器留着，免得把布局/触摸的骨架也弄没；
    /// * 叶子必须**比自己小**（≥ 按钮 1.2 倍的跳过：那是命中区/背景，不是图标）；
    /// * 跳过我们自己的字形；
    /// * ★ **"白圆盘"（`discClassFragment`）要整层透明掉，并且继续往下走**——
    ///   见文件头"2026-10-03 修"：它自己就是那圈白色（是**容器**，没有"图形叶子"），
    ///   上一版在这里 `return` 把它整棵跳过了，正是"点一下暂停就换一张脸"的病根；
    /// * 记下改过的视图**与它当时的 alpha**（`HiddenView`），`restore()` 逐个写回**原值**
    ///   —— 不是一律写 1（理由见 `HiddenView` 的注释）。
    @discardableResult
    private static func hideNativeContent(
        of button: UIView,
        discClassFragment: String?,
        snapshotHostsUnlimitedSize: Bool = false
    ) -> Int {
        let size = button.bounds.size
        guard size.width > 1, size.height > 1 else { return 0 }

        var changed = (objc_getAssociatedObject(button, &alphaKey) as? [HiddenView]) ?? []
        let glyph = objc_getAssociatedObject(button, &glyphKey) as? UIView
        var hidden = 0

        func note(_ view: UIView) {
            if !changed.contains(where: { $0.view === view }) { changed.append(HiddenView(view)) }
        }

        func visit(_ view: UIView, depth: Int, unlimitedSize: Bool) {
            guard depth <= 8 else { return }
            let className = NSStringFromClass(type(of: view))

            if view === glyph || className.contains("eevee-npv-transport-glyph") { return }

            // ★ 白圆盘：它自己是容器（白色由它自己画）⇒ 整层透明，**然后继续往下**把里面
            //   那个原生 play/pause 图形也透明掉（双保险）。`alpha = 0` 不影响按钮的命中判定：
            //   命中的是 `PlayButtonView` 自己，子视图全透明时它照样收得到触摸。
            if let fragment = discClassFragment, className.contains(fragment) {
                if view.alpha > 0 {
                    note(view)
                    view.alpha = 0
                    hidden += 1
                }
                for sub in view.subviews { visit(sub, depth: depth + 1, unlimitedSize: unlimitedSize) }
                return
            }

            if view.subviews.isEmpty {
                // 叶子：这才是真正画东西的那些。
                if view.alpha == 0 { return }
                if !unlimitedSize,
                   view.bounds.width > size.width * 1.2 || view.bounds.height > size.height * 1.2 {
                    return
                }
                // ⚠️ 只动"看起来是图形"的叶子类。2026-10-05 加这条：用户报"自定义的暂停键
                // 点了没反应"，而在拿到日志之前，**能自己排除的风险就要排除** ——
                // 递归到底可能顺手把某个非图形的内部件（命中层/装饰层的子件）也透明掉。
                // 白名单只放 UILabel / UIImage / *ImageView / *IconView，其它一律不碰。
                let visual = className.contains("Label")
                    || className.contains("Image")
                    || className.contains("IconView")
                if !visual { return }
                note(view)
                view.alpha = 0
                hidden += 1
                return
            }

            // ★ pw 的同款补丁（`PlayerControls.x` 原文）：*"The holder Spotify crossfades a snapshot
            //   of the disc in when play turns to pause."* —— 换播放状态时 Spotify 会**交叉淡入一张
            //   圆盘快照**，它装在一个**恰好是纯 `UIView`** 的直接子视图里。常规走查有 `1.2×` 的
            //   尺寸闸，而那张快照**可能比按钮大** ⇒ 在它下面**取消尺寸闸**（只对播放键开）。
            //   判据照 pw：**直接子视图**且类**恰好**是 `UIView`
            //   （圆盘 / `CondensedButton` / 我们的字形都不在射程内）。
            let childUnlimited = unlimitedSize
                || (snapshotHostsUnlimitedSize && depth == 0 && object_getClass(view) == UIView.self)
            for sub in view.subviews { visit(sub, depth: depth + 1, unlimitedSize: childUnlimited) }
        }

        for sub in button.subviews { visit(sub, depth: 0, unlimitedSize: false) }

        objc_setAssociatedObject(button, &alphaKey, changed, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return hidden
    }

    /// Spotify 自己的缓冲 spinner 还立着吗（pw 的 `spinnerShowing`）。
    ///
    /// pw 原文：*"A spinner that is still up this long after a state change is buffering,
    /// not a track starting."* 走查有界（深度 4）。
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

    /// 在按钮上叠一个我们自己的字形（**不吃触摸** —— 按钮的动作原样生效）。
    ///
    /// 幂等：字形已经在、而且画的是对的符号 → 只对齐尺寸；否则换图。
    private static func placeGlyph(
        in button: UIView,
        systemName: String,
        size: CGFloat,
        hidden: Bool = false
    ) {
        let configuration = UIImage.SymbolConfiguration(pointSize: size, weight: .medium)
        guard let image = UIImage(systemName: systemName, withConfiguration: configuration) else { return }

        let glyph: UIImageView
        if let existing = objc_getAssociatedObject(button, &glyphKey) as? UIImageView {
            glyph = existing
        } else {
            glyph = UIImageView()
            glyph.contentMode = .center
            glyph.isUserInteractionEnabled = false
            glyph.accessibilityIdentifier = "eevee-npv-transport-glyph"
            glyph.tintColor = .white
            button.addSubview(glyph)
            objc_setAssociatedObject(button, &glyphKey, glyph, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }

        let last = objc_getAssociatedObject(button, &playStateKey) as? String
        if last != systemName {
            glyph.image = image.withRenderingMode(.alwaysTemplate)
            objc_setAssociatedObject(button, &playStateKey, systemName, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }

        // 铺满按钮并居中：用 autoresizing 跟着按钮走，不碰它自己的约束。
        let target = CGRect(origin: .zero, size: button.bounds.size)
        if glyph.frame != target {
            glyph.frame = target
            glyph.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        }
        // Spotify 的缓冲 spinner 立着时把我们的字形藏起来（pw 的做法）—— 见 `spinnerShowing`。
        let wantedAlpha: CGFloat = hidden ? 0 : 1
        if glyph.alpha != wantedAlpha { glyph.alpha = wantedAlpha }
        // 每帧置于最上（Spotify 换帧会重排 subviews）。
        if button.subviews.last !== glyph {
            button.bringSubviewToFront(glyph)
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
        displayedPlaySymbol = fromState
        return fromState
    }

    /// 那颗播放键**被点了**（`PlayButtonView.uiButtonTapped`，只认听歌页那一颗）。
    ///
    /// pw v0.21.1 `PlayerControls.x` 的做法逐字照搬其思路（代码自己写）：
    /// 把字形翻到"这一下的目标态"（当前显示的反面），当场落地，不等下一个布局回合；
    /// 之后由 `playGlyphName()` 在状态跟上时交还。
    static func notePlayTapped(from button: UIView) {
        guard isEnabled else { return }
        // 同一个类还挂在迷你条 / 吸顶头 / 全屏歌词页上 —— 只有我们记住的那一颗算数。
        guard let play = lastPlayButton, button === play else { return }

        let current = displayedPlaySymbol.isEmpty ? playGlyphName() : displayedPlaySymbol
        let target = (current == "play.fill") ? "pause.fill" : "play.fill"
        tapOverrideSymbol = target
        tapOverrideUntil = CFAbsoluteTimeGetCurrent() + tapTrust
        displayedPlaySymbol = target

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
        writeDebugLog("[NPVControls] hook 已装（\(PlaybackControlsUnitHook.targetName)）")
    } else {
        writeDebugLog(
            "[NPVControls] missing \(PlaybackControlsUnitHook.targetName)"
                + " — 走「进页面时 apply」那条兜底路（判据是按钮 id，与类名无关）"
        )
    }

    if let cls = NSClassFromString(PlayButtonTapHook.targetName),
       class_getInstanceMethod(cls, playButtonTapSelector) != nil {
        NowPlayingTapGroup().activate()
        writeDebugLog(
            "[NPVControls] 点击钩子已装（\(PlayButtonTapHook.targetName).uiButtonTapped）"
                + " — 字形在点击那一刻就翻，不等播放器状态"
        )
    } else {
        writeDebugLog(
            "[NPVControls] 没有 \(PlayButtonTapHook.targetName).uiButtonTapped"
                + " — 字形只在布局回合/节拍上更新（慢一拍，功能不受影响）"
        )
    }
}
