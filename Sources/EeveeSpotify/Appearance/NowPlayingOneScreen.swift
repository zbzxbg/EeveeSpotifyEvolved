import Foundation
import UIKit
import ObjectiveC.runtime

/// 听歌页「一屏」：把播放器下面那些卡片**全部折起来**，并把列表**钉在它自己的顶部** ——
/// 也就是 Music app / kumone 那种"一屏一首歌、滚不动"。
///
/// ## 借鉴来源（许可与"借了什么"都写清）
///
/// 思路与算法借自 **spoti.pw v0.21.1**（`LICENSE` = **GPL-3.0**，与本仓库 GPL-3.0 兼容）的
/// `tweak/Sources/Redesigned/Player/PlayerCards.x` 与 `PlayerScroll.x`。
/// **落地代码是我们自己的 Swift 实现**（不是搬过来的 ObjC）。取证、目标类在 9.1.88 上的
/// 存活情况、依赖面，都记在 `Tools/eevee-hookfinder/SPOTIPW_0211_PORT_ASSESSMENT.md`。
/// ⚠️ 许可边界：**只允许借 ≤ v0.21.1 那一侧**；`v0.22.0` 起是 PolyForm Strict，一行都不能碰。
///
/// ## ★ 为什么是"钉住"，而不是"把滚动关掉"（这是 pw 用真机 + 二进制偏移换来的）
///
/// 听歌页的**下拉关闭**挂在**列表自己的 pan recogniser** 上：
/// `-[SPTBarInteractivePresentationController scrollViewDidAppear:]` 取走列表的
/// `panGestureRecognizer`、对它 `addDismissPanWithGestureRecognizer:`，并让自己的 dismiss
/// recogniser 等它失败；那个 handler **只在列表处于（或高于）顶部时**才启动关闭。
/// **把滚动关掉会把那个 recogniser 一起带走 ⇒ 播放器再也划不掉。**
///
/// 所以这里关的是"范围"：把 `contentInset.bottom` 设成"让列表最多只能滚到它自己的顶部"。
/// 于是上拉只拉伸回弹、下拉仍能到负偏移、**关闭手势完全不受影响**。
///
/// ## 我们和 pw 的两处不同（刻意的）
///
/// | | pw v0.21.1 | 我们 |
/// |---|---|---|
/// | 重算时机 | hook `viewDidLayoutSubviews` + `willDisplayCell` + `scrollViewDidScroll` | **蹭 `DeclutterChrome` 既有的 0.3s 复查节拍**（不新开 hook、不挂可选方法 —— 本仓库两条纪律） |
/// | 代价 | 每一帧都准 | 最坏 0.3s 的窗口里能多滑一点点，下一拍立刻被拉回 |
///
/// 卡片折叠那一半在 `NowPlayingOneScreenCards.x.swift`（那个必须是个 Orion hook）。
///
/// 开关：**扩展功能 → 听歌页 →「一屏（卡片折起来，不可滚动）」**，**默认关**。
/// 日志 tag：`[OneScreen]`。
///
/// ⚠️ **为什么默认关**：它会连**歌词卡**一起折起来 —— kumone 敢把卡片全折，是因为它把歌词
/// **搬进了播放器**（pw 的 `PlayerLyrics.x`），我们这一版还没做那一步；折掉之后听歌页就没有
/// "打开歌词"的入口了。而且一旦钉住，**保留下来的卡片也永远滚不到**（这正是"一屏"的含义），
/// 所以"只折一部分"不是一个稳定的中间态 —— 要么全折（一屏），要么别开。
/// 下一步把歌词搬进播放器之后，默认值才有资格改成开。
enum NowPlayingOneScreen {

    static let logTag = "OneScreen"

    /// 播放器那张列表在真机树里的 `accessibilityIdentifier` —— 日志 38 的 `[Tree]` 里就有
    /// （`6.UICollectionView@0,0,414,896,id=scrolling_npv_collection_view_accessibility_identifier`）。
    private static let listIdentifier = "scrolling_npv_collection_view_accessibility_identifier"

    /// inset 只按"差一点点"比较，不做相等判断（`CGFloat` 相等判断在这里没意义）。
    private static let slack: CGFloat = 0.5
    /// 锚点走查上限（本仓库纪律：不给别人的视图树无界遍历）。
    private static let maxNodes = 2000

    /// 我们改过的列表上记着**它原来的** bottom inset —— 关开关要原样写回。
    private static var originalInsetKey: UInt8 = 0

    private static weak var lastPage: UIView?
    private static weak var lastList: UIScrollView?

    private static var didLogPin = false
    private static var didLogGiveUp = false
    private static var didLogNotNeeded = false
    private static var didLogDiag = false
    /// 合并用的占位：一次布局里几十张卡只排一枪（本仓库纪律：短促重试不叠加）。
    private static var repinScheduled = false

    static var isEnabled: Bool { UserDefaults.nowPlayingOneScreen }

    // MARK: - 对外入口

    /// 进听歌页时叫一次（蹭既有的 `NPVScrollViewControllerHook.viewWillAppear` / `.viewDidAppear`）。
    ///
    /// 找不到列表时**刻意不打日志**：`viewWillAppear` 那一刻列表常常还没建出来，
    /// 打了就是每进一次页面一条噪音。"真的从来找不到"由 `reconcile()` 负责上报。
    static func apply(in pageView: UIView) {
        lastPage = pageView

        guard isEnabled else {
            restore()
            return
        }
        guard let list = locateList(in: pageView) else { return }
        lastList = list
        pin(list)
    }

    /// 设置页切开关时叫一次：还挂着就当场落地，否则等下次进听歌页。
    static func reapply() {
        guard let page = lastPage, page.window != nil else { return }
        apply(in: page)
    }

    /// 蹭 `DeclutterChrome` 既有的复查节拍（**不新开定时器**，本仓库纪律）。
    ///
    /// 为什么需要：卡片是**列表建好之后**才陆续到的，每来一张都会把内容高度顶上去，
    /// 而 `apply` 只在进页面时跑一次；`willDisplayCell` 那一刻的高度更是"一个 runloop
    /// 之后才定"（pw 为此专门补了一枪 `dispatch_async`）。
    ///
    /// 成本：没在听歌页时 = 两次 weak 读 + 一次 `window` 读；在听歌页时再加几次属性读
    /// （值没漂就**一个字节都不写**）。
    ///
    /// - Returns: 这一拍真的改东西了吗（给排查用）。
    @discardableResult
    static func reconcile() -> Bool {
        guard isEnabled else { return false }
        guard let page = lastPage, page.window != nil else { return false }

        if let list = lastList, list.window != nil {
            return pin(list)
        }

        // 列表换过实例（列表随页面重建）⇒ 重找一次。
        guard let list = locateList(in: page) else {
            logOnce("找不到听歌页的列表（\(listIdentifier)）— 本次不施加")
            return false
        }
        lastList = list
        return pin(list)
    }

    /// 卡片**折叠那一刻**叫一次（由 `NowPlayingOneScreenCards.x.swift` 调）。
    ///
    /// **为什么必须有这个入口**（2026-10-03 夜用户实测）：开启「一屏」后卡片确实全没了，
    /// 但**页面还能往下滑** ⇒ 说明"钉住"要么没跑、要么跑在**卡片到货之前**：
    /// 那时内容还没变高，公式给的是 `want >= 0`，我们按纪律什么都不做（见 `pin`），
    /// 之后要是再没有布局 / 滚动回合，这个错就一直留在那儿。
    ///
    /// pw 的注释写得很清楚：卡片**是播放器之后很久才到的**，所以它也在 `willDisplayCell`
    /// 里补了一枪；而且因为"cell 的高度是**一个 runloop 之后**才定的"，那一枪是 `dispatch_async`。
    ///
    /// **合并**：一次布局里有几十张卡，不合并就是几十个 block（本仓库纪律：短促重试不叠加）。
    static func noteCardCollapsed() {
        guard isEnabled, lastList != nil else { return }
        guard !repinScheduled else { return }
        repinScheduled = true
        DispatchQueue.main.async {
            repinScheduled = false
            repinNow()
        }
    }

    /// 合并后的那一枪：列表还在就重算一次。
    private static func repinNow() {
        guard isEnabled else { return }
        guard let list = lastList, list.window != nil else { return }
        pin(list)
    }

    /// 关掉开关时把 bottom inset 写回原值（我们只改过这一处）。
    static func restore() {
        guard let list = lastList else { return }
        guard let boxed = objc_getAssociatedObject(list, &originalInsetKey) as? NSNumber else { return }

        let original = CGFloat(boxed.doubleValue)
        var inset = list.contentInset
        guard abs(inset.bottom - original) > slack else { return }

        inset.bottom = original
        list.contentInset = inset
        objc_setAssociatedObject(list, &originalInsetKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        writeDebugLog("[\(logTag)] 列表 inset 已写回原值 — 滚动范围还原（reason=switch off）")
    }

    // MARK: - 钉住

    /// 把列表钉在它自己的顶部。**返回这一拍有没有真的写东西**。
    ///
    /// 公式（pw 的注释逐句译过来）：
    /// * `safeArea` = 安全区在"它自己的 inset"之外**额外**加的那部分，必须留着；
    /// * `over` = 内容比可视区高出来的那部分 —— 现在全靠卡片撑着；
    /// * 它能滚到的最远处，就是它静止时的位置：`-adjusted.top`（它自己的顶）；
    /// * ⇒ `want` 就是"让上面那句话成立"所需的 bottom inset。
    @discardableResult
    private static func pin(_ list: UIScrollView) -> Bool {
        let bounds = list.bounds
        guard bounds.height > 1 else { return false }

        let own = list.contentInset
        let adjusted = list.adjustedContentInset
        let safeArea: CGFloat = adjusted.bottom - own.bottom
        let over: CGFloat = list.contentSize.height - bounds.height
        let want: CGFloat = -adjusted.top - over - safeArea

        // 正数表示"内容还没铺满一屏"（**卡片还没到货、或者已经全折完了**）⇒ 不该压。
        // ⚠️ 这里**必须把 inset 退回原值**，不能只是"什么都不做"：
        // 真机日志 39 的现场 —— 卡片还在时先按 `content.h=2132` 压了 `-1236pt`；
        // 卡片一折起来内容就只剩一屏（`want=+0`），而上一版在这里直接 return ⇒
        // 那 -1236 留在列表上 ⇒ **往下能滑 1236pt 的空白**（用户报的就是这个）。
        if want >= 0 {
            if !didLogNotNeeded {
                didLogNotNeeded = true
                writeDebugLog(
                    "[\(logTag)] 内容还没到一屏高（want=+\(Int(want))pt）— 不该压"
                        + "（卡片还没到货、或已经全折完时就是这样）"
                )
            }
            revertInsetIfNeeded(list)
            logDiagnosticOnce(list)
            return false
        }
        guard abs(want - own.bottom) > slack else { return false }

        rememberOriginalInset(of: list)

        var next = own
        next.bottom = want
        list.contentInset = next

        if !didLogPin {
            didLogPin = true
            writeDebugLog(
                "[\(logTag)] 列表已钉在顶部 — 折掉 \(Int(-want))pt 的卡片范围"
                    + "（上拉只回弹，下拉关闭不受影响）"
            )
        }
        logDiagnosticOnce(list)
        return true
    }

    /// ★ 一次性诊断行：把「**为什么还能往下滑**」一次问清楚。
    ///
    /// 2026-10-03 夜用户实测："卡片全没了，但还能往下滑"。当时能猜的原因有四个
    /// （没找到列表 / 没到该压的时候 / 压了但值不对 / 剩下的只是**橡皮筋回弹**），
    /// 而日志里一条都分不开。这一行把四个数一次打出来：
    ///   · `inset.bottom` —— 我们到底压了多少（0 = 一个字都没压）；
    ///   · `content.h` vs `bounds.h` —— 内容比一屏高多少（高多少就该压多少）；
    ///   · `adj.top/bottom` —— 安全区那块（公式里必须留着的）；
    ///   · `bounce` —— **`alwaysBounceVertical`**：即使钉得完美，它开着就仍然能往下拽一把
    ///     （内容不满一屏时那只是回弹，不是滚动 —— 要彻底去掉得关它，而关它有风险，
    ///     见 `NowPlayingOneScreen` 文件头）；
    ///   · `panRecs` —— 那条列表上有几个 pan 手势（pw 说**下拉关闭**就骑在其中一个上）。
    private static func logDiagnosticOnce(_ list: UIScrollView) {
        guard !didLogDiag else { return }
        didLogDiag = true

        let own = list.contentInset
        let adjusted = list.adjustedContentInset
        let pans = (list.gestureRecognizers ?? []).filter { $0 is UIPanGestureRecognizer }.count

        writeDebugLog(
            "[\(logTag)] diag inset.bottom=\(Int(own.bottom))"
                + " content.h=\(Int(list.contentSize.height)) bounds.h=\(Int(list.bounds.height))"
                + " adj.top=\(Int(adjusted.top)) adj.bottom=\(Int(adjusted.bottom))"
                + " bounce=\(list.alwaysBounceVertical ? "on" : "off") panRecs=\(pans)"
        )
    }

    /// 把 inset **退回我们记下的原值**（幂等；没记过就什么都不做）。
    ///
    /// 与 `restore()`（关开关用）的区别：那个是不管怎样都退；这个是**每一拍的自纠**，
    /// 用在"内容缩回一屏内、不该再压"的时候 —— 见 `pin` 里那个分支的注释（日志 39 的现场）。
    @discardableResult
    private static func revertInsetIfNeeded(_ list: UIScrollView) -> Bool {
        guard let boxed = objc_getAssociatedObject(list, &originalInsetKey) as? NSNumber else { return false }

        let original = CGFloat(boxed.doubleValue)
        var inset = list.contentInset
        let pressed = inset.bottom
        guard abs(pressed - original) > slack else { return false }

        inset.bottom = original
        list.contentInset = inset
        writeDebugLog(
            "[\(logTag)] 内容缩回一屏内 ⇒ inset.bottom 由 \(Int(pressed)) 退回 \(Int(original))"
                + "（不该再压着了）"
        )
        return true
    }

    private static func rememberOriginalInset(of list: UIScrollView) {
        guard objc_getAssociatedObject(list, &originalInsetKey) == nil else { return }
        let value = NSNumber(value: Double(list.contentInset.bottom))
        objc_setAssociatedObject(list, &originalInsetKey, value, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// 这个视图是不是挂在**我们钉住的那张列表**下面。
    ///
    /// 卡片折叠的**最硬判据**（`NowPlayingOneScreenCards.x.swift` 用它）：跟类名、模块名
    /// 怎么变都无关 —— 我们本来就是从 `accessibilityIdentifier` 认列表的。
    /// 跳数封顶 12：卡片离列表也就几层，超过说明不是它的后代。
    static func isInsidePinnedList(_ view: UIView) -> Bool {
        guard let list = lastList else { return false }

        var node: UIView? = view
        var hops = 0
        while let current = node, hops < 12 {
            if current === list { return true }
            node = current.superview
            hops += 1
        }
        return false
    }

    /// 先在这一页的根视图里找；找不到再退到**窗口**里按那个 id 找。
    ///
    /// 为什么留这条兜底：pw 取证的是 **9.1.78**（它从 VC 的 view 里找得到那个 id），
    /// 我们这套基线是 **9.1.88** —— 万一那条列表其实不在这一页的子树里，
    /// `apply` 会**静默**失败、整个功能一动不动。那个 id 在整棵窗口树里只有一处，
    /// 认错页的风险可以忽略；走查仍然有界（`maxNodes`）。
    private static func locateList(in pageView: UIView) -> UIScrollView? {
        if let list = findList(in: pageView) { return list }
        guard let window = pageView.window else { return nil }
        return findList(in: window)
    }

    /// 从听歌页根视图往下按 `accessibilityIdentifier` 找那张列表（有界广度优先）。
    private static func findList(in root: UIView) -> UIScrollView? {
        var visited = 0
        var queue: [UIView] = [root]

        while !queue.isEmpty, visited < maxNodes {
            let view = queue.removeFirst()
            visited += 1

            if let scroll = view as? UIScrollView, scroll.accessibilityIdentifier == listIdentifier {
                return scroll
            }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }

    // MARK: - 日志

    private static func logOnce(_ message: String) {
        guard !didLogGiveUp else { return }
        didLogGiveUp = true
        writeDebugLog("[\(logTag)] \(message)")
    }
}
