import UIKit

/// **歌单页那排 setting pill** —— 藏掉它。
///
/// 那排是 Spotify 自己的东西，AM 里没有：
/// ```
/// 歌单页    ┌ + 添加 ┐ ┌ ≡ 编辑 ┐ ┌ ↕ 排序 ┐ ┌ ✎ 姓名和详情 ┐      ← 149
/// ```
///
/// 判据：四颗的**文字逐个整串相等**。必须整串相等 —— `添加歌曲`（148 里那行）含"添加"，子串匹配会把它一起藏掉。
///
/// 纪律：
/// · **记原值**（`wasHidden`），关开关 / 换页时 `restore` 原样写回 —— 与 `EntityPageAppearance` 其余十处同一个形状；
/// · 每拍有界，页面上没有这排时**什么都不做**；
/// · ⚠️ 藏的是**视图**，不是列表里的行高 ⇒ 若 Spotify 把这一排算进页头高度，藏完会留一条空档。
///
/// 扫描顺序（那排 pill 在页头那一棵里，而页根下先排着整个列表）：
/// 1. `EntityPageHeaderManager.headerHost`（歌单页就是 `PL.Header`）—— 那一棵小得多；
/// 2. 整页兜底。
/// 只从页根按层走是**不够**的：900 个节点常常在走到页头之前就被列表的 cell 吃光了，
/// 于是那排 pill 一直露着（往下滑时它跟着页头滚出屏幕，看起来像"自己又没了"）。
///
/// 「喜欢的歌曲」那排 tags chips **不再动**：旧判据 `Toolbar_Core.ToolbarChip*` 属于搜索 / 资料库的工具条，不是它；后来加的形状兜底（≥4 颗、自己那段文字 ≤6 字的 `UIControl`）在真机上也没命中过。与其继续猜类名，那半边判据已删干净 —— 本文件现在**只管歌单页那排 pill**。
enum EntityPageCurationHide {

    /// 那排 pill 的模块前缀。
    private static let identifierMarkers = [
        "PlaylistCuration",
        "CurationActionsToolbar",
    ]

    /// 文字兜底：那一排四颗的字面（**整串相等**，见文件头）。只比视图自己的那段文字，
    /// 不进子树 —— 进子树会把整行/整页的文字都带回来。
    private static let textMarkers: Set<String> = [
        "添加", "编辑", "排序", "姓名和详情",
        "add", "edit", "sort", "name & details", "name and details",
        "追加", "編集", "並び替え", "名前と詳細",
    ]

    /// 页头那一棵的上限。`PL.Header` 里是封面 + 文字块 + 搜索框 + 这排 pill，
    /// 通常几百个节点；给到 900 是"再大也一定走完"的量级。
    private static let headerNodes = 900

    /// 整页兜底的上限。页根下先排着整个列表（可见 cell 各自一棵子树）⇒ 900 不够。
    /// 3000 节点的深度优先只跑到"看不见的东西"才会超，代价是亚毫秒级。
    private static let maxNodes = 3000

    /// 一个被我们藏掉的视图。
    ///
    /// ⚠️ 用 **class** 而不是 struct：`weak var` 不能写在 struct 里（编译器直接报错），
    /// 而这里必须用弱引用 —— 否则换页之后这些记录会把上一页的整棵子树吊住。
    private final class Hidden {
        weak var view: UIView?
        let wasHidden: Bool

        init(view: UIView) {
            self.view = view
            self.wasHidden = view.isHidden
        }
    }

    private static var hidden: [Hidden] = []
    private static var didReport = false

    /// 空扫诊断：每页只报一次，带上"候选 id / 短文字" —— 下一次日志能直接指认那排 pill 的类名或 id。
    private static weak var emptyPage: UIView?
    private static var emptyPasses = 0
    private static var didReportEmpty = false

    // MARK: - 入口
    //
    // 每拍调一次。只在专辑 / 歌单页上由 `EntityPageAppearance.tick` 调用。
    static func apply(to page: UIView) {
        guard page.window != nil else { return }

        var marked: [UIView] = []
        var labelled: [UIView] = []
        var rows: [UIView] = []

        // 1) 页头那一棵先扫：那排 pill 在页头里，而页根下先排着整个列表。
        if let header = EntityPageHeaderManager.headerHost,
           header === page || header.isDescendant(of: page) || page.isDescendant(of: header) {
            collect(in: header, limit: headerNodes, marked: &marked, labelled: &labelled, rows: &rows)
        }

        // 2) 页头那一棵没凑齐就扫整页。
        var scannedPage = false
        if marked.isEmpty, rows.isEmpty, labelled.count < 2 {
            collect(in: page, limit: maxNodes, marked: &marked, labelled: &labelled, rows: &rows)
            scannedPage = true
        }

        var targets = resolvedTargets(marked: marked, labelled: labelled, rows: rows)

        // 3) 页头那一趟可能只认出文字、又凑不出共同祖先（文字落在不同子树里）——
        //    这时整页再扫一遍。类名判据不看文字，所以这一趟仍可能整排收掉。
        if targets.isEmpty, !scannedPage, labelled.count >= 2 {
            collect(in: page, limit: maxNodes, marked: &marked, labelled: &labelled, rows: &rows)
            targets = resolvedTargets(marked: marked, labelled: labelled, rows: rows)
        }

        guard !targets.isEmpty else {
            noteEmptyPass(on: page)
            return
        }

        for view in targets where !hidden.contains(where: { $0.view === view }) {
            hidden.append(Hidden(view: view))
        }
        for view in targets where !view.isHidden {
            view.isHidden = true
        }

        guard !didReport else { return }
        didReport = true
        let described = targets.map { view -> String in
            let frame = view.convert(view.bounds, to: page)
            let size = "\(Int(frame.width.rounded()))x\(Int(frame.height.rounded()))"
            let identifier = view.accessibilityIdentifier ?? "-"
            return "\(NSStringFromClass(type(of: view)))@\(size) id=\(identifier)"
        }
        // ⚠️ 不要在这条字符串的插值里写引号：`swift_member_check.py` 的去字符串扫描器会提前收尾。
        let joined = described.joined(separator: " | ")
        writeDebugLog(
            "[PageRepaint] hid \(targets.count) chrome row(s) the AM look does not have"
                + " (playlist pills): \(joined)"
        )
    }

    /// 关开关 / 换页 / 离开实体页时原样写回。
    static func restore() {
        for record in hidden {
            record.view?.isHidden = record.wasHidden
        }
        hidden.removeAll()
        emptyPage = nil
        emptyPasses = 0
        didReportEmpty = false
    }

    /// 把三路候选折成要藏的视图：类名命中的那一排、id 命中的、以及文字命中的共同祖先。
    ///
    /// 文字那条必须收**它们共同的那一行**（一颗颗藏会在原处留四个洞）；
    /// 只认得其中两颗时也收共同那一层（9.2.2 的「编辑 / 姓名和详情 / 排序」三颗没有 id，
    /// 文字也不在 `UILabel` / `accessibilityLabel` 上）。
    private static func resolvedTargets(marked: [UIView], labelled: [UIView], rows: [UIView]) -> [UIView] {
        var targets = rows
        targets.append(contentsOf: marked)
        if labelled.count >= 2, let row = commonAncestor(of: labelled) {
            targets.append(row)
        }
        if marked.count >= 2, let row = commonAncestor(of: marked) {
            targets.append(row)
        }
        return targets
    }

    // MARK: - 扫描

    /// 深度优先收候选。类名 / id 命中就**不再进它的子树**（那一行已经到手）；
    /// 文字命中同理（命中的是按钮 / 标签本身，行要从它的祖先里找）。
    private static func collect(
        in root: UIView,
        limit: Int,
        marked: inout [UIView],
        labelled: inout [UIView],
        rows: inout [UIView]
    ) {
        var stack: [UIView] = [root]
        var visited = 0
        while let view = stack.popLast(), visited < limit {
            visited += 1
            if isRowChrome(view) {
                rows.append(view)
                if rows.count >= 2 { return }
                continue
            }
            if isMarked(view) {
                marked.append(view)
                if marked.count >= 4 { return }
                continue
            }
            if view.bounds.height > 1, view.bounds.height <= 80,
               let text = ownText(of: view), textMarkers.contains(text) {
                labelled.append(view)
                if labelled.count >= 6 { return }
                continue
            }
            stack.append(contentsOf: view.subviews.reversed())
        }
    }

    // MARK: - 判据

    /// 那排 pill 的容器类名。
    ///
    /// 9.2.2 上中间三颗既没有 id、文字也读不到，只有这一条能整排收掉 ——
    /// 而且它和 `Toolbar_Core` 那批搜索 / 资料库的 chip 不是同一个类。
    private static let rowClassNameMarker = "ToolbarChipCollectionView"

    /// 类名命中那排 pill 的容器。只认高度像"一排"的：同名的外层容器也可能出现。
    private static func isRowChrome(_ view: UIView) -> Bool {
        let className = NSStringFromClass(type(of: view))
        guard className.contains(rowClassNameMarker) else { return false }
        return view.bounds.height > 1 && view.bounds.height <= 200
    }

    private static func isMarked(_ view: UIView) -> Bool {
        let identifier = view.accessibilityIdentifier ?? ""
        guard identifierMarkers.contains(where: { identifier.contains($0) }) else { return false }
        // 只收"一排"那么高的东西：真机里那排是 44~64pt；id 若落在页头容器上就别动。
        return view.bounds.height > 1 && view.bounds.height <= 200
    }

    /// 只取**控件自己**那一段文字（不进子树）—— 进子树会把整行/整页的文字都带回来。
    ///
    /// 不限定 `UIControl`：Encore 的 pill 有的只是带 `accessibilityLabel` 的普通视图 /
    /// `UILabel`，按 `UIControl` 收会一颗都命不中（那排 pill 露着的一条来路）。
    private static func ownText(of view: UIView) -> String? {
        var raw = view.accessibilityLabel ?? ""
        if raw.isEmpty, let button = view as? UIButton {
            raw = button.title(for: .normal) ?? button.title(for: .selected) ?? ""
        }
        if raw.isEmpty, let label = view as? UILabel {
            raw = label.text ?? ""
        }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return text.isEmpty ? nil : text
    }

    /// 几颗控件**共同**的那一层（往上找，要求它装得下全部、而且自己也不高）。
    private static func commonAncestor(of views: [UIView]) -> UIView? {
        guard let first = views.first else { return nil }
        var node: UIView? = first.superview
        var depth = 0
        while let current = node, depth < 8 {
            let holdsAll = views.allSatisfy { $0 === current || $0.isDescendant(of: current) }
            if holdsAll, current.bounds.height > 1, current.bounds.height <= 200 {
                return current
            }
            node = current.superview
            depth += 1
        }
        return nil
    }

    // MARK: - 空扫诊断

    /// 连续 5 拍（≈3s）都没找到 —— 报一次候选，下一次日志能直接指认。
    ///
    /// 只在**真的空扫**时多走两趟有界 DFS，正常页面（找到就 return）一个字节都不多花。
    private static func noteEmptyPass(on page: UIView) {
        if emptyPage !== page {
            emptyPage = page
            emptyPasses = 0
            didReportEmpty = false
        }
        guard !didReportEmpty else { return }
        emptyPasses += 1
        guard emptyPasses >= 5 else { return }
        didReportEmpty = true

        let ids = sampleIdentifiers(in: page, fragments: ["Curation", "Toolbar"], limit: 6)
        let texts = sampleShortTexts(in: page, limit: 8)
        // 专辑页**本来就没有**这排 pill：两样候选都空就什么都不报，别把日志刷成噪音。
        let hasMarker = !ids.isEmpty || texts.contains(where: { textMarkers.contains($0) })
        guard hasMarker else { return }
        writeDebugLog(
            "[PageRepaint] no curation row after \(emptyPasses) pass(es) —"
                + " ids=[\(ids.joined(separator: ", "))]"
                + " short texts=[\(texts.joined(separator: ", "))]"
        )
    }

    private static func sampleIdentifiers(in root: UIView, fragments: [String], limit: Int) -> [String] {
        var stack: [UIView] = [root]
        var visited = 0
        var found: [String] = []
        while let view = stack.popLast(), visited < maxNodes, found.count < limit {
            visited += 1
            let identifier = view.accessibilityIdentifier ?? ""
            if !identifier.isEmpty, fragments.contains(where: { identifier.contains($0) }) {
                found.append(identifier)
            }
            stack.append(contentsOf: view.subviews.reversed())
        }
        return found
    }

    private static func sampleShortTexts(in root: UIView, limit: Int) -> [String] {
        var stack: [UIView] = [root]
        var visited = 0
        var found: [String] = []
        while let view = stack.popLast(), visited < maxNodes, found.count < limit {
            visited += 1
            if let text = ownText(of: view), text.count <= 12, !found.contains(text) {
                found.append(text)
            }
            stack.append(contentsOf: view.subviews.reversed())
        }
        return found
    }
}
