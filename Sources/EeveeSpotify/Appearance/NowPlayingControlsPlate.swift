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

// MARK: - Hook（可选的加速落点）

struct NowPlayingControlsGroup: HookGroup {}

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
    private static let playDiscClassFragment = "MixedPlayButtonDecorationView"

    /// 字形尺寸（照照片 40/41 的比例；与歌词壳那三键一致）。
    private static let skipGlyphSize: CGFloat = 22
    private static let playGlyphSize: CGFloat = 30

    /// 走查上限（本仓库纪律）。
    private static let maxNodes = 800

    private static var alphaKey: UInt8 = 0
    private static var glyphKey: UInt8 = 0
    private static var playStateKey: UInt8 = 0

    private static weak var lastUnit: UIView?
    private static var didLogInstall = false

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

        if let previous {
            hideNativeContent(of: previous, excludingClassFragment: nil)
            placeGlyph(in: previous, systemName: "backward.fill", size: skipGlyphSize)
        }
        if let next {
            hideNativeContent(of: next, excludingClassFragment: nil)
            placeGlyph(in: next, systemName: "forward.fill", size: skipGlyphSize)
        }
        if let play {
            // 白圆盘要留一条命：它是播放键的"装饰层"，透明掉它、字形照旧叠在上面。
            hideNativeContent(of: play, excludingClassFragment: playDiscClassFragment)
            placeGlyph(in: play, systemName: playGlyphName(), size: playGlyphSize)
        }

        if !didLogInstall, previous != nil || play != nil || next != nil {
            didLogInstall = true
            writeDebugLog(
                "[\(logTag)] 三个控制键已换成本地字形"
                    + "（原生按钮的动作/状态/无障碍保留；只把原生图标设成透明）"
            )
        }
    }

    /// 那个 id 的按钮（给 hook 用；走查有界）。
    static func button(_ identifier: String, in root: UIView) -> UIView? {
        findByIdentifier(identifier, in: root)
    }

    /// 关掉开关 / 离开页面：把字形拿走、把被我们透明掉的原生视图写回。
    static func restore() {
        guard let unit = lastUnit else { return }
        for id in [previousButtonID, playButtonID, nextButtonID] {
            guard let button = findByIdentifier(id, in: unit) else { continue }
            (objc_getAssociatedObject(button, &glyphKey) as? UIView)?.removeFromSuperview()
            objc_setAssociatedObject(button, &glyphKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

            let restored = (objc_getAssociatedObject(button, &alphaKey) as? [UIView]) ?? []
            for view in restored { view.alpha = 1 }
            objc_setAssociatedObject(button, &alphaKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            objc_setAssociatedObject(button, &playStateKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        lastUnit = nil
        didLogInstall = false
        writeDebugLog("[\(logTag)] 已还原（原生图标透明度写回、我们的字形已拿走）")
    }

    // MARK: - 我们"换字形"的那两手

    /// 把按钮里**原来画图标的那一层**设成透明（pw 的同款做法：透明而不是 hidden ——
    /// hidden 会让某些 Encore 布局把它当成"没有内容"而重排）。
    ///
    /// * 只看**直接子视图**：按钮的图标就在那一层，再往下是图标自己的内部件；
    /// * 跳过我们自己的字形；
    /// * 跳过"白圆盘"（`excludingClassFragment`）—— 它是按钮自己的装饰，我们只在播放键上放过它；
    /// * 比按钮还大的子视图不动（那多半是命中区/背景，不是图标）；
    /// * 记下改过的视图，`restore()` 要写回。
    private static func hideNativeContent(of button: UIView, excludingClassFragment: String?) {
        let size = button.bounds.size
        guard size.width > 1, size.height > 1 else { return }

        var changed = (objc_getAssociatedObject(button, &alphaKey) as? [UIView]) ?? []

        for sub in button.subviews {
            if sub === (objc_getAssociatedObject(button, &glyphKey) as? UIView) { continue }
            if sub.alpha == 0 { continue }
            if sub.bounds.width > size.width + 1 || sub.bounds.height > size.height + 1 { continue }
            if let fragment = excludingClassFragment,
               NSStringFromClass(type(of: sub)).contains(fragment) {
                continue
            }
            // 已经是透明的不重复记（否则还原表会越滚越大）。
            if !changed.contains(where: { $0 === sub }) {
                changed.append(sub)
            }
            sub.alpha = 0
        }

        objc_setAssociatedObject(button, &alphaKey, changed, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// 在按钮上叠一个我们自己的字形（**不吃触摸** —— 按钮的动作原样生效）。
    ///
    /// 幂等：字形已经在、而且画的是对的符号 → 只对齐尺寸；否则换图。
    private static func placeGlyph(
        in button: UIView,
        systemName: String,
        size: CGFloat
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
    private static let projection = AppleMusicLyricsPlaybackProjection {
        WordByWordPositionResolver.shared.currentPositionSeconds()
    }

    private static func playGlyphName() -> String {
        projection.refresh()
        return projection.isPlaying ? "pause.fill" : "play.fill"
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
}
