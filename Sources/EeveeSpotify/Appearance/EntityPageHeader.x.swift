import Foundation
import Orion
import UIKit
import ObjectiveC.runtime

/// 关联对象的键。**必须放在文件作用域**：`&变量` 取到的地址要稳定且唯一，
/// 这是本仓库既有的写法（见 `DeclutterChrome.x.swift` 的 `declutterHiddenByUsKey`）。
private var entityPageHeaderKey: UInt8 = 0

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

    private static var applying = false
    private static var logged = Set<String>()

    /// 每一拍的耗时（50 / 200 / 800 拍各报一次）。
    private static let meter = PerfMeter("EntityPageHeader")

    /// 页头每一拍要用的那几个视图**缓存下来**。
    ///
    /// ★ 2026-10-13（用户：「用较快的速度往下滑，会有渲染跟不上的问题」）：pw 的 `SGRFindByIdentifier`
    /// 带一个 `static char` key —— **命中一次之后每一拍只做一次"还在不在"的检查**，不再走子树。
    /// 我们原来是每拍 **5 次全树 BFS**（shuffle / play / save / download / 协作者）+ 3~4 次文本遍历，
    /// 而页头在快速滑动时**每一帧**都在折叠（`layoutSubviews` 每帧一次）⇒ 那些搜索全落在主线程上。
    private static var cachedShuffle: UIView?
    private static var cachedPlay: UIView?
    private static var cachedTrailing: UIView?
    private static var cachedCreatorLink: UIView?
    /// ★ 2026-10-13（性能）：封面元素与"那一块文字"也缓存 —— 这两次原来是**每帧**各一次整棵子树搜索
    /// （`eeveeFindView(layout, "Components.Header.UI.ArtworkImage")` / `blockIn(layout,…)`）。
    private static var cachedCover: UIView?
    private static var cachedBlock: UIView?
    /// ★ 2026-10-13（性能）：上一拍认下的那四个标签（见 `TextViews`）。
    private static var cachedTextViews: TextViews?
    /// 专辑页那条路（见 `applyToAlbumPage`）：头容器、封面、三个文字容器，以及"kind·日期那行晚到"
    /// 的重试计数。**全部走缓存** —— 这一拍同样是每帧级的（pw 也是在 `layoutSubviews` 里每拍找，
    /// 靠它的 `SGRFindByIdentifier` 不再重搜）。
    private static var cachedAlbumHeader: UIView?
    private static var cachedAlbumCover: UIView?
    private static var cachedAlbumTitleRow: UIView?
    private static var cachedAlbumParentRow: UIView?
    private static var cachedAlbumMetadata: UIView?
    private static var albumRetryKey: UInt8 = 0

    /// 尾部按钮的兜底字形：**做成常量**（原来每一拍都 `UIImage(systemName:)` 造一张新的，
    /// 而这一拍在折叠的每一帧都会走到 —— 与"字形只取一次"同一条纪律）。
    private static let plusGlyph = UIImage(systemName: "plus")
    private static let downloadGlyph = UIImage(systemName: "arrow.down")

    /// 先看缓存（**还要在原来那棵树里、还在窗口上**），没有再搜。
    private static func find(_ identifier: String, in root: UIView, cache: inout UIView?) -> UIView? {
        if let cached = cache, cached.window != nil, cached.isDescendant(of: root) { return cached }
        let found = eeveeFindView(root, identifier: identifier)
        cache = found
        return found
    }

    // MARK: - 入口

    /// 从 `HeaderContentLayout` 的 `layoutSubviews` 调用 —— **快速滑动时每一帧一次**，
    /// 所以整段用 `PerfMeter` 记着：50 / 200 / 800 拍各报一次"一次多少毫秒"，
    /// 下一份日志就能直接回答"是不是我们拖慢的"，而不是靠猜。
    static func apply(in layout: UIView) {
        meter.measure { applyOnce(in: layout) }
    }

    private static func applyOnce(in layout: UIView) {
        guard isEnabled, !applying else { return }
        guard layout.bounds.width > 120, layout.bounds.height > 40 else { return }
        // 歌单页那条路（专辑页是**另一条路**：`applyToAlbumPage`，挂点也不同 —— 见它的说明）。
        guard let headerRoot = playlistHeaderRoot(of: layout) else { return }

        applying = true
        defer { applying = false }

        let fullbleedClass = NSClassFromString("_TtC28EncoreConsumerMobile_BaseKit26HeaderFullbleedCentralView")
        let fullbleed = layout.subviews.first { view in
            guard let fullbleedClass else { return false }
            return view.isKind(of: fullbleedClass)
        }

        // ★ 2026-10-13（性能）：这两个原来是每帧各一次整棵子树搜索，走缓存（同上面那五个挂点）。
        let cover = find("Components.Header.UI.ArtworkImage", in: layout, cache: &cachedCover) ?? fullbleed
        let block: UIView
        if let cached = cachedBlock, cached.window != nil, cached.isDescendant(of: layout) {
            block = cached
        } else {
            guard let found = blockIn(layout, cover: cover, fullbleed: fullbleed) else { return }
            cachedBlock = found
            block = found
        }
        guard block.bounds.height > 20 else { return }

        let texts = headerTexts(block: block, headerRoot: headerRoot)
        guard !texts.title.isEmpty else {
            logOnce("noTitle", "no title found — leaving Spotify's header alone")
            return
        }

        // 我们那一份：挂在 **headerRoot** 上（block 万一被换掉，同一份跟着搬过去，不会画两份）。
        let header: EntityPageHeaderView
        if let existing = objc_getAssociatedObject(headerRoot, &entityPageHeaderKey) as? EntityPageHeaderView {
            header = existing
        } else {
            header = EntityPageHeaderView()
            objc_setAssociatedObject(headerRoot, &entityPageHeaderKey, header, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
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

        // ★ 五个挂点全部走缓存（pw 的 `SGRFindByIdentifier` 同一条纪律）：命中过就不再搜树。
        let shuffle = find("Components.UI.ShuffleButton", in: block, cache: &cachedShuffle)
        let play = find("header-play-button", in: headerRoot, cache: &cachedPlay)
        let save = find("Components.UI.AddToButton", in: block, cache: &cachedTrailing)
        let download = save == nil ? eeveeFindView(block, identifier: "DownloadButton.Granular*") : nil
        header.updateRow(
            shuffle: shuffle,
            play: play,
            trailing: save ?? download,
            trailingFallback: save != nil ? plusGlyph : downloadGlyph
        )
        header.updateCreatorLink(
            find("Components.PlaylistHeader.collaboratorsButton", in: block, cache: &cachedCreatorLink)
        )

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
        // ★ 2026-10-13：**两个页面都藏**（歌单页的头 `PL.Header` / 专辑页的 `CreativeWorkTemplateView`）
        //   —— 两个页面我们都在行里镜像了这颗 Play。别的页面（艺人页那种浮动 Play）不碰。
        guard isEntityPage(of: view) else { return }
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

    /// 这是不是**我们接管的那两种页面**里的视图：歌单页判 `PL.Header`，专辑页判页面 root 的 id
    /// 或它的头容器 —— 三个都在祖先链上，走一次就够（pw 的 `SGRPlaylistHeaderOf` / `SGRAlbumPageOf`
    /// 也是各走一次祖先链）。
    private static func isEntityPage(of view: UIView) -> Bool {
        var node: UIView? = view
        var level = 0
        while let current = node, level < 24 {
            level += 1
            if let identifier = current.accessibilityIdentifier,
               identifier == "PL.Header"
                || identifier == "CreativeWorkPlatform.CreativeWorkTemplateView"
                || identifier == "CreativeWorkPlatform.Components.UI.CreativeWorkHeader" {
                return true
            }
            node = current.superview
        }
        return false
    }

    // MARK: - 专辑页（**另一条路**）

    /// 专辑页那一拍。**与歌单页不是同一条路** —— 两边的头结构不同，pw 也是分开的两份
    /// （`Album/AlbumHeader.x` 与 `Playlist/PlaylistHeader.x`）：
    ///
    /// ```
    /// 歌单页（PL.Header）            封面 + **一个** block：标题 / 描述 / 创建者 / 长度 / 操作行
    /// 专辑页（CreativeWorkHeader）   顶部 group（封面 + 标题 + 艺人）+ 底部 group（kind·日期 + 操作行）
    /// ```
    ///
    /// ⇒ 歌单页那个 `blockIn`（按宽度挑一块）在专辑页会挑到**底部 group**（那里没有标题），
    /// 所以这里**不挑块**：文字按**明确的 id** 读（`TitleRow` / `ParentRow` / `MetadataRow` ——
    /// pw 的 `AlbumHeader.x` 用的就是这三个），我们那一份铺在**整个头**上
    /// （pw 逐字：`setFrame(info, header.bounds)`）。
    ///
    /// 挂点是 `CreativeWorkTemplateView.layoutSubviews`（pw 的 `AlbumHeader.x` 也挂这里）。
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
        if headerView.frame != header.bounds { headerView.frame = header.bounds }

        concealAlbumChrome(in: header, avoiding: cover, skipping: headerView)

        headerView.update(title: texts.title, creator: texts.creator, length: texts.length, about: "")

        // Play 与 Shuffle 在**页面上**（浮在右上角，不在头里）—— pw 的 `floatingIn` 逐字：
        // 只搜页面的直接子视图、且宽度 ≤120 的那些（头 / wash / 列表都是整页宽，走进去等于每拍走整棵树）。
        let play = findFloating("header-play-button", in: page, cache: &cachedPlay)
        let shuffle = findFloating("Components.UI.ShuffleButton", in: page, cache: &cachedShuffle)
        let add = find("Components.UI.AddToButton", in: header, cache: &cachedTrailing)
        let download = add == nil ? eeveeFindView(header, identifier: "DownloadButton.Granular*") : nil
        headerView.updateRow(
            shuffle: shuffle,
            play: play,
            trailing: add ?? download,
            trailingFallback: add != nil ? plusGlyph : downloadGlyph
        )
        // 专辑页的"创建者"就是艺人，点它开艺人页 —— pw 逐字：`[info showCreatorLink:parent]`。
        headerView.updateCreatorLink(
            find("CreativeWorkPlatform.Components.UI.ParentRow", in: header, cache: &cachedAlbumParentRow)
        )

        eeveeConceal(play)
        // ★ 2026-10-13（照片 104：用户「播放按键的右边有按键重合」）：我们镜像的那两颗**再点名藏一次**。
        //   `concealAlbumChrome` 走的是"整支藏"，理论上已经覆盖它们，但 Spotify 会把按钮**晚一拍**
        //   加进一支已经藏过的分支里（新视图不受之前那次藏的影响）⇒ Spotify 的 AddToButton 就和我们的
        //   玻璃圆叠在同一格上。这两颗的 id 是我们逐颗找到的，直接点名最稳（幂等）。
        eeveeConceal(add)
        eeveeConceal(download)

        // 那行 kind·日期是 collection view 的 **cell**，晚一拍才建出来（pw 也等：最多 6 次、每次 0.25s）。
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

    /// 藏掉专辑页头里 Spotify 自己画的东西，**绕开封面那一支**。
    ///
    /// ⚠️ 为什么不能像歌单页那样整支藏（`for sub in block.subviews { eeveeConceal(sub) }`）：
    /// 专辑页的封面与标题**在同一支**里（顶部 group 装着"封面方块 + 标题块"），而封面归
    /// `EntityPageAppearance.concealNativeCover` 管 —— **那边记了原值**。`eeveeConceal` 不记原值，
    /// 这边再藏一次就会把"已经藏了"写进对面的原值记录 ⇒ 关掉开关封面再也回不来。
    ///
    /// 规则：**含封面的一支只递归、不整支藏**；封面自己跳过；其余整支藏掉。
    private static func concealAlbumChrome(in root: UIView, avoiding cover: UIView?, skipping ours: UIView) {
        for sub in root.subviews {
            if sub === ours { continue }
            if let cover {
                if sub === cover { continue }
                if cover.isDescendant(of: sub) {
                    concealAlbumChrome(in: sub, avoiding: cover, skipping: ours)
                    continue
                }
            }
            eeveeConceal(sub)
        }
    }

    /// 专辑页的文字：**按明确的 id 读**（pw 的 `applyHeader` 用同样这三个 id）。
    private static func albumTexts(in header: UIView) -> HeaderTexts {
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
    /// pw 的 `metadataText` 逐字：按**画出来的顺序**（x 从小到大）读，空格连接。
    private static func metadataLine(_ root: UIView) -> String {
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

    /// pw 的 `floatingIn`（`AlbumHeader.x`）：那两颗浮动控件是**页面的直接子视图、48pt 上下**，
    /// 而头、wash、列表都是整页宽 —— 只搜"小尺寸的直接子视图"，免得每一拍走一整棵树。
    private static func findFloating(_ identifier: String, in page: UIView, cache: inout UIView?) -> UIView? {
        if let cached = cache, cached.window != nil, cached.isDescendant(of: page) { return cached }
        var found: UIView?
        for sub in page.subviews where sub.bounds.width <= 120 {
            if let hit = eeveeFindView(sub, identifier: identifier) {
                found = hit
                break
            }
        }
        cache = found
        return found
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

    /// ★ 2026-10-13（性能）：**上一拍认下的那四个标签**。
    ///
    /// 日志 86 逐字：`[Perf][EntityPageHeader] 200 passes, 140.53 ms total, 0.703 ms avg` ——
    /// 而 `HeaderContentLayout.layoutSubviews` 在页头折叠时**每一帧**都会来（用户那边就是
    /// 「用较快的速度往下滑，会有渲染跟不上的问题」）。原来每一拍要走 **5~8 次整棵子树遍历**：
    /// 封面 1 次 + `Metadata*` 最多 3 次 + 脸堆 1 次 + 标题 1 次 + 创建者 1 次，全落在主线程上。
    ///
    /// pw 的每一步查找都带 `static char` key（`SGRFindByIdentifier`：命中过就不再搜树）——
    /// 这里照它的纪律，把**引用**留下，之后每一拍只读 `.text`。
    /// 引用一旦离开那棵树（Spotify 换了 label、换了页面）就整批作废，重新认一次。
    private struct TextViews {
        weak var title: UILabel?
        weak var creator: UILabel?
        weak var length: UILabel?
        weak var about: UILabel?
    }

    /// 文本来源**分两级**（pw 的分法）：标题/描述优先读页面的 view model，创建者与长度读
    /// Spotify 自己那些**被藏起来的标签**（所以语言永远跟着 Spotify 走）。
    ///
    /// ⚠️ 9.1.88 上 model 那条路的存在性**没证实**（`dump-9.1.88.txt` 里没有
    /// `defaultHeaderViewModel` / `playlistName` 这两个名字）⇒ 一律 `responds(to:)` 守卫，
    /// 拿不到就退回标签启发式。**标签兜底才是这里的主路径**。
    /// ★ 2026-10-13（性能）：上一拍认下的四个标签还在那棵树上 ⇒ **只读 `.text`**（每帧一次，成本≈0）。
    /// 认不出来（进页面第一拍、或者 Spotify 换了 label）才走下面那条完整的启发式。
    private static func headerTexts(block: UIView, headerRoot: UIView) -> HeaderTexts {
        if let views = cachedTextViews, let title = views.title, title.isDescendant(of: block) {
            var texts = HeaderTexts()
            texts.title = title.text ?? ""
            texts.creator = views.creator?.text ?? ""
            texts.length = views.length?.text ?? ""
            texts.about = views.about?.text ?? ""
            return texts
        }
        let (texts, views) = headerTextsSlow(block: block, headerRoot: headerRoot)
        cachedTextViews = views
        return texts
    }

    /// 完整那条：**只在缓存失效时走**（进页面那一拍、换页面、Spotify 换掉标签）。
    /// 返回的 `views` 为 `nil` = "这一页的值不完全是标签读来的"（view model 参与了）⇒ 不许走快路。
    private static func headerTextsSlow(block: UIView, headerRoot: UIView) -> (HeaderTexts, TextViews?) {
        var texts = HeaderTexts()
        var views = TextViews()
        var fromModel = false

        let model = viewModel(from: headerRoot)
        if let model {
            if let name = modelString(model, "playlistName") { texts.title = name; fromModel = true }
            if let about = plainText(modelString(model, "playlistDescription")) { texts.about = about; fromModel = true }
        }

        // 长度：Spotify 自己那行（`Components.Header.UI.Metadata*`）—— **只查一次**（原来这条最多查三次）。
        let metadata = metadataView(block)
        if let metadata, let label = firstLabel(in: metadata, skipping: nil) {
            texts.length = label.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            views.length = label
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
                if let label = firstLabel(in: current, skipping: facepile) {
                    texts.creator = label.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    views.creator = label
                    break
                }
                row = current.superview
                level += 1
            }
        }

        // 标题兜底：block 里**字号最大**的那个标签（页头里最大的字就是标题），
        // 同字号取最靠上的。排除长度那行与创建者那行。
        if texts.title.isEmpty, let label = biggestLabel(in: block, skipping: [facepile, metadata]) {
            texts.title = label.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            views.title = label
        }

        // 描述兜底：只剩**一个**没被认领的标签、而且它够长时才用它（宁可没有，不要贴错）。
        if texts.about.isEmpty {
            let leftovers = unclaimedLabels(in: block, facepile: facepile, metadata: metadata)
            if leftovers.count == 1, let only = leftovers.first,
               let text = only.text?.trimmingCharacters(in: .whitespacesAndNewlines), text.count > 12 {
                texts.about = text
                views.about = only
            }
        }

        // view model 参与了 ⇒ 值不是（也不该）从标签读的，快路会读错 ⇒ 这一页禁用快路。
        return (texts, fromModel ? nil : views)
    }

    private static func metadataView(_ block: UIView) -> UIView? {
        eeveeFindView(block, identifier: "Components.Header.UI.Metadata*")
    }

    /// 字号最大的那个标签（页头里最大的字就是标题）。返回**标签本身**而不是文本 ——
    /// 调用方要把它当引用缓存下来，之后每一拍只读 `.text`（见 `TextViews`）。
    private static func biggestLabel(in root: UIView, skipping skip: [UIView?]) -> UILabel? {
        var best: (size: CGFloat, y: CGFloat, label: UILabel)?
        forEachView(root) { view in
            guard let label = view as? UILabel else { return }
            for skipped in skip.compactMap({ $0 }) where view.isDescendant(of: skipped) { return }
            let text = (label.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            let size = label.font.pointSize
            let y = label.convert(.zero, to: root).y
            if let current = best {
                if size > current.size || (size == current.size && y < current.y) {
                    best = (size, y, label)
                }
            } else {
                best = (size, y, label)
            }
        }
        return best?.label
    }

    /// block 里还没被认领的标签（标题/创建者/长度之外的那些）。
    private static func unclaimedLabels(in block: UIView, facepile: UIView?, metadata: UIView?) -> [UILabel] {
        var labels: [UILabel] = []
        let biggest = biggestLabel(in: block, skipping: [facepile, metadata])
        var titleTaken = false
        forEachView(block) { view in
            guard let label = view as? UILabel else { return }
            if let facepile, view.isDescendant(of: facepile) { return }
            if let metadata, view.isDescendant(of: metadata) { return }
            let text = (label.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count > 1 else { return }
            if !titleTaken, let biggest, label === biggest { titleTaken = true; return }
            labels.append(label)
        }
        return labels
    }

    /// 那一行里第一个非空标签。返回**标签本身**，理由同 `biggestLabel`（引用要留下来当缓存）。
    private static func firstLabel(in root: UIView, skipping skip: UIView?, longerThan minimum: Int = 1) -> UILabel? {
        var found: UILabel?
        forEachView(root) { view in
            guard found == nil, let label = view as? UILabel else { return }
            if let skip, view.isDescendant(of: skip) { return }
            let text = (label.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count > minimum { found = label }
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
///
/// ⚠️ hook 类**不能加 `final`/`private`/`fileprivate`** —— Orion 会生成自己的胶水子类，
/// 2026-10-13 实测报错：`A class hook cannot be private, fileprivate, or final`。
/// 本机 `orion_hook_guard.py` 已加这条规则（规则 5）。
class EntityPageHeaderLayoutHook: ClassHook<UIView> {
    typealias Group = EntityPageHeaderGroup
    static let targetName = "_TtC28EncoreConsumerMobile_BaseKit19HeaderContentLayout"

    func layoutSubviews() {
        orig.layoutSubviews()
        // ★ 2026-10-13：**满幅封面那条路也挂在这一拍上** —— 页面出现的第一帧就把 Spotify 那张
        //   262×262 的小封面藏掉。原来只有 `EntityPageAppearance` 的 0.6s tick 会藏，
        //   而第一帧封面已经画出来了 ⇒ 用户看到的"刚进歌单页小封面短暂展现一会"。
        //   `layoutPass` 是幂等且便宜的（缓存了封面引用），重活仍在 tick 里。
        EntityPageAppearance.layoutPass(in: target)
        EntityPageHeaderManager.apply(in: target)
    }
}

/// Spotify 自己那颗 Play：会在前景区晚一步出现，所以它自己那一拍也要补一次。
class EntityPagePlayButtonHook: ClassHook<UIView> {
    typealias Group = EntityPageHeaderGroup
    static let targetName = "_TtC28EncoreConsumerMobile_BaseKit14PlayButtonView"

    func layoutSubviews() {
        orig.layoutSubviews()
        EntityPageHeaderManager.concealPlayButtonIfNeeded(target)
    }
}

/// ★ 2026-10-13：**专辑页的主挂点**。pw 的 `Album/AlbumHeader.x` 也挂在这一拍上
/// （它的 `applyPage` 就是从 `%hook _TtC28CreativeWorkPlatform_PageKit24CreativeWorkTemplateView
/// - (void)layoutSubviews` 进来的）—— 歌单页那个 `HeaderContentLayout` 覆盖的是"那一块"，
/// 而专辑页要的是**整个头**（标题、艺人、kind·日期和操作行分在两个 group 里）。
class EntityPageAlbumLayoutHook: ClassHook<UIView> {
    typealias Group = EntityPageHeaderGroup
    static let targetName = "_TtC28CreativeWorkPlatform_PageKit24CreativeWorkTemplateView"

    func layoutSubviews() {
        orig.layoutSubviews()
        EntityPageHeaderManager.applyToAlbumPage(target)
    }
}

func activateEntityPageHeader() {
    // 两个开关共用这一条每帧的布局拍：AM 页头（`entityPageAMHeader`）与"满幅封面 + 取色底"
    // （`entityPageDissolve`）。**任一打开这条钩子就得在**，否则满幅封面那条路又退回 0.6s 的 tick。
    guard EntityPageHeaderManager.isEnabled || EntityPageAppearance.isEnabled else { return }

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
    // 专辑页那条路是**可选**的：类不在就只做歌单页（不能因为一个可选的类把整组拖垮）。
    let album = NSClassFromString(EntityPageAlbumLayoutHook.targetName) != nil
    writeDebugLog(
        "[EntityPageHeader] on — AM header \(EntityPageHeaderManager.isEnabled ? "ON" : "OFF"),"
            + " page look \(EntityPageAppearance.isEnabled ? "ON" : "OFF")"
            + " (one layout pass drives both; playlist pages"
            + (album ? " + album pages)" : "; the album hook class is missing on this build)")
    )
}
