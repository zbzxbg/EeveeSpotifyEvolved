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
/// · 每拍有界（≤ 900 节点 / 命中 4 个就停），页面上没有这排时**什么都不做**；
/// · ⚠️ 藏的是**视图**，不是列表里的行高 ⇒ 若 Spotify 把这一排算进页头高度，藏完会留一条空档。
///
/// 「喜欢的歌曲」那排 tags chips **不再动**：旧判据 `Toolbar_Core.ToolbarChip*` 属于搜索 / 资料库的工具条，不是它；后来加的形状兜底（≥4 颗、自己那段文字 ≤6 字的 `UIControl`）在真机上也没命中过。与其继续猜类名，那半边判据已删干净 —— 本文件现在**只管歌单页那排 pill**。
enum EntityPageCurationHide {

    /// 那排 pill 的模块前缀。
    private static let identifierMarkers = [
        "PlaylistCuration",
    ]

    /// 文字兜底：那一排四颗的字面（**整串相等**，见文件头）。
    private static let textMarkers: Set<String> = [
        "添加", "编辑", "排序", "姓名和详情",
        "add", "edit", "sort", "name & details", "name and details",
        "追加", "編集", "並び替え", "名前と詳細",
    ]

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

    // MARK: - 入口
    //
    // 每拍调一次。只在专辑 / 歌单页上由 `EntityPageAppearance.tick` 调用。
    static func apply(to page: UIView) {
        guard page.window != nil else { return }

        var marked: [UIView] = []
        var labelled: [UIView] = []

        var queue: [UIView] = [page]
        var visited = 0
        while !queue.isEmpty, visited < 900, marked.count < 4 {
            let view = queue.removeFirst()
            visited += 1

            if isMarked(view) {
                marked.append(view)
                continue
            }
            if let control = view as? UIControl, let text = ownText(of: control),
               textMarkers.contains(text) {
                labelled.append(control)
                continue
            }
            queue.append(contentsOf: view.subviews)
        }

        // 文字那条：四颗按钮要收**它们共同的那一行**（一颗颗藏会在原处留四个洞）。
        var targets = marked
        if labelled.count >= 2, let row = commonAncestor(of: labelled) {
            targets.append(row)
        }
        guard !targets.isEmpty else { return }

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
    }

    // MARK: - 判据

    private static func isMarked(_ view: UIView) -> Bool {
        let identifier = view.accessibilityIdentifier ?? ""
        guard identifierMarkers.contains(where: { identifier.contains($0) }) else { return false }
        // 只收"一排"那么高的东西：真机里那排是 44~64pt；id 若落在页头容器上就别动。
        return view.bounds.height > 1 && view.bounds.height <= 200
    }

    /// 只取**控件自己**那一段文字（不进子树）—— 进子树会把整行/整页的文字都带回来。
    private static func ownText(of view: UIView) -> String? {
        var raw = view.accessibilityLabel ?? ""
        if let button = view as? UIButton {
            let title = button.title(for: .normal) ?? button.title(for: .selected) ?? ""
            if raw.isEmpty { raw = title }
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
}
