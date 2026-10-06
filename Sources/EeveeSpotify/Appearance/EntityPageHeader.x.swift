import Foundation
import Orion
import UIKit
import ObjectiveC.runtime

/// 页头替换：找到歌单页头、把 Spotify 那一列藏掉、把我们自己的（`EntityPageHeaderView`）摆上去。
///
/// ## 为什么挂 `HeaderContentLayout`
///
/// 它是那一块的**布局视图**（真机日志：`22.HeaderContentLayout@0,0,414,485`；符号表
/// `dump-9.1.88.txt:7799` 也在），**每一拍折叠/展开都会走它的 `layoutSubviews`** ——
/// 一个挂点就能覆盖"首次出现 / 滚动折叠 / 内容晚到"三种时机。
///
/// pw 还挂了一个 `SPTFreeTierPlaylistEncoreHeaderViewController`（它的 `viewDidLayoutSubviews`
/// 与 `update`）——**那个类在 9.1.88 上已经不存在**（歌单头改由 `ListUXPlatform_FreeTierPlaylistImpl`
/// 的 slot/element 类拼出来），所以这里不用它：主挂点已经够，计数器晚到那种情况由
/// "每一拍都重读一遍文本"覆盖。
///
/// ## 作用域（v1 故意收窄）
///
/// **只作用于歌单页**：`headerRoot` 必须是 `PL.Header`（那个 id 只在歌单页出现，
/// 真机日志 `15.UIView@…,id=PL.Header`）。专辑页用的是同一个 `HeaderContentLayout`，
/// 但它的头部结构、控件 id 与歌单不同 ⇒ **v1 一律不碰**（少一个变量，先让歌单页验完）。
///
/// ## 安全阀
///
/// 认不出标题就整块不动（`apply` 早退，一个视图都不藏）。所以任何一环失配 = "没生效"，
/// 而不是"歌单页坏了"。结果会在调试日志里留一行。
enum EntityPageHeaderManager {

    static var isEnabled: Bool { UserDefaults.entityPageAMHeader }

    private static var headerKey: UInt8 = 0
    private static var applying = false
    private static var logged = Set<String>()

    // MARK: - 入口

    /// 从 `HeaderContentLayout` 的 `layoutSubviews` 调用。
    static func apply(in layout: UIView) {
        guard isEnabled, !applying else { return }
        guard layout.bounds.width > 120, layout.bounds.height > 40 else { return }
        // 只认歌单页（专辑页 v1 不碰）。
        guard let headerRoot = playlistHeaderRoot(of: layout) else { return }

        applying = true
        defer { applying = false }

        let fullbleedClass = NSClassFromString("_TtC28EncoreConsumerMobile_BaseKit26HeaderFullbleedCentralView")
        let fullbleed = layout.subviews.first { view in
            guard let fullbleedClass else { return false }
            return view.isKind(of: fullbleedClass)
        }

        let cover = eeveeFindView(layout, identifier: "Components.Header.UI.ArtworkImage") ?? fullbleed
        guard let block = blockIn(layout, cover: cover, fullbleed: fullbleed) else { return }
        guard block.bounds.height > 20 else { return }

        let texts = headerTexts(block: block, headerRoot: headerRoot)
        guard !texts.title.isEmpty else {
            logOnce("noTitle", "no title found — leaving Spotify's header alone")
            return
        }

        // 我们那一份：挂在 **headerRoot** 上（block 万一被换掉，同一份跟着搬过去，不会画两份）。
        let header: EntityPageHeaderView
        if let existing = objc_getAssociatedObject(headerRoot, &headerKey) as? EntityPageHeaderView {
            header = existing
        } else {
            header = EntityPageHeaderView()
            objc_setAssociatedObject(headerRoot, &headerKey, header, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }

        if header.superview !== block {
            block.addSubview(header)
        } else if block.subviews.last !== header {
            block.bringSubviewToFront(header)
        }

        // 位置：**页面宽度、居中** —— Spotify 的 block 比页面窄（真机 386 / 402）。
        let x = -block.convert(.zero, to: headerRoot).x
        let frame = CGRect(x: round(x), y: 0, width: headerRoot.bounds.width, height: block.bounds.height)
        if header.frame != frame { header.frame = frame }

        // Spotify 那一列整列藏掉（我们自己的那份除外）。幂等；Spotify 边加载边往里加东西，
        // 所以**每一拍都要重新走一遍**。
        for sub in block.subviews where sub !== header { eeveeConceal(sub) }

        header.update(title: texts.title, creator: texts.creator, length: texts.length, about: texts.about)

        let shuffle = eeveeFindView(block, identifier: "Components.UI.ShuffleButton")
        let play = eeveeFindView(headerRoot, identifier: "header-play-button")
        let save = eeveeFindView(block, identifier: "Components.UI.AddToButton")
        let download = save == nil ? eeveeFindView(block, identifier: "DownloadButton.Granular*") : nil
        header.updateRow(
            shuffle: shuffle,
            play: play,
            trailing: save ?? download,
            trailingFallback: UIImage(systemName: save != nil ? "plus" : "arrow.down")
        )
        header.updateCreatorLink(eeveeFindView(block, identifier: "Components.PlaylistHeader.collaboratorsButton"))

        // Play 在页头的**前景区**，不在 block 里 ⇒ 单独藏一次（它自己那一拍也会再补，见下面的 hook）。
        eeveeConceal(play)

        logOnce(
            "applied",
            "applied — title \"\(texts.title)\", creator \"\(texts.creator.isEmpty ? "-" : texts.creator)\""
                + ", length \"\(texts.length.isEmpty ? "-" : texts.length)\""
                + ", shuffle \(shuffle == nil ? "missing" : "ok")"
                + ", play \(play == nil ? "missing" : "ok")"
                + ", trailing \(save != nil ? "save" : (download != nil ? "download" : "none"))"
        )
    }

    /// `PlayButtonView` 自己的那一拍：页面刚打开时它会**晚一步**进前景区（pw 也遇到：角上先闪一下
    /// Spotify 自己的绿盘）。只有它确实在歌单页头里才藏 —— 专辑页那种浮动 Play 不碰。
    static func concealPlayButtonIfNeeded(_ view: UIView) {
        guard isEnabled else { return }
        guard view.accessibilityIdentifier == "header-play-button" else { return }
        guard playlistHeaderRoot(of: view) != nil else { return }
        eeveeConceal(view)
    }

    // MARK: - 找页面 / 找那一块

    /// 往上找 `PL.Header`（歌单页头那个容器）。找不到就返回 nil ——
    /// **专辑页与别的页面因此完全不受影响**。
    private static func playlistHeaderRoot(of view: UIView) -> UIView? {
        var node: UIView? = view
        while let current = node {
            if current.accessibilityIdentifier == "PL.Header" { return current }
            node = current.superview
        }
        return nil
    }

    /// 那一块"文字 + 控件"：`HeaderContentLayout` 里**宽度接近整页**的那个孩子
    /// （封面方形与满幅图都排除掉）。
    ///
    /// 按宽度取而不是"取最靠下的"：Liked Songs 的 layout 里还有一个 45pt 的图标槽位，
    /// 加载途中它会落在 block 下面，按"最靠下"会把它当成 block（pw 在真机上因此把页头画了两遍）。
    private static func blockIn(_ layout: UIView, cover: UIView?, fullbleed: UIView?) -> UIView? {
        let wide = layout.bounds.width * 0.6
        var block: UIView?
        for sub in layout.subviews {
            if sub === cover || sub === fullbleed { continue }
            if sub is EntityPageHeaderView { continue }
            if sub.bounds.width < wide { continue }
            if block == nil || sub.frame.minY > block!.frame.minY { block = sub }
        }
        return block
    }

    // MARK: - 读文字

    private struct HeaderTexts {
        var title = ""
        var creator = ""
        var length = ""
        var about = ""
    }

    /// 文本来源**分两级**（pw 的分法）：标题/描述优先读页面的 view model，创建者与长度读
    /// Spotify 自己那些**被藏起来的标签**（所以语言永远跟着 Spotify 走）。
    ///
    /// ⚠️ 9.1.88 上 model 那条路的存在性**没证实**（`dump-9.1.88.txt` 里没有
    /// `defaultHeaderViewModel` / `playlistName` 这两个名字）⇒ 一律 `responds(to:)` 守卫，
    /// 拿不到就退回标签启发式。**标签兜底才是这里的主路径**。
    private static func headerTexts(block: UIView, headerRoot: UIView) -> HeaderTexts {
        var texts = HeaderTexts()
        let model = viewModel(from: headerRoot)
        if let model {
            texts.title = modelString(model, "playlistName") ?? ""
            texts.about = plainText(modelString(model, "playlistDescription")) ?? ""
        }

        // 长度：Spotify 自己那行（`Components.Header.UI.Metadata*`）。
        if let metadata = eeveeFindView(block, identifier: "Components.Header.UI.Metadata*") {
            texts.length = firstLabelText(in: metadata, skipping: nil) ?? ""
        }

        // 创建者：脸堆（FacepileView）那一行里、除了脸堆以外的第一个非空标签。
        var facepile: UIView?
        forEachView(block) { view in
            if facepile == nil, NSStringFromClass(type(of: view)).contains("FacepileView") { facepile = view }
        }
        if let facepile {
            var row: UIView? = facepile.superview
            var level = 0
            while let current = row, current !== block, level < 3 {
                if let name = firstLabelText(in: current, skipping: facepile) {
                    texts.creator = name
                    break
                }
                row = current.superview
                level += 1
            }
        }

        // 标题兜底：block 里**字号最大**的那个标签（页头里最大的字就是标题），
        // 同字号取最靠上的。排除长度那行与创建者那行。
        if texts.title.isEmpty {
            texts.title = biggestLabelText(in: block, skipping: [facepile, metadataView(block)]) ?? ""
        }

        // 描述兜底：只剩**一个**没被认领的标签、而且它够长时才用它（宁可没有，不要贴错）。
        if texts.about.isEmpty {
            let leftovers = unclaimedLabels(in: block, facepile: facepile, metadata: metadataView(block))
            if leftovers.count == 1, let only = leftovers.first,
               let text = only.text?.trimmingCharacters(in: .whitespacesAndNewlines), text.count > 12 {
                texts.about = text
            }
        }

        return texts
    }

    private static func metadataView(_ block: UIView) -> UIView? {
        eeveeFindView(block, identifier: "Components.Header.UI.Metadata*")
    }

    /// 字号最大的那个标签的文本。
    private static func biggestLabelText(in root: UIView, skipping skip: [UIView?]) -> String? {
        var best: (size: CGFloat, y: CGFloat, text: String)?
        forEachView(root) { view in
            guard let label = view as? UILabel else { return }
            for skipped in skip.compactMap({ $0 }) where view.isDescendant(of: skipped) { return }
            let text = (label.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            let size = label.font.pointSize
            let y = label.convert(.zero, to: root).y
            if let current = best {
                if size > current.size || (size == current.size && y < current.y) {
                    best = (size, y, text)
                }
            } else {
                best = (size, y, text)
            }
        }
        return best?.text
    }

    /// block 里还没被认领的标签（标题/创建者/长度之外的那些）。
    private static func unclaimedLabels(in block: UIView, facepile: UIView?, metadata: UIView?) -> [UILabel] {
        var labels: [UILabel] = []
        let biggest = biggestLabelText(in: block, skipping: [facepile, metadata])
        var titleTaken = false
        forEachView(block) { view in
            guard let label = view as? UILabel else { return }
            if let facepile, view.isDescendant(of: facepile) { return }
            if let metadata, view.isDescendant(of: metadata) { return }
            let text = (label.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count > 1 else { return }
            if !titleTaken, text == biggest { titleTaken = true; return }
            labels.append(label)
        }
        return labels
    }

    private static func firstLabelText(in root: UIView, skipping skip: UIView?, longerThan minimum: Int = 1) -> String? {
        var found: String?
        forEachView(root) { view in
            guard found == nil, let label = view as? UILabel else { return }
            if let skip, view.isDescendant(of: skip) { return }
            let text = (label.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count > minimum { found = text }
        }
        return found
    }

    private static func forEachView(_ root: UIView, _ body: (UIView) -> Void) {
        var queue: [UIView] = [root]
        var visited = 0
        while !queue.isEmpty, visited < 1500 {
            let view = queue.removeFirst()
            visited += 1
            body(view)
            queue.append(contentsOf: view.subviews)
        }
    }

    /// HTML 描述（`<a>` 链接与 `&amp;` 之类的实体）→ 纯文本。
    private static func plainText(_ html: String?) -> String? {
        guard let html, !html.isEmpty else { return nil }
        var text = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&amp;": "&", "&quot;": "\"", "&#x27;": "'", "&#39;": "'",
                        "&lt;": "<", "&gt;": ">", "&nbsp;": " "]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - 读 view model（能找到就用，找不到算了）

    /// 沿 responder 链找页面的 view model：先问 `defaultHeaderViewModel` / `headerViewModel`，
    /// 再问 `headerController` 要一个。**每个 selector 都先 `responds(to:)`**。
    private static func viewModel(from view: UIView) -> AnyObject? {
        var responder: UIResponder? = view
        var guardCount = 0
        while let current = responder, guardCount < 40 {
            guardCount += 1
            if let object = current as? NSObject {
                for name in ["defaultHeaderViewModel", "headerViewModel"] {
                    if let value = performObject(object, name) { return value }
                }
                if let controller = performObject(object, "headerController") as? NSObject,
                   let value = performObject(controller, "defaultHeaderViewModel") {
                    return value
                }
            }
            responder = current.next
        }
        return nil
    }

    private static func performObject(_ object: NSObject, _ name: String) -> AnyObject? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector), let value = object.perform(selector) else { return nil }
        return value.takeUnretainedValue()
    }

    private static func modelString(_ model: AnyObject, _ name: String) -> String? {
        guard let object = model as? NSObject,
              let value = performObject(object, name) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func logOnce(_ key: String, _ message: String) {
        guard logged.insert(key).inserted else { return }
        writeDebugLog("[EntityPageHeader] \(message)")
    }
}

// MARK: - 挂点

struct EntityPageHeaderGroup: HookGroup {}

/// 主挂点：那一块的布局视图每一拍都会走这里。
final class EntityPageHeaderLayoutHook: ClassHook<UIView> {
    typealias Group = EntityPageHeaderGroup
    static let targetName = "_TtC28EncoreConsumerMobile_BaseKit19HeaderContentLayout"

    func layoutSubviews() {
        orig.layoutSubviews()
        EntityPageHeaderManager.apply(in: target)
    }
}

/// Spotify 自己那颗 Play：会在前景区晚一步出现，所以它自己那一拍也要补一次。
final class EntityPagePlayButtonHook: ClassHook<UIView> {
    typealias Group = EntityPageHeaderGroup
    static let targetName = "_TtC28EncoreConsumerMobile_BaseKit14PlayButtonView"

    func layoutSubviews() {
        orig.layoutSubviews()
        EntityPageHeaderManager.concealPlayButtonIfNeeded(target)
    }
}

func activateEntityPageHeader() {
    guard EntityPageHeaderManager.isEnabled else { return }

    let required = [
        EntityPageHeaderLayoutHook.targetName,
        EntityPagePlayButtonHook.targetName,
    ]
    let missing = required.filter { NSClassFromString($0) == nil }
    guard missing.isEmpty else {
        writeDebugLog("[EntityPageHeader] skipped — missing \(missing.joined(separator: ", "))")
        return
    }

    EntityPageHeaderGroup().activate()
    writeDebugLog("[EntityPageHeader] on (playlist pages only; album pages untouched in v1)")
}
