import Foundation
import SwiftUI
import UIKit
import Orion
import ObjectiveC.runtime

// 「播放器控件换成本地字形」：把 Spotify 那三个控制键（上一首 / 播放暂停 / 下一首）的图标
// 换成 Apple Music 那套细字形，按钮本身留着（pw `PlayerControls.x` 的做法）。
//
// 关键：**钉整颗按钮的 layer，不逐叶子把 alpha 按回去**。
// ① 三颗按钮整个 layer 钉住（`pinInvisible`：duration 极长、`isRemovedOnCompletion = false`），
// 之后 Spotify 往里面塞什么（圆盘 / 原生字形 / 新快照 / 缓冲 spinner）**出生即不可见**；
// ② **只动 layer、绝不写 `alpha`** —— 渲染看呈现层（钉在 0 ⇒ 看不见），命中判定看模型值
// （没变 ⇒ 照样收得到触摸）。这是播放 / 暂停还活着的前提；
// ③ 字形挂在**按钮的兄弟层**（`button.superview`），每拍按按钮框重算，`zPosition = 1000`
// （快照是后插的，`bringSubviewToFront` 只在跑到的那一拍有效）。
// 还原 = `removeAnimation` 撤钉 + 拿走字形 —— 原生一个字节都没改过。
//
// 9.1.88 的树里圆盘与 `CondensedButton` 是**兄弟**，pw 那套"按几何认圆盘"不能照抄；按钮按 id 认。
// hook 落点 `PlaybackControlsElementsUnit` 只是"快一点的落点"：`NPVScrollViewControllerHook` 进页面时也调 apply。
// 开关跟随 `nowPlayingAnyLayout`，日志 tag `[NPVControls]`。
//
// MARK: - Hook（可选的加速落点）
//
// 播放键**被点的那一下**用的选择器 —— 靠它把字形"在触摸那一刻就翻过去"。
//
// ⚠️ 来源是 pw 的 `%hook _TtC28EncoreConsumerMobile_BaseKit14PlayButtonView` +
// `- (void)uiButtonTapped`，**没有在 9.1.88 上验证过**（实测从不触发），所以：
// · 激活前用 `class_getInstanceMethod` 探测（见 `installTapTargetIfNeeded`）；
// · 探测不到就走"给内部 `UIControl` 加 target"那条路，绝不因为探测失败而丢功能。
let playButtonTapSelector = NSSelectorFromString("uiButtonTapped")

// MARK: - 门面
//
// 「控制键换成本地字形」的门面。
//
// ⚠️ **整个 enum 标 `@MainActor`**：它下面用的 `AppleMusicLyricsPlaybackProjection` 是
// `@MainActor` 的，而所有入口（hook 的布局回合 / 进页面 apply / 复查节拍 / 设置页 binding）
// 本来就都在主线程。不标的话编译器会逐行报"非隔离上下文里引用 MainActor 成员"。
@MainActor
enum NowPlayingControlsPlate {

    static let logTag = "NPVControls"

    /// 三个按钮的 id（判据只有这一处）。`internal` 是因为上面那个 hook 也要用。
    static let previousButtonID = "SPTNowPlayingPreviousTrackButton"
    static let playButtonID = "SPTNowPlayingPlayButton"
    static let nextButtonID = "SPTNowPlayingNextTrackButton"

    /// 字形尺寸（与歌词壳那三键一致）。
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
    //
    // 我们那条"钉住不可见"动画的 key。
    static let pinAnimationKey = "eevee-pin-invisible"

    /// 这个视图是不是已经被我们钉住了。
    static func isPinned(_ view: UIView) -> Bool {
        view.layer.animation(forKey: pinAnimationKey) != nil
    }

    /// 把视图**钉成不可见**：在它的 layer 上加一条 duration 极长、`isRemovedOnCompletion = false`
    /// 的 `opacity` 动画，把**呈现层**钉在 0。
    ///
    /// **只动 layer，不写 `alpha`**：渲染读呈现层（0 ⇒ 看不见），`hitTest` 读模型值
    /// （没变 ⇒ 照样收得到触摸）。所以既"看不见"又"碰得到"，还原也只需撤动画。
    /// 播放键必须如此 —— 那颗 `CondensedButton` 还得收触摸，写 `alpha = 0` 会让 hit-test 跳过它。
    ///
    /// ⚠️ 不能改成"写 `alpha = 0` + 复查节拍硬按回去"：Spotify 每按一次就多出一层新图形，
    /// 逐叶子追永远慢一拍（病根是"它出生到我们钉住之间那一帧"）。整颗按钮钉住才从根上关掉这个窗口。
    ///
    /// `force`：UIKit 写 `alpha` 会加一条隐式 `opacity` 动画，同 keyPath 后加的覆盖先加的 ⇒
    /// 我们的钉会被压下去。重申 = 用同一个 key 再 `add` 一遍，把动画重新排到最后。
    /// ⚠️ 但**不要无条件每拍重申**：`refreshGlyphs` 也会从 `layoutSubviews` 跑，转场时那是
    /// 每帧 3 个动画对象。只在"钉没了"或"有别人的 `opacity` 动画"时重申。
    ///
    /// pw 的 `SGRSuppress`（运行时子类 + 覆写 `setAlpha:`）不能照抄：它的 `subclassable` 会因
    /// 类名以 `_Tt` 开头而拒绝，且覆写 `setAlpha:` 会连带改掉命中判定。
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
    /// 同一个类名被反复钉 ⇒ 它**每次都在被重建**，那就是还在闪的源头；只报一次就看不见。
    private static var pinnedClassCounts: [String: Int] = [:]

    private static func notePinnedClass(_ view: UIView) {
        let name = NSStringFromClass(type(of: view))
        let count = (pinnedClassCounts[name] ?? 0) + 1
        pinnedClassCounts[name] = count
        guard count == 1 || count == 2 || count == 10 || count == 100 else { return }
        // **类名不是身份，`accessibilityIdentifier` 才是**：上一首与下一首共用同一个类
        // （`Encore.Button.Tertiary`），只报类名会把它们读成"同一颗按钮被钉了两次"。
        writeDebugLog(
            "[\(logTag)] pinned \(name) id=\(view.accessibilityIdentifier ?? "-") (time \(count))"
        )
    }

    private static weak var lastUnit: UIView?
    /// 我们动过的按钮（**弱引用**）。
    ///
    /// ⚠️ 为什么要单独记：`restore` 只认 `lastUnit` 的话，**关开关时通常人在设置页**，
    /// 那一刻 `lastUnit` 可能已经是 nil ⇒ 钉就永远撤不掉（漏还原就是"播放键没有圆底"）。
    private static let touchedButtons = NSHashTable<UIView>.weakObjects()
    /// 上一次上报的"找到几个按钮 / 隐掉几个叶子"——只在这两个数变了时才打日志
    /// （`refreshGlyphs` 在 hook 的每个布局回合都会跑，不能每次都打）。
    private static var lastReportedSignature: String = ""

    /// 跟随「听歌页布局」总开关：任一布局开着就用本地字形。
    ///
    /// 二级菜单已删除，不再看 `nowPlayingControlGlyphs`；总开关关掉时必须把
    /// Spotify 的三个原生图标写回来，否则"布局关着、图标却还是本地字形"。
    static var isEnabled: Bool {
        UserDefaults.nowPlayingAnyLayout
    }

    // MARK: - 对外入口
    //
    // 从**任意一个**祖先视图（那一排的容器，或听歌页的根视图）把三个按钮找出来换掉。
    //
    // 三条调用路都走同一条实现：
    // 1. `PlaybackControlsUnitHook.layoutSubviews`（快、准，播放/暂停字形跟得住状态）；
    // 2. `NPVScrollViewControllerHook` 的 appear（兜底 —— 万一某版没这个 hook 也装得上）；
    // 3. `DeclutterChrome` 的 0.3s 节拍（`reconcile`，负责层被 Spotify 重排挤掉之后长回来）。
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
    /// **钉整颗按钮**，不是逐个叶子/圆盘去钉：新图形不是同一批实例，逐叶子永远慢一拍。
    /// 三颗按钮整个 layer 钉住之后，Spotify 往里面塞多少新图形都**出生即不可见**。
    ///
    /// 代价只有一个：我们的字形**不能再当按钮的子视图**（会跟着被钉没）⇒ 挂到
    /// **按钮的兄弟层**上，每一拍照按钮的框重算位置（见 `placeGlyph`）。
    /// pw 把字形放进按钮内部是为了跟"按下回弹"，但按钮整层钉住之后那份回弹本来也看不见了。
    ///
    /// ⚠️ `pinInvisible` **只动 layer、不写 `alpha`** ⇒ 三颗按钮**照样收得到触摸**
    /// （这是播放/暂停还活着的前提）。
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
            // 给播放键**内部那颗真正收触摸的 `UIControl`** 挂我们自己的 target/action ——
            // 这是"点击那一刻就翻字形"在 9.1.88 上**唯一真正生效**的路
            // （那条 `uiButtonTapped` 钩子从来没被调用过，见 `installTapTargetIfNeeded`）。
            installTapTargetIfNeeded(on: play)
            // 内层那颗的 `.touchUpInside` 在 9.1.88 上不发（见 `tapGestureHosts`）
            // ⇒ 外层这颗再挂一个不吞事件的手势，点击那一刻就翻字形，不再等投影。
            installTapGestureIfNeeded(on: play)
            // pw 的同款补丁：缓冲 spinner 还立着时**把我们的字形藏起来** —— 否则"缓冲中"
            // 会显示一个假的播放/暂停字形，点完看到的就是"字形自己跳"。
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
    /// 不能"钉一次就再也不看"：钉丢了、或者有别人的 `opacity` 动画压上来时要重申
    /// （见 `pinInvisible` 的 `force` 说明），那条钉才是**持续有效**的。
    private static func pinButton(_ button: UIView) -> Bool {
        let isNew = !isPinned(button)
        if isNew {
            notePinnedClass(button)
        } else {
            // 已经钉过 ⇒ 顺手看一眼这颗按钮身上有没有**别人的** `opacity` 动画（H1 的判据）。
            noteForeignOpacity(button)
        }
        // 重申**只在能起作用的时候**做，见 `pinInvisible` 的 `force` 说明。
        // 无条件每拍重申也能 work，但 `refreshGlyphs` 也会从 `layoutSubviews` 跑
        // ⇒ 转场时是**每帧 3 个** `CABasicAnimation`，属于白花的开销。
        // 只在"钉没了"或"有别人的 opacity 动画"时重申，两种情况都还盖得住。
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
    /// ⚠️ **这只是一个"提示"，不是判决**：
    /// · 真阳性：UIStackView 增删 arranged subview / 有动画的布局回合都会加隐式
    /// `"opacity"` 动画 —— 那种时候我们的钉确实可能被压在下面；
    /// · 假阳性：一条**空转**的、或者早就加在我们之前的 `opacity` 动画也会命中；
    /// · 假阴性：`alpha` 的**模型值**写（动画块外写不产生动画）根本不加动画。
    /// ⇒ 只报**观察到的事实**，不替它下结论。**每个类名只报一次**。
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

    // MARK: - 判据日志
    //
    // 判据通道。**每路一个预算**，不共用。
    //
    // 要分开的三条机理：**H1 钉被盖掉**（Spotify 写 `alpha`，隐式 `opacity` 动画盖住我们的钉）、
    // **H2 硬切**（`glyph.image` 瞬时换图，没有 crossfade）、**H3 位置跳步**（只在节拍上重排）。
    // 三行只读判据（换符号 / 跳位置 / 钉被盖掉）+ 一行点击判据分别对应它们。
    //
    // ⚠️ 不能用一个共用预算：`move` 那一路是**帧级**的（翻页/滚动动画一来，1 秒就能烧光），
    // 后面的 `tap` 会被静默丢掉 —— 而 `tap` 是"三颗按钮还都能按"唯一的自动判据。
    // 判据被静默丢掉比没有更坏（会得到假绿灯），所以每路各自限额，用满时各留一行墓志铭。
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
    /// 与 `MiniBarGlass.armColorGuard` 同一套纪律：**一次只排一轮、不叠加**
    /// （`rehideBurstUntil` 占位）—— 否则每次布局都排一次，就成了仓库纪律里禁止的变相轮询。
    ///
    /// ⚠️ 窗口取"最后一个 deadline"（0.6s）、判定是 `>=` ⇒ 只要那一轮里还有东西被写回，
    /// 就会再排下一轮（一轮 4 次 `asyncAfter`）。这是**有意的**：Spotify 每换一次播放状态
    /// 就重建那颗图形。真正停下来的条件是那一拍没有新按钮被钉住。
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

    /// 关掉开关 / 离开页面：把字形拿走、撤掉三颗按钮上的钉。
    ///
    /// ⚠️ **不依赖 `lastUnit` 还在**：它只在"听歌页还在"时才有值，而关开关时人在设置页。
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
            // 撤钉 = 完全复原。我们**从来没写过 alpha**（钉只动 layer），
            // 所以撤掉动画之后那颗按钮就是原样，不需要写回任何值。
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
    //
    // Spotify 自己的缓冲 spinner 还立着吗（pw 的 `spinnerShowing`）。
    //
    // 状态变化后这么久 spinner 还立着，就是"在缓冲"而不是"曲目刚开始"（pw 的判断）。
    // 走查有界（深度 4）。⚠️ 我们**不写** spinner 自己的 `alpha`，所以这里读到的是原生值。
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
    /// **不能是按钮的子视图**：整颗按钮的 layer 被钉住了（见 `refreshGlyphs`），子视图会
    /// **跟着一起不可见**。所以字形挂在 **`button.superview`**（那一排 `AutoLayoutStackView`）上。
    /// 它是**非 arranged** 子视图（`addSubview` 而不是 `addArrangedSubview`），
    /// stack view 不会去布局它，`frame` 由我们说了算。
    ///
    /// 幂等：字形已经在、而且画的是对的符号 → 只对齐位置；否则换图。
    private static func placeGlyph(
        in button: UIView,
        systemName: String,
        size: CGFloat,
        hidden: Bool = false
    ) {
        let configuration = UIImage.SymbolConfiguration(pointSize: size, weight: .medium)
        // 播放/暂停用 SF Symbol 的实心 `play.fill` / `pause.fill`（与跳过键同一套系统字形）；
        // 自绘的中空描边三角观感不行，不要再改回去。
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
            // **z 序不要靠 subview 顺序**：Spotify 换帧会重排 subviews，而
            // `bringSubviewToFront` 只在我们跑到的那一拍生效，`zPosition` 是**持续生效**的。
            // 这是我们自己视图的属性，关开关时随字形一起消失，不欠还原。
            glyph.layer.zPosition = 1000
            objc_setAssociatedObject(button, &glyphKey, glyph, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }

        let last = objc_getAssociatedObject(button, &playStateKey) as? String
        if last != systemName {
            glyph.image = image.withRenderingMode(.alwaysTemplate)
            objc_setAssociatedObject(button, &playStateKey, systemName, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            // 判据 ①：字形**换符号**的每一次。H2（硬切）与"投影抖动 / 点击接管到期后回弹"
            // 全靠这条序列才分得开。
            // ⚠️ 不写嵌套双引号字面量 —— 先算成变量（见 `NowPlayingLyricsPlate` 的说明）。
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
            // 判据 ②：字形**跳位置**的每一次（H3：只在节拍上重排 ⇒ 跳着追按钮）。
            // 只读、只在真的动过帧时打一行；这一路是**帧级**的，所以预算收得最紧（40 行）。
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
    /// 用仓库既有的 `AppleMusicLyricsPlaybackProjection`（它已经处理了"位置连续前进才算在播"
    /// 这套滞后判断），**不去猜 `isPaused` 这种未公开属性**。
    ///
    /// ⚠️ **必须只建一次并缓存**：`refresh` 的判定是"相对上一次的锚点有没有前进"
    /// （锚点为空时只记锚点、不给 `isPlaying = true`）—— 每次新建实例它就永远停在"暂停"，
    /// 字形永远画成 play。`AppleMusicLyricsOverlayHost` 也是靠缓存同一个 projection 避开的。
    ///
    /// ⚠️ 但**光靠它是慢的**：`pauseThreshold = 0.35s` 再加一个 0.3~0.5s 的节拍 ⇒
    /// 点一下暂停后字形最坏要 **~0.85s** 才翻过来（pw 说的 "looked like a slow button"）。
    /// ⇒ 点击那一拍由 `notePlayTapped` 直接接管。
    private static let projection = AppleMusicLyricsPlaybackProjection {
        WordByWordPositionResolver.shared.currentPositionSeconds()
    }

    /// 点击后"先信触摸"的窗口（pw 的 `kTapTrust = 1.2` 秒）。
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
        let fromState = projection.isPlaying ? playingSymbol : pausedSymbol

        // 点击那一刻已经把字形翻过去了：播放器状态晚 ~0.35s + 一个节拍才跟上来，
        // 那段时间**以点击为准**（最多 1.2s）；一旦状态跟上、或窗口过期，就交还。
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

    // MARK: - 字形的粘滞判决
    //
    // 投影说换，不代表**现在**就该换。
    //
    // 病根：位置提供者在两次采样之间没前进（采样来自 `DeclutterChrome` 那条 ≈0.5s 的节拍，
    // 外加 `layoutSubviews`），而投影的 `pauseThreshold` 只有 **0.35s** —— **采样间隔比阈值
    // 还长** ⇒ 一次"没前进"就直接判暂停 ⇒ 字形闪一下，下一次采样又翻回来。
    //
    // ## 判据
    //
    // 新状态要**连续 `stableSamples` 次、并且持续 ≥ `stableSeconds`** 才允许换符号。
    // 自己点的那一下**不受影响** —— `notePlayTapped` 的接管窗口是**立刻生效**的
    // （`playGlyphName` 在它前面就 return 了）。
    private static let stableSamples = 2
    private static let stableSeconds: CFAbsoluteTime = 1.2

    /// 两个符号名（只在这里定义一次，免得散落的字符串字面量对不上）。
    private static let playingSymbol = "pause.fill"
    private static let pausedSymbol = "play.fill"

    /// **分歧上限**：在"一直来回翻"的形态下，每隔一次采样 `wanted` 就恰好等于**当前已画**
    /// 的那个 ⇒ 候选被反复清零 ⇒ `settled` 永远不提交，字形**无限期冻在**上一次提交的值上。
    /// 那等于把"闪"换成"错"。所以兜底：**分歧持续超过 `disagreeLimit` 就无条件采纳**。
    private static let disagreeLimit: CFAbsoluteTime = 2.5
    private static var disagreeSince: CFAbsoluteTime = 0

    private static var candidateSymbol = ""
    private static var candidateSince: CFAbsoluteTime = 0
    private static var candidateCount = 0

    private static func settled(_ wanted: String) -> String {
        let now = CFAbsoluteTimeGetCurrent()

        // 还没画过任何符号（刚进页面）⇒ 直接采用，别让人先看到一个空按钮。
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

        // **不对称**：「在播」立刻采纳，「暂停」才要等窗口。
        //
        // 要压的就是"一次采样没前进 ⇒ 假暂停"那**一个**方向；反方向（位置确实前进了）
        // 没有假阳性的余地，而且它是假暂停的**恢复** —— 压它只会让错的那一帧留得更久。
        // 点下去的那一下由 `notePlayTapped` 的接管窗口**当场**翻过去（那条路在这之前就 return 了）。
        if wanted == playingSymbol {
            displayedPlaySymbol = wanted
            candidateSymbol = wanted
            candidateCount = 0
            disagreeSince = 0
            return wanted
        }

        // 从这里往下：`wanted` 与屏幕上那个不一致，且方向是"**声明暂停**"。
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

    /// 播放键**内部那颗真正收触摸的 `UIControl`**。
    /// 树形：`PlaybackControlsUnit > … > PlayButtonView > CondensedButton(UIButton)`。
    private static func transportControl(in button: UIView) -> UIControl? {
        if let control = button as? UIControl { return control }
        var visited = 0
        var queue: [UIView] = button.subviews
        while !queue.isEmpty, visited < 64 {
            let view = queue.removeFirst()
            visited += 1
            if let control = view as? UIControl { return control }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// **给那颗 `UIControl` 挂我们自己的 target/action。**
    ///
    /// `PlayButtonView.uiButtonTapped` 那个钩子在 9.1.88 上根本不会被调用 ——
    /// 类里"有这个方法"≠"这条路会被走"。它一失效，"点击那一刻就翻字形"就不生效，
    /// 所有翻转都退回投影（再叠上 1.2s 粘滞窗口就是"反应更慢"）。
    ///
    /// 挂在 `UIControl` 的 `.touchUpInside` 上是**纯公开 API**：不赌私有选择器、
    /// 不依赖 pw 的 `uiButtonTapped`。我们只**读**这一下，不吞事件、不改状态。
    ///
    /// ⚠️ **装过就不再装**（`tapTargets` 表），而且 **`restore` 也不清这个表** ——
    /// 清掉会对同一颗控件 `addTarget` 两次 ⇒ 一下就翻两下。
    /// 开关关掉后那个 target 还在，但它第一句就 `guard isEnabled` ⇒ 空转。
    private static let tapTargets = NSHashTable<UIControl>.weakObjects()

    /// **内层那颗 `UIControl` 的 `.touchUpInside` 在 9.1.88 上也不发**（它不在触摸的落点上，
    /// Spotify 把那一下交给了外层）⇒ 补一条**不吞事件的手势**：挂在**外层那颗**上，
    /// `cancelsTouchesInView = false` ⇒ Spotify 自己的动作照常发出，我们只是"听见这一下"。
    private static let tapGestureHosts = NSHashTable<UIView>.weakObjects()

    private static func installTapGestureIfNeeded(on play: UIView) {
        guard !tapGestureHosts.contains(play) else { return }
        let recognizer = UITapGestureRecognizer(
            target: NowPlayingPlayTapTarget.shared,
            action: #selector(NowPlayingPlayTapTarget.tapped)
        )
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesEnded = false
        play.addGestureRecognizer(recognizer)
        tapGestureHosts.add(play)
        noteDiagnostic(
            .tap,
            "tap recognizer installed on the play button itself"
                + " (it hears the tap even when the inner control does not)"
        )
    }

    private static func installTapTargetIfNeeded(on button: UIView) {
        guard let control = transportControl(in: button) else { return }
        guard !tapTargets.contains(control) else { return }
        control.addTarget(
            NowPlayingPlayTapTarget.shared,
            action: #selector(NowPlayingPlayTapTarget.tapped),
            for: .touchUpInside
        )
        tapTargets.add(control)
        noteDiagnostic(.tap, "tap target installed on \(identifier(of: control))")
    }

    /// 那颗 `UIControl` 被点了（见 `installTapTargetIfNeeded`）—— **这是真正生效的那条路**。
    static func notePlayTappedFromControl() {
        guard isEnabled, let play = lastPlayButton else { return }
        noteTapSeen(from: play)
        notePlayTapped(from: play)
    }

    /// 播放键那一下**被我们看到了**（在"认不认这颗按钮"之前就报）。
    ///
    /// 两条来源都会走到这里：
    /// ① `uiButtonTapped` 钩子 —— **9.1.88 上实测从不触发**；
    /// ② 我们挂在内部那颗 `UIControl` 上的 target/action —— **真正生效的那条**。
    ///
    /// 就说明"看到了但没认下这颗按钮"（比如 id 挂的位置和我们记的不是一条链）。
    static func noteTapSeen(from button: UIView) {
        guard isEnabled else { return }
        let isOurs = lastPlayButton.map { button.isDescendant(of: $0) } ?? false
        noteDiagnostic(
            .tap,
            "tap seen on \(identifier(of: button)) (isOurPlayerButton=\(isOurs))"
        )
    }

    /// 那颗播放键**被点了**（只认听歌页那一颗）。
    ///
    /// 把字形翻到"这一下的目标态"（当前显示的反面），当场落地，不等下一个布局回合；
    /// 之后由 `playGlyphName` 在状态跟上时交还。
    static func notePlayTapped(from button: UIView) {
        guard isEnabled else { return }
        // 同一个类还挂在迷你条 / 吸顶头 / 全屏歌词页上 —— 只有我们记住的那一颗算数。
        // ⚠️ 判据是"**互为祖先/后代**"而不是严格同一实例：万一 id 挂在子树里、而我们
        // hook 到的是外壳，严格判等会让接管窗口**永远不生效**。放宽之后仍然只认听歌页那一颗
        // （迷你条那颗与它不是一条链），而 `isDescendant(of:)` 本来就包含"就是自己"。
        guard let play = lastPlayButton,
              button.isDescendant(of: play) || play.isDescendant(of: button) else { return }

        let current = displayedPlaySymbol.isEmpty ? playGlyphName() : displayedPlaySymbol
        let target = (current == pausedSymbol) ? playingSymbol : pausedSymbol
        tapOverrideSymbol = target
        tapOverrideUntil = CFAbsoluteTimeGetCurrent() + tapTrust
        displayedPlaySymbol = target

        // 判据 ③：**点击钩子真的在这颗键上跑过** —— 它同时是"三颗按钮还都能按"的
        // 自动化判据（光"装上了"证明不了这条路会被走）。
        noteDiagnostic(
            .tap,
            "play button tapped — glyph \(current) -> \(target)"
                + " (trust \(String(format: "%.1f", tapTrust))s)"
        )

        // 当场画上去（`reconcile` 找不到那一排时下一个节拍也会补上，最坏退回"慢一拍"）。
        _ = reconcile()
    }

    // MARK: - 查找
    //
    // 有界广度优先找 id（本仓库纪律：不给别人的视图树无界遍历）。
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

// MARK: - 手势目标
//
// 播放键**内部那颗 `UIControl`** 的 target（`UIControl` 的 target 必须是 ObjC 对象）。
//
// 见 `installTapTargetIfNeeded`：这是"点击那一刻就翻字形"在 9.1.88 上唯一真正生效的路
// —— `PlayButtonView.uiButtonTapped` 那个钩子实测从不触发。
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
