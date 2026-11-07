import Foundation
import Orion
import UIKit
import ObjectiveC.runtime

extension EntityPageHeaderManager {
    /// 页头每一拍要用的那几个视图**缓存下来**。
    ///
    /// `SGRFindByIdentifier` 带一个 `static char` key —— 命中一次之后每拍只做"还在不在"的检查。
    /// 原来每拍 5 次全树 BFS（shuffle / play / save / download / 协作者）+ 3~4 次文本遍历，
    /// 而页头在快速滑动时每帧都在折叠（`layoutSubviews` 每帧一次）⇒ 那些搜索全落在主线程上。
    static var cachedShuffle: UIView?
    static var cachedPlay: UIView?
    static var cachedTrailing: UIView?
    static var cachedCreatorLink: UIView?
    /// 封面元素与"那一块文字"也缓存 —— 不缓存的话**每帧**各要一次整棵子树搜索
    /// （`eeveeFindView(layout, "Components.Header.UI.ArtworkImage")` / `blockIn(layout,…)`）。
    static var cachedCover: UIView?
    static var cachedBlock: UIView?
    /// 我们**当前这一页**画出来的那份页头（弱引用）。
    ///
    /// 只给 `playlistPageDidLayout` 用：那一拍判断"主挂点是不是已经在干活" —— 是就什么都不做，
    /// 免得每 0.5s 白扫一遍整棵页面树。
    static weak var currentHeader: EntityPageHeaderView?
    /// 那一份页头挂在哪一层 —— `pinMoreButton` 的落点（弱引用：换页 / 页头重建自动失效）。
    ///
    /// 存在的唯一理由：`⋯` 挂在 **window** 上，而 `EntityPageAppearance.tick` 每 0.6s 要把它
    /// 重钉一次（见 `refreshPinnedMore`）。没有这个落点，`⋯` 就只能等下一次**布局回合**
    /// ——也就是必须有别的交互触发一次布局 —— 才回来。
    static weak var currentHeaderRoot: UIView?

    /// 当前这一页的**页头容器**（弱引用）。`EntityPageAppearance` 用它判断"这一页的页头确实归我们管"，
    /// 也是满幅页头找页面根/找图源的起点。
    static var headerHost: UIView? { currentHeaderRoot }

    /// 我们那一份页头是不是**还在最前面那一页上**（`refreshPinnedMore` 用的同一条判据）。
    /// `EntityPageAppearance` 拿它挡"换页动画里上一页的满幅图"。
    static var isHeaderVisible: Bool { isHeaderOnScreen() }

    /// 页面级备用入口的节流（BFS 最多 1500 个节点，不能每帧跑）。
    static var lastPlaylistProbe: CFAbsoluteTime = 0
    /// 页头里那几个大圆头像（见 `headerAvatars`）—— 这一拍是每帧的，按 `layout` 缓存，换页才重扫。
    static weak var artworkScannedLayout: UIView?
    static var cachedArtwork: [UIView] = []
    /// 歌单页头里那个「在此页面上查找」搜索框（AM 页头接管后不该留着）。
    static var cachedFindField: UIView?
    /// 上一拍认下的那四个标签（见 `TextViews`）。
    static var cachedTextViews: TextViews?
    /// 「Follow 那颗的子树」只打一次（见 `probeFollowSubtree`）。
    static var didProbeFollow = false
    /// 简介卡是**懒加载**的（页面滚到"关于"那一段才建），所以某一拍找不到它**不能**就退回
    /// shuffle —— 那样的就永远是 shuffle。这里把**找到过的那颗控件**用 weak 记住
    /// （上一页释放后自动失效，下一页找到就替换），于是"只要见过一次 Info，之后每拍都还是 Info"。
    static weak var artistBioControl: UIView?
    /// 右上角那颗 `⋯` —— Spotify 的菜单按钮（`Components.UI.ContextMenuButton-<hash>`）
    /// 与**我们自己画的那一颗**（`EntityPageHeaderButton` 复用：玻璃圆 + 字形 + 转发）。
    static var cachedMore: UIView?
    static var pinnedMore: EntityPageHeaderButton?
    /// 我们那颗 `⋯` 还在屏上、可 Spotify 的源已经没了 —— 只报一次（见 `pinMoreButton`）。
    static var didReportPinnedMoreMissing = false
    /// `⋯` 挂到 window 之后，只报一次几何/可交互性（用来判断"点不到"是位置还是层级）。
    static var didReportPinnedMoreGeometry = false
    /// 歌单页「在此页面上查找」那一行的容器/滚动几何，只报一次（治"进入后还能往上划"）。
    static var didReportPlaylistMetrics = false
    /// 艺人页 section / cell 的文字探针（找「最新发行 / 艺人之选」，不用转储视图树）。
    static weak var artistProbePage: UIView?
    static func applyOnce(in layout: UIView) {
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

        // 这两个不缓存就要每帧各一次整棵子树搜索（同上面那五个挂点）。
        let cover = find("Components.Header.UI.ArtworkImage", in: layout, cache: &cachedCover) ?? fullbleed
        var block: UIView
        if let cached = cachedBlock, cached.window != nil, cached.isDescendant(of: layout) {
            block = cached
        } else {
            guard let found = blockIn(layout, cover: cover, fullbleed: fullbleed) else { return }
            cachedBlock = found
            block = found
        }
        guard block.bounds.height > 20 else { return }

        // 生成歌单（电台 / This Is / 音乐全纪录）用的是**满幅页头**（`HeaderFullbleedCentralView`）。
        // 那个容器里**不只装图**：`…ArtworkWrapper` → `Encore.ImageView`，一道 `GradientView` 渐变，
        // 还有一个装着 **45pt 白色大标题**的 `AutoLayoutStackView` —— Spotify 自己在这个容器里
        // 画了一遍大标题。把整支满幅图当"封面"跳过，那行标题就留下来，和我们画的叠成两个。
        // ⇒ 先把容器里**那张图**认出来：留着图，同一容器里的渐变和大标题一起藏
        // （`concealInside` 本来就是"逐层往下藏、遇到图片绕开"）。
        // ⚠️ **认不出图就整支放过** —— 空名单会把满幅图一起藏掉，而 conceal 不会自己撤销，
        // 那就是一整块永久黑屏。
        var fullbleedKept: [UIView] = []
        // 满幅头里**那张图**：`probeCoverOverlap` 用它量重叠，与"不许藏"名单是两件事 ——
        // 交给 hero 画的时候，图反而要从名单里拿掉（名单里只剩同容器的大标题）。
        var fullbleedPicture: UIView?
        // 这张图**已经交给 hero 画**了 ⇒ Spotify 那份（连它上面那层渐变）要一起让位。
        var fullbleedHandedOver = false
        // 满幅头里留下的是**一行大圆头像**（电台）⇒ 不做底沿化开（会糊掉头像下半截）。
        var fullbleedArtIsAvatarRow = false
        if let fullbleed {
            let picture = fullbleedArtwork(in: fullbleed)
            fullbleedPicture = picture.first
            fullbleedKept = picture
            fullbleedArtIsAvatarRow = !picture.isEmpty && picture.allSatisfy {
                NSStringFromClass(type(of: $0)).contains("AvatarView")
            }
            // 认出了图才有"留谁"这件事。⚠️ 名单为空的"整支放过"安全阀不能被破坏，
            // 所以只在非空时往里合并。
            if !picture.isEmpty {
                // 我们自己那张满幅照片已经在画这张图时，Spotify 这份是**压在我们上面**的
                // （它是页头内容那支，晚于 `_backgroundViewContainer` 挂上）⇒ 化开蒙版与顶上那条纱
                // 全画在被盖住的那一层上：屏上是硬边，状态栏上也没有那条同色的纱。
                // 这时把图与渐变一起让位，页头只剩我们自己画的。图没到的那几拍
                // `isHeroDrawing` 为 false，照旧留着，免得页头先空一块。
                // ⚠️ 电台那一族认出来的是**一行大圆头像**（`AvatarView`），不是一张图 —— 留着：
                // hero 画的是方封面，替换不出那一排的排版。
                let avatarsOnly = picture.allSatisfy { NSStringFromClass(type(of: $0)).contains("AvatarView") }
                // 图这一支的下缘由我们自己的纱化开（`updateArtworkFade`）：Spotify 那层
                // 渐变/模糊的锚点和长度是按它原来的页头定的，跟着留就是第二条淡化曲线，
                // 与图的下沿、与我们的纱各错开一段，中间露出一条横贯的磨砂带 ⇒ 不留。
                // 电台（一行头像）那一支仍要它 —— 那片由它自己收，`artworkFadeEnabled` 也是关的。
                if EntityPageAppearance.isHeroDrawing, !avatarsOnly {
                    fullbleedHandedOver = true
                    fullbleedKept = []
                } else if avatarsOnly {
                    fullbleedKept += fullbleedGradients(in: fullbleed)
                }
            }
        }

        // 满幅那张图**交给 hero 当图源**：它是 Spotify 给这一版页头专配的宽图，比 262pt 那张
        // 方封面清晰得多，裁法也正是页头要的那一版（见 `EntityPageAppearance.fullbleedPictureImage`）。
        // 认不出满幅图时写 nil，hero 退回方封面那条老路。
        EntityPageAppearance.fullbleedPictureView = fullbleedPicture

        var texts = headerTexts(block: block, headerRoot: headerRoot)

        // 按宽度挑出来的"那一块"**不一定装着标题** —— 电台页头的排版是"头像 / 大标题 / 小圆点 /
        // 创建者 / 按钮行"各成一格，挑到按钮行或创建者那格时标题就是空的，于是整页什么都不做。
        // ⇒ 标题读不到时**换一块再读一次**：从字号最大的标签往上爬（`textBlockAroundBiggestLabel`）。
        if texts.title.isEmpty,
           let retry = textBlockAroundBiggestLabel(in: layout, cover: cover, fullbleed: fullbleed),
           retry !== block {
            block = retry
            cachedBlock = retry
            texts = headerTexts(block: block, headerRoot: headerRoot)
        }
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
        currentHeader = header

        if header.superview !== block {
            block.addSubview(header)
        } else if block.subviews.last !== header {
            block.bringSubviewToFront(header)
        }

        // 位置：**页面宽度、居中** —— Spotify 的 block 比页面窄（真机 386 / 402）。
        // 高度再加上"给封面让出来的那一段"（见 `coverDrop`）：贴底排 ⇒ 文字整体下移，
        // 落在封面下面。
        //
        // 文字块可能**比我们这一份还矮**（生成歌单的页头是插件拼的，标题那一块常常只有一百来 pt，
        // 而我们的内容要两百多）。frame 高度若只取 block 高度，内容会从负 y 溢出块外、被上层的
        // 封面 / 渐变盖住。这里把 frame **向上**补到"内容刚好装下"：贴底排 ⇒ 内容的绝对位置
        // **一个点都不变**，只是 bounds 变高（不会被裁剪、`room` 也够了）。块够高时这一句是空转。
        //
        // ⚠️ **只在没有 `PL.Header` 的那条兜底路上开**：普通歌单页的折叠行为已经调好
        // （块矮下去时内容跟着页头一起走），不要因为这一句把它的裁剪边界也改掉。
        let x = -block.convert(.zero, to: headerRoot).x
        let isPLHeader = headerRoot.accessibilityIdentifier == "PL.Header"
        var height = block.bounds.height + coverDrop(of: header)
        if !isPLHeader {
            let needed = header.contentHeight(forWidth: headerRoot.bounds.width) + header.contentBottom
            height = max(height, needed)
        }
        // **底边锚到"列表第一行上沿"**（歌单页两种都开：普通歌单与生成歌单）。
        // 我们这一块是**贴底排**的，底边就是"内容最低能到哪里"：
        // · 普通歌单：`block` 底边 = `PL.Header` 底边 = 列表起点 ⇒ 用 `block` 底边；
        //   用 `y = 0` + 高度里加 `coverDrop` 的话，那一截会把内容**推到 block 下面的列表里**；
        // · 生成歌单：`block` 所在的布局层比页头真正占的高度高 ⇒ 拿 `visibleCells` 量到的
        //   第一行上沿当底边。
        // 两者取**更小的那个**（内容既不能进列表、也不能掉出块底），`y` 由底边反推 ⇒
        // `coverDrop` 只让我们的视图向上变高，不再把内容往下推。
        let rawListTop = firstRowTop(around: headerRoot, in: block)
        let listTop = rawListTop.flatMap { top -> CGFloat? in
            let shift = block.bounds.height - (top + header.contentBottom)
            guard top > 20, shift > 4, shift <= 120 else { return nil }
            return top
        }
        let bottom = min(block.bounds.height, listTop.map { $0 + header.contentBottom } ?? block.bounds.height)
        if let listTop {
            logOnce(
                "listAnchor_" + String(describing: ObjectIdentifier(headerRoot)),
                "playlist: the first row starts at \(Int(listTop.rounded()))pt, but the header layout"
                    + " reaches \(Int(block.bounds.height.rounded()))pt — anchored our block to the row"
                    + " (\(Int((block.bounds.height - bottom).rounded()))pt up)"
            )
        }
        var frame = CGRect(
            x: round(x),
            y: bottom - height,
            width: headerRoot.bounds.width,
            height: height
        )
        if header.frame != frame { header.frame = frame }
        // 满幅页头的图**下缘化开**：Spotify 那层渐变不保证存在（不存在时页头就是一块硬边纯色），
        // 我们自己补一条。只在"留下的是 Spotify 那张图"这一支开。
        // 落点与开关留在这里，**颜色却被取色定时器晚一步送来** ⇒ 页面停住后这一拍可能是最后一拍
        // 布局，纱就再也没人建（见 `refreshArtworkFade`）。
        artworkFadeHost = header
        artworkFadePicture = fullbleedPicture
        artworkFadeEnabled = fullbleedPicture != nil && !fullbleedHandedOver && !fullbleedArtIsAvatarRow
        updateArtworkFade(in: header, enabled: artworkFadeEnabled, source: "layout")

        // z 序与几何两道保险。
        raiseToTop(header, in: headerRoot, role: "playlist")
        // `fullbleed` 是"找不到封面时的整幅兜底"（整块页头背景）—— 它的 frame 几乎盖满整个页头，
        // 拿来量"封面压到文字"会得到几百 pt 的假重叠，把我们的内容一路往下推。
        // 几何判据**只认真封面**：找不到就跳过这一支（宁可这一拍不动，也不要把页头撑出边界）。
        // 满幅页头量的是**容器里那张图**（`fullbleedPicture`）而不是整支容器 —— 整支会把渐变和
        // 大标题也算进去，同样是几百 pt 的假重叠。认不出图时退回"这一支不量"。
        probeCoverOverlap(
            cover: fullbleedPicture ?? (cover === fullbleed ? nil : cover),
            headerView: header,
            root: headerRoot,
            anchored: true,
            role: "playlist"
        )
        // 把三段高度打进日志（每页一次）：藏掉某一段之后留下的空白，靠它定位空在哪两段之间。
        // 后面两个数是给"生成歌单的按键压到列表第一行"留的判据：我们的内容要 `need` 那么高，
        // 而 Spotify 给页头留的那一格（`host` 那一项）可能更矮 —— 内容比那一格高就会溢到列表上。
        logOnce(
            "playlistGeom_" + String(describing: ObjectIdentifier(headerRoot)),
            "playlist geometry — PL.Header \(Int(headerRoot.bounds.height.rounded()))pt,"
                + " block \(Int(block.frame.minY.rounded()))..\(Int(block.frame.maxY.rounded()))pt,"
                + " our block \(Int(header.frame.minY.rounded()))..\(Int(header.frame.maxY.rounded()))pt,"
                + " text top \(Int(header.textTop.rounded()))pt,"
                + " cover bottom \(cover.map { Int($0.convert($0.bounds, to: header).maxY.rounded()) } ?? -1)pt,"
                + " need \(Int(header.contentHeight(forWidth: headerRoot.bounds.width).rounded()))pt,"
                + " host \(slotDescription(of: headerRoot))"
        )

        // Spotify 那一列整列藏掉（我们自己的那份除外）。幂等；Spotify 边加载边往里加东西，
        // 所以**每一拍都要重新走一遍**。
        //
        // 电台页头的"封面"**不是一张图**，是**一行三个大圆头像**（`Encore.AvatarView`），
        // 而且和标题常常同在一个容器里 ⇒ 整支藏掉会把头像一起删掉、那一块变成空白。
        // 所以走 `concealInside(keeping:)`：**逐层往下藏，遇到图片区就绕开**。
        // 与正常歌单页的"方封面在 block 外面、不参与 conceal"是同一条语义 ——
        // 电台页只是把那张封面换成了三个头像，位置关系一模一样（图在上、字在下）。
        let artwork = headerArtwork(in: layout, cover: cover, fullbleed: fullbleed)
        // 满幅页头里**同一支容器**装着图和 Spotify 的大标题 —— 只藏标题、留图。
        // 名单 = 图（`fullbleedArtwork`）+ 上面那份"不许藏"的（头像可能就在这层里：
        // 电台页的三个圆头像和标题常常同容器，见 `concealInside` 那段说明）。
        // 名单为空时整支放过（否则满幅图会跟着消失，那是一条不可逆的黑屏）。
        if let fullbleed, fullbleedHandedOver || !fullbleedKept.isEmpty {
            concealInside(fullbleed, keeping: fullbleedKept + artwork)
            if fullbleedHandedOver {
                logOnce(
                    "hidFullbleedPicture",
                    "full-bleed header: let Spotify's own picture go — our sharp hero draws it now,"
                        + " so the dissolve and the top band land on the picture that is on screen"
                )
            } else {
                logOnce(
                    "hidFullbleedTitle",
                    "full-bleed header: kept the picture (\(fullbleedKept.count) view(s)) and concealed"
                        + " everything else in that container — Spotify draws its big title in there,"
                        + " which is the second copy of the page title"
                )
            }
        }
        for sub in block.subviews where sub !== header {
            concealInside(sub, keeping: artwork)
        }

        // （歌单页的那个**搜索歌单内歌曲框**还在）：
        // 「在此页面上查找」那颗搜索框在 **PL.Header 里、不在 block 里**（上游
        // `GlassPlaylist.x` 也是从 header 里找 `Components.Header.UI.Toolbar.SearchField`）
        // ⇒ 上面那轮 `block.subviews` 永远命不中。AM 页头接管后它不该留在页头，
        // 这里单独藏一次（连它的圆底包装一起，走 `wrapperFor`）。
        if let findField = find(
            "Components.Header.UI.Toolbar.SearchField",
            in: headerRoot,
            cache: &cachedFindField
        ) {
            eeveeConceal(wrapperFor(findField, in: headerRoot))
            logOnce(
                "hidPlaylistFind",
                "playlist page: hid Spotify's find-in-playlist field (it lives in PL.Header, not in the header block)"
            )
            reportPlaylistMetrics(headerRoot: headerRoot, findField: findField)
        }

        header.update(title: texts.title, creator: texts.creator, length: texts.length, about: texts.about)

        // 五个挂点全部走缓存（同 `SGRFindByIdentifier` 的纪律）：命中过就不再搜树。
        // 这三颗都走 `findControl` —— 按 id 拿到的是包装层时，点了没反应。
        let shuffle = findControl("Components.UI.ShuffleButton", in: block, cache: &cachedShuffle)
        // Play 的挂点比另外两颗多一层不确定性：普通歌单页它在 `PL.Header` 里，而**满幅页头**
        // （官方编辑歌单那一族）把它挂在 block / 布局层，`headerRoot` 里一个都没有。
        // 只认 headerRoot 的后果就是 `play missing` —— 界面上剩一个空胶囊（现场见 2026-11-08 的日志）。
        // 依次退：headerRoot → block → 整个布局层；三档都找不到才留空（那时 `updateRow` 会把
        // 我们那颗也藏起来，宁可没有，也不要一个点不动的空壳）。
        let play = findControl("header-play-button", in: headerRoot, cache: &cachedPlay)
            ?? findControl("header-play-button", in: block, cache: &cachedPlay)
            ?? findControl("header-play-button", in: layout, cache: &cachedPlay)
        let save = findControl("Components.UI.AddToButton", in: block, cache: &cachedTrailing)
        // download 也必须钻到真正的 `UIControl`（同上面三颗）—— "已点赞的歌曲"那一页走的正是它。
        let download = save == nil
            ? eeveeFindView(block, identifier: "DownloadButton.Granular*").map { firstControl(in: $0) ?? $0 }
            : nil
        header.updateRow(
            shuffle: shuffle,
            play: play,
            trailing: save ?? download,
            trailingFallback: save != nil ? plusGlyph : downloadGlyph
        )
        // 长按播放键 = 随机播放（见 `EntityPageHeaderPlay.feedLongPress`）。
        header.updatePlayLongPress(shuffle)
        header.updateCreatorLink(
            find("Components.PlaylistHeader.collaboratorsButton", in: block, cache: &cachedCreatorLink)
        )

        // Play 在页头的**前景区**，不在 block 里 ⇒ 单独藏一次（它自己那一拍也会再补，见下面的 hook）。
        eeveeConceal(play)

        // 把 `⋯` 钉到右上角去（照 AM）。
        pinMoreButton(in: headerRoot)

        logOnce(
            "applied",
            "applied — title \"\(texts.title)\", creator \"\(texts.creator.isEmpty ? "-" : texts.creator)\""
                + ", length \"\(texts.length.isEmpty ? "-" : texts.length)\""
                + ", shuffle \(describe(shuffle))"
                + ", play \(describe(play))"
                + ", trailing \(save != nil ? "save" : (download != nil ? "download" : "none"))"
        )
    }

    /// 歌单页 **VC 自己那一拍**（taurus 的 `PlaylistField.x` 也挂在同一个 VC 上）。
    ///
    /// 主挂点是 `HeaderContentLayout`，只要这一版还用那个布局类就每帧都会来。但生成歌单的页头是
    /// **插件拼的**（`ThisIsArtistHeaderPluginImpl` / `FullBleedHeaderLayoutPluginImpl`），万一某个
    /// 版本换成另一套布局类，主挂点就**一次都不会来** ⇒ 需要一条不依赖布局类的入口。
    ///
    /// **页面本身布局过**这件事永远会发生。找不到 `HeaderContentLayout` 就什么都不做；
    /// 找到了就交给同一条 `apply`。
    ///
    /// 代价：一次 BFS（≤1500 节点），**0.5s 一次**、而且"我们那份已经挂在这一页里"就直接返回
    /// ⇒ 正常页面上它几乎不进 BFS。
    static func playlistPageDidLayout(_ page: UIView) {
        guard isEnabled else { return }
        if let header = currentHeader, header.window != nil, header.isDescendant(of: page) { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastPlaylistProbe >= 0.5 else { return }
        lastPlaylistProbe = now
        guard let layout = firstView(withClassName: "HeaderContentLayout", in: page) else {
            logOnce(
                "playlistPageNoLayout",
                "playlist page laid out but has no HeaderContentLayout — the header hook never fires here"
            )
            return
        }
        apply(in: layout)
    }

    /// `PlayButtonView` 自己的那一拍：页面刚打开时它会**晚一步**进前景区（角上会先闪一下 Spotify
    /// 自己的绿盘）。只有它确实在实体页（歌单 / 专辑）里才藏 —— 艺人页那种浮动 Play 不碰。
    ///
    /// 还有一条更硬的前提：**我们那份页头真的镜像到了 play**（`hasMirroredPlay`）。
    /// 满幅歌单页上 `play` 第一次扫不到（它不在 `headerRoot` 里），这时候把原件藏掉
    /// 就只剩一个点不动的空胶囊 —— 宁可露着原生按钮。
    static func concealPlayButtonIfNeeded(_ view: UIView) {
        guard isEnabled else { return }
        guard view.accessibilityIdentifier == "header-play-button" else { return }
        // **两个页面都藏**（歌单页的 `PL.Header` / 专辑页的 `CreativeWorkTemplateView`）——
        // 两边我们都在行里镜像了这颗 Play。别的页面（艺人页那种浮动 Play）不碰。
        guard isEntityPage(of: view) else { return }
        // 还得再问一句**我们那份页头真的挂上去了没有** —— 生成歌单的页头是插件拼的，万一这一页
        // 最后没画成（没标题 / 找不到文字块），把 Spotify 那颗藏掉就是"两个都没有"。
        // ⚠️ 三条路（歌单 / 专辑 / 艺人）都会写 `currentHeader`，所以这一句不会误伤那两页。
        guard let header = currentHeader, header.window != nil else { return }
        // **我们真的镜像到 play 了吗**：只藏原件、没造替代品，屏幕上就是中间那个空胶囊
        // （满幅歌单页的现场）。`hasMirroredPlay` 跟着 `updateRow` 的 `play == nil` 一起变，
        // 所以扫不到源控件时这一句会让 Spotify 自己的绿盘留着 —— 露着原生按钮也比空壳好。
        guard header.hasMirroredPlay else { return }
        eeveeConceal(view)
    }

    // MARK: - 找页面 / 找那一块
    //
    // 往上找歌单页头的容器。找不到就返回 nil —— **专辑页与别的页面因此完全不受影响**。
    //
    // `PL.Header` 只是"普通歌单页"那一种实现的标签。9.1.88 里官方生成的歌单（This Is / 电台）
    // 由 **slot 插件**拼页头（`ThisIsArtistHeaderPluginImpl`、`PlaylistDefaultHeaderImpl` /
    // `FullBleedHeaderLayoutPluginImpl`），容器**不带 `PL.Header`** ⇒ 只认 id 的话在 `guard`
    // 那一行就 return，页头保持 Spotify 原样（不是画得不对，是根本没进来）。
    //
    // 参照 taurus 的 `SGRPlaylistHeaderOf`：**从不看 accessibility id**，沿 responder chain 找
    // 类名含 `FreeTierPlaylist` 的 VC，页头容器直接取那个 VC 的 view ⇒ 三种歌单走同一条路。
    // 9.1.88 上没有那个 header VC，"页头自己那一层"是 header slot 的宿主
    // `…ElementCollectionViewCell`。所以按同一顺序退，每一档都只看类名：
    //
    // ① `PL.Header` —— 普通歌单，原样保留；
    // ② 最近的 `UICollectionViewCell` 祖先（header slot 的宿主）；
    // ③ `HeaderContentLayout` 自己（挂点就是它，天然在手上）；
    // ④ responder chain 上第一个 VC 的 view（taurus 那一档的等价物）。
    //
    // ⚠️ ②③④ **全部要先过 `isPlaylistPage`**（VC 类名含 `FreeTierPlaylist`）——
    // 专辑页 / 艺人页 / 首页的 `HeaderContentLayout` 因此一个字节都不动。
    static func playlistHeaderRoot(of view: UIView) -> UIView? {
        if let root = ancestor(of: view, identifier: "PL.Header") { return root }
        guard isPlaylistPage(of: view) else { return nil }

        // ② header slot 的宿主 cell（taurus 的 `headerVC.viewIfLoaded` 在这一版的对位）。
        var node: UIView? = view
        var level = 0
        while let current = node, level < 6 {
            let name = NSStringFromClass(type(of: current))
            if current is UICollectionViewCell, name.contains("Cell") {
                logOnce(
                    "playlistRootCell",
                    "generated playlist (no PL.Header): header root = \(name)"
                )
                return current
            }
            node = current.superview
            level += 1
        }

        // ③ 挂点自己就是页头那一块的布局视图。
        if NSStringFromClass(type(of: view)).contains("HeaderContentLayout") {
            logOnce(
                "playlistRootLayout",
                "generated playlist (no PL.Header): header root = HeaderContentLayout itself"
            )
            return view
        }

        // ④ taurus 那一档：responder chain 上第一个 VC 的 view。
        var responder: UIResponder? = view
        var hops = 0
        while let current = responder, hops < 40 {
            hops += 1
            if let controller = current as? UIViewController, let root = controller.viewIfLoaded {
                logOnce(
                    "playlistRootVC",
                    "generated playlist (no PL.Header): header root = "
                        + "\(NSStringFromClass(type(of: controller))).view"
                )
                return root
            }
            responder = current.next
        }
        return nil
    }

    /// 这一页是不是**歌单页**（普通 / This Is / 电台都算）。
    ///
    /// taurus 的判据：responder chain 上**第一个 VC** 的类名含 `FreeTierPlaylist`。这里多认一条
    /// `PL.Header` 祖先 —— 普通歌单页那条路走的就是这个祖先，不让它因为 VC 换名而失效。
    ///
    /// ⚠️ 只看类名、不看 id：`ThisIsArtistHeaderPluginImpl` 那类插件页头**没有** id 可看。
    /// ⚠️ 判据**故意只收 `FreeTierPlaylist`**：这一条同时管着"要不要藏 Spotify 自己那颗 Play"
    /// （`concealPlayButtonIfNeeded`）—— 收得太宽（比如把 `Station` 也算进来），
    /// 万一那页根本没有我们的页头，就会变成"按钮被藏了、我们那颗又没画"。
    static func isPlaylistPage(of view: UIView) -> Bool {
        if ancestor(of: view, identifier: "PL.Header") != nil { return true }
        var responder: UIResponder? = view
        var hops = 0
        while let current = responder, hops < 60 {
            hops += 1
            if current is UIViewController,
               NSStringFromClass(type(of: current)).contains("FreeTierPlaylist") {
                return true
            }
            responder = current.next
        }
        return false
    }

    // MARK: - 页头的 z 序与几何（"封面挡住自画的字"那两类）
    //
    // 把承载我们文字的 view **连它到 `root` 的每一层**都提到最上（祖先链提升）。
    //
    // 只在**我们自己这一层** `bringSubviewToFront` 不够 —— 封面 / 渐变的宿主常常是"我们所在
    // 那一层的**兄弟**"，甚至更高一层（歌单页：我们挂在 `block` 里，封面是 `PL.Header` 的另一个
    // 子视图；专辑页：封面是 `CreativeWorkHeader` 的另一个子视图）。
    // Spotify 每次重建页头都会把这些层**重新插到我们上面**（它的布局方块不认我们的顺序）
    // ⇒ 每拍沿祖先链逐层提一次，幂等、最多 8 层。第一次发现"有人在我们上面"时记一行类名。
    static func raiseToTop(_ view: UIView, in root: UIView, role: String) {
        var node: UIView? = view
        var levels = 0
        var above: [String] = []
        while let current = node, current !== root, levels < 8 {
            if let parent = current.superview {
                if parent.subviews.last !== current {
                    if above.count < 2,
                       let last = parent.subviews.last {
                        above.append(NSStringFromClass(type(of: last)))
                    }
                    parent.bringSubviewToFront(current)
                }
            }
            node = current.superview
            levels += 1
        }
        guard !above.isEmpty else { return }
        let list = above.joined(separator: ", ")
        logOnce(
            "raised_" + role + "_" + String(describing: ObjectIdentifier(view)),
            "\(role): something sat above our header text (\(list)) — raised our block to the top"
        )
    }

    /// 文字压到封面时"我们要往下让多少"（存在**我们那一份**上）。
    ///
    /// 我们这一份是**贴底排**的（`y = bounds.height - contentBottom - contentHeight`）⇒
    /// **只把它自己加高**（不碰 Spotify 的任何视图）就能让文字整体下移，直到落在封面下面。
    /// 值由 `probeCoverOverlap` 维护：自然位置不再重叠时清回 0，不会累积。
    static var coverDropKey: UInt8 = 0
    static let coverDropLimit: CGFloat = 140

    static func coverDrop(of headerView: EntityPageHeaderView) -> CGFloat {
        guard let value = (objc_getAssociatedObject(headerView, &coverDropKey) as? NSNumber)?.doubleValue
        else { return 0 }
        return CGFloat(value)
    }

    /// "封面压到我们的文字带了吗" —— 命中时记一行（两边的帧都换算到 `headerView` 里）。
    ///
    /// z 序已由 `raiseToTop` 保证我们在最上，所以这里捕的是**几何上的打架**（封面下缘伸进
    /// 文字带 ⇒ 字压在封面上、或封面的阴影糊住字）。
    ///
    /// 两条约束，缺一个就会把内容推出页头：
    /// · 用 `textTop - currentDrop`（**没加过 drop 的自然位置**）量 ⇒ 同一个封面位置永远得到
    /// 同一个目标值，不会累加；
    /// · 没有重叠时把 drop **清回 0**（`fullbleed` 那种假重叠已由调用方挡掉，这里清的是
    /// "滚动过程中量到、现在已经不成立"的那一截）。
    ///
    /// 还要**先看我们那一行字在不在页头里**（`root`）：页头收起时整块文字被搬到页头上面（屏幕外），
    /// 那时封面换算出来的底边会落到很远的下方，量出来的"重叠"能有几百 pt ⇒ drop 一路顶到上限，
    /// 内容被推下去一大截。
    ///
    /// `anchored`：我们的底边已经被锚在列表第一行上沿（`y = 底边 - 高度`）时，`coverDrop` 已经
    /// 被那个 `y` 吸收掉了 —— 这时文字的自然位置就是 `headerView.textTop` 本身，**不能再减一次**
    /// `current`，否则量出来的重叠会多出一个 drop，越量越大。
    static func probeCoverOverlap(
        cover: UIView?,
        headerView: EntityPageHeaderView,
        root: UIView,
        anchored: Bool,
        role: String
    ) {
        guard let cover, headerView.bounds.height > 1, headerView.window != nil else { return }
        // 只在页头高度**稳定**的那一拍量。滚动中页头每帧都在变高/变矮，而这段代码会反过来改
        // 页头高度（`+ coverDrop`）⇒ 量一次、改一次、下一拍又量到不同的值 ⇒ 按钮每帧上下跳。
        // 中途保持上一次的 drop，停下之后这一拍再收敛。
        let currentHeight = Double(headerView.bounds.height)
        let lastHeight = (objc_getAssociatedObject(headerView, &coverProbeHeightKey) as? NSNumber)?.doubleValue
        objc_setAssociatedObject(
            headerView,
            &coverProbeHeightKey,
            NSNumber(value: currentHeight),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        if let lastHeight, abs(currentHeight - lastHeight) > 1 { return }

        // `textTop` 用 -1 表示"没有标题"，但**标题上沿正好压在本视图顶边**时也是 -1 ⇒
        // 不能拿 `textTop > 0` 当判据（那种页会被整段跳过）。先问 `hasTitle`，再把 -1 夹成 0 继续量。
        guard headerView.hasTitle else { return }
        let current = coverDrop(of: headerView)
        // **两边都在 `root` 里量**。这一条是关键：原来封面换算到 `headerView` 坐标、文字也用它自己的
        // 坐标，而 `headerView` 的高度里就含 `coverDrop` ⇒ 它一变高，封面的换算值跟着变，"自然位置"
        // 根本不稳定：量到重叠 → 加 drop → 下一拍量到更大的重叠 → 一路顶到 140pt 上限。
        // 在 `root` 里量时，文字的绝对位置与 drop 无关（贴底排 + 底边固定）⇒ 量一次就收敛。
        let naturalTextTop = anchored ? headerView.textTop : max(0, headerView.textTop - current)
        let textTopInRoot = headerView.convert(CGPoint(x: 0, y: naturalTextTop), to: root).y
        // 我们那一行字**不在页头里**（收起 / 正在收起）⇒ 没有"被封面压到"这回事，这一拍不动。
        guard textTopInRoot >= -1, textTopInRoot <= root.bounds.height else { return }
        let coverRect = cover.convert(cover.bounds, to: root)
        let overlap = coverRect.maxY - textTopInRoot
        guard overlap > 1, coverRect.minY < root.bounds.height else {
            // 自然位置下没有重叠 ⇒ 之前那截 drop 已经不需要了（多半是滚动中途量到的）。
            guard current > 2 else { return }
            objc_setAssociatedObject(
                headerView,
                &coverDropKey,
                NSNumber(value: 0),
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
            logOnce(
                "coverDropClear_" + role + "_" + String(describing: ObjectIdentifier(headerView)),
                "\(role): the cover no longer overlaps our text — cleared the extra \(Int(current.rounded()))pt"
            )
            return
        }
        let wanted = min(coverDropLimit, max(0, overlap))
        // 2pt 的滞回 —— 1pt 级的变化不算"需要挪"（那几个 pt 正是抖动的来源）。
        guard abs(wanted - current) > 2 else { return }
        let coverBottom = Int(coverRect.maxY.rounded())
        let textLine = Int(textTopInRoot.rounded())
        logOnce(
            "coverOverlap_" + role + "_" + String(describing: ObjectIdentifier(headerView)),
            "\(role): the cover reaches \(coverBottom)pt but our text starts at \(textLine)pt"
                + " — they overlap; moving our block down to \(Int(wanted.rounded()))pt"
        )

        // 艺人页的"字压图"是**故意**的（AM 就是那样）⇒ 只对专辑 / 歌单页动手。
        guard role != "artist" else { return }
        objc_setAssociatedObject(
            headerView,
            &coverDropKey,
            NSNumber(value: Double(wanted)),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        logOnce(
            "coverDrop_" + role + "_" + String(describing: ObjectIdentifier(headerView)),
            "\(role): our text sat \(Int(overlap.rounded()))pt inside the cover"
                + " — moved our block down \(Int(wanted.rounded()))pt"
                + " (only our own view grew; Spotify's views are untouched)"
        )
    }

    /// 把 `⋯` **钉在页头的右上角**（照 AM，与返回键同高）。
    ///
    /// AM 在那一格放的是"**分享 + ⋯**"的玻璃胶囊；而 **Spotify 的专辑页/艺人页没有独立的分享按钮**
    /// —— `ShareButton*`（`ShareButtonNowPlayingView` / `lyrics-share-button`）只出现在听歌页与
    /// 歌词页，专辑页与艺人页的分享是 `⋯` 菜单里的一项。所以这里**只做 `⋯` 一颗**，
    /// 不去造一颗点不动的假分享键（纪律：绝不留下"看得见、点不动"的东西）。
    ///
    /// 藏 Spotify 行里那颗走 `wrapperFor`（连它的圆底一起）—— 否则同一页上会出现两颗 `⋯`。
    static func pinMoreButton(in headerRoot: UIView) {
        // 先记下落点：`EntityPageAppearance.tick` 每 0.6s 靠它重钉（见 `refreshPinnedMore`）。
        // 放在最前面 —— 这一页的 `⋯` 可能还没建出来，那一拍也得把落点记住。
        currentHeaderRoot = headerRoot
        // 走 `findControl`：根因与播放键是同一个 —— 按 id 拿到的是 `ElementView<…>` 包装层。
        guard let menu = findControl("Components.UI.ContextMenuButton*", in: headerRoot, cache: &cachedMore) else {
            // 这一页没有 `⋯`（或者还没建出来）⇒ 什么都不做，**也不留一颗假的**。
            //
            // 但要留一行日志：`pinnedMore` 是**文件级静态**、一旦建出来就留在屏上 ——
            // "Spotify 重建了页头、源失效"会留下一颗永远点不动、也没有任何痕迹的按钮。
            // 这一行能分清"这一页没有 ⋯" 与 "有，但源丢了"。
            if let stale = pinnedMore, stale.window != nil, !didReportPinnedMoreMissing {
                didReportPinnedMoreMissing = true
                writeDebugLog(
                    "[EntityPageHeader] pinned ⋯ is still on screen but Spotify's ContextMenuButton is gone"
                        + " — the button has no source and will do nothing"
                )
            }
            return
        }
        didReportPinnedMoreMissing = false

        let side = EntityPageHeaderMetrics.pinnedMoreSide
        let more: EntityPageHeaderButton
        if let existing = pinnedMore {
            more = existing
        } else {
            more = EntityPageHeaderButton()
            more.accessibilityIdentifier = "eevee-pinned-more"
            pinnedMore = more
            writeDebugLog(
                "[EntityPageHeader] pinned the ⋯ into the top trailing corner, level with the back button"
                    + " (AM's corner; Spotify keeps its own ⋯ hidden in the row)"
            )
        }
        // **挂到 window 上，不再塞进页头**：塞进页头时它要么被页头/导航栏盖住、
        // 要么根本不在一条能收到触摸的链上。
        // window 是最后加、最上面的一层：位置用 window 坐标算，不会被页头折叠带走。
        // 离开实体页时由 `EntityPageAppearance.restore` 调 `removePinnedMore` 收走。
        guard let host = headerRoot.window else { return }
        if more.superview !== host {
            host.addSubview(more)
        } else if host.subviews.last !== more {
            host.bringSubviewToFront(more)
        }

        // 与左上角那颗返回键同高：window 坐标 + 安全区。
        let top = host.safeAreaInsets.top + 4
        let frame = CGRect(
            x: host.bounds.width - side - 16,
            y: top,
            width: side,
            height: side
        )
        if more.frame != frame { more.frame = frame }
        if !didReportPinnedMoreGeometry {
            didReportPinnedMoreGeometry = true
            let inWindow = more.convert(more.bounds, to: host)
            writeDebugLog(
                "[EntityPageHeader] pinned ⋯ geometry — host window \(Int(host.bounds.width))x\(Int(host.bounds.height)),"
                    + " safeTop \(Int(host.safeAreaInsets.top)), button at \(Int(inWindow.minX)),\(Int(inWindow.minY)),"
                    + " interactive \(more.isUserInteractionEnabled), hidden \(more.isHidden)"
            )
        }
        more.feed(from: menu)
        // 三件事一起补上：
        // ② **`fireTarget = menu`**：转发目标从**弱引用** `source` 换成这颗真实控件 ——
        // `source` 一旦被回收（Spotify 重建页头）就变成一颗**静默失效**的按钮；
        // ③ `firesDeep = true`：前三档都落空时再往祖先链/选中回调那一档找（见 `eeveeFireWide`）。
        //
        // **不能跳过 target/action**（`skipsControlAction = false`）：这颗按钮有
        // `touchUpInside → EncoreControlEventHandler`，跳过它就只能落到手势那一档，而手势读不出
        // `_targets` ⇒ `fired: NOTHING`。触发顺序：`primaryActionTriggered` → `touchUpInside` →
        // 都没有才 `accessibilityActivate`。
        //
        // 另外**不能把源控件藏死**：`eeveeConceal`（`layer.isHidden` + 空 mask）会留下一个
        // **hidden** 的视图，UIKit 侧拿不到可用的锚点，菜单弹不出来。见下面 `eeveeBlank`。
        more.role = "more"
        more.fireTarget = menu
        more.skipsControlAction = false
        more.firesDeep = true

        // **只遮不藏**（`eeveeBlank`：空 mask + 关交互 + 关无障碍，`isHidden` 一个都不碰）——
        // 这颗按钮**必须还是一个"活着"的控件**，菜单才弹得出来。
        eeveeBlank(wrapperFor(menu, in: headerRoot))
    }

    /// **列表第一行的上沿**（换算到 `block` 坐标里）；认不出返回 nil。
    ///
    /// 只信 collection view 的 `visibleCells` —— 那些格子的帧是现成的，不需要额外布局，
    /// 滚动时自然跟着更新。页头自己那一格要排除：它装着 `block`，上沿在页头里面。
    static func firstRowTop(around headerRoot: UIView, in block: UIView) -> CGFloat? {
        guard let collection = eeveeEnclosingCollectionView(of: headerRoot) else { return nil }
        // 页头那一格的上沿：比它还高的格子（别的 section / 嵌套列表）不算"列表第一行"。
        var floorY: CGFloat = 0
        var node: UIView? = headerRoot
        var levels = 0
        while let current = node, levels < 8 {
            if current is UICollectionViewCell {
                floorY = current.convert(current.bounds, to: block).minY
                break
            }
            node = current.superview
            levels += 1
        }
        var top: CGFloat?
        for cell in collection.visibleCells {
            if cell === headerRoot || headerRoot.isDescendant(of: cell) || cell.isDescendant(of: block) {
                continue
            }
            let rect = cell.convert(cell.bounds, to: block)
            guard rect.height > 1, rect.maxY > 0, rect.minY >= floorY - 1 else { continue }
            top = min(top ?? .greatestFiniteMagnitude, rect.minY)
        }
        return top
    }

    /// **页头那一格有多高**（header slot 的宿主 cell）—— 只给日志用。
    ///
    /// 生成歌单的"按键压到列表第一行"要分清是哪一种：我们的内容比那一格高（`need > host`），
    /// 还是那一格本身就和 `headerRoot` 的高度对不上（排在它后面的列表因此提前开始）。
    static func slotDescription(of root: UIView) -> String {
        var node: UIView? = root
        var level = 0
        while let current = node, level < 5 {
            if current is UICollectionViewCell || current is UITableViewCell {
                let kind = NSStringFromClass(type(of: current))
                let frame = current.convert(current.bounds, to: root.window ?? current)
                return "\(kind) \(Int(frame.minY.rounded()))h\(Int(frame.height.rounded()))"
            }
            node = current.superview
            level += 1
        }
        return "none (\(NSStringFromClass(type(of: root))))"
    }

    /// 把隐藏的搜索框那一行的**真实 frame / 父链 / 滚动 offset / topInset** 打一次，
    /// 用来分清"空档是那一行的高度"还是"contentInset 多了一截"，再决定折高度还是改 offset。
    static func reportPlaylistMetrics(headerRoot: UIView, findField: UIView) {
        guard !didReportPlaylistMetrics else { return }
        didReportPlaylistMetrics = true

        var chain: [String] = []
        var node: UIView? = findField
        var level = 0
        while let current = node, level < 4 {
            let frame = current.convert(current.bounds, to: headerRoot)
            chain.append(
                "\(NSStringFromClass(type(of: current)))"
                    + " \(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))"
            )
            node = current.superview
            level += 1
        }

        let scroll = eeveeOutermostScroll(from: headerRoot)
        let offset = scroll.map { "\(Int($0.contentOffset.x)),\(Int($0.contentOffset.y))" } ?? "-"
        let inset = scroll.map { "\(Int($0.adjustedContentInset.top))" } ?? "-"
        let host = headerRoot.window ?? headerRoot
        let headerFrame = headerRoot.convert(headerRoot.bounds, to: host)
        writeDebugLog(
            "[EntityPageHeader] playlist find-field chain — \(chain.joined(separator: " < "));"
                + " scroll offset=\(offset) topInset=\(inset);"
                + " PL.Header \(Int(headerFrame.minY))h\(Int(headerFrame.height))"
        )
    }

    /// 离开实体页时把挂在 window 上的 `⋯` 收走（见 `pinMoreButton`）。
    ///
    /// ⚠️ **不要在这里清 `currentHeaderRoot`**：清掉之后，只有**布局回合**能把它写回来，
    /// 而 `⋯` 的保活正是为了"没有布局回合"的情形（页面开着不动）——
    /// 一次弹层（或菜单）把这个按钮收走，就再也不会自己回来。
    /// 落点失效由 `refreshPinnedMore` 的 `isDescendant(of:)` 判据挡住（换页时它一定不成立）。
    static func removePinnedMore(reason: String = "") {
        guard let more = pinnedMore else { return }
        more.removeFromSuperview()
        pinnedMore = nil
        didReportPinnedMoreMissing = false
        didReportPinnedMoreGeometry = false
        writeDebugLog(
            "[EntityPageHeader] pinned ⋯ removed"
                + (reason.isEmpty ? "" : " (\(reason))")
        )
    }

    /// 「我们那一份页头**现在真的在最前面那一页上**」—— `⋯` 的保活判据。
    ///
    /// 只看 `currentHeader.window != nil` 不够：设置页 / 其它弹层是**盖在同一个 window 上**的一层，
    /// 页头的视图还留在窗口里（只是被盖住）⇒ 判成"还在"就会把那颗 `⋯` 一直提到弹层上面。
    /// 所以还要沿 responder chain 问一遍"这一页的哪个 VC 弹了东西"。
    static func isHeaderOnScreen() -> Bool {
        guard let header = currentHeader, let window = header.window else { return false }
        guard !header.isHidden, header.alpha > 0.01 else { return false }
        guard header.convert(header.bounds, to: window).intersects(window.bounds) else { return false }
        // 盖着别的页面（设置页 / 弹层）时，`⋯` 不能浮上去。
        //
        // ⚠️ 只问 `window.rootViewController.presentedViewController` 不够：弹层可以由**任何一个**
        // VC 发起（设置页就是从它自己的 VC 弹的）⇒ 从页头往上走 responder chain，碰到每个 VC 都问一遍。
        var node: UIResponder? = header
        var hops = 0
        while let current = node, hops < 80 {
            hops += 1
            if let controller = current as? UIViewController {
                var presented = controller.presentedViewController
                while let next = presented {
                    // `⋯` 自己打开的菜单就是一个 presented VC（`ContextMenuViewController`）——
                    // 那是这颗按钮的菜单，不是"盖住这一页"的另一页：菜单开着时把按钮摘掉，关掉之后
                    // 又要等下一拍钉回来，中间会闪一下 ⇒ 这一类 presenter 不算遮挡。
                    if !NSStringFromClass(type(of: next)).contains("ContextMenu") { return false }
                    presented = next.presentedViewController
                }
            }
            node = current.next
        }
        return true
    }

    /// **`⋯` 的每拍保活** —— 由 `EntityPageAppearance.tick`（0.6s 一拍）调用。
    ///
    /// `⋯` 挂在 window 上，而钉它的 `apply` 只在**布局回合**里跑 —— 停在页面上不动时一个布局回合
    /// 都没有。旧版 `tick` 那句"没有实体页就收走"用的又是 `EntityPageAppearance.currentTarget()`，
    /// 它认不出**生成歌单**（电台 / This Is / 音乐全览：页头是插件拼的、封面也没有那两个 id）
    /// ⇒ 每 0.6s 把 `⋯` 摘一次，只有布局回合才被 `apply` 重新钉回来。
    ///
    /// 现在：页头还在屏上 ⇒ 留在 window 上并**重钉一次**（位置 / z 序 / 源控件都跟着最新状态，
    /// 幂等）；页头走了（包括被弹层盖住）⇒ 收走。
    static func refreshPinnedMore() {
        guard isHeaderOnScreen(),
              let root = currentHeaderRoot, root.window != nil
        else {
            removePinnedMore(reason: "the entity page is gone")
            return
        }
        // 落点必须**恰好装着**我们那一份页头：换页时 `apply` 还没跑、旧落点还在窗口里的话，
        // 这一句能挡住"把上一页的页头当成这一页"。
        guard let header = currentHeader, header === root || header.isDescendant(of: root) else {
            removePinnedMore(reason: "our header is no longer in that root")
            return
        }
        pinMoreButton(in: root)
    }

}
