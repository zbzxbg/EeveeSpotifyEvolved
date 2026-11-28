// 「横屏两栏」的左栏：把底排里的三行**搬出来**自己摆。
//
// 底排（`npv.bottomStackView`）在横屏是一个 Spotify 每帧重写的定值盒子（真机上是 272×240）：
// 写 `bounds`、挂 999 优先级的宽高约束都留不住，折掉一行它也不缩 —— 于是封面只能拿到
// 「可用高 − 那 240pt」那一小块，进度条也永远比封面宽出一大截。
//
// 所以这一层换了个做法：把**歌名 / 进度 / 传输**三格从底排里结构性搬出来（各自
// `addSubview` 到页面上），位置与宽度由我们按两栏几何给。行本身还是原生的 —— 滑杆能拖、
// 播放键能点、歌名/时间自己更新 —— 只是不再受那个定值盒子的摆布。
//
// 搬不动（认不出那一格 / 它不在底排里）就什么都不做：页面维持"盒子没搬"的老样子。
// 日志 tag：`[iOS27]`，一次性一行 `landscape rows — …`。
import Foundation
import UIKit

@MainActor
extension NowPlayingIOS27 {

    /// 搬出来的一行：它自己 + 原来在底排里的槽位（收尾放回去）。
    struct LandscapeRow {
        weak var view: UIView?
        weak var home: UIView?
        var index: Int
    }

    /// 左栏里"歌名 + 进度"合计多高（封面与歌词容器都按它收边）。
    private(set) static var landscapeRowsContentHeight: CGFloat = 0
    /// 底部那一行（传输行）现在占的框（页面坐标）。
    private(set) static var landscapeTransportFrame: CGRect?

    static var landscapeTitleRow: LandscapeRow?
    static var landscapeProgressRow: LandscapeRow?
    static var landscapeTransportRow: LandscapeRow?

    /// 我们画的两个时间（原生那两颗在横屏会被藏掉：栏宽一窄它们就撑破进度行）。
    static var landscapeTimeLabels: (left: UILabel, right: UILabel)?

    private static var didLogLandscapeRows = false
    /// "这一格因为控制器父子关系搬不动"只报一次 —— 搬不动的那一格下一拍还会再试，
    /// 不拦的话 0.3s 一行刷屏。
    private static var didLogLandscapeHierarchy = false

    // MARK: - 每拍入口

    /// 把三行搬出底排、按 `layout` 摆好。返回这一拍有没有写东西。
    ///
    /// ⚠️ 必须排在 `placeTitleRow` / `placeProgress` **之前**：它们要按"行在页面上"来量。
    @discardableResult
    static func placeLandscapeRows(in page: UIView, layout: LandscapeLayout) -> Bool {
        var changed = false
        // 底排可能已经被 Spotify 换掉；三行都已经搬出来的话不再依赖它（位置每拍重算）。
        if let stack = bottomStackView(in: page) {
            if landscapeTitleRow == nil {
                landscapeTitleRow = detachLandscapeRow(
                    containing: titleRowView(in: page),
                    from: stack,
                    in: page
                )
            }
            if landscapeProgressRow == nil {
                landscapeProgressRow = detachLandscapeRow(
                    containing: progressUnit(in: page),
                    from: stack,
                    in: page
                )
            }
            if landscapeTransportRow == nil {
                landscapeTransportRow = detachLandscapeRow(
                    containing: playButtonView(in: page),
                    from: stack,
                    in: page
                )
            }
        }
        // 一格都没搬动 ⇒ 不假装成功，页面按老的摆法走。
        guard landscapeTitleRow != nil || landscapeProgressRow != nil || landscapeTransportRow != nil else {
            return false
        }

        // 宽度：封面那一栏再左右各让出原生行自己的内边距（真机量到的是 24），内容线才对得上封面。
        let inset: CGFloat = 24
        let contentX = max(12, page.safeAreaInsets.left + 16)
        let rowLeft = contentX - inset
        let rowWidth = layout.column.width + inset * 2

        var y = layout.cover.maxY + LayoutGeometry.landscapeCoverStackGap
        if let row = landscapeTitleRow?.view {
            let height = row.bounds.height > 1 ? row.bounds.height : 56
            if place(row, at: CGRect(x: rowLeft, y: y, width: rowWidth, height: height)) {
                changed = true
            }
            y += height + 6
        }
        if let row = landscapeProgressRow?.view {
            let height = row.bounds.height > 1 ? row.bounds.height : 41
            if place(row, at: CGRect(x: rowLeft, y: y, width: rowWidth, height: height)) {
                changed = true
            }
            y += height
        }
        landscapeRowsContentHeight = (y - (layout.cover.maxY + LayoutGeometry.landscapeCoverStackGap))
            .rounded()

        // 传输行一行要 ≈270pt（五颗键），放不进窄栏 ⇒ 搬到页面底部居中，
        // 歌词来源与它**平排**（见 `placeLyricsCredit`）。
        if let row = landscapeTransportRow?.view {
            let height = row.bounds.height > 1 ? row.bounds.height : 64
            let width = min(row.bounds.width > 1 ? row.bounds.width : 272, page.bounds.width - 48)
            let frame = CGRect(
                x: ((page.bounds.width - width) / 2).rounded(),
                y: (page.bounds.height - page.safeAreaInsets.bottom - 12 - height).rounded(),
                width: width,
                height: height
            )
            if place(row, at: frame) { changed = true }
            landscapeTransportFrame = frame
            if page.subviews.last !== row { page.bringSubviewToFront(row) }
        }

        placeLandscapeTimeLabels(in: page, layout: layout)

        if !didLogLandscapeRows {
            didLogLandscapeRows = true
            func name(_ row: LandscapeRow?) -> String {
                guard let view = row?.view else { return "missing" }
                // 类名一起打：这三格是什么类型决定"能不能搬"（见 `adoptControllers`）。
                return "\(NSStringFromClass(type(of: view)))"
                    + " \(Int(view.bounds.width))×\(Int(view.bounds.height))"
            }
            writeDebugLog(
                "[\(logTag)] landscape rows — title \(name(landscapeTitleRow)),"
                    + " progress \(name(landscapeProgressRow)),"
                    + " transport \(name(landscapeTransportRow));"
                    + " left column \(Int(layout.column.width))pt,"
                    + " block \(Int(landscapeRowsContentHeight))pt,"
                    + " bottom row at y \(Int(landscapeTransportFrame?.minY ?? 0))"
            )
        }
        return changed
    }

    /// 转回竖屏 / 收尾：三行放回底排原来的槽位，时间标签退回原生那两颗。
    static func restoreLandscapeRows() {
        // 下一程（再转横屏）重新记一行日志。
        didLogLandscapeHierarchy = false
        for row in [landscapeTitleRow, landscapeProgressRow, landscapeTransportRow] {
            restoreLandscapeRow(row)
        }
        landscapeTitleRow = nil
        landscapeProgressRow = nil
        landscapeTransportRow = nil
        landscapeRowsContentHeight = 0
        landscapeTransportFrame = nil
        for label in [landscapeTimeLabels?.left, landscapeTimeLabels?.right].compactMap({ $0 }) {
            label.removeFromSuperview()
        }
        landscapeTimeLabels = nil
        releaseNativeTimeLabels()
    }

    // MARK: - 搬 / 放

    private static func place(_ view: UIView, at frame: CGRect) -> Bool {
        guard view.frame != frame else { return false }
        view.frame = frame
        return true
    }

    /// 从 `stack` 里把"装着 `view` 的那一格"搬出来。认不出就返回 nil（不搬）。
    private static func detachLandscapeRow(
        containing view: UIView?,
        from stack: UIView,
        in page: UIView
    ) -> LandscapeRow? {
        guard let view else { return nil }
        var node = view
        var hops = 0
        while hops < 8 {
            if let parent = node.superview, parent === stack {
                var index = stack.subviews.firstIndex(of: node) ?? 0
                if let stackView = stack as? UIStackView,
                   let arranged = stackView.arrangedSubviews.firstIndex(of: node) {
                    index = arranged
                }
                // ⚠️ 搬之前先过一遍层级体检（见 `adoptControllers`）：子树里如果有"自己是
                // 某个控制器根视图"的视图，而那个控制器不在页面控制器下面，这一搬就是
                // `UIViewControllerHierarchyInconsistency` ⇒ 主线程 abort。
                guard adoptControllers(in: node, page: page) else { return nil }
                node.removeFromSuperview()
                node.translatesAutoresizingMaskIntoConstraints = true
                node.transform = .identity
                page.addSubview(node)
                return LandscapeRow(view: node, home: stack, index: index)
            }
            guard let next = node.superview else { return nil }
            node = next
            hops += 1
        }
        return nil
    }

    // MARK: - 搬之前的层级体检
    //
    // 把一棵子树从窗口上摘下来再挂回去时，UIKit 会对**整棵子树**跑一遍 appearance 转发检查
    // （`-[UIView _associatedViewControllerForwardsAppearanceCallbacks:performHierarchyCheck:isRoot:]`，
    // 由 `_willMoveToWindow:` 调起）：子树里只要有视图是**某个控制器的根视图**，而那个控制器的
    // 父控制器不是挂载目标所属的控制器（这里是 `page` = `NPVScrollViewController.view` ⇒
    // 页面控制器），就抛 `UIViewControllerHierarchyInconsistency`
    // （"child view controller:<X> should have parent view controller:<Y> but actual parent is:<Z>"）
    // ⇒ 主线程 abort。栈长这样：`__NSFireTimer` → `DeclutterChrome` 的复查节拍 →
    // 这一层 → `_addSubview:positioned:relativeTo:` → 抛。
    //
    // 竖屏页内歌词与全屏歌词页都不搬原生视图，所以只有横屏这一层会踩到。
    //
    // 处理原则和这一层其它地方一致（"搬不动就什么都不做"）：
    // · 控制器**没有父控制器**（Spotify 自己也是裸挂的宿主视图）⇒ `addChild` 到页面控制器，
    //   层级立刻一致，照搬；
    // · 控制器**有别的父控制器** ⇒ 不搬 —— 那是在拆 Spotify 的父子关系，
    //   留着原生摆法，只记一行日志（照那行日志决定要不要显式认过来）。

    /// 这个视图**自己**是不是某个控制器的根视图（是就返回那个控制器）。
    ///
    /// 判据就是 responder 链：普通视图的 `next` 是它的 superview，只有控制器根视图的
    /// `next` 才是控制器本人 —— 正好是 UIKit 那条检查关心的那一种视图。
    private static func owningController(of view: UIView) -> UIViewController? {
        view.next as? UIViewController
    }

    /// `page` 所属的控制器（`NPVScrollViewController`）—— UIKit 眼里"应有父控制器"就是它。
    private static func pageController(of page: UIView) -> UIViewController? {
        var responder: UIResponder? = page
        var hops = 0
        while let current = responder, hops < 64 {
            if let controller = current as? UIViewController { return controller }
            responder = current.next
            hops += 1
        }
        return nil
    }

    /// 把 `node` 子树里"无主的控制器"认到页面控制器下面；认不了的（有别的父控制器）返回
    /// `false`，调用方就此放弃搬这一格。
    ///
    /// 走查上限 200 个节点（本仓库纪律：全页 BFS 都要有预算），够覆盖一整格了。
    private static func adoptControllers(in node: UIView, page: UIView) -> Bool {
        guard let host = pageController(of: page) else { return true }
        var queue: [UIView] = [node]
        var visited = 0
        while !queue.isEmpty, visited < 200 {
            let view = queue.removeFirst()
            visited += 1
            queue.append(contentsOf: view.subviews)
            guard let owner = owningController(of: view), owner !== host else { continue }
            if owner.parent === host { continue }
            if let parent = owner.parent {
                if !didLogLandscapeHierarchy {
                    didLogLandscapeHierarchy = true
                    writeDebugLog(
                        "[\(logTag)] landscape rows — \(NSStringFromClass(type(of: node))) owns"
                            + " \(NSStringFromClass(type(of: owner))), whose parent is"
                            + " \(NSStringFromClass(type(of: parent))) — not detaching this row"
                    )
                }
                return false
            }
            host.addChild(owner)
            owner.didMove(toParent: host)
            if !didLogLandscapeHierarchy {
                didLogLandscapeHierarchy = true
                writeDebugLog(
                    "[\(logTag)] landscape rows — adopted \(NSStringFromClass(type(of: owner)))"
                        + " under the page's controller before detaching"
                )
            }
        }
        return true
    }

    private static func restoreLandscapeRow(_ row: LandscapeRow?) {
        guard let row, let view = row.view, let home = row.home, home.window != nil else { return }
        guard view.superview !== home else { return }
        view.removeFromSuperview()
        view.transform = .identity
        if let stackView = home as? UIStackView {
            view.translatesAutoresizingMaskIntoConstraints = false
            stackView.insertArrangedSubview(view, at: min(row.index, stackView.arrangedSubviews.count))
        } else {
            view.translatesAutoresizingMaskIntoConstraints = true
            home.insertSubview(view, at: min(row.index, home.subviews.count))
        }
    }

    /// 那颗播放键（传输行里最中间那颗）—— 只用它来认"装着传输行的格子"。
    private static func playButtonView(in page: UIView) -> UIView? {
        visibleView(
            identifier: NowPlayingLyricsPlate.playButtonIdentifier,
            in: page,
            requireAlpha: false,
            horizontalMargin: 0
        )
    }

    // MARK: - 时间

    /// 横屏：原生那两颗时间**藏起来**（栏宽一窄它们就撑破进度行），自己画两颗放在栏的两端。
    ///
    /// 文字直接读原生那两颗（它自己每秒更新），所以不用自己算时长。
    private static func placeLandscapeTimeLabels(in page: UIView, layout: LandscapeLayout) {
        guard let progress = landscapeProgressRow?.view else { return }
        let natives = nativeTimeLabels(in: progress)
        guard !natives.isEmpty else { return }
        hideNativeTimeLabels(natives)

        let labels: (left: UILabel, right: UILabel)
        if let existing = landscapeTimeLabels, existing.left.superview === page {
            labels = existing
        } else {
            let left = makeTimeLabel(identifier: "eevee-ios27-time-left", alignRight: false)
            let right = makeTimeLabel(identifier: "eevee-ios27-time-right", alignRight: true)
            page.addSubview(left)
            page.addSubview(right)
            landscapeTimeLabels = (left, right)
            labels = (left, right)
            // 藏起来之后 `progressTimeLabels` 认不出它们，字体那一步就此停手 —— 记着的原字体照旧。
        }

        let elapsed = natives.min { $0.convert($0.bounds, to: page).minX < $1.convert($1.bounds, to: page).minX }
        let remaining = natives.max { $0.convert($0.bounds, to: page).minX < $1.convert($1.bounds, to: page).minX }
        labels.left.text = elapsed?.text ?? ""
        labels.right.text = remaining?.text ?? elapsed?.text ?? ""

        let width = max(40, layout.column.width / 2)
        let top = progress.convert(progress.bounds, to: page).maxY + 2
        labels.left.frame = CGRect(x: layout.column.minX, y: top, width: width, height: 18).integral
        labels.right.frame = CGRect(
            x: layout.column.maxX - width,
            y: top,
            width: width,
            height: 18
        ).integral
    }

    private static func makeTimeLabel(identifier: String, alignRight: Bool) -> UILabel {
        let label = UILabel()
        label.accessibilityIdentifier = identifier
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        label.textColor = UIColor(white: 1, alpha: 0.72)
        label.textAlignment = alignRight ? .right : .left
        label.isUserInteractionEnabled = false
        return label
    }

    /// 进度行里原生那两颗时间（按 x 排序，左边的是已播、右边的是剩余）。
    private static func nativeTimeLabels(in progress: UIView) -> [UILabel] {
        var result: [UILabel] = []
        var queue: [UIView] = [progress]
        var visited = 0
        while !queue.isEmpty, visited < 200 {
            let view = queue.removeFirst()
            visited += 1
            queue.append(contentsOf: view.subviews)
            guard let label = view as? UILabel else { continue }
            guard !(label.accessibilityIdentifier ?? "").hasPrefix("eevee-ios27-") else { continue }
            result.append(label)
        }
        return result
    }

    /// 原生时间标签（藏过的记原值，转回竖屏写回来）。
    private static func hideNativeTimeLabels(_ labels: [UILabel]) {
        for label in labels {
            let key = ObjectIdentifier(label)
            if landscapeNativeTimeHidden[key] == nil {
                landscapeNativeTimeHidden[key] = label.isHidden
                landscapeNativeTimeViews.add(label)
            }
            if !label.isHidden { label.isHidden = true }
        }
    }

    /// 把藏过的原生时间标签显回来。
    static func releaseNativeTimeLabels() {
        for label in landscapeNativeTimeViews.allObjects {
            guard let wasHidden = landscapeNativeTimeHidden[ObjectIdentifier(label)] else { continue }
            if label.isHidden != wasHidden { label.isHidden = wasHidden }
        }
        landscapeNativeTimeViews.removeAllObjects()
        landscapeNativeTimeHidden.removeAll()
    }

    static let landscapeNativeTimeViews = NSHashTable<UILabel>.weakObjects()
    private static var landscapeNativeTimeHidden: [ObjectIdentifier: Bool] = [:]
}
