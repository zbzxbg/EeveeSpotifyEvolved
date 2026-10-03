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
/// ## ⛔ 曾经的「禁止回弹」已删除（2026-10-03 真机日志 41 的判决）
///
/// 那一版在钉住之后还把列表的 `alwaysBounceVertical` 关掉，想连最后一点橡皮筋也去掉。
/// 用户实测：**开了它就再也划不掉播放器了** —— 文档当初把它标成"唯一风险点"，
/// 它确实是，而且坏得很干脆。
///
/// 日志 41（全量 37 份日志里唯一一份 `bounce=off`）的现场：
///
/// ```
/// [OneScreen] 已关掉列表的回弹（alwaysBounceVertical=false）
/// [OneScreen] diag inset.bottom=0 content.h=896 bounds.h=896 adj.top=0 adj.bottom=0 bounce=off panRecs=3
/// ```
///
/// **机制**（与 pw v0.21.1 `PlayerScroll.x` 的记载同源）：**下拉关闭是经过列表那一层接管的** ——
/// 列表在顶部时把下拉让给窗口，窗口那一侧才启动关闭。所以：
///   · `alwaysBounceVertical = true`：下拉被列表接住（它愿意接），
///     而钉住之后**列表没有任何内部可滚范围**（`content.h == bounds.h`）
///     ⇒ 这次拖动只能落到"让位"那条路 ⇒ **关得掉**；
///   · `alwaysBounceVertical = false` **且内容不满一屏**：pan 既不滚、也不进让位那条路
///     ⇒ **窗口永远收不到这次下拉** ⇒ 播放器划不掉。
///
/// ⚠️ 这条"机制"是从**它坏掉的方式**反推出来的（日志 41 的现场 + pw 那句"关闭骑在列表的 pan 上"），
/// 我们**没有**反汇编去证 9.1.88 的窗口那侧是怎么写的（`SPTBar*` 在 9.1.88 的 dump 里一个都没有）。
/// 但结论足够硬：**唯一动过那个属性的那次构建，就是关闭坏掉的那次。**
///
/// ⇒ 所以：**在这一页上 `alwaysBounceVertical` 不是"观感调参"，它是关闭手势链条的一环。**
///
/// ## ★ 2026-10-05：用户再问「开启"一屏"还是能和橡皮筋一样往下滑，pw 不是解决了吗」
///
/// **答案：pw 没有解决，它是刻意保留的。** 它 `PlayerScroll.x` 的文件头原话（v0.21.1，GPL-3.0）：
///
/// > *"So the range is closed instead: the bottom inset is set to whatever makes the furthest the
/// > list can scroll its own top. **A drag upward then only stretches and springs back**, a drag
/// > downward still carries the offset below zero, and the dismissal is untouched."*
///
/// 逐句对到我们这边：
/// * *"the range is closed instead"* = 我们做的**就是**这一件事（`inset.bottom` → `min(want, 0)`）；
/// * *"**A drag upward then only stretches and springs back**"* = ★ **pw 明确承认那条橡皮筋还在**
///   （上拉/下拉都只"拉伸并弹回"）；
/// * *"a drag downward still carries the offset below zero, **and the dismissal is untouched**"*
///   —— ★ 这两句是**同一件事的两面**：**那个负的 `contentOffset` 就是下拉关闭的输入**。
///   去掉回弹 = 去掉负偏移 = **关闭手势没有输入**。
///
/// **真机已经证明过这一条**：日志 41（全量 37 份里唯一一份 `bounce=off`）—— 那次就是把
/// `alwaysBounceVertical` 关掉去追这最后一点橡皮筋，结果**播放器再也划不掉**，
/// 开关当天就删了。而 pw 也写明**连滚动都不能关**：
/// *"Turning scrolling off takes that recogniser out with it and the player can no longer be swiped away."*
///
/// **日志 49 的现状**（用户这次报的现场）：
/// `inset.bottom=0 content.h=896 bounds.h=896 adj.top=0 adj.bottom=0 bounce=on panRecs=3`
/// ⇒ ★ `content.h == bounds.h`：**一点可滚范围都不剩了**。用户感到的那点位移**纯粹是回弹**，
/// 不是"还有内容能滚上去"。—— 也就是说「一屏」这一半是**做对了**的。
///
/// **所以只有一条路能同时要"拉不动"与"还能划掉"**：**自己接管下拉关闭**
/// （把列表在顶部的下拉读成"关闭进度"，自己驱动 dismiss），拿到之后才敢关 `bounces`。
/// 这条路的两个已知障碍：
///   1. pw 的挂点（`SPTBarInteractivePresentationController` / `SPTBarOverlayPresentationTransition`）
///      在 **9.1.88 上不存在**（探针实测缺这 2 个）⇒ **没有现成可抄的挂点**；
///   2. 本仓库在"自己加手势"上有前车之鉴（双击手势整块删掉）。
///
/// 三档选择（等用户拍板，**不擅自做**）：
///   * **A. 接受它**（pw 同款，成本 0）：只在设置页文案里说清"下拉那一下就是关闭手势本身"；
///   * **B. 自己接管关闭手势**（独立一轮，风险中高）：hook 列表的 pan → 顶部下拉给阈值 → 我们驱动
///     `dismiss`；成了才能把 `bounces` 关掉。**需要上面那条 diag 先回答"delegate 是谁"**；
///   * **C. 只关一端**：`UIScrollView` **没有**"只关顶部回弹"的公开开关（`bounces` 是两端总闸，
///     `alwaysBounceVertical` 在内容不满一屏时等于关掉顶部）—— **所以 C 不存在**。
///
/// 代价（说清楚）：列表拖拽时仍会有橡皮筋 —— 那是"一屏"目前**无法消除**的残留：
/// 想去掉它就得碰上面那个属性，一碰关闭手势就坏。
/// 开关与它的 UI 行、UserDefaults 键、en / zh-CN 的文案**全部删除**，不留"按了会坏"的入口
/// （那两条文案历史上只存在这两种语言）。
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

        // ★ 目标值**不是"压 / 不压"的二选一** —— 目标永远是"让列表最多只能滚到它自己的顶"。
        //
        // 日志 40 的现场把这件事说清了：内容**刚好一屏**时 `want = +0`，而 Spotify 自己把
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

    /// ★ 一次性诊断行：把「**为什么还能往下滑**」一次问清楚。
    ///
    /// 2026-10-03 夜用户实测："卡片全没了，但还能往下滑"。当时能猜的原因有四个
    /// （没找到列表 / 没到该压的时候 / 压了但值不对 / 剩下的只是**橡皮筋回弹**），
    /// 而日志里一条都分不开。这一行把几个数一次打出来：
    ///   · `inset.bottom` —— 我们到底压了多少（0 = 一个字都没压）；
    ///   · `content.h` vs `bounds.h` —— 内容比一屏高多少（高多少就该压多少）；
    ///     ★ **两者相等 ⇒ 一点可滚范围都没有了，剩下的只可能是"回弹"**；
    ///   · `adj.top/bottom` —— 安全区那块（公式里必须留着的）；
    ///   · `bounce` —— **`alwaysBounceVertical`，只读**：它必须一直是 `on`。
    ///     ⚠️ 这一格是**回归判据**：曾经我们把它写成 `false`（「禁止回弹」），
    ///     结果**下拉关闭播放器直接坏掉**（日志 41）。它现在是只读的哨兵 ——
    ///     `bounce=off` 再出现，就说明有人又把关闭手势链条碰断了。
    ///   · `bounces` —— `UIScrollView.bounces`（**两端**回弹的总闸）。日志 49 里用户报
    ///     "一屏开着还能像橡皮筋一样往下滑"，那时 `content.h==bounds.h` 已经成立
    ///     ⇒ 剩下的就是它。**要动它必须先有"自己接管下拉关闭"的办法**（见文件头）。
    ///   · `panRecs` / `pan=<delegate>` —— 那条列表上有几个 pan 手势，以及**第一个 pan 的
    ///     delegate 是谁**。下拉关闭就骑在其中一个 pan 上，而 pw 说窗口那侧会让自己的
    ///     dismiss recogniser **等它失败** ⇒ 如果我们将来要"让列表在顶部主动让位"，
    ///     要不要接管 delegate、能不能接管，就看这一格（只读，不碰）。
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

    /// 这个视图是不是挂在**我们钉住的那张列表**下面。    ///
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
