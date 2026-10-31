import Foundation
import UIKit
import ObjectiveC.runtime


/// 听歌页「一屏」：把播放器下面那些卡片**全部折起来**，并把列表**钉在它自己的顶部** ——
/// Music app / kumone 那种"一屏一首歌、滚不动"。
///
/// 算法借自 spoti.pw v0.21.1（GPL-3.0）的 `Redesigned/Player/PlayerCards.x` / `PlayerScroll.x`，
/// 落地是本地 Swift 实现。**许可边界：只许借 ≤ v0.21.1**；v0.22.0 起是 PolyForm Strict，一行不能碰。
///
/// ## 为什么是"钉住范围"而不是"关掉滚动"
/// 下拉关闭挂在**列表自己的 pan recogniser** 上（`SPTBarInteractivePresentationController
/// scrollViewDidAppear:` 取走它、让 dismiss 识别器等它失败，且只在列表处于 / 高于顶部时才启动）：
/// **把滚动关掉会把那个 recogniser 一起带走 ⇒ 播放器再也划不掉。**
/// 所以这里只关"范围"：把 `contentInset.bottom` 设成"让列表最多滚到它自己的顶部"。
/// 于是上拉只拉伸回弹、下拉仍能到负偏移、**关闭手势完全不受影响**。
///
/// ⚠️ **`alwaysBounceVertical` 在这一页上不是观感调参，是关闭手势链条的一环**：
/// 真机试过把它关掉 ⇒ 播放器再也划不掉（那一版当天就删了）。`content.h == bounds.h` 之后
/// 感到的位移纯粹是回弹；`UIScrollView` 也没有"只关一端"的公开开关
/// ⇒ 想彻底去掉回弹只剩"自己接管下拉关闭"一条路（hook 列表 pan → 自己驱动 dismiss，
/// 前提是先用诊断回答"delegate 是谁"）。
///
/// ## 其它
/// · 重算时机：蹭 `DeclutterChrome` 既有的 0.3s 复查节拍（**不新开 hook、不挂可选方法**）；
/// · 卡片折叠那一半在 `NowPlayingOneScreenCards.x.swift`（那个必须是 Orion hook）；
/// · 开关：听歌页 →「修改Spotify听歌页布局」总开关起把原来那颗
/// 「隐藏 Spotify 的听歌页模块」收进去了），**默认开**
/// （`UserDefaults.nowPlayingLayout && UserDefaults.nowPlayingOneScreen`），日志 tag `[OneScreen]`。
/// 默认开的前提是"歌词进播放器"（`NowPlayingLyricsPlate`）补上了打开歌词的入口 ——
/// 否则折掉歌词卡之后，听歌页就没有"打开歌词"的地方了。
enum NowPlayingOneScreen {

    static let logTag = "OneScreen"

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

    /// 这颗开关由「修改Spotify听歌页布局」总开关统一写；
    /// 再叠一道 `nowPlayingLayout` 的门，是为了"总开关关掉 ⇒ 这一套一律不生效"
    /// （哪怕有外部写回 / 导入备份把那颗键写成了 true）。
    static var isEnabled: Bool {
        UserDefaults.nowPlayingAnyLayout && UserDefaults.nowPlayingOneScreen
    }

    // MARK: - 对外入口
    //
    // 进听歌页时叫一次（蹭既有的 `NPVScrollViewControllerHook.viewWillAppear` / `.viewDidAppear`）。
    //
    // 找不到列表时**刻意不打日志**：`viewWillAppear` 那一刻列表常常还没建出来，
    // 打了就是每进一次页面一条噪音。"真的从来找不到"由 `reconcile` 负责上报。
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
    /// **为什么必须有这个入口**夜一屏后卡片确实全没了，
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

    /// 关掉开关时把 bottom inset 写回原值 —— 我们只改过这一处
    /// （`alwaysBounceVertical` 从此一字节都不碰，见文件头）。
    static func restore() {
        guard let list = lastList else { return }

        // 开关关掉之后再看一次诊断（下次开起来时那一行会重新打一遍，不靠"整场只报一次"）。
        didLogDiag = false

        if let boxed = objc_getAssociatedObject(list, &originalInsetKey) as? NSNumber {
            let original = CGFloat(boxed.doubleValue)
            var inset = list.contentInset
            if abs(inset.bottom - original) > slack {
                inset.bottom = original
                list.contentInset = inset
                objc_setAssociatedObject(list, &originalInsetKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                writeDebugLog(
                    "[\(logTag)] list inset.bottom written back to \(Int(original)) - scroll range restored (reason=switch off)"
                )
            }
        }
    }

    // MARK: - 钉住
    //
    // 把列表钉在它自己的顶部。**返回这一拍有没有真的写东西**。
    //
    // 公式（pw 的注释逐句译过来）：
    // * `safeArea` = 安全区在"它自己的 inset"之外**额外**加的那部分，必须留着；
    // * `over` = 内容比可视区高出来的那部分 —— 现在全靠卡片撑着；
    // * 它能滚到的最远处，就是它静止时的位置：`-adjusted.top`（它自己的顶）；
    // * ⇒ `want` 就是"让上面那句话成立"所需的 bottom inset。
    @discardableResult
    private static func pin(_ list: UIScrollView) -> Bool {
        let bounds = list.bounds
        guard bounds.height > 1 else { return false }

        let own = list.contentInset
        let adjusted = list.adjustedContentInset
        let safeArea: CGFloat = adjusted.bottom - own.bottom
        let over: CGFloat = list.contentSize.height - bounds.height
        let want: CGFloat = -adjusted.top - over - safeArea

        // 目标值**不是"压 / 不压"的二选一** —— 目标永远是"让列表最多只能滚到它自己的顶"。
        //
        // 而 Spotify 自己把
        // `contentInset.bottom` 留了 **34**（安全区那一档）⇒ 那 34pt 就是用户还能往下滑的距离。
        // 早先两版都栽在这一支上：先按"卡片还在时"的内容压了 -1236（留下 1236pt 空白）；
        // 改成"`want >= 0` 就退回原值"之后，又把 Spotify 那 34 原样留着（还是能滑 34pt）。
        // 统一成 `min(want, 0)`：该压就压，不该压就把自带的那截**归零**（不做无谓的正 inset）。
        let target: CGFloat = min(want, 0)

        guard abs(target - own.bottom) > slack else { return false }

        if target == 0, own.bottom > slack, !didLogNotNeeded {
            didLogNotNeeded = true
            writeDebugLog(
                "[\(logTag)] zeroed the list's own inset.bottom=\(Int(own.bottom))pt"
                    + " (with the content exactly one screen tall, that was the distance it could still scroll)"
            )
        }

        rememberOriginalInset(of: list)

        var next = own
        next.bottom = target
        list.contentInset = next

        if !didLogPin {
            didLogPin = true
            writeDebugLog(
                "[\(logTag)] list pinned to its top - closed off \(Int(max(0, -want)))pt of card range"
                    + " (a pull up only stretches; pull-to-dismiss is handled by the list yielding at its top," 
                    + " we only change the range and never the bounce)"
            )
        }
        logDiagnosticOnce(list)
        return true
    }

    /// 一次性诊断行：把「**为什么还能往下滑**」一次问清楚。
    ///
    /// 夜用户实测："卡片全没了，但还能往下滑"。当时能猜的原因有四个
    /// （没找到列表 / 没到该压的时候 / 压了但值不对 / 剩下的只是**橡皮筋回弹**），
    /// 这一行把几个数一次打出来：
    /// · `inset.bottom` —— 我们到底压了多少（0 = 一个字都没压）；
    /// · `content.h` vs `bounds.h` —— 内容比一屏高多少（高多少就该压多少）；
    /// **两者相等 ⇒ 一点可滚范围都没有了，剩下的只可能是"回弹"**；
    /// · `adj.top/bottom` —— 安全区那块（公式里必须留着的）；
    /// · `bounce` —— **`alwaysBounceVertical`，只读**：它必须一直是 `on`。
    /// ⚠️ 这一格是**回归判据**：曾经我们把它写成 `false`（「禁止回弹」），
    /// 结果**下拉关闭播放器直接坏掉**。它现在是只读的哨兵 ——
    /// `bounce=off` 再出现，就说明有人又把关闭手势链条碰断了。
    /// · `bounces` —— `UIScrollView.bounces`（**两端**回弹的总闸）。
    /// "一屏开着还能像橡皮筋一样往下滑"，那时 `content.h==bounds.h` 已经成立
    /// ⇒ 剩下的就是它。**要动它必须先有"自己接管下拉关闭"的办法**（见文件头）。
    /// · `panRecs` / `pan=<delegate>` —— 那条列表上有几个 pan 手势，以及**第一个 pan 的
    /// delegate 是谁**。下拉关闭就骑在其中一个 pan 上，而 pw 说窗口那侧会让自己的
    /// dismiss recogniser **等它失败** ⇒ 如果我们将来要"让列表在顶部主动让位"，
    /// 要不要接管 delegate、能不能接管，就看这一格（只读，不碰）。
    private static func logDiagnosticOnce(_ list: UIScrollView) {
        guard !didLogDiag else { return }
        didLogDiag = true

        let own = list.contentInset
        let adjusted = list.adjustedContentInset
        let pans = (list.gestureRecognizers ?? []).compactMap { $0 as? UIPanGestureRecognizer }

        var panDelegate = "nil"
        if let pan = pans.first, let delegate = pan.delegate {
            panDelegate = String(describing: type(of: delegate))
        }

        writeDebugLog(
            "[\(logTag)] diag inset.bottom=\(Int(own.bottom))"
                + " content.h=\(Int(list.contentSize.height)) bounds.h=\(Int(list.bounds.height))"
                + " adj.top=\(Int(adjusted.top)) adj.bottom=\(Int(adjusted.bottom))"
                + " bounce=\(list.alwaysBounceVertical ? "on" : "off")"
                + " bounces=\(list.bounces ? "on" : "off")"
                + " panRecs=\(pans.count) pan=\(panDelegate)"
        )
    }

    private static func rememberOriginalInset(of list: UIScrollView) {
        guard objc_getAssociatedObject(list, &originalInsetKey) == nil else { return }
        let value = NSNumber(value: Double(list.contentInset.bottom))
        objc_setAssociatedObject(list, &originalInsetKey, value, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// 这个视图是不是挂在**我们钉住的那张列表**下面。 ///
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

    /// 我们认出来的那张播放器列表（可能为 nil：还没进过听歌页）。
    ///
    /// 为什么对别的功能开放：**「歌词进播放器」要把气泡摆在它上面**（用它的 `layer.position`
    /// 量当前位置 —— `frame` 在 transform 非恒等时不可信，本仓库纪律）。
    /// 认列表的判据仍然只有这一处（`accessibilityIdentifier`），别处别再抄一份。
    static var pinnedList: UIScrollView? { lastList }

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
