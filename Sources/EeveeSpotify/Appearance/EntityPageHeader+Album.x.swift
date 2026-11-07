import Foundation
import Orion
import UIKit
import ObjectiveC.runtime

extension EntityPageHeaderManager {
    /// 专辑页那条路（`applyToAlbumPage`）：头容器、封面、三个文字容器，以及"kind·日期那行晚到"
    /// 的重试计数。**全部走缓存** —— 这一拍同样是每帧级的。
    static var cachedAlbumHeader: UIView?
    static var cachedAlbumCover: UIView?
    static var cachedAlbumTitleRow: UIView?
    static var cachedAlbumParentRow: UIView?
    static var cachedAlbumMetadata: UIView?
    static var albumRetryKey: UInt8 = 0

    /// `concealAlbumChrome` 的判据是"绕开封面那一支"，但它靠每一拍现找 `cover`。首次进入时封面
    /// 往往**比页头晚一拍**才建出来 ⇒ 那一拍 `cover == nil`，装着"封面 + 标题"的 `ElementView` 被整支
    /// `eeveeConceal` 掉；封面随后出现在这个**已经 hidden 的分支**里时，后面的每拍只递归、不整支藏，
    /// **不会把分支放回来** ⇒ 封面永远不显示。
    ///
    /// 这里把"整支藏掉"的原值记下来；一旦未来某一拍 `cover` 落在某个记录过的分支里，就原样还回去，
    /// 再走正常的递归。
    private final class AlbumConcealedBranch {
        weak var view: UIView?
        private let layerHidden: Bool
        private let mask: CALayer?
        private let interactive: Bool
        private let accessibilityHidden: Bool

        init(_ view: UIView) {
            self.view = view
            layerHidden = view.layer.isHidden
            mask = view.layer.mask
            interactive = view.isUserInteractionEnabled
            accessibilityHidden = view.accessibilityElementsHidden
        }

        func restore() {
            guard let view else { return }
            if view.layer.isHidden != layerHidden { view.layer.isHidden = layerHidden }
            if view.layer.mask !== mask { view.layer.mask = mask }
            if view.isUserInteractionEnabled != interactive { view.isUserInteractionEnabled = interactive }
            if view.accessibilityElementsHidden != accessibilityHidden {
                view.accessibilityElementsHidden = accessibilityHidden
            }
        }
    }

    static var albumConcealedBranches: [AlbumConcealedBranch] = []
    static let albumConcealedBranchLimit = 8
    /// "封面还没建出来就先藏了头"只报一次。
    static var didLogAlbumBlindConceal = false
    /// 封面晚到时重跑 `applyToAlbumPage` 的计数（按页面记账）。
    ///
    /// 只靠 `layoutSubviews` 不保险 —— 页头建完之后可能不再有布局回合，封面到了也没人把
    /// "被整支藏掉的分支"放回来。这里最多补 8 次（≈1.6s）。
    static var albumCoverRetryKey: UInt8 = 0

    // MARK: - 专辑页（**另一条路**）
    //
    // 专辑页那一拍。**与歌单页不是同一条路** —— 两边的头结构不同：
    //
    // ```
    // 歌单页（PL.Header）            封面 + **一个** block：标题 / 描述 / 创建者 / 长度 / 操作行
    // 专辑页（CreativeWorkHeader）   顶部 group（封面 + 标题 + 艺人）+ 底部 group（kind·日期 + 操作行）
    // ```
    //
    // ⇒ 歌单页那个 `blockIn`（按宽度挑一块）在专辑页会挑到**底部 group**（那里没有标题），
    // 所以这里**不挑块**：文字按**明确的 id** 读（`TitleRow` / `ParentRow` / `MetadataRow`），
    // 我们那一份铺在**整个头**上（`setFrame(info, header.bounds)`）。
    //
    // 挂点是 `CreativeWorkTemplateView.layoutSubviews`。
    static func applyToAlbumPage(_ page: UIView) {
        guard isEnabled, !applying else { return }
        guard page.bounds.width > 120, page.bounds.height > 200 else { return }
        guard let header = find(
            "CreativeWorkPlatform.Components.UI.CreativeWorkHeader",
            in: page,
            cache: &cachedAlbumHeader
        ), header.bounds.height > 40 else { return }

        applying = true
        defer { applying = false }

        let texts = albumTexts(in: header)
        guard !texts.title.isEmpty else {
            logOnce("noTitleAlbum", "album page: no title found — leaving Spotify's header alone")
            return
        }

        let cover = find(
            "CreativeWorkPlatform.Components.UI.ArtWorkElement.WithCoverArt",
            in: header,
            cache: &cachedAlbumCover
        )
        // 封面到了 ⇒ 把"当时因为它还没建出来而被整支藏掉"的分支放回来
        // （先于下面的 `concealAlbumChrome`，那一趟会递归进这一支、只藏非封面的兄弟）。
        if let cover {
            revealAlbumBranches(containing: cover)
            objc_setAssociatedObject(page, &albumCoverRetryKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        } else {
            // 封面还没建出来：这一拍先藏了头，之后可能没有布局回合再叫我们 ⇒ 补几拍。
            scheduleAlbumCoverRetry(page)
        }

        let headerView: EntityPageHeaderView
        if let existing = objc_getAssociatedObject(header, &entityPageHeaderKey) as? EntityPageHeaderView {
            headerView = existing
        } else {
            headerView = EntityPageHeaderView()
            objc_setAssociatedObject(header, &entityPageHeaderKey, headerView, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        if headerView.superview !== header {
            header.addSubview(headerView)
        } else if header.subviews.last !== headerView {
            header.bringSubviewToFront(headerView)
        }
        currentHeader = headerView
        // 专辑页的标题小一档：34pt 的长标题会折成两行大字（AM 的专辑页也不是那个尺寸）。
        headerView.titleSize = .compact
        if cover == nil, !didLogAlbumBlindConceal {
            didLogAlbumBlindConceal = true
            writeDebugLog(
                "[EntityPageHeader] album: the cover element is not built yet — concealing the"
                    + " header now; the branch that later holds it will be restored when it arrives"
            )
        }
        concealAlbumChrome(in: header, avoiding: cover, skipping: headerView)

        // 高度再加上"给封面让出来的那一段"（见 `coverDrop`）。
        let albumFrame = CGRect(
            x: 0,
            y: 0,
            width: header.bounds.width,
            height: header.bounds.height + coverDrop(of: headerView)
        )
        if headerView.frame != albumFrame { headerView.frame = albumFrame }

        // z 序与几何两道保险。
        raiseToTop(headerView, in: header, role: "album")
        probeCoverOverlap(cover: cover, headerView: headerView, root: header, anchored: false, role: "album")

        headerView.update(title: texts.title, creator: texts.creator, length: texts.length, about: "")

        // Play 与 Shuffle 在**页面上**（浮在右上角，不在头里）：只搜页面的直接子视图、且宽度 ≤120
        // 的那些（头 / wash / 列表都是整页宽，走进去等于每拍走整棵树）。
        let play = findFloating("header-play-button", in: page, cache: &cachedPlay)
        let shuffle = findFloating("Components.UI.ShuffleButton", in: page, cache: &cachedShuffle)
        let add = findControl("Components.UI.AddToButton", in: header, cache: &cachedTrailing)
        // download 也要先钻到真正的 `UIControl`（同上面歌单页那三颗）。
        let download = add == nil
            ? eeveeFindView(header, identifier: "DownloadButton.Granular*").map { firstControl(in: $0) ?? $0 }
            : nil
        headerView.updateRow(
            shuffle: shuffle,
            play: play,
            trailing: add ?? download,
            trailingFallback: add != nil ? plusGlyph : downloadGlyph
        )
        // 长按播放键 = 随机播放（见 `EntityPageHeaderPlay.feedLongPress`）。
        headerView.updatePlayLongPress(shuffle)
        // 专辑页的"创建者"就是艺人，点它开艺人页。
        headerView.updateCreatorLink(
            find("CreativeWorkPlatform.Components.UI.ParentRow", in: header, cache: &cachedAlbumParentRow)
        )

        // 三颗**都藏"包着它的最外层等尺寸视图"**（`wrapperFor`）—— 见那个函数的说明。
        // shuffle 也要藏：我们那一行里本来就有它，Spotify 原生那颗与我们的叠在同一格。
        // trailing 的源与字形一并进日志，能分辨是"取错了源"还是"取错了字形"。
        eeveeConceal(wrapperFor(play, in: page))
        eeveeConceal(wrapperFor(shuffle, in: page))
        eeveeConceal(wrapperFor(add, in: header))
        eeveeConceal(wrapperFor(download, in: header))

        // 把 `⋯` 钉到右上角去（照 AM）。
        pinMoreButton(in: header)
        logOnce(
            "trailingSource",
            "trailing ← \(add != nil ? "AddToButton" : (download != nil ? "DownloadButton" : "nothing"))"
                + " (id \(add?.accessibilityIdentifier ?? download?.accessibilityIdentifier ?? "-"))"
                + ", glyph \(eeveeGlyph(of: add ?? download) == nil ? "none" : "taken"),"
                + " shuffle \(shuffle == nil ? "missing" : "found")"
        )

        // 那行 kind·日期是 collection view 的 **cell**，晚一拍才建出来（最多等 6 次、每次 0.25s）。
        if texts.length.isEmpty {
            let tries = (objc_getAssociatedObject(header, &albumRetryKey) as? NSNumber)?.intValue ?? 0
            if tries < 6 {
                objc_setAssociatedObject(
                    header,
                    &albumRetryKey,
                    NSNumber(value: tries + 1),
                    .OBJC_ASSOCIATION_RETAIN_NONATOMIC
                )
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak page] in
                    guard let page else { return }
                    applyToAlbumPage(page)
                }
            }
        }

        logOnce(
            "appliedAlbum",
            "album page — title \"\(texts.title)\", artist \"\(texts.creator.isEmpty ? "-" : texts.creator)\""
                + ", kind \"\(texts.length.isEmpty ? "-" : texts.length)\""
                + ", shuffle \(shuffle == nil ? "missing" : "ok")"
                + ", play \(play == nil ? "missing" : "ok")"
                + ", trailing \(add != nil ? "add" : (download != nil ? "download" : "none"))"
        )
    }

    /// 是不是**我们自己**插进 Spotify 视图树里的东西 —— 统一靠 id 前缀 `eevee-` 认。
    ///
    /// 藏"头里除我们那份以外的一切"时**必须跳过这些**。按具体 id 逐个跳不行：后加的
    /// `eevee-pinned-more`（右上角那颗 ⋯）就会被顺手藏掉，切到专辑页/艺人页时永远是 `hidden`
    /// —— 那两条路每拍都在藏"头里除了页头以外的一切"。
    ///
    /// 判据用前缀之后，以后再往 Spotify 的树里插自己的视图，不用回来补这一行。
    static func isOurs(_ view: UIView) -> Bool {
        (view.accessibilityIdentifier ?? "").hasPrefix("eevee-")
    }

    /// 藏掉专辑页头里 Spotify 自己画的东西，**绕开封面那一支**。
    ///
    /// ⚠️ 为什么不能像歌单页那样整支藏（`for sub in block.subviews { eeveeConceal(sub) }`）：
    /// 专辑页的封面与标题**在同一支**里（顶部 group 装着"封面方块 + 标题块"），而封面归
    /// `EntityPageAppearance.concealNativeCover` 管 —— **那边记了原值**。`eeveeConceal` 不记原值，
    /// 这边再藏一次就会把"已经藏了"写进对面的原值记录 ⇒ 关掉开关封面再也回不来。
    ///
    /// 规则：**含封面的一支只递归、不整支藏**；封面自己跳过；其余整支藏掉。
    static func concealAlbumChrome(in root: UIView, avoiding cover: UIView?, skipping ours: UIView) {
        for sub in root.subviews {
            if sub === ours { continue }
            // **我们自己插的一律跳过**（见 `isOurs`）—— 否则 `eevee-pinned-more` 会被顺手藏掉。
            if isOurs(sub) { continue }
            if let cover {
                if sub === cover { continue }
                if cover.isDescendant(of: sub) {
                    concealAlbumChrome(in: sub, avoiding: cover, skipping: ours)
                    continue
                }
            }
            concealAlbumBranch(sub)
        }
    }

    /// 整支藏掉一个顶层分支，并**记下原值**（`eeveeConceal` 自己不记账）。
    static func concealAlbumBranch(_ view: UIView) {
        pruneAlbumConcealedBranches()
        if !albumConcealedBranches.contains(where: { $0.view === view }),
           albumConcealedBranches.count < albumConcealedBranchLimit {
            albumConcealedBranches.append(AlbumConcealedBranch(view))
        }
        eeveeConceal(view)
    }

    static func pruneAlbumConcealedBranches() {
        albumConcealedBranches.removeAll { record in
            guard let view = record.view, view.window != nil else { return true }
            return false
        }
    }

    /// 封面到了之后：把"当时因为找不到封面而被整支藏掉"的分支原样放回来。
    ///
    /// 只有**确实包含封面**的那一支会被还原；不包含封面的分支继续留着藏（那是设计）。
    static func revealAlbumBranches(containing cover: UIView) {
        guard !albumConcealedBranches.isEmpty else { return }
        var kept: [AlbumConcealedBranch] = []
        var restored = 0
        for record in albumConcealedBranches {
            guard let view = record.view, view.window != nil else { continue }
            if cover.isDescendant(of: view) {
                record.restore()
                restored += 1
            } else {
                kept.append(record)
            }
        }
        albumConcealedBranches = kept
        guard restored > 0 else { return }
        writeDebugLog(
            "[EntityPageHeader] album: the cover arrived inside a branch that was concealed"
                + " while it was missing — restored \(restored) branch(es)"
        )
    }

    /// 封面还没建出来时补几拍 `applyToAlbumPage`，好让 `revealAlbumBranches` 有机会跑。
    static func scheduleAlbumCoverRetry(_ page: UIView) {
        let tries = (objc_getAssociatedObject(page, &albumCoverRetryKey) as? NSNumber)?.intValue ?? 0
        guard tries < 8 else { return }
        objc_setAssociatedObject(
            page,
            &albumCoverRetryKey,
            NSNumber(value: tries + 1),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak page] in
            guard let page, page.window != nil else { return }
            applyToAlbumPage(page)
        }
    }

    /// 离开专辑页 / 关开关：把记录过的分支全部写回。`concealAlbumChrome` 本身不做还原。
    static func restoreAlbumWashBranches(reason: String) {        guard !albumConcealedBranches.isEmpty else { return }
        let count = albumConcealedBranches.count
        for record in albumConcealedBranches { record.restore() }
        albumConcealedBranches.removeAll()
        writeDebugLog(
            "[EntityPageHeader] album: restored \(count) concealed header branch(es) (\(reason))"
        )
    }

    /// 专辑页的文字：**按明确的 id 读**（`TitleRow` / `ParentRow` / `MetadataRow`）。
    static func albumTexts(in header: UIView) -> HeaderTexts {
        var texts = HeaderTexts()

        if let title = find("CreativeWorkPlatform.Components.UI.TitleRow", in: header, cache: &cachedAlbumTitleRow),
           let label = firstLabel(in: title, skipping: nil) {
            texts.title = label.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        if let parent = find("CreativeWorkPlatform.Components.UI.ParentRow", in: header, cache: &cachedAlbumParentRow) {
            if let label = firstLabel(in: parent, skipping: nil) {
                texts.creator = label.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            } else {
                texts.creator = parent.accessibilityLabel ?? ""
            }
        }
        if let metadata = find("Components.UI.MetadataRow", in: header, cache: &cachedAlbumMetadata) {
            texts.length = metadataLine(metadata)
        }

        // 标题兜底：id 没找到时退回"字号最大的那个标签"（与歌单页同一条兜底）。
        if texts.title.isEmpty, let label = biggestLabel(in: header, skipping: []) {
            texts.title = label.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        return texts
    }

    /// 专辑页那行是**两格**（kind 与日期各是一个 cell、各一个 label）。
    /// 按**画出来的顺序**（x 从小到大）读，空格连接。
    static func metadataLine(_ root: UIView) -> String {
        var parts: [(x: CGFloat, text: String)] = []
        forEachView(root) { view in
            guard let label = view as? UILabel, label.window != nil else { return }
            let text = (label.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            parts.append((label.convert(.zero, to: root).x, text))
        }
        parts.sort { $0.x < $1.x }
        return parts.map(\.text).joined(separator: " ")
    }

}
