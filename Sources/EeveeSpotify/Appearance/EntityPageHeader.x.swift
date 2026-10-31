import Foundation
import Orion
import UIKit
import ObjectiveC.runtime

/// 关联对象的键。**必须放在文件作用域**：`&变量` 取到的地址要稳定且唯一
/// （同 `DeclutterChrome.x.swift` 的 `declutterHiddenByUsKey`）。
var entityPageHeaderKey: UInt8 = 0

/// 上一拍量"封面压没压到文字"时这个页头的高度。
///
/// `probeCoverOverlap` 会改我们那一块的高度（`header.bounds.height + coverDrop`），而滚动中页头
/// 每帧都在变高变矮 ⇒ 量到的重叠每帧不同，`coverDrop` 就在 0 / 4 / 6 之间来回翻，按钮跟着上下跳。
/// 只在页头高度**稳定**时量一次，滚动中途保持上一次的值。
var coverProbeHeightKey: UInt8 = 0

/// 页头替换：找到歌单页头、藏掉 Spotify 那一列、把 `EntityPageHeaderView` 摆上去。
///
/// 挂 `HeaderContentLayout`：它是那一块的布局视图，每一拍折叠/展开都走 `layoutSubviews`
/// ⇒ 一个挂点覆盖"首次出现 / 滚动折叠 / 内容晚到"三种时机。`SPTFreeTierPlaylistEncoreHeaderViewController`
/// 在 9.1.88 上已不存在（歌单头改由 `ListUXPlatform_FreeTierPlaylistImpl` 的 slot/element 拼出来），
/// 故不用它；计数器晚到由"每一拍重读文本"覆盖。
///
/// 作用域只到歌单页：`headerRoot` 必须是 `PL.Header`（该 id 只在歌单页出现）。专辑页共用同一个
/// `HeaderContentLayout`，但头部结构与控件 id 都不同 ⇒ 走 `applyToAlbumPage` 那条独立的路。
///
/// 安全阀：认不出标题就整块不动（`apply` 早退，一个视图都不藏）。任何一环失配 = "没生效"，
/// 而不是"歌单页坏了"。
enum EntityPageHeaderManager {

    static var isEnabled: Bool { UserDefaults.entityPageAMHeader }

    private static var applying = false
    private static var logged = Set<String>()

    /// 每一拍的耗时（50 / 200 / 800 拍各报一次）。
    private static let meter = PerfMeter("EntityPageHeader")

    /// 页头每一拍要用的那几个视图**缓存下来**。
    ///
    /// `SGRFindByIdentifier` 带一个 `static char` key —— 命中一次之后每拍只做"还在不在"的检查。
    /// 原来每拍 5 次全树 BFS（shuffle / play / save / download / 协作者）+ 3~4 次文本遍历，
    /// 而页头在快速滑动时每帧都在折叠（`layoutSubviews` 每帧一次）⇒ 那些搜索全落在主线程上。
    private static var cachedShuffle: UIView?
    private static var cachedPlay: UIView?
    private static var cachedTrailing: UIView?
    private static var cachedCreatorLink: UIView?
    /// 封面元素与"那一块文字"也缓存 —— 这两次原来是**每帧**各一次整棵子树搜索
    /// （`eeveeFindView(layout, "Components.Header.UI.ArtworkImage")` / `blockIn(layout,…)`）。
    private static var cachedCover: UIView?
    private static var cachedBlock: UIView?
    /// 我们**当前这一页**画出来的那份页头（弱引用）。
    ///
    /// 只给 `playlistPageDidLayout` 用：那一拍判断"主挂点是不是已经在干活" —— 是就什么都不做，
    /// 免得每 0.5s 白扫一遍整棵页面树。
    private static weak var currentHeader: EntityPageHeaderView?
    /// 页面级备用入口的节流（BFS 最多 1500 个节点，不能每帧跑）。
    private static var lastPlaylistProbe: CFAbsoluteTime = 0
    /// 页头里那几个大圆头像（见 `headerAvatars`）—— 这一拍是每帧的，按 `layout` 缓存，换页才重扫。
    private static weak var artworkScannedLayout: UIView?
    private static var cachedArtwork: [UIView] = []
    /// 歌单页头里那个「在此页面上查找」搜索框（AM 页头接管后不该留着）。
    private static var cachedFindField: UIView?
    /// 上一拍认下的那四个标签（见 `TextViews`）。
    private static var cachedTextViews: TextViews?
    /// 专辑页那条路（`applyToAlbumPage`）：头容器、封面、三个文字容器，以及"kind·日期那行晚到"
    /// 的重试计数。**全部走缓存** —— 这一拍同样是每帧级的。
    private static var cachedAlbumHeader: UIView?
    private static var cachedAlbumCover: UIView?
    private static var cachedAlbumTitleRow: UIView?
    private static var cachedAlbumParentRow: UIView?
    private static var cachedAlbumMetadata: UIView?
    private static var albumRetryKey: UInt8 = 0

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

    private static var albumConcealedBranches: [AlbumConcealedBranch] = []
    private static let albumConcealedBranchLimit = 8
    /// "封面还没建出来就先藏了头"只报一次。
    private static var didLogAlbumBlindConceal = false
    /// 封面晚到时重跑 `applyToAlbumPage` 的计数（按页面记账）。
    ///
    /// 只靠 `layoutSubviews` 不保险 —— 页头建完之后可能不再有布局回合，封面到了也没人把
    /// "被整支藏掉的分支"放回来。这里最多补 8 次（≈1.6s）。
    private static var albumCoverRetryKey: UInt8 = 0

    /// 艺人页那条路（见 `applyToArtistPage`）：名字、月听众那行、照片、Follow —— 同样全走缓存。
    private static var cachedArtistName: UIView?
    private static var cachedArtistMeta: UIView?
    private static var cachedArtistCover: UIView?
    private static var cachedArtistFollow: UIView?
    /// 艺人页左边那颗 `i` 的转发目标：**艺人简介卡**（`CreatorBiographyCard`）。
    private static var cachedArtistBio: UIView?
    /// Follow 点击后的延迟复查要用这两样（见 `refreshArtistFollow`）。
    /// 都是**弱引用**：离开艺人页之后不该把整页留住。
    private static weak var lastArtistPage: UIView?
    private static weak var lastArtistHeaderView: EntityPageHeaderView?

    /// 艺人页标签栏的**原值**记录（关开关时逐个写回）。
    /// 视图一律弱引用 —— 离开艺人页之后不该把整页/滚动视图留住。
    private final class ArtistStripPageState {
        weak var scroll: UIScrollView?
        let enabled: Bool
        let transform: CGAffineTransform

        init(scroll: UIScrollView) {
            self.scroll = scroll
            enabled = scroll.isScrollEnabled
            transform = scroll.transform
        }
    }

    private final class ArtistStripState {
        weak var strip: UIView?
        let alpha: CGFloat
        let interactive: Bool
        let accessibilityHidden: Bool
        let pages: [ArtistStripPageState]

        init(strip: UIView, pages: [ArtistStripPageState]) {
            self.strip = strip
            alpha = strip.alpha
            interactive = strip.isUserInteractionEnabled
            accessibilityHidden = strip.accessibilityElementsHidden
            self.pages = pages
        }
    }

    private static var artistStripState: ArtistStripState?
    /// 从页面根出发那条兜底搜索**每页只试两拍**（见 `applyToArtistPage`）——
    /// 这两个数就是它的记账（换页清零；主力是 `ArtistBiographyViewHook`）。
    private static weak var artistBioSearchPage: UIView?
    private static var artistBioSearchPasses = 0
    /// **读到过的艺人简介**按艺人名缓存（那一块是懒加载的，读一次就够；cell 一被回收文字就没了）。
    private static var bioTexts: [String: String] = [:]
    /// 现在这一页的艺人名（`applyToArtistPage` 每拍写）—— "我们自己的艺人介绍"拿它当标题。
    private static var artistNameStorage = ""

    static var currentArtistName: String { artistNameStorage }

    /// 读到的简介（没有就是 nil）。
    static func cachedBioText(for name: String) -> String? { bioTexts[name] }

    /// **Spotify 自己那条数据线**（`SPTArtistAboutDataLoader`）交出的 `SPTArtistAbout` ——
    /// "关于艺人"的**权威正文 + 真链接**。
    ///
    /// 与"从界面拼文字"的区别：**正文**就是模型的 `biographyText` 字段，艺人名 / "每月有 x 名听众"
    /// 那两行根本不在里面，不需要任何"猜哪一行不是正文"的判据；**完整**：界面 label 会被
    /// `is_async_biography_truncation_enabled` 截断，这个字段不会；**链接**是 `SPTArtistSocialLink`
    /// 上的 `wikipedia` / `twitter` … 都是 `NSURL`，直接就是艺人真地址。
    ///
    /// 线程：completion 可能在后台队列 ⇒ 只在这儿读模型（纯 ObjC 读，安全），落库一律切主线程。
    static func artistAboutDidLoad(_ about: AnyObject?) {
        guard let about = about as? NSObject else { return }
        // completion 可能在后台队列 ⇒ 只在这儿读模型（纯 ObjC 读，安全），落库切主线程。
        if Thread.isMainThread {
            storeArtistAbout(about)
        } else {
            DispatchQueue.main.async { storeArtistAbout(about) }
        }
    }

    /// 把模型落库（`bioTexts` / `bioLinks` 的其它读点都在主线程 ⇒ 这里必须主线程调）。
    ///
    /// **落库的 key 必须与所有读点一致**：`cachedBioText` / `cachedBioLinks` / `hasCapturedBio`
    /// 用的都是**页面上的艺人名**（`artistNameStorage`）。模型的 `artistName` 多数时候逐字相同，
    /// 但**不保证**（本地化 / 版本差异 / 空白与大小写）⇒ 只按模型名存就会出现
    /// "hook 装上了、日志也打了、卡片里却什么都没有"。
    /// 所以：**页面名为主**；模型名不同就再当别名存一份（两个读法都能命中）。
    private static func storeArtistAbout(_ about: NSObject) {
        let biography = eeveeArtistAboutBiography(from: about)
        let links = eeveeArtistAboutLinks(from: about)
        guard biography != nil || !links.isEmpty else {
            writeDebugLog("[ArtistBio] loader — the model carried neither a biography nor a link")
            return
        }

        let pageName = artistNameStorage.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelName = eeveeArtistAboutName(from: about)
        let primary = pageName.isEmpty ? (modelName ?? "") : pageName
        guard !primary.isEmpty else { return }

        let previous = bioTexts[primary]?.count ?? 0
        applyArtistAbout(biography: biography, links: links, to: primary)
        if let modelName, modelName != primary {
            applyArtistAbout(biography: biography, links: links, to: modelName)
        }

        if let biography {
            writeDebugLog(
                "[ArtistBio] loader — \(primary), biography \(biography.count) char"
                    + " (was \(previous))"
            )
        } else {
            writeDebugLog("[ArtistBio] loader — \(primary), biographyText missing on the model")
        }
        if !links.isEmpty {
            writeDebugLog(
                "[ArtistBio] loader links — \(links.map(\.kind).joined(separator: ","))"
                    + " (from the model, real URLs)"
            )
        }
    }

    /// `storeArtistAbout` 的落库那一半 —— **同一份数据可以写两个 key**。
    private static func applyArtistAbout(
        biography: String?,
        links: [(kind: String, url: URL)],
        to name: String
    ) {
        guard !name.isEmpty else { return }

        if let biography {
            let previous = bioTexts[name]?.count ?? 0
            // 已经有一份更长的（比如上次那页读到的）就不覆盖；否则以数据线为准。
            if biography.count >= previous {
                bioTexts[name] = biography
            }
        }

        guard !links.isEmpty else { return }
        var refs = bioLinks[name] ?? []
        for link in links {
            // 同一个 kind 只留一条。判据不能是"已有一条**带 URL** 的就跳过" —— 那样
            // 「页面扫描先存一条读不到 URL 的 wikipedia → 模型这一轮再进一条带真地址的
            // wikipedia」会**变成两条**，卡片上就是两颗"维基百科"（而卡片只取前三颗，
            // 还会把别的链接顶掉）。现在：同 kind 已存在时**用模型这条覆盖**（真地址只有
            // 模型有），已有真地址的则严格不再加。
            if let index = refs.firstIndex(where: { $0.kind == link.kind }) {
                if refs[index].url == nil {
                    refs[index] = ArtistBioLinkRef(
                        kind: link.kind,
                        title: eeveeArtistBioLinkTitle(for: link.kind),
                        url: link.url,
                        control: refs[index].control
                    )
                }
                continue
            }
            refs.append(
                ArtistBioLinkRef(
                    kind: link.kind,
                    title: eeveeArtistBioLinkTitle(for: link.kind),
                    url: link.url,
                    control: nil
                )
            )
        }
        bioLinks[name] = refs
    }

    /// 「关于艺人」那块里找到的**社交链接**（维基 / 推特 / …）—— 按艺人名存。
    ///
    /// Spotify 自己那一块里就有这些链接按钮，我们把整块折掉之后它们一起消失。现在**露头那一刻
    /// 就记下这些控件**（weak 引用），`ArtistBioSheet` 用它们画胶囊、点下去转发给控件本身
    /// （走 Spotify 自己的打开逻辑）。
    static func cachedBioLinks(for name: String) -> [ArtistBioLinkRef] { bioLinks[name] ?? [] }

    private static var bioLinks: [String: [ArtistBioLinkRef]] = [:]

    /// 在**一块子树**里把社交链接**认下来**（有界：默认 800 个节点、最多 6 条；空表不落库，
    /// 下一拍还能再试）。
    ///
    /// 这些按钮是 `SPTArtistExternalSocialLinkButton` / `…ButtonViewModel` / `SPTArtistSocialLink`，
    /// 点它走委托 `externalSocialLinkTappedForType:`。`ArtistBioSheet` 用记下的控件画胶囊、
    /// 点下去优先用读到的真链接。
    ///
    /// ⚠️ 起点给**页面根**（`eeveeArtistBioSearchRoot`）而不是只给那张卡：艺人页的
    /// `CreatorBiographyCardLayout` 里只有 bio / 头部 / 粉丝数 / "显示更多"，
    /// **没有**社交链接按钮 —— 只扫卡片会一条都收不到。
    private static func captureBioLinks(from root: UIView, name: String, limit: Int = 800) {
        var refs = bioLinks[name] ?? []
        guard refs.count < 6 else { return }

        var queue: [UIView] = [root]
        var visited = 0
        while !queue.isEmpty, visited < limit, refs.count < 6 {
            let view = queue.removeFirst()
            visited += 1
            if let hit = eeveeArtistBioLink(from: view),
               // 同一个 kind 只收一条：类名片段会同时命中那颗按钮与它的容器，
               // 不去重的话同一颗维基会画出两张胶囊。
               !refs.contains(where: { $0.control === view || (hit.kind != "link" && $0.kind == hit.kind) }) {
                refs.append(
                    ArtistBioLinkRef(kind: hit.kind, title: hit.title, url: hit.url, control: view)
                )
                writeDebugLog(
                    "[ArtistBio] link \(hit.kind) — url \(hit.url == nil ? "not readable" : "read")"
                        + ", title \(hit.title)"
                )
            }
            queue.append(contentsOf: view.subviews)
        }

        guard !refs.isEmpty else { return }
        bioLinks[name] = refs
        let kinds = refs.map(\.kind).joined(separator: ",")
        writeDebugLog("[ArtistBio] links found — \(kinds) (\(refs.count) control(s))")
    }

    /// 这一页的艺人简介**已经读到过**了吗 —— `EntityPageSectionDrop` 折叠「关于艺人」那一格之前要问它。
    ///
    /// 折叠与读取是**两条独立的线**：折叠按 `CreatorBiography` 认（认得对），读取按
    /// `SPTArtistAboutBiographyView` 认（这一版页面上没有）⇒ 那一格被折成 0 高、我们的卡片又读不到
    /// 文字，两边都看不到。现在读不到就**不折**（宁可留着 Spotify 那段）。
    static var hasCapturedBio: Bool {
        !artistNameStorage.isEmpty && bioTexts[artistNameStorage] != nil
    }

    /// 读到简介之后**主动让列表重排一次** —— 折叠的闸门是"读到了吗"（`EntityPageSectionDrop`），
    /// 而"这一格多高"只在布局时被问，所以读到那一刻不作废布局的话，折叠要等用户滚一下才生效。
    ///
    /// 有界：从页面往下最多走 600 个节点、最多作废 **4** 个 `UICollectionView`，一律 `async`，
    /// 不会在布局回合里递归（与 `EntityPageRepaint.scheduleRelayout` 同一条纪律）。
    private static func relayoutAfterBioCapture(in page: UIView) {
        var queue: [UIView] = [page]
        var visited = 0
        var invalidated = 0
        while !queue.isEmpty, visited < 600, invalidated < 4 {
            let view = queue.removeFirst()
            visited += 1
            if let collection = view as? UICollectionView {
                invalidated += 1
                DispatchQueue.main.async { collection.collectionViewLayout.invalidateLayout() }
            }
            queue.append(contentsOf: view.subviews)
        }
        writeDebugLog(
            "[EntityPageHeader] about-artist captured — asked \(invalidated) collection view(s) to re-lay out"
        )
    }

    /// 「Follow 那颗的子树」只打一次（见 `probeFollowSubtree`）。
    private static var didProbeFollow = false
    /// 简介卡是**懒加载**的（页面滚到"关于"那一段才建），所以某一拍找不到它**不能**就退回
    /// shuffle —— 那样的就永远是 shuffle。这里把**找到过的那颗控件**用 weak 记住
    /// （上一页释放后自动失效，下一页找到就替换），于是"只要见过一次 Info，之后每拍都还是 Info"。
    private static weak var artistBioControl: UIView?
    /// 右上角那颗 `⋯` —— Spotify 的菜单按钮（`Components.UI.ContextMenuButton-<hash>`）
    /// 与**我们自己画的那一颗**（`EntityPageHeaderButton` 复用：玻璃圆 + 字形 + 转发）。
    private static var cachedMore: UIView?
    private static var pinnedMore: EntityPageHeaderButton?
    /// 我们那颗 `⋯` 还在屏上、可 Spotify 的源已经没了 —— 只报一次（见 `pinMoreButton`）。
    private static var didReportPinnedMoreMissing = false
    /// `⋯` 挂到 window 之后，只报一次几何/可交互性（用来判断"点不到"是位置还是层级）。
    private static var didReportPinnedMoreGeometry = false
    /// 歌单页「在此页面上查找」那一行的容器/滚动几何，只报一次（治"进入后还能往上划"）。
    private static var didReportPlaylistMetrics = false
    /// 艺人页 section / cell 的文字探针（找「最新发行 / 艺人之选」，不用转储视图树）。
    private static weak var artistProbePage: UIView?
    private static var artistProbeReports = 0
    private static var artistProbeLastPass: CFAbsoluteTime = 0
    private static var artistProbeSignature = ""

    /// 尾部按钮的兜底字形：**做成常量** —— 这一拍在折叠的每一帧都会走到，
    /// 每拍 `UIImage(systemName:)` 造一张新的没有意义（与"字形只取一次"同一条纪律）。
    private static let plusGlyph = UIImage(systemName: "plus")
    private static let downloadGlyph = UIImage(systemName: "arrow.down")

    /// 先看缓存（**还要在原来那棵树里、还在窗口上**），没有再搜。
    private static func find(_ identifier: String, in root: UIView, cache: inout UIView?) -> UIView? {
        if let cached = cache, cached.window != nil, cached.isDescendant(of: root) { return cached }
        let found = eeveeFindView(root, identifier: identifier)
        cache = found
        return found
    }

    /// 同 `find`，但**钻到真正能响应点击的那颗控件**上。
    ///
    /// 按 id 找到的往往是 `ElementView<URL, Any, Any>` 那层**包装** —— 转发打在包装上就是没反应，
    /// `isSelected` 也恒假（永远不变绿）。所以 play / shuffle / follow 这些都必须走这条，
    /// 否则就是"日志说转发成功、界面一动不动"。
    ///
    /// 两条纪律：
    /// · **钻不到就退回原来那个**（宁可保持原样，也不要因为钻而把东西丢掉）；
    /// · 钻过一次**把钻到的那个写回缓存** —— 否则每拍都要在包装层里再走一趟子树。
    private static func findControl(_ identifier: String, in root: UIView, cache: inout UIView?) -> UIView? {
        let found = find(identifier, in: root, cache: &cache)
        guard let found, !(found is UIControl) else { return found }
        guard let control = firstControl(in: found) else { return found }
        cache = control
        return control
    }

    /// 只进日志：这颗控件**是什么类、是不是 `UIControl`** —— "有没有钻到真控件"就是这一行的答案。
    private static func describe(_ control: UIView?) -> String {
        guard let control else { return "missing" }
        let kind = NSStringFromClass(type(of: control))
        let tag = control is UIControl ? "UIControl" : "wrapper"
        return "\(kind)[\(tag)]"
    }

    // MARK: - 入口
    //
    // 从 `HeaderContentLayout` 的 `layoutSubviews` 调用 —— **快速滑动时每一帧一次**，
    // 所以整段用 `PerfMeter` 记着（50 / 200 / 800 拍各报一次耗时），性能回归才有判据。
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

        // 这两个原来是每帧各一次整棵子树搜索，走缓存（同上面那五个挂点）。
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
        if let fullbleed {
            fullbleedKept = fullbleedArtwork(in: fullbleed)
        }
        let fullbleedPicture = fullbleedKept.first

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
        // ⚠️ 普通歌单页 `y` **恒为 0**（原来就是这样；`coverDrop` 靠"加高"把文字往下推，
        // 改成负 y 会把那一段抵消掉）。只有兜底那条路才允许向上长。
        let frame = CGRect(
            x: round(x),
            y: isPLHeader ? 0 : min(0, block.bounds.height - height),
            width: headerRoot.bounds.width,
            height: height
        )
        if header.frame != frame { header.frame = frame }

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
            role: "playlist"
        )
        // 把三段高度打进日志（每页一次）：藏掉某一段之后留下的空白，靠它定位空在哪两段之间。
        logOnce(
            "playlistGeom_" + String(describing: ObjectIdentifier(headerRoot)),
            "playlist geometry — PL.Header \(Int(headerRoot.bounds.height.rounded()))pt,"
                + " block \(Int(block.frame.minY.rounded()))..\(Int(block.frame.maxY.rounded()))pt,"
                + " our block \(Int(header.frame.minY.rounded()))..\(Int(header.frame.maxY.rounded()))pt,"
                + " text top \(Int(header.textTop.rounded()))pt,"
                + " cover bottom \(cover.map { Int($0.convert($0.bounds, to: header).maxY.rounded()) } ?? -1)pt"
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
        if let fullbleed, !fullbleedKept.isEmpty {
            concealInside(fullbleed, keeping: fullbleedKept + artwork)
            logOnce(
                "hidFullbleedTitle",
                "full-bleed header: kept the picture (\(fullbleedKept.count) view(s)) and concealed"
                    + " everything else in that container — Spotify draws its big title in there,"
                    + " which is the second copy of the page title"
            )
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
        let play = findControl("header-play-button", in: headerRoot, cache: &cachedPlay)
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
    private static func playlistHeaderRoot(of view: UIView) -> UIView? {
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
    /// `PL.Header` 祖先 —— 普通歌单页那条路已经验证过，不让它因为 VC 换名而失效。
    ///
    /// ⚠️ 只看类名、不看 id：`ThisIsArtistHeaderPluginImpl` 那类插件页头**没有** id 可看。
    /// ⚠️ 判据**故意只收 `FreeTierPlaylist`**：这一条同时管着"要不要藏 Spotify 自己那颗 Play"
    /// （`concealPlayButtonIfNeeded`）—— 收得太宽（比如把 `Station` 也算进来），
    /// 万一那页根本没有我们的页头，就会变成"按钮被藏了、我们那颗又没画"。
    private static func isPlaylistPage(of view: UIView) -> Bool {
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

    /// 沿 superview 链往上找带某个 accessibility id 的祖先（含自己）。
    private static func ancestor(of view: UIView, identifier: String) -> UIView? {
        var node: UIView? = view
        var level = 0
        while let current = node, level < 40 {
            level += 1
            if current.accessibilityIdentifier == identifier { return current }
            node = current.superview
        }
        return nil
    }

    /// 这是不是**我们接管的那两种页面**里的视图：歌单页判 `PL.Header`（以及生成歌单那条类名判据），
    /// 专辑页判页面 root 的 id 或它的头容器 —— 都在祖先链上，走一次就够。
    private static func isEntityPage(of view: UIView) -> Bool {
        if isPlaylistPage(of: view) { return true }
        var node: UIView? = view
        var level = 0
        while let current = node, level < 24 {
            level += 1
            if let identifier = current.accessibilityIdentifier,
               identifier == "CreativeWorkPlatform.CreativeWorkTemplateView"
                || identifier == "CreativeWorkPlatform.Components.UI.CreativeWorkHeader" {
                return true
            }
            node = current.superview
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
    private static func raiseToTop(_ view: UIView, in root: UIView, role: String) {
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
    private static var coverDropKey: UInt8 = 0
    private static let coverDropLimit: CGFloat = 140

    private static func coverDrop(of headerView: EntityPageHeaderView) -> CGFloat {
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
    private static func probeCoverOverlap(cover: UIView?, headerView: EntityPageHeaderView, role: String) {
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
        let naturalTextTop = max(0, headerView.textTop - current)
        let frame = cover.convert(cover.bounds, to: headerView)
        guard frame.maxY > naturalTextTop + 1, frame.minY < headerView.bounds.height else {
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
        let overlap = frame.maxY - naturalTextTop
        let wanted = min(coverDropLimit, max(0, overlap))
        // 2pt 的滞回 —— 1pt 级的变化不算"需要挪"（那几个 pt 正是抖动的来源）。
        guard abs(wanted - current) > 2 else { return }
        let coverBottom = Int(frame.maxY.rounded())
        let textLine = Int(naturalTextTop.rounded())
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
        probeCoverOverlap(cover: cover, headerView: headerView, role: "album")

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

    // MARK: - 艺人页（**第三条路**）
    //
    // 艺人页页头：照片满幅铺到页面顶部并向页面底色渐隐，名字与月听众居中落在渐隐底部，
    // 下面一行 shuffle / 白色 Play 胶囊 / Follow（照 Apple Music）。
    //
    // 页面判据是 **`creator-page`**；页头容器是 `TemplateKit` 的 **`HeaderContainer`** ——
    // 那个容器**身上没有 accessibility id**，只能按类名认。
    //
    // ⚠️ 两个**绝不能动**的地方：
    // · 这里**只用空 mask 藏东西、绝不设 hidden** —— 页头在 `OverflowStackView` 里，
    // 一行里最"高"的视图被 hidden 时它会 force-unwrap nil 并 trap（见 `eeveeBlank`）；
    // · **不要强制** `…context_menu_in_navigation_bar_enabled_artist` 那个 flag（同一个 trap）。
    //
    // 真机树（`creator-page` dump）：
    //
    // ```
    // 14.TemplateView@0,0,414,896,id=creator-page
    // 15.UIView@0,0,414,896,id=CreativeWorkPlatform.Tab      ← 和专辑页同一个容器（要清底）
    // 16.UIScrollView…id=PCFFTabLayoutViewController.containerScrollView
    // 17.UIStackView@0,0,414,1416
    // 18.HeaderContainer@0,0,414,520                        ← hero 宿主（420 与 584 两档都出现过）
    // 19.ElementView<URL,Any,Any>@0,420,414,100
    // 20.ImageHeaderView@0,0,414,100
    // 22.ShadowContainer@0,0,414,414,alpha=-0.15,id=Components.Header.UI.ArtworkImage  ← 照片，全宽 414
    // 22.GradientView@0,-100,414,200                        ← 照片上那层渐变（同样要藏）
    // 22.AdaptiveTitle@0,-154,382,212,id=Encore.AdaptiveTitle   ← 名字
    // 21.UIStackView@16,-16,107,24,id=ImageHeaderView.VerifiedBadge
    // 23.OBJC_ONLY_Label@0,0,326,18,id=Components.Header.UI.Metadata  ← "xx 月听众"
    // 22.OverflowStackView@0,0,290,48                       ← ⚠️ 就是它（在里面 hidden 会 trap）
    // 23.ElementView<URL,Any,Any>@0,4,58,40                 ← Follow（`Encore.Button.Secondary`，"关注"）
    // 24.EncoreButton@0,0,48,48,id=Components.UI.ContextMenuButton-…
    // 22.ElementView<URL,Any,Any>@338,0,68,48               ← play（`header-play-button`）
    // 22.HeaderNavigationBar@0,0,414,100 > 23.GradientView@0,0,414,100
    // 18.UIView@0,520,414,896,id=PCFFTabLayoutViewController.tabsViewAccessibilityID
    // 19.UIView@0,0,414,44,id=Components.UI.TabsSectionHeading  ← Music / Video / Merch
    // ```
    //
    // 注意 `HeaderContainer` 是 **520 / 584pt**、照片是 **414×414 全宽**；Follow 那一行在
    // `OverflowStackView` 里 —— 也就是"藏 header 里的东西不能碰 hidden"这条在本机同样成立。
    static func applyToArtistPage(_ page: UIView) {
        guard isEnabled, !applying else { return }
        guard page.accessibilityIdentifier == "creator-page" else {
            // 先分清"这一页不是艺人页"与"它是艺人页、但根 id 不叫 creator-page"。
            // 后者是我们漏接管，这一行会给出真实 id。
            if eeveeFindView(
                page,
                identifier: "Curation.FollowButtonElementKit.FollowButton",
                maxNodes: 800
            ) != nil {
                let rootID = page.accessibilityIdentifier ?? "nil"
                logOnce(
                    "artistRootMismatch",
                    "artist-like page ignored — root id is \(rootID), not creator-page"
                )
            }
            return
        }
        guard page.bounds.width > 120, page.bounds.height > 200 else { return }
        guard let header = artistHeaderContainer(in: page), header.bounds.height > 80 else { return }

        applying = true
        defer { applying = false }

        // 标签栏是一颗开关（默认藏，见 `UserDefaults.artistHideTabs`）。
        if UserDefaults.artistHideTabs {
            hideArtistTabStrip(in: page)
        } else {
            restoreArtistStrip()
        }

        // 名字：`Encore.AdaptiveTitle`（45pt）；拿不到就退回"字号最大的那个标签"（与歌单页同一条兜底）。
        var name = ""
        if let title = find("Encore.AdaptiveTitle", in: header, cache: &cachedArtistName),
           let label = firstLabel(in: title, skipping: nil) {
            name = label.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        if name.isEmpty, let label = biggestLabel(in: header, skipping: []) {
            name = label.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        guard !name.isEmpty else {
            logOnce("noNameArtist", "artist page: no name found — leaving Spotify's header alone")
            return
        }

        // 记下艺人名（`i` 那张"我们自己的艺人介绍"拿它当标题）。
        //
        // **换了一位艺人 ⇒ 上一页记下的专辑目标立刻作废**：否则点新页面上的卡片会去打开
        // **上一位艺人**的专辑 —— 那是这张卡最不能犯的错。
        //
        // 也不要指望"扫列表读简介"（延后读 + 定时补读）：那一段是懒加载的，不滚到就不建，
        // 零滚动读到的永远是空。
        if !artistNameStorage.isEmpty, artistNameStorage != name {
            clearWebReleaseURI(reason: "the page moved on to another artist")
        }
        artistNameStorage = name

        // 副标题：`Components.Header.UI.Metadata`（形如 "58,4M monthly listeners"）。
        var meta = ""
        if let metadata = find("Components.Header.UI.Metadata*", in: header, cache: &cachedArtistMeta) {
            meta = metadataLine(metadata)
        }

        // 我们那一份：铺在**整个页头容器**上（`setFrame(info, header.bounds)`，内容贴底）。
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
        currentHeader = headerView
        // Follow 状态复查要能找回"这一页 / 这个页头"（见 `refreshArtistFollow`）。
        lastArtistPage = page
        lastArtistHeaderView = headerView
        if headerView.onTrailingTapped == nil {
            headerView.onTrailingTapped = { EntityPageHeaderManager.refreshArtistFollow() }
        }
        // **只有这一页的页头会缩**（520 → 100pt 的导航栏）⇒ 也只有这一页要那条"装不下就渐隐让位"。
        // 歌单/专辑页的页头是定高的，给它打开只会把整块内容弄没。
        headerView.fadesWhenTight = true
        // **贴底 0**（不是默认的 14）⇒ 姓名与那三颗整体下移 14pt，与 AM 的页头对齐
        // （见 `contentBottom` 那段）。
        if headerView.contentBottom != 0 { headerView.contentBottom = 0 }

        // 取这一位艺人的最新发布。优先级：
        // · **艺人之选**是 Spotify 自己的板块，只能从页面里读（`captureArtistPick`）；
        // · 读不到（多半是没滚到 / 这位艺人没有那一块）⇒ 退回 `ArtistLatestReleaseSource`。
        scheduleLatestRelease(for: headerView, name: name)
        // 「艺人之选」优先：它就在同一页上（懒加载板块），滚到那一块时读一次就换掉卡片内容。
        captureArtistPick(in: page)
        // 「热门新歌」那一块也在同一页上 ⇒ 卡片的数据**从页面读**；苹果目录只当最后兜底
        // （见 `scheduleLatestRelease`）。
        captureLatestRelease(in: page)
        // 那一块在列表很下面、懒加载 ⇒ 布局拍停掉之后就没人再读了（见 `startReleasePolling`：
        // 这就是"刚进没有、重进才有"的根因）。
        startReleasePolling(in: page, name: name)
        // 卡片的触摸交给 manager 转发给页面里那一张真卡（`handleReleaseCardTap`）——
        // 卡片挂在页头下面那一格，`onTap` 在 `releaseCardHost(for:)` 里就接好了。
        // 进页后替显示更多（原地铺开这一段 → 那条黑带与半截行都不再出现）。
        scheduleSectionExpansion(in: page)

        // Spotify 那一列：**空 mask 藏**（不碰 hidden —— 见函数头那段）。照片归 `EntityPageAppearance`。
        let cover = find("Components.Header.UI.ArtworkImage", in: header, cache: &cachedArtistCover)
        blankArtistChrome(in: header, avoiding: cover, skipping: headerView)

        // z 序与几何两道保险。
        raiseToTop(headerView, in: header, role: "artist")
        probeCoverOverlap(cover: cover, headerView: headerView, role: "artist")

        // 月听众那行是一颗开关（默认保留）。`meta` 仍算出来给日志用。
        headerView.update(
            title: name,
            creator: "",
            length: UserDefaults.artistHideListeners ? "" : meta,
            about: ""
        )

        // 三颗：shuffle / play / Follow。那一行会随 `ImageHeaderView` 一起缩成 100pt 的导航栏，
        // 所以和专辑页一样：浮动控件从**页面**找，Follow 是页头那一行里的文字按钮。
        //
        // 三颗**全部走 `findControl`** —— 按 id 拿到的都是 `ElementView<…>` 包装层，
        // 转发打在包装上 = 没反应，`isSelected` 也恒假。
        let play = findControl("header-play-button", in: page, cache: &cachedPlay)
        let shuffle = findControl("Components.UI.ShuffleButton", in: page, cache: &cachedShuffle)
        let follow = findControl(
            "Curation.FollowButtonElementKit.FollowButton",
            in: header,
            cache: &cachedArtistFollow
        ) ?? eeveeFindView(header, identifier: "FollowButton*").map { firstControl(in: $0) ?? $0 }
        // Follow 是**文字按钮**（"关注" / "已关注"），取不到字形 ⇒ 用一对 SF Symbol 兜底，
        // 而且按它的选中态换字形 —— 状态因此看得见。
        //
        // 左边那颗照 AM 换成 Info。**不要找 `Components.UI.CreatorBiographyCard*`** ——
        // 那是听歌页的"了解艺人"卡，艺人页上根本没有它（那样会永远退回 shuffle）。
        // 艺人页真正的"关于艺人"是 **`SPTArtistAboutBiographyView`**：
        //
        // 382 = 414−32（列表行的内缩），两种高度就是"收起 / 展开"。它**没有 accessibility id**，
        // 只能按**类名**认 ⇒ `eeveeFindView(_:classNameContains:)`。旧 id 那条留着当第二顺位。
        // 缓存失效的三个条件都要看：**没找到过 / 已经不在窗口上 / 换了一页**。
        let bioStale = cachedArtistBio == nil
            || cachedArtistBio?.window == nil
            || !(cachedArtistBio?.isDescendant(of: page) ?? false)
        // **这条 BFS 只在前两拍试**：`SPTArtistAboutBiographyView` 落在**深度 20**，从页面根搜要走掉
        // 几千个节点，而且它在页面刚打开时往往还没建出来。主力是 `ArtistBiographyViewHook`
        // （那个类出现即认下，事件驱动、零搜索），这里只剩"钩子还没触发时"的兜底。
        if artistBioSearchPage !== page {
            artistBioSearchPage = page
            artistBioSearchPasses = 0
        }
        if bioStale, artistBioSearchPasses < 2 {
            artistBioSearchPasses += 1
            // 判据用**真机证实过的那三个名字**（见 `eeveeArtistBioCard`）。不要把这个类排在
            // 第一判据 —— 它在这一版艺人页上一次都没出现过，排前面会让后面那条 id 前缀永远轮不到。
            cachedArtistBio = eeveeArtistBioCard(in: page)
                ?? eeveeFindView(page, classNameContains: "SPTArtistAboutBiographyView")
        }
        if let info = cachedArtistBio, let control = firstControl(in: info) { artistBioControl = control }
        // **记住找到过的那颗**（见 `artistBioControl`）—— 那一块是懒加载的，
        // 某一拍没有它不代表该退回 shuffle。
        let leading = artistBioControl

        // 判据用 `eeveeIsOn` 而不是只看 `(follow as? UIControl)?.isSelected` —— 三条信号一起看
        // （`isSelected` / 无障碍里的 `.selected` / 文字里的"已关注"），四条都进日志（`eeveeOnSignals`）。
        let followed = eeveeIsOn(follow)
        headerView.updateRow(
            shuffle: leading ?? shuffle,
            play: play,
            trailing: follow,
            // 未关注 ⇒ `star`（SF Symbol 的 star 本来就是中空）+ **强制用兜底字形**
            // （不采用 Spotify 那颗自己的"＋人"图）；已关注 ⇒ Spotify 自己的绿勾优先，
            // 取不到才用 `checkmark` 兜底。
            trailingFallback: UIImage(systemName: followed ? "checkmark" : "star"),
            trailingPrefersFallback: !followed
        )
        // **左边那颗永远是 `i`**，不因为"那一块还没建出来"退回 shuffle 的样子；**动作**落在
        // "关于艺人"上（`setLeadingTarget`），目标没建出来时点它只会把页面往下滚一屏去把它滚出来，
        // **绝不退回去做随机播放**。随机播放改挂**长按播放键**（见 `updatePlayLongPress`）。
        //
        // **转发目标用"关于艺人"那一块本身**（`cachedArtistBio`，不是它里面第一颗 `UIControl`）——
        // 处理它的那一层在**祖先链**上，配合 `eeveeFireWide`（再往上 6 层 + cell 的选中回调）才走通。
        headerView.setLeadingTarget(cachedArtistBio, glyph: UIImage(systemName: "info.circle"))
        headerView.updatePlayLongPress(shuffle)
        headerView.updateCreatorLink(nil)

        // 把 Follow 那颗的子树打一次，
        // 看"已关注"到底画在哪个类上、状态挂在哪个属性上。只打一次。
        probeFollowSubtree(follow)

        eeveeBlank(play)
        eeveeBlank(shuffle)
        eeveeBlank(follow)
        eeveeBlank(leading)

        // 把 `⋯` 钉到右上角去（照 AM）。
        pinMoreButton(in: header)

        // 日志要说清三件事 ——
        // · **左边那颗到底是谁**（简介卡 / 找不到简介卡退回的 shuffle / 压根没有）；
        // · 三颗各自**钻到了什么类**（`[UIControl]` = 真控件、`[wrapper]` = 还是包装层）；
        // · follow 的四条状态信号（哪一条真的会随"已关注"变，下一份日志就看出来了）。
        let leadingKind = leading == nil
            ? "MISSING (button still shows i; tapping scrolls the page to build it)"
            : (leading === shuffle ? "shuffle-fallback" : "about(SPTArtistAboutBiographyView)")
        let followNote = follow == nil ? "missing" : (followed ? "following" : "follow")
        logOnce(
            "appliedArtist",
            "artist page — name \"\(name)\", meta \"\(meta.isEmpty ? "-" : meta)\""
                + ", leading \(leadingKind)"
                + ", play \(describe(play))"
                + ", shuffle \(describe(shuffle))"
                + ", follow \(followNote) \(describe(follow))"
                + ", followSignals \(eeveeOnSignals(follow))"
        )

        // 找「最新发行 / 艺人之选」用（用户不想开转储视图树）。
        probeArtistPageSections(in: page)
    }

    /// （播放按键和热门歌曲中间塞个方框……最新发布歌曲 / 艺人之选）：
    /// 把艺人页里**每个 CollectionViewCell 的 y / 第一个文字 / ids** 按位置打出来，
    /// 每页最多 10 次、0.8s 节流、内容没变不重复。最新发行那一段时，
    /// 不用开转储视图树。
    private static func probeArtistPageSections(in page: UIView) {
        if artistProbePage !== page {
            artistProbePage = page
            artistProbeReports = 0
            artistProbeLastPass = 0
            artistProbeSignature = ""
        }
        guard artistProbeReports < 10 else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - artistProbeLastPass >= 0.8 else { return }
        artistProbeLastPass = now

        var cells: [(y: CGFloat, text: String, ids: String)] = []
        var queue: [UIView] = [page]
        var visited = 0
        while !queue.isEmpty, visited < 2000 {
            let view = queue.removeFirst()
            visited += 1
            if NSStringFromClass(type(of: view)).contains("CollectionViewCell") {
                var ids: [String] = []
                var idQueue: [UIView] = [view]
                var idVisited = 0
                while !idQueue.isEmpty, idVisited < 40 {
                    let child = idQueue.removeFirst()
                    idVisited += 1
                    if let id = child.accessibilityIdentifier, !id.isEmpty { ids.append(id) }
                    idQueue.append(contentsOf: child.subviews)
                }
                let text = eeveeControlText(of: view).prefix(40)
                let frame = view.convert(view.bounds, to: page)
                cells.append((
                    y: frame.minY,
                    text: String(text),
                    ids: ids.prefix(6).joined(separator: ",")
                ))

                // cell 里那些**可能**是"最新发行 / 艺人之选"的类（Release / Carousel /
                // SectionHeading / Pick / Card）也单独列出来 —— 它们的 id 可能为空，
                // 但类名 + 文字足够下一轮定位。每格最多 8 条。
                var interesting: [String] = []
                var innerQueue: [UIView] = [view]
                var innerVisited = 0
                while !innerQueue.isEmpty, innerVisited < 120, interesting.count < 8 {
                    let inner = innerQueue.removeFirst()
                    innerVisited += 1
                    let cls = NSStringFromClass(type(of: inner))
                    let hit = ["Release", "Carousel", "SectionHeading", "Pick", "Card"]
                        .contains { cls.localizedCaseInsensitiveContains($0) }
                    if hit {
                        let innerText = eeveeControlText(of: inner).prefix(30)
                        interesting.append("\(cls) [\(innerText)]")
                    }
                    innerQueue.append(contentsOf: inner.subviews)
                }
                if !interesting.isEmpty {
                    writeDebugLog(
                        "[ArtistPageProbe] matches y=\(Int(frame.minY)) — \(interesting.joined(separator: " | "))"
                    )
                }
            }
            queue.append(contentsOf: view.subviews)
        }

        cells.sort { $0.y < $1.y }
        let shown = Array(cells.prefix(14))
        let signature = shown
            .map { "\(Int($0.y))|\($0.text)|\($0.ids)" }
            .joined(separator: "||")
        guard !signature.isEmpty, signature != artistProbeSignature else { return }
        artistProbeSignature = signature
        artistProbeReports += 1

        for cell in shown {
            writeDebugLog(
                "[ArtistPageProbe] cell y=\(Int(cell.y)) ids=[\(cell.ids)] text=\(cell.text)"
            )
        }
    }

    /// **点击之后重新读一次 Follow 的状态**。
    ///
    /// 不能只靠 `applyToArtistPage` 的下一拍：`tapped` 里那次 `refreshTint` 发生在**转发之前**，
    /// 读到的是点击前的旧状态；而 Spotify 更新关注状态**不保证**会让页头再布局一次
    /// （现象就是"点关注不变绿、再点取消反而变绿"，迟了一整次点击）。
    ///
    /// 由 `EntityPageHeaderButton.afterFire` 在点击后 0.2 / 0.7 / 1.6 / 3.0 / 5.0s 各叫一次：
    /// 重新认一次控件（Spotify 可能整颗换掉）、读状态、换 `star` / `checkmark` 与绿色描边。
    static func refreshArtistFollow() {
        guard isEnabled else { return }
        guard let page = lastArtistPage, page.window != nil,
              let headerView = lastArtistHeaderView, headerView.window != nil else { return }

        // **每次都重新认**（清掉缓存再搜）：Spotify 换关注状态时可能整颗 Follow 重建，旧实例还挂在
        // 树上（只是被我们 blank 了）⇒ 只信缓存会一直读到旧值。一次点击最多搜 4 次，页头已建好。
        cachedArtistFollow = nil
        var follow: UIView?
        if let header = artistHeaderContainer(in: page) {
            follow = findControl(
                "Curation.FollowButtonElementKit.FollowButton",
                in: header,
                cache: &cachedArtistFollow
            ) ?? eeveeFindView(header, identifier: "FollowButton*").map { firstControl(in: $0) ?? $0 }
        }
        guard let follow else {
            logOnce("followRefreshMissing", "follow state after tap — the Follow control is not in the tree")
            return
        }

        cachedArtistFollow = follow
        let followed = eeveeIsOn(follow)
        headerView.updateFollow(
            followed: followed,
            glyph: UIImage(systemName: followed ? "checkmark" : "star"),
            source: follow
        )
        logOnce(
            "followRefresh-\(followed)",
            "follow state after tap — followed=\(followed); \(eeveeOnSignals(follow))"
        )
    }

    // MARK: - 「艺人之选」/「最新发布」卡片（艺人页三颗按钮下面那张）
    //
    // 「艺人之选」读到的样子（标题 + 副标题 + 封面）。
    private struct ArtistPick {
        let title: String
        let meta: String?
        let artwork: UIImage?
    }

    private static var artistPickCache: [String: ArtistPick] = [:]
    private static var didLogArtistPick = false
    /// 每一位艺人只发一次"最新发布"请求（数据源自己还有 TTL 缓存与在飞去重）。
    private static var releaseArtist: String?

    /// 找"某个标题行**下面那一格**"——「艺人之选」与「热门新歌」共用同一套。
    ///
    /// 这两个板块都是 **Spotify 自己的**、苹果目录里没有 ⇒ 只能从页面里读。它们和其它懒加载板块
    /// 一样：**没滚到就不存在**，所以每拍做一次**有界**尝试（≤1800 节点 / 深 14）：找到标题就取它
    /// 下面那一格（同 section 的下一格，或下一个 section 的第一格）的封面 + 最长的一段文字 +
    /// 次长的一段。找到才换，找不到就继续用最新发布（**绝不拿猜出来的东西冒充**）。
    ///
    /// **不要**拿艺人的名字去问苹果的目录：那一套既受商店地区影响（`cn` 目录对某些艺人 0 条），
    /// 又受罗马字/假名影响（`Nanatsukaze` vs `ナナツカゼ`）—— 全是页面里本来没有的问题。
    ///
    /// - Returns: 那一格 + 它的 `IndexPath`（索引只进日志）。
    private static func sectionCard(
        in page: UIView,
        headingMatches: (String) -> Bool
    ) -> (cell: UIView, path: IndexPath)? {
        var queue: [(view: UIView, depth: Int)] = [(page, 0)]
        var visited = 0

        // 900 / 12 在现在的艺人页（列表很长、每张卡十几层）不够 —— 标题行明明在屏幕上，BFS 预算
        // 就先用完了 ⇒ 一直读不到「热门新歌」/「艺人之选」，卡片只能落到兜底。1800 / 深 14 仍然有界。
        while !queue.isEmpty, visited < 1800 {
            let (view, depth) = queue.removeFirst()
            visited += 1

            if let label = view as? UILabel,
               let text = label.text,
               !text.isEmpty,
               headingMatches(text) {
                // ⚠️ `enclosingCell` 返回 `UIView?`（它同时认 table cell），而 `indexPath(for:)`
                // 只吃 `UICollectionViewCell` ⇒ 必须显式转一次。
                guard let ancestor = enclosingCell(of: label),
                      let cell = ancestor as? UICollectionViewCell,
                      let collection = eeveeEnclosingCollectionView(of: cell),
                      let indexPath = collection.indexPath(for: cell) else { return nil }

                var candidates: [IndexPath] = []
                if indexPath.item + 1 < collection.numberOfItems(inSection: indexPath.section) {
                    candidates.append(IndexPath(item: indexPath.item + 1, section: indexPath.section))
                }
                if indexPath.section + 1 < collection.numberOfSections,
                   collection.numberOfItems(inSection: indexPath.section + 1) > 0 {
                    candidates.append(IndexPath(item: 0, section: indexPath.section + 1))
                }
                for candidate in candidates {
                    if let next = collection.cellForItem(at: candidate) {
                        return (next, candidate)
                    }
                }
                return nil
            }

            guard depth < 14 else { continue }
            queue.append(contentsOf: view.subviews.map { ($0, depth + 1) })
        }
        return nil
    }

    /// 「艺人之选」/「热门新歌」那一行里**第一张小卡**（横向 carousel 的 cell）。
    ///
    /// 卡片显示的是哪一张，点击就必须转发给**那一张** —— 所以数据与点击目标都取这同一颗，
    /// 而不是整条 carousel 的宿主格。
    private static func firstNestedCell(in view: UIView) -> UIView? {
        var queue: [UIView] = view.subviews
        var visited = 0
        while !queue.isEmpty, visited < 400 {
            let node = queue.removeFirst()
            visited += 1
            if node is UICollectionViewCell { return node }
            queue.append(contentsOf: node.subviews)
        }
        return nil
    }

    /// 卡片现在指向的那一格（点击转发目标）。**弱引用** —— 换页/重排之后它可能已经没了。
    private static weak var releaseCardSource: UIView?
    /// 那一格属于**哪位艺人**。换了艺人但页面还留在导航栈里时，旧格子的 `window` 仍然非空
    /// ⇒ 只靠弱引用/`window` 判断会转发到上一页，这里再按名字卡一道。
    private static var releaseCardSourceName: String?

    /// 记下"卡片现在的目标"（数据与点击共用同一格）。
    private static func setReleaseCardSource(_ card: UIView, name: String) {
        releaseCardSource = card
        releaseCardSourceName = name
    }

    static func captureArtistPick(in page: UIView) {
        let name = currentArtistName
        guard !name.isEmpty else { return }
        if artistPickCache[name] != nil {
            if !didLogArtistPick, let pick = artistPickCache[name] {
                didLogArtistPick = true
                writeDebugLog("[Release] artist pick cached — \(pick.title)")
            }
            return
        }

        guard let found = sectionCard(in: page, headingMatches: isPickHeading) else { return }
        let card = firstNestedCell(in: found.cell) ?? found.cell
        guard let pick = makePick(from: card) else { return }
        artistPickCache[name] = pick
        setReleaseCardSource(card, name: name)
        writeDebugLog(
            "[Release] artist pick — \(pick.title)"
                + " (from \(found.path.section),\(found.path.item))"
        )
        if let headerView = lastArtistHeaderView, currentArtistName == name {
            applyPick(pick, to: headerView)
        }
    }

    // MARK: - 「最新发布」：先读页面自己那一块

    private static var releaseSectionCache: [String: ArtistPick] = [:]
    /// 每页试了几次"读页面那一块"——**只进日志**（真的闸门是 `scheduleLatestRelease` 里的墙钟）。
    private static var releaseSectionMisses: [String: Int] = [:]
    private static var didLogReleaseSection = false

    /// 那一块在 Spotify 里叫什么（多语言各写一条，与 `isPickHeading` 同一个思路）。
    private static func isReleaseHeading(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let needles = [
            "热门新歌", "最新发布", "新发布", "新发行", "发行作品",
            "popular releases", "new releases", "latest release", "new music", "releases",
            "新曲", "最新リリース", "リリース",
        ]
        return needles.contains { lowered.contains($0) }
    }

    /// 这张卡片的数据**从页面里读**（同一套 `sectionCard`，与「艺人之选」共用）：
    ///
    /// * 封面 = 那一格里的第一张像样的图，标题 / 副标题 = 那一格里最长 / 次长的两段文字；
    /// * **不问网络** ⇒ 没有"商店地区没这首歌"、也没有"罗马字 vs 假名对不上"这两类问题。
    ///
    /// 页面那一块是懒加载的（滚到才建出来）⇒ 每拍**机会式**看一次，读到就画；
    /// 一直读不到才由 `scheduleLatestRelease` 落到兜底。
    static func captureLatestRelease(in page: UIView) {
        let name = currentArtistName
        guard !name.isEmpty else { return }
        if releaseSectionCache[name] != nil {
            if !didLogReleaseSection, let release = releaseSectionCache[name] {
                didLogReleaseSection = true
                writeDebugLog("[Release] latest release from the page — \(release.title)")
            }
            return
        }

        releaseSectionMisses[name] = (releaseSectionMisses[name] ?? 0) + 1

        guard let found = sectionCard(in: page, headingMatches: isReleaseHeading) else { return }
        let card = firstNestedCell(in: found.cell) ?? found.cell
        guard let release = makePick(from: card) else { return }
        releaseSectionCache[name] = release
        // 卡片显示的就是这一张小卡 ⇒ 点击转发给它（`handleReleaseCardTap`）。
        setReleaseCardSource(card, name: name)
        writeDebugLog(
            "[Release] latest release from the page — \(release.title)"
                + " (from \(found.path.section),\(found.path.item))"
        )
        if let headerView = lastArtistHeaderView, currentArtistName == name {
            applyPick(release, to: headerView)
        }
    }

    /// 卡片被点了一下。
    ///
    /// 卡片不编目标，**转发给页面里那一张真卡** —— `eeveeSelectAncestorCell` 走的是
    /// `collectionView(_:didSelectItemAt:)`（真人点卡那一条），所以落地页与 Spotify 自己完全一致
    /// （专辑 / 单曲就进那一张，不会跑到「全部歌曲」）。
    ///
    /// 页面那一行是**懒加载骨架**、卡片的数据来自 Web API 时，页面上**没有**可转发的那一格 ——
    /// 这时用记下来的**专辑 URI**走 App 自己的链接分发器（`SpotifyURIOpener.open`）。
    /// 三档顺序固定：还在页面上的那一格 → 重新找到的那一格 → 专辑 URI。
    ///
    /// 三档都不成立（换页 / 数据不属于这一页 / URI 也被清了）就**什么都不做**，只留一行日志。
    private static func handleReleaseCardTap() {
        let name = currentArtistName

        // ① 页面里那一格还在、而且确实属于**这一页**的艺人 ⇒ 照旧转发给它。
        if releaseCardSourceName == name, let source = releaseCardSource, source.window != nil {
            let path = eeveeSelectAncestorCell(of: source)
                ?? eeveeActivate(source)
                ?? "NOTHING"
            writeDebugLog("[Release] card tapped — fired: \(path)")
            return
        }

        // ② 那一格被列表回收了（"热门新歌"在列表很下面，页头滚回去时它可能已经没了）
        // ⇒ 先按**标题行**重新找一次（原逻辑），找到就转发。
        if releaseCardSourceName == name,
           let headerView = lastArtistHeaderView,
           let page = eeveeAncestor(withIdentifier: "creator-page", of: headerView),
           let found = sectionCard(in: page, headingMatches: isReleaseHeading) {
            let card = firstNestedCell(in: found.cell) ?? found.cell
            releaseCardSource = card
            let path = eeveeSelectAncestorCell(of: card)
                ?? eeveeActivate(card)
                ?? "NOTHING"
            writeDebugLog("[Release] card tapped — re-found the page row, fired: \(path)")
            return
        }

        // ③ 卡片的数据来自 **Web API**（页面上那一行还是骨架）⇒ 用记下来的专辑 URI 打开。
        // ⚠️ 只认"这一页的艺人"记下的那个 URI（换页之后不能去开上一位艺人的专辑）。
        guard releaseAlbumArtist == name, let uri = releaseAlbumURI, !uri.isEmpty else {
            writeDebugLog(
                "[Release] card tapped — no page row and no album uri for \"\(name)\", nothing opened"
            )
            return
        }
        let opened = SpotifyURIOpener.open(uri)
        let resultText = opened ? "opened" : "NOT opened"
        writeDebugLog("[Release] card tapped — \(uri) \(resultText) through the link dispatcher")
    }

    // MARK: - 「显示更多」：进页替用户展开一次

    private static var expandScheduledPages = Set<ObjectIdentifier>()

    /// 那一颗是 Spotify 的 `Components.UI.ListSectionFooter.Button`：它把"热门"那一段截在 6 行，
    /// 底部再盖一条往黑的渐变（`ScrollGradientOverlay`）让胶囊读得清 —— 看到的就是
    /// **半截的第 6 行 + 一条黑带**。⇒ 进页后**替用户点一次**：原地铺开。
    ///
    /// 进页的 1 秒里列表还在长（`contentSize` 每拍都在变）⇒ 那一拍 footer 很可能**还没建出来**，
    /// 所以试三轮（1.0 / 2.5 / 5.0s），点到就停。每页只排一次。
    private static let expandAttemptDelays: [Double] = [1.0, 2.5, 5.0]

    private static func scheduleSectionExpansion(in page: UIView) {
        let key = ObjectIdentifier(page)
        guard !expandScheduledPages.contains(key) else { return }
        expandScheduledPages.insert(key)
        attemptSectionExpansion(in: page, attempt: 0)
    }

    private static func attemptSectionExpansion(in page: UIView?, attempt: Int) {
        guard let page, attempt >= 0, attempt < expandAttemptDelays.count else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + expandAttemptDelays[attempt]) { [weak page] in
            guard let page, page.window != nil else { return }
            if expandSectionFooters(in: page) { return }
            if attempt + 1 < expandAttemptDelays.count {
                attemptSectionExpansion(in: page, attempt: attempt + 1)
            } else {
                writeDebugLog(
                    "[EntityPageHeader] section expansion — no footer button after"
                        + " \(expandAttemptDelays.count) attempt(s)"
                )
            }
        }
    }

    /// 这一颗是不是"**原地展开**这一段"那颗 footer。
    ///
    /// ⚠️ 判据不能只看文字：`显示全部 / show all / see all / すべて表示` 是**导航**，不是展开 ——
    /// 那样会点到标签栏的主页键（`NavigationButtonHome`）、或者把页面导航到「全部歌曲」。
    /// 三条一起收：
    ///
    /// ① **必须**是 `ListSectionFooter` 那一族（id 里带这个词）—— 没有 id 的**一律不点**；
    /// ② 文字里要有"**更多**"（`更多 / more / もっと`）；
    /// ③ 文字里**不能**有"**全部**"（`全部 / all / すべて`）—— 那是"去完整列表"，点了就离开这一页。
    private static func isSectionFooter(_ control: UIControl) -> Bool {
        guard (control.accessibilityIdentifier ?? "").contains("ListSectionFooter") else { return false }
        // 文字两处都看：无障碍标签是一处，`UIButton.titleLabel` / 子树里的 UILabel 是另一处
        // （`eeveeControlText` 就是取后者 —— 自绘的 Encore 按钮往往只有它）。
        let text = [
            control.accessibilityLabel ?? "",
            control.accessibilityValue ?? "",
            eeveeControlText(of: control),
        ].joined(separator: " ").lowercased()
        guard !text.isEmpty else { return false }
        let expands = ["更多", "more", "もっと"].contains { text.contains($0) }
        let navigates = ["全部", "all", "すべて"].contains { text.contains($0) }
        return expands && !navigates
    }

    /// 点最多**两颗**「显示更多」；**点到了返回 true**（调用方据此停止重试）。
    ///
    /// ⚠️ 不要放宽到 4 颗 —— 页面上恰好有两颗 footer 时会连着导航两次（见 `isSectionFooter`）。
    private static func expandSectionFooters(in page: UIView) -> Bool {
        var found: [UIControl] = []
        var queue: [UIView] = [page]
        var visited = 0
        while !queue.isEmpty, visited < 1200, found.count < 2 {
            let view = queue.removeFirst()
            visited += 1
            if let control = view as? UIControl, isSectionFooter(control) {
                found.append(control)
                continue
            }
            queue.append(contentsOf: view.subviews)
        }

        guard !found.isEmpty else { return false }

        for control in found {
            let path = eeveeActivate(control) ?? "NOTHING"
            let identifier = String(describing: control.accessibilityIdentifier ?? "-")
            writeDebugLog("[EntityPageHeader] section expansion — \(path) on \(identifier)")
        }
        return true
    }

    /// 卡片挂在页头**下面**的那一格（见 `setReleaseCard`）。
    private static weak var releaseCardHost: UIView?
    /// 那一格的高度（有卡片 106，没有 0 —— 收成 0 时列表自然回到原位）。
    private static var releaseCardHeight: NSLayoutConstraint?
    private static weak var releaseCardView: EntityPageHeaderReleaseCard?
    /// 这一格属于哪一份页头（换页就重建）。
    private static weak var releaseCardOwner: EntityPageHeaderView?

    /// **卡片不画在页头里，而是挂到页头下面那一格**。
    ///
    /// 卡片若贴底排在 `EntityPageHeaderView` 内部（`contentHeight` 里多算 106pt），就得让
    /// 「页头容器长高 106pt」—— 但艺人页页头是 `UIStackView` 的 arranged subview
    /// （`UIStackView 414×1416` = `HeaderContainer 414×520` + 内容 `414×896`），改 `frame`
    /// 不会让 stack 重排 ⇒ 列表仍从 520 开始，卡片正好压在列表前两行上。
    ///
    /// 所以在 stack 里**页头之后**插一格（`releaseCardHost`，高度 106），卡片画在那一格里。
    /// stack 自己会把列表推下去，页头高度 / 标题 / 三颗 / 渐变全部回到原位。
    ///
    /// 认不出 stack（页头不在 stack 里）就只打一行日志、不画卡片：宁可没有卡片，也不要压住列表。
    static func setReleaseCard(
        for headerView: EntityPageHeaderView,
        title: String?,
        date: String?,
        meta: String?,
        artwork: UIImage? = nil,
        artworkURL: URL? = nil,
        isTappable: Bool = false
    ) {
        guard let title, !title.isEmpty else {
            hideReleaseCard()
            return
        }
        guard let host = releaseCardHost(for: headerView) else {
            logOnce(
                "releaseCardNoStack",
                "release card — the header is not an arranged subview of a stack,"
                    + " so the card is skipped instead of covering the list"
            )
            return
        }
        guard let card = releaseCardView else { return }
        if card.superview !== host { host.addSubview(card) }
        card.update(
            title: title,
            date: date,
            meta: meta,
            artwork: artwork,
            artworkURL: artworkURL
        )
        card.isTappable = isTappable
        if card.isHidden { card.isHidden = false }
        releaseCardHeight?.constant = EntityPageHeaderReleaseCard.spacing
            + EntityPageHeaderReleaseCard.height
    }

    /// 清掉卡片（换页 / 没数据）：把那一格收成 0 高，列表自然回到原位。
    private static func hideReleaseCard() {
        guard let card = releaseCardView else { return }
        card.isTappable = false
        if !card.isHidden { card.isHidden = true }
        if releaseCardHeight?.constant != 0 { releaseCardHeight?.constant = 0 }
    }

    /// 页头**下面**那一格（懒建）。返回 nil = 这页头的父层不是 stack，画不了。
    private static func releaseCardHost(for headerView: EntityPageHeaderView) -> UIView? {
        guard let container = headerView.superview else { return nil }
        guard let slot = stackSlot(for: container) else { return nil }

        if let owner = releaseCardOwner, owner !== headerView {
            // 换了一页 ⇒ 旧那一格留在旧页面的 stack 上，这里重新建一格。
            releaseCardHost?.removeFromSuperview()
            releaseCardHost = nil
            releaseCardHeight = nil
            releaseCardView?.removeFromSuperview()
            releaseCardView = nil
        }
        releaseCardOwner = headerView

        if let host = releaseCardHost, host.superview === slot.stack {
            return host
        }

        let host = UIView()
        host.backgroundColor = .clear
        host.accessibilityIdentifier = "eevee-entity-header-release-host"
        host.translatesAutoresizingMaskIntoConstraints = false
        let height = host.heightAnchor.constraint(equalToConstant: 0)
        height.isActive = true
        let index = min(slot.index + 1, slot.stack.arrangedSubviews.count)
        slot.stack.insertArrangedSubview(host, at: index)
        releaseCardHost = host
        releaseCardHeight = height

        let card = EntityPageHeaderReleaseCard()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.accessibilityIdentifier = "eevee-entity-header-release"
        card.isHidden = true
        // 点击往上交给 manager —— 由它转发给页面里那张真卡（`handleReleaseCardTap`）。
        card.onTap = { handleReleaseCardTap() }
        host.addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(
                equalTo: host.leadingAnchor,
                constant: EntityPageHeaderMetrics.side
            ),
            card.trailingAnchor.constraint(
                equalTo: host.trailingAnchor,
                constant: -EntityPageHeaderMetrics.side
            ),
            card.topAnchor.constraint(
                equalTo: host.topAnchor,
                constant: EntityPageHeaderReleaseCard.spacing
            ),
            card.heightAnchor.constraint(equalToConstant: EntityPageHeaderReleaseCard.height),
        ])
        releaseCardView = card

        writeDebugLog(
            "[Release] card host inserted after the header in "
                + NSStringFromClass(type(of: slot.stack))
        )
        return host
    }

    /// 往上找"把 `container` 当 arranged subview 的那个 stack"。
    private static func stackSlot(for container: UIView) -> (stack: UIStackView, index: Int)? {
        var node: UIView? = container
        var level = 0
        while let current = node, level < 4 {
            if let stack = current.superview as? UIStackView,
               let index = stack.arrangedSubviews.firstIndex(of: current) {
                return (stack, index)
            }
            node = current.superview
            level += 1
        }
        return nil
    }

    /// 每一位艺人只取一次「最新发布」（缓存优先 ⇒ 同步就能画）。
    ///
    /// 闸门用**墙钟**而不是"页头布局跑了几拍"：页头稳定之后就不再重排，拍数根本到不了设定值
    /// ⇒ 既读不到页面那一块、也不触发兜底，卡片会静默地永远不出现。进页 6 秒后还没有页面数据
    /// 就去问一次，并且**一定留一行日志**。
    private static var releaseSectionFirstSeen: [String: Date] = [:]
    private static let releaseFallbackDelay: TimeInterval = 6

    // MARK: - 「最新发布」：页面那一块是**懒加载**的，得有人按时去看

    private static var releasePollTimer: Timer?
    private static weak var releasePollPage: UIView?
    private static var releasePollDeadline: Date?
    private static var releasePollName = ""
    private static let releasePollInterval: TimeInterval = 1.5
    private static let releasePollLifetime: TimeInterval = 90

    /// **"时有时无"的根因** —— 卡片的数据要读页面里「热门新歌」那一块，而那一块在列表中很下面
    /// （标题在 **y≈1020pt**，窗口只有 896pt），Spotify 用的是**懒加载**：没滚到就一直是
    /// `RetrievalRowLoadingElementUI … 正在加载`。
    ///
    /// 而唯一的读取时机原来是**布局拍**（`applyToArtistPage` → `captureLatestRelease`）——
    /// 页头一旦稳定、列表不再重排，**布局拍就不来了** ⇒ 真正滚到那一块的时候没人去读。
    /// 同一个原因也会让它落到兜底，于是选错专辑（同名艺人）、而且不可点。
    ///
    /// ⇒ 进艺人页后**按 1.5 秒一拍去看 90 秒**（与布局拍无关）。读到就画，画完就变成
    /// 页面里那一格 ⇒ 数据对、点击也转发得动。
    static func startReleasePolling(in page: UIView, name: String) {
        if releasePollPage === page, releasePollTimer != nil, releasePollName == name { return }
        releasePollTimer?.invalidate()
        releasePollPage = page
        releasePollName = name
        releasePollDeadline = Date().addingTimeInterval(releasePollLifetime)

        let timer = Timer(timeInterval: releasePollInterval, repeats: true) { _ in
            guard let page = releasePollPage, page.window != nil,
                  currentArtistName == releasePollName else {
                releasePollTimer?.invalidate()
                releasePollTimer = nil
                return
            }
            if let deadline = releasePollDeadline, Date() > deadline {
                releasePollTimer?.invalidate()
                releasePollTimer = nil
                writeDebugLog(
                    "[Release] gave up looking for the page's own releases row"
                        + " after \(Int(releasePollLifetime))s"
                )
                return
            }
            captureLatestRelease(in: page)
            captureArtistPick(in: page)
            // 页面里那一行**一直是骨架**时，这一拍也顺手保证屏幕上那张卡有数据
            // （墙钟节流在里面；已经拿到 / 页面里已有数据时它立刻返回）。
            askSpotifyForLatestRelease(artist: releasePollName)
        }
        RunLoop.main.add(timer, forMode: .common)
        releasePollTimer = timer
    }

    private static func scheduleLatestRelease(for headerView: EntityPageHeaderView, name: String) {
        // ① 已经有"艺人之选"⇒ 卡片归它。
        if let pick = artistPickCache[name] {
            applyPick(pick, to: headerView)
            return
        }

        // ② 其次是**页面上那一块**（「热门新歌」/「最新发布」，见 `captureLatestRelease`）——
        // 这条不问网络。
        if let release = releaseSectionCache[name] {
            applyPick(release, to: headerView)
            return
        }

        // ③ **页面那一块只是骨架**（`RetrievalRowLoadingElementUI … 正在加载`），Spotify 懒加载，
        // 进页那一刻它**根本不存在** ⇒ 只读页面的数据线永远出不来卡片。这里补一条**不依赖页面**
        // 的数据线：用 `DataLoaderServiceHooks` 抓的令牌直接问 Spotify 自己的 Web API
        // （`ArtistReleasesFromSpotify`）。取回来的那一张连同**专辑 URI**一起画上去，
        // 于是卡片既显示得出来、也点得动（`handleReleaseCardTap` 用那个 URI 打开）。
        //
        // ⚠️ 页面里的数据永远优先：一旦 `captureLatestRelease` / `captureArtistPick` 读到那一格，
        // `applyPick` 会清掉这里的 URI（卡片与点击都回到页面那一格）。
        if let release = webReleaseApplied[name] {
            if webReleaseShownHeader !== headerView {
                applyWebReleaseCard(release, artist: name, headerView: headerView)
            }
            return
        }

        // ⛔ **不拿苹果目录的发布来填这张卡**。
        //
        // 苹果目录（iTunes）里只有标题 / 日期 / 封面，**没有 Spotify 的专辑目标** ⇒
        // `applyLatestRelease` 只能把卡片设成 `isTappable = false`，的就是
        // "数据像是 Apple 的、点下去没反应"。更糟的是同名艺人会被目录匹配到别人。
        // ⇒ 这一档不画任何死卡；页面那一块还没加载出来时由上面的 ③ 补上。
        // 真要恢复苹果目录，正确做法是拿到 Spotify 的发布 id，而不是再画一张死卡。
        if releaseArtist != name {
            headerView.updateRelease(title: nil, date: nil, meta: nil)
        }
        if releaseSectionFirstSeen[name] == nil {
            releaseSectionFirstSeen[name] = Date()
        }
        guard releaseArtist != name else { return }

        // 记下"这一页已经等过"，避免同一页每拍都写一行。
        releaseArtist = name
        if let waited = releaseSectionFirstSeen[name].map({ Date().timeIntervalSince($0) }) {
            writeDebugLog(
                "[Release] no page section after \(Int(waited))s —"
                    + " asking the Web API while the page's own row is still a skeleton"
            )
        }
        // 进页这一刻就把 Web API 那条请求发出去（墙钟节流在 `askSpotifyForLatestRelease` 里 ——
        // 布局拍每帧都来，不能每帧都问）。
        askSpotifyForLatestRelease(artist: name)
    }

    private static func applyLatestRelease(_ release: ArtistLatestRelease, to headerView: EntityPageHeaderView) {
        let date = release.date.map { ArtistLatestReleaseSource.cardDateFormat.string(from: $0) }
        let meta = release.trackCount > 0
            ? String(format: "artist_latest_release_tracks".localized, release.trackCount)
            : nil
        headerView.updateRelease(
            title: release.title,
            date: date,
            meta: meta,
            artworkURL: release.artworkURL,
            // 苹果目录里的发布在 Spotify 里没有对应目标 ⇒ **不可点**（不留看得见点不动的控件）。
            isTappable: false
        )
    }

    /// 页面里读到的卡片（「艺人之选」/「热门新歌」）—— 数据与目标都是那一格 ⇒ **可点**。
    private static func applyPick(_ pick: ArtistPick, to headerView: EntityPageHeaderView) {
        // **页面里的数据一到，Web API 那张卡立刻作废** —— 数据与点击都回到页面那一格。
        // 清的是**专辑 URI**，不动 `webReleaseApplied`
        // （离开再回来时还要能同步重画一次，见 `askSpotifyForLatestRelease`）。
        clearWebReleaseURI(reason: "the page's own row now provides the card")
        headerView.updateRelease(
            title: pick.title,
            date: nil,
            meta: pick.meta,
            artwork: pick.artwork,
            // 只有"目标还在、而且属于**这一页**的艺人"才可点（换页后旧格子可能还活着）。
            isTappable: releaseCardSource != nil && releaseCardSourceName == currentArtistName
        )
        // 卡片挂在页头下面那一格，页头高度不需要动（见 `releaseCardHost(for:)`）。
    }

    // MARK: - 「最新发布」：Spotify Web API 那条线（页面那一行是骨架时的数据源）
    //
    // 进艺人页时页面里那一行是 `RetrievalRowLoadingElementUI … 正在加载` 的**骨架**，
    // Spotify 懒加载 ⇒ 只读页面的数据线进页必然读不到。这一段补的就是那条**不依赖页面**的路：
    // `ArtistReleasesFromSpotify` 用抓到的令牌问 Spotify 自己的 Web API，拿回"这位艺人的最新一张"
    // + **专辑 URI**，于是卡片 ① 进页很快就出现，② 点得动（`SpotifyURIOpener.open`）。
    //
    // 纪律：页面里的数据（艺人之选 / 热门新歌）**永远优先**；一旦读到就清掉这里的 URI，
    // 卡片与点击都回到"转发给页面那一格"。
    //
    // 现在这张卡要打开的专辑（Web API 来源）。**必须与 `releaseAlbumArtist` 一起对得上当前页**。
    private static var releaseAlbumURI: String?
    private static var releaseAlbumArtist: String?
    /// 已经画到哪一份页头上 —— 同一份页头只画一次（`updateRelease` 会重启封面下载，不能每拍都来）。
    private static weak var webReleaseShownHeader: EntityPageHeaderView?
    /// 每位艺人取回来的那一张（**同步重画**用：离开再回来不用再问网络）。
    private static var webReleaseApplied: [String: SpotifyArtistRelease] = [:]
    /// 每位艺人上一次问接口的**墙钟**（布局拍每帧都来，不能每帧都问）。
    private static var webReleaseAskedAt: [String: Date] = [:]
    private static var webReleaseAskCount: [String: Int] = [:]
    private static let webReleaseRetryInterval: TimeInterval = 20

    /// 问一次 Web API（**墙钟节流**）。三道闸门：
    ///
    /// · 页面里已经有数据（艺人之选 / 热门新歌）⇒ 不问；
    /// · 这位艺人已经取回来过 ⇒ 只同步重画，不问；
    /// · 20s 之内问过 ⇒ 跳过（`webReleaseRetryInterval`；90s 的轮询因此最多问 4 次）。
    ///
    /// 由 `scheduleLatestRelease`（进页那一刻）与 `startReleasePolling` 的节拍各调一次。
    private static func askSpotifyForLatestRelease(artist: String) {
        guard isEnabled else { return }
        guard !artist.isEmpty else {
            writeDebugLog("[Release] spotify — no artist name on the page yet, not asking")
            return
        }
        // 页面里的数据优先。这一档**故意不写日志**：页面那条路自己已经有一行
        // （`latest release from the page — …` / `artist pick — …`），而这里的调用点是每拍级的。
        guard artistPickCache[artist] == nil, releaseSectionCache[artist] == nil else { return }

        if let release = webReleaseApplied[artist] {
            if let headerView = lastArtistHeaderView, headerView.window != nil,
               webReleaseShownHeader !== headerView {
                applyWebReleaseCard(release, artist: artist, headerView: headerView)
            }
            return
        }

        let now = Date()
        // 节流那一档**故意不打日志**：它在每一拍都会命中（每帧一行 = 把日志冲掉）。
        // "问过几次"由下面那行 `attempt N` 回答。
        if let asked = webReleaseAskedAt[artist], now.timeIntervalSince(asked) < webReleaseRetryInterval {
            return
        }
        webReleaseAskedAt[artist] = now
        let attempt = (webReleaseAskCount[artist] ?? 0) + 1
        webReleaseAskCount[artist] = attempt
        writeDebugLog("[Release] spotify — asking the Web API for \"\(artist)\" (attempt \(attempt))")

        // 回调契约：**主队列**（数据源保证；`applyWebRelease` 里还兜了一次）。
        ArtistReleasesFromSpotify.fetch(artist: artist) { release in
            applyWebRelease(release, artist: artist)
        }
    }

    /// 接口回来了（主队列）。取回来的那一张要**记住**（离开再回来同步重画），
    /// 但只有"还是这一页 + 页面里还没有数据 + 页头还在屏上"时才画。
    private static func applyWebRelease(_ release: SpotifyArtistRelease?, artist: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { applyWebRelease(release, artist: artist) }
            return
        }

        guard let release else {
            writeDebugLog(
                "[Release] spotify — \"\(artist)\": nothing usable, the card keeps waiting for the page row"
            )
            return
        }
        webReleaseApplied[artist] = release

        guard isEnabled else {
            writeDebugLog("[Release] spotify — \"\(artist)\": the artist page header is off, card not drawn")
            return
        }
        guard currentArtistName == artist else {
            writeDebugLog(
                "[Release] spotify — \"\(artist)\": the page moved on before the answer, kept for later"
            )
            return
        }
        guard artistPickCache[artist] == nil, releaseSectionCache[artist] == nil else {
            writeDebugLog("[Release] spotify — \"\(artist)\": the page row arrived first, keeping its card")
            return
        }
        guard let headerView = lastArtistHeaderView, headerView.window != nil else {
            writeDebugLog(
                "[Release] spotify — \"\(artist)\": the page is not on screen, stored for the next visit"
            )
            return
        }
        applyWebReleaseCard(release, artist: artist, headerView: headerView)
    }

    /// 把 Web API 的那一张画到卡片上 —— **可点**，目标就是它自己的专辑 URI。
    ///
    /// 三条守卫都是"绝不能画错"：页头还在树上、页面里的数据没抢走这张卡、
    /// 接口回的主艺人名与页面上那位**归一化后仍然相等**。
    private static func applyWebReleaseCard(
        _ release: SpotifyArtistRelease,
        artist: String,
        headerView: EntityPageHeaderView
    ) {
        guard headerView.window != nil, headerView.superview != nil else {
            writeDebugLog("[Release] spotify — \"\(artist)\": the header view left the tree, card not drawn")
            return
        }
        guard artistPickCache[artist] == nil, releaseSectionCache[artist] == nil else {
            writeDebugLog(
                "[Release] spotify — \"\(artist)\": the page row owns the card now, Web API result ignored"
            )
            return
        }
        let wanted = ArtistReleasesFromSpotify.normalized(artist)
        let arrived = ArtistReleasesFromSpotify.normalized(release.artistName)
        guard !arrived.isEmpty, arrived == wanted else {
            writeDebugLog(
                "[Release] spotify — \"\(artist)\": the answer names \"\(release.artistName)\","
                    + " not this page — no card (never guess)"
            )
            return
        }

        releaseAlbumURI = release.albumURI
        releaseAlbumArtist = artist
        webReleaseShownHeader = headerView

        let meta = release.trackCount > 0
            ? String(format: "artist_latest_release_tracks".localized, release.trackCount)
            : nil
        headerView.updateRelease(
            title: release.title,
            date: release.dateText,
            meta: meta,
            artworkURL: release.artworkURL,
            // 有专辑 URI ⇒ 点得动（`handleReleaseCardTap` 第 ③ 档用它打开）。
            isTappable: true
        )
        // 卡片挂在页头下面那一格，页头高度不需要动（见 `releaseCardHost(for:)`）。

        let dateText = release.dateText ?? "-"
        writeDebugLog(
            "[Release] spotify — \"\(artist)\": card shows \"\(release.title)\" (\(dateText))"
                + ", tap opens \(release.albumURI)"
        )
    }

    /// Web API 那张卡的**点击目标**作废（页面里那一格读到了 / 换页了）。
    ///
    /// 只清"现在该打开什么"与"画在哪份页头上"；`webReleaseApplied` **保留** ——
    /// 离开再回来时还能同步重画一次（那时页面里那一格多半又没了）。
    private static func clearWebReleaseURI(reason: String) {
        // 没有要清的就**不打日志**：`applyPick` 每一拍都会调到这里（每帧一行 = 刷屏）。
        guard releaseAlbumURI != nil || releaseAlbumArtist != nil || webReleaseShownHeader != nil else {
            return
        }
        releaseAlbumURI = nil
        releaseAlbumArtist = nil
        webReleaseShownHeader = nil
        writeDebugLog("[Release] spotify — cleared the Web API album target (\(reason))")
    }

    /// 标题行的文字是不是"艺人之选"这一块（多语言各写一条 —— Spotify 的 UI 跟着 App 语言走）。
    private static func isPickHeading(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let needles = [
            "艺人之选",
            "artist's pick",
            "artists pick",
            "artist pick",
            "アーティストのピックアップ",
            "アーティストピック",
        ]
        return needles.contains { lowered.contains($0) }
    }

    /// 往上找最近的 collection/table cell（标题行 → 装它的那一格）。
    private static func enclosingCell(of view: UIView) -> UIView? {
        var node: UIView? = view
        var levels = 0
        while let current = node, levels < 12 {
            if current is UICollectionViewCell || current is UITableViewCell { return current }
            node = current.superview
            levels += 1
        }
        return nil
    }

    /// 从"下一格"里抠出 pick：**最长的一段文字当标题**，另一段当副标题，第一张像样的图当封面。
    private static func makePick(from cell: UIView) -> ArtistPick? {
        var image: UIImage?
        var texts: [String] = []
        var queue: [UIView] = [cell]
        var visited = 0

        while !queue.isEmpty, visited < 120 {
            let view = queue.removeFirst()
            visited += 1
            if image == nil, let imageView = view as? UIImageView,
               let found = imageView.image, found.size.width > 40 {
                image = found
            }
            if let label = view as? UILabel,
               let text = label.text?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty, text.count <= 120 {
                texts.append(text)
            }
            queue.append(contentsOf: view.subviews)
        }

        var unique: [String] = []
        for text in texts where !unique.contains(text) { unique.append(text) }

        guard let title = unique.max(by: { $0.count < $1.count }) else { return nil }
        let meta = unique.first { $0 != title }
        return ArtistPick(title: title, meta: meta, artwork: image)
    }

    /// 设置页改了「艺人页」那两格之后，如果艺人页还在下面，**当场重跑一遍**。
    ///
    /// 设置页是盖在艺人页上的，它自己不一定会让下面的页面再布局一次 ⇒ 没有这一句，切完开关
    /// 要退回去再滚一下才看得到变化（月听众那行尤其明显）。
    static func reapplyArtistPageAppearance() {
        guard isEnabled, !applying,
              let page = lastArtistPage, page.window != nil else { return }
        applyToArtistPage(page)
    }

    /// 艺人页的页头容器：`TemplateKit` 的 `HeaderContainer`（**没有 accessibility id**，按类名认）。
    private static func artistHeaderContainer(in page: UIView) -> UIView? {
        var queue: [UIView] = [page]
        var visited = 0
        while !queue.isEmpty, visited < 400 {
            let view = queue.removeFirst()
            visited += 1
            if NSStringFromClass(type(of: view)).contains("HeaderContainer") { return view }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// **"关于艺人"出现的那一拍就认下它**。
    ///
    /// 不能靠搜：`applyToArtistPage` 里那次 BFS 从**页面根**出发，而 `SPTArtistAboutBiographyView`
    /// 落在**深度 20**（`21.UIScrollView` → … → 那个 section，旁边就是 `ArtistAboutListenersView` /
    /// `ListRow id=artist-about-listeners`）⇒ 从根搜基本拿不到目标。
    /// 这个类**没有 accessibility id**，但它是 ObjC 类（`SPT*`）⇒ 直接挂它自己：事件驱动、零搜索。
    static func artistBiographyAppeared(_ view: UIView) {
        guard isEnabled else { return }
        guard isArtistPageAncestor(of: view) else { return }
        cachedArtistBio = view
        if let control = firstControl(in: view) { artistBioControl = control }
        captureBioTextOnSight(from: view)
    }

    /// **这一块露头的那一刻就把正文读走**。
    ///
    /// 这里若只记下"它在哪儿"（给 `i` 转发用）、正文靠进页面时扫一次列表，就会两头落空：这张卡
    /// 是**懒加载**的，进页那一刻整页还没有它 ⇒ 它出现了我们什么都没读，`bioTexts` 一直空 ⇒
    /// ① `i` 那张卡说"没有可读的介绍"；② 列表里那一段因为折叠闸门（`hasCapturedBio`）也不折。
    ///
    /// 所以：**只要它露头就读**（必须当场读 —— cell 一被回收文字就没了），并按艺人名存起来；
    /// 存下来那一刻顺手作废一次布局，折叠闸门才打得开（见 `relayoutAfterBioCapture`）。
    private static func captureBioTextOnSight(from view: UIView) {
        let name = artistNameStorage
        guard !name.isEmpty else { return }

        // **社交链接那颗一起收下**：这一段是懒加载的，控件一被回收就没了 ⇒ 露头那一刻就把它们
        // 记下来，`ArtistBioSheet` 那颗胶囊点下去时再转发给它们自己。
        captureBioLinks(from: view, name: name)

        guard bioTexts[name] == nil, bioTexts.count < 32 else { return }
        // 同一张卡有两条读法：
        // · `eeveeArtistBioText` —— 按 id 读**一颗** label，最准，但 Spotify 有时把整段塞进
        // 一个 label（段之间的换行只剩视觉段距，字符串里没有 `\n`）；
        // · `eeveeArtistBioBlockText` —— 把卡里**每一颗** label 按位置拼起来，段与段之间天然有 `\n`。
        // **两边都读，选换行更多的那一份**（不要"label 优先"：那样永远轮不到会有分行的 block）。
        let labelText = eeveeArtistBioText(in: view)
        let blockText = eeveeArtistBioBlockText(in: view)
        let picked = Self.richerBioText(label: labelText, block: blockText)
        guard let raw = picked.text, !raw.isEmpty else { return }
        // **存之前先收拾** —— 卡里那两行"艺人名 / 每月有 x 名听众"不是简介，
        // 见 `eeveeSanitizedArtistBio`。
        let text = eeveeSanitizedArtistBio(raw, artistName: name)
        guard !text.isEmpty else { return }
        bioTexts[name] = text
        writeDebugLog(
            "[ArtistBio] capture source — \(picked.source), label \(Self.lineCount(labelText)) line(s),"
                + " block \(Self.lineCount(blockText)) line(s), chose \(Self.lineCount(text)) line(s)"
        )
        writeDebugLog(
            "[EntityPageHeader] about-artist captured on sight — \(name), \(text.count) char"
                + (text.count == raw.count ? "" : " (cleaned from \(raw.count) char)")
        )
        if let page = eeveeAncestor(withIdentifier: "creator-page", of: view) {
            relayoutAfterBioCapture(in: page)
        }
    }

    /// 简介的两条读法里**换行更多**的那一份（见 `captureBioTextOnSight` 的说明）。
    private static func richerBioText(label: String?, block: String?) -> (text: String?, source: String) {
        switch (label, block) {
        case let (label?, block?):
            return lineCount(block) > lineCount(label) ? (block, "block") : (label, "label")
        case let (label?, nil):
            return (label, "label")
        case let (nil, block?):
            return (block, "block")
        default:
            return (nil, "none")
        }
    }

    private static func lineCount(_ text: String?) -> Int {
        guard let text else { return 0 }
        return text.components(separatedBy: "\n").count
    }

    /// 往上找页面根那个 `creator-page`（与 `EntityPageAppearance.isArtistPage` 同一个判据）。
    private static func isArtistPageAncestor(of view: UIView) -> Bool {
        var node: UIView? = view
        var level = 0
        while let current = node, level < 24 {
            level += 1
            if current.accessibilityIdentifier == "creator-page" { return true }
            node = current.superview
        }
        return false
    }

    /// 现在认下的"关于艺人"那一块（没有就是 nil）—— 给 `eeveeMaterialiseBio` 的"扫列表"用。
    ///
    /// 那一块是懒加载的，页面刚打开时整棵树只有 1000 来个节点 ⇒ 扫一遍列表把它逼出来之后，
    /// 这里就能拿到它。
    static var artistBioTarget: UIView? { cachedArtistBio }

    /// 藏掉艺人页头里 Spotify 自己画的东西，**绕开那张照片**，而且**只用空 mask**（见 `eeveeBlank`）。
    private static func blankArtistChrome(in root: UIView, avoiding cover: UIView?, skipping ours: UIView) {
        for sub in root.subviews {
            if sub === ours { continue }
            // 同 `concealAlbumChrome` —— 我们自己的东西（页头、右上角那颗 ⋯、满幅封面）一律跳过，
            // 否则艺人页上那颗 `⋯` 也是永远 hidden。
            if isOurs(sub) { continue }
            if let cover {
                if sub === cover { continue }
                if cover.isDescendant(of: sub) {
                    blankArtistChrome(in: sub, avoiding: cover, skipping: ours)
                    continue
                }
            }
            eeveeBlank(sub)
        }
    }

    /// **歌手页那条 tab 栏（Music / Video / Merch）要走掉**：Video / Merch 两页的存在只是为了让
    /// 它们可以被去掉，Music 列表本身要留下并上移到那一格的位置。
    ///
    /// 用 `alpha = 0`（**不是 hidden**：它在 `AutoLayoutStackView` 里，隐藏会 trap）+ 关交互，
    /// 再把同层的分页 scroll 整体上移一格的高度、并关掉分页。
    static func hideArtistTabStrip(in page: UIView) {
        guard let strip = eeveeFindView(page, identifier: "Components.UI.TabsSectionHeading") else { return }

        // 换了一页 / 旧记录已经失效 ⇒ 先把旧的写回去，再给这一条重新记原值。
        if let state = artistStripState, state.strip !== strip {
            restoreArtistStrip()
        }
        if artistStripState == nil {
            var pages: [ArtistStripPageState] = []
            if let parent = strip.superview {
                for sibling in parent.subviews {
                    guard let scroll = sibling as? UIScrollView else { continue }
                    pages.append(ArtistStripPageState(scroll: scroll))
                }
            }
            artistStripState = ArtistStripState(strip: strip, pages: pages)
        }

        if strip.alpha != 0 { strip.alpha = 0 }
        if strip.isUserInteractionEnabled { strip.isUserInteractionEnabled = false }
        strip.accessibilityElementsHidden = true

        let lift = strip.bounds.height
        guard lift > 0, let parent = strip.superview else { return }
        for sibling in parent.subviews {
            guard let pages = sibling as? UIScrollView else { continue }
            if pages.isScrollEnabled { pages.isScrollEnabled = false }
            let move = CGAffineTransform(translationX: 0, y: -lift)
            if pages.transform != move { pages.transform = move }
        }
        logOnce("artistStrip", "artist page: the Music/Video/Merch strip is gone, the Music list moved up \(Int(lift))pt")
    }

    /// 关掉「隐藏 Music / Video / Merch 标签栏」时，把 `hideArtistTabStrip` 动过的每一格写回。
    ///
    /// 这颗开关默认是**开**；关掉时必须能还原，否则用户只能重启 Spotify 才能看见标签栏。
    /// 记录只存**原值**，不猜"应该是什么"。
    static func restoreArtistStrip() {
        guard let state = artistStripState else { return }
        if let strip = state.strip {
            strip.alpha = state.alpha
            strip.isUserInteractionEnabled = state.interactive
            strip.accessibilityElementsHidden = state.accessibilityHidden
        }
        for page in state.pages {
            guard let scroll = page.scroll else { continue }
            scroll.isScrollEnabled = page.enabled
            scroll.transform = page.transform
        }
        artistStripState = nil
        writeDebugLog("[EntityPageHeader] artist page: the Music/Video/Merch strip is back (the hide-tabs switch is off)")
    }

    /// 是不是**我们自己**插进 Spotify 视图树里的东西 —— 统一靠 id 前缀 `eevee-` 认。
    ///
    /// 藏"头里除我们那份以外的一切"时**必须跳过这些**。按具体 id 逐个跳不行：后加的
    /// `eevee-pinned-more`（右上角那颗 ⋯）就会被顺手藏掉，切到专辑页/艺人页时永远是 `hidden`
    /// —— 那两条路每拍都在藏"头里除了页头以外的一切"。
    ///
    /// 判据用前缀之后，以后再往 Spotify 的树里插自己的视图，不用回来补这一行。
    private static func isOurs(_ view: UIView) -> Bool {
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
    private static func concealAlbumChrome(in root: UIView, avoiding cover: UIView?, skipping ours: UIView) {
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
    private static func concealAlbumBranch(_ view: UIView) {
        pruneAlbumConcealedBranches()
        if !albumConcealedBranches.contains(where: { $0.view === view }),
           albumConcealedBranches.count < albumConcealedBranchLimit {
            albumConcealedBranches.append(AlbumConcealedBranch(view))
        }
        eeveeConceal(view)
    }

    private static func pruneAlbumConcealedBranches() {
        albumConcealedBranches.removeAll { record in
            guard let view = record.view, view.window != nil else { return true }
            return false
        }
    }

    /// 封面到了之后：把"当时因为找不到封面而被整支藏掉"的分支原样放回来。
    ///
    /// 只有**确实包含封面**的那一支会被还原；不包含封面的分支继续留着藏（那是设计）。
    private static func revealAlbumBranches(containing cover: UIView) {
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
    private static func scheduleAlbumCoverRetry(_ page: UIView) {
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

    /// 把 Follow 那颗的**子树**打一次，看"已关注"到底画在哪个类上、状态挂在哪个属性上。
    /// 只打一次，60 个节点以内。
    ///
    /// ⚠️ 不能靠猜：`Encore.Button.Secondary` 是 Spotify 自己的按钮，标题可能不是 `UILabel`
    /// （SwiftUI 宿主 / 自绘都见过），状态也可能既不在 `isSelected` 也不在无障碍特征上。
    /// 这一行日志一次性把"类名 / id / label / value / 文字 / 选中特征"全列出来。
    private static func probeFollowSubtree(_ follow: UIView?) {
        guard !didProbeFollow, let follow else { return }
        didProbeFollow = true

        var lines: [String] = []
        var queue: [(view: UIView, depth: Int)] = [(follow, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 60 {
            let (view, depth) = queue.removeFirst()
            visited += 1
            let kind = NSStringFromClass(type(of: view))
            let id = view.accessibilityIdentifier ?? "-"
            let label = view.accessibilityLabel ?? "-"
            let value = view.accessibilityValue ?? "-"
            let selected = view.accessibilityTraits.contains(.selected)
            var text = "-"
            if let asLabel = view as? UILabel { text = asLabel.text ?? "-" }
            if let asButton = view as? UIButton {
                text = asButton.title(for: .normal) ?? asButton.title(for: .selected) ?? "-"
            }
            lines.append(
                "\(depth):\(kind) id=\(id) label=\(label) value=\(value) text=\(text) sel=\(selected)"
            )
            guard depth < 3 else { continue }
            for sub in view.subviews { queue.append((sub, depth + 1)) }
        }
        writeDebugLog(
            "[EntityPageHeader] follow subtree (\(visited) node(s)): \(lines.joined(separator: " | "))"
        )
    }

    /// **往上找"仍然恰好包着这个控件"的最外层视图**：那是 Spotify 布局放的 element view，
    /// 藏它才不会连控件本身一起弄丢。
    ///
    /// 只藏控件本身的话，那颗按钮的**圆底/边框画在它的父视图上**、还留在原地 ⇒ Spotify 的圆
    /// 与我们的玻璃圆叠在一起，看着就是"两个图标重合"。往上收到"尺寸不再变化"的那一层再藏，
    /// 整个按钮（含圆底）一起消失。
    ///
    /// 参数与返回值都做成可选：调用方那四颗（play / shuffle / add / download）本来就是 `UIView?`，
    /// `eeveeConceal` 收的也是 `UIView?` ⇒ `eeveeConceal(wrapperFor(play, in: page))` 一句就合法，
    /// 不必在四个调用点各写一次 `if let`（那条路还会漏掉其中一个）。
    private static func wrapperFor(_ control: UIView?, in stop: UIView) -> UIView? {
        guard let control else { return nil }
        var wrapper = control
        var node: UIView? = control.superview
        // ⚠️ **层数上限**：万一祖先链上连着几层同尺寸的包装容器，走到页面那一层就会把**整页**藏掉。
        // 5 层足够收住一颗按钮。
        var levels = 0
        while let current = node, current !== stop, levels < 5 {
            levels += 1
            if abs(current.bounds.width - control.bounds.width) > 4 { break }
            if abs(current.bounds.height - control.bounds.height) > 4 { break }
            wrapper = current
            node = current.superview
        }
        return wrapper
    }

    /// 把 `⋯` **钉在页头的右上角**（照 AM，与返回键同高）。
    ///
    /// AM 在那一格放的是"**分享 + ⋯**"的玻璃胶囊；而 **Spotify 的专辑页/艺人页没有独立的分享按钮**
    /// —— `ShareButton*`（`ShareButtonNowPlayingView` / `lyrics-share-button`）只出现在听歌页与
    /// 歌词页，专辑页与艺人页的分享是 `⋯` 菜单里的一项。所以这里**只做 `⋯` 一颗**，
    /// 不去造一颗点不动的假分享键（纪律：绝不留下"看得见、点不动"的东西）。
    ///
    /// 藏 Spotify 行里那颗走 `wrapperFor`（连它的圆底一起）—— 否则同一页上会出现两颗 `⋯`。
    private static func pinMoreButton(in headerRoot: UIView) {
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

    /// 把隐藏的搜索框那一行的**真实 frame / 父链 / 滚动 offset / topInset** 打一次，
    /// 用来分清"空档是那一行的高度"还是"contentInset 多了一截"，再决定折高度还是改 offset。
    private static func reportPlaylistMetrics(headerRoot: UIView, findField: UIView) {
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

    /// 专辑页的文字：**按明确的 id 读**（`TitleRow` / `ParentRow` / `MetadataRow`）。
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
    /// 按**画出来的顺序**（x 从小到大）读，空格连接。
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

    /// 从 `root` 往下找**第一个真正的控件**（`UIControl`，含自身）。
    ///
    /// 按 id 找到的往往是**外面那层 `ElementView<…>` 包装**，而不是能响应 `sendActions` /
    /// `handleTap` 的那颗按钮：转发打在包装上 = 没反应；`(source as? UIControl)?.isSelected`
    /// 也恒为假 ⇒ 永远不变绿（随机播放 / 播放键 / Follow 三处都是这个根因）。
    private static func firstControl(in root: UIView) -> UIView? {
        if root is UIControl { return root }
        var queue: [UIView] = root.subviews
        var visited = 0
        while !queue.isEmpty, visited < 400 {
            let view = queue.removeFirst()
            visited += 1
            if view is UIControl { return view }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// 那两颗浮动控件是**页面的直接子视图、48pt 上下**，而头、wash、列表都是整页宽 ——
    /// 只搜"小尺寸的直接子视图"，免得每一拍走一整棵树。
    private static func findFloating(_ identifier: String, in page: UIView, cache: inout UIView?) -> UIView? {
        if let cached = cache, cached.window != nil, cached.isDescendant(of: page) { return cached }
        var found: UIView?
        for sub in page.subviews where sub.bounds.width <= 120 {
            if let hit = eeveeFindView(sub, identifier: identifier) {
                // 钻到真正的控件（见 `firstControl`）：命中的若是包装层，点了就是没反应。
                // 缓存里存的**也是钻过之后的那一个**，所以每拍不会重走这一趟。
                found = firstControl(in: hit) ?? hit
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
    /// 加载途中它会落在 block 下面，按"最靠下"会把它当成 block（页头就会画两遍）。
    private static func blockIn(_ layout: UIView, cover: UIView?, fullbleed: UIView?) -> UIView? {
        let wide = layout.bounds.width * 0.6
        var block: UIView?
        for sub in layout.subviews {
            if sub === cover || sub === fullbleed { continue }
            if sub is EntityPageHeaderView { continue }
            // 文字块**绝不能把封面包在里面** —— 下面那轮 `concealInside` 会把封面一起藏掉。
            // 普通歌单页的满宽块本来就不含封面（这一句是空转），但生成歌单的页头可能只有
            // "一个大容器"，不挡这一下就会把整页图片藏没。
            // ⚠️ 只认**真封面**：`cover` 可能是"找不到封面时的整幅兜底"（`fullbleed`），
            // 拿它当判据会把正常块也误杀。
            if let cover, cover !== fullbleed, cover.isDescendant(of: sub) { continue }
            if sub.bounds.width < wide { continue }
            if block == nil || sub.frame.minY > block!.frame.minY { block = sub }
        }
        if block != nil { return block }
        return textBlockAroundBiggestLabel(in: layout, cover: cover, fullbleed: fullbleed)
    }

    /// 从**字号最大的那个标签**往上爬，取第一个"够宽、且不含封面"的祖先当文字块。
    ///
    /// 两处用：`blockIn` 找不到满宽孩子时；`applyOnce` 挑出来的那块里**没有标题**时
    /// （电台页头"头像 / 大标题 / 圆点 / 创建者 / 按钮行"各成一格，很容易挑错）。
    ///
    /// ⚠️ 一碰到含封面的那一层就停：再往上会把封面也当成 Spotify 的 chrome 藏掉。
    private static func textBlockAroundBiggestLabel(
        in layout: UIView,
        cover: UIView?,
        fullbleed: UIView?
    ) -> UIView? {
        guard let label = biggestLabel(in: layout, skipping: [cover, fullbleed]) else { return nil }
        var candidate: UIView = label
        var hops = 0
        while hops < 8 {
            // 从标签的**父层**开始：block 要能装下标题，不能是标签自己
            // （那样下面那轮 `block.subviews` 什么都藏不掉，标题会叠两层）。
            guard let parent = candidate.superview, parent !== layout else { break }
            candidate = parent
            hops += 1
            if let cover, cover !== fullbleed, cover.isDescendant(of: candidate) { break }
            if candidate.bounds.width >= layout.bounds.width * 0.5,
               candidate.bounds.height > 20 {
                logOnce(
                    "blockByLabel",
                    "text block by label = \(NSStringFromClass(type(of: candidate)))"
                        + " (no full-width child, or the wide one had no title)"
                )
                return candidate
            }
        }
        return nil
    }

    // MARK: - 图片区（正常歌单 = 一张方封面；电台 = 一行三个大圆头像）
    //
    // 页头里**不许藏**的那些视图（图片区）。
    //
    // · 正常歌单 = 一张方封面，元素 id `Components.Header.UI.ArtworkImage`；
    // · 电台 = **一行三个大圆头像**（`Encore.AvatarView`），左右两张还各自出血到屏幕外。
    //
    // 两者在版式里的角色**完全一样**：图在上，标题 / 创建者 / 按钮在下。
    // ⇒ 统一成一份"不许藏"的名单，`concealInside` 绕着它走。
    private static func headerArtwork(in layout: UIView, cover: UIView?, fullbleed: UIView?) -> [UIView] {
        var artwork: [UIView] = []
        // ⚠️ 只认**真封面**：`cover` 可能是"找不到封面时的整幅兜底"（`fullbleed`），
        // 把它算进名单等于整页都不藏。
        if let cover, cover !== fullbleed { artwork.append(cover) }
        artwork.append(contentsOf: headerAvatars(in: layout))
        return artwork
    }

    /// 满幅页头（`HeaderFullbleedCentralView`）里**那张图** —— 除了它，容器里其余的都是
    /// Spotify 自己的 chrome（渐变 + 大标题），要藏。
    ///
    /// 判据按**类名**，三档：
    /// · `…HeaderFullbleedCentralView…14ArtworkWrapper` —— 图就装在这个私有嵌套类里；
    /// · 某些版本没有 `ArtworkWrapper` ⇒ 退回容器里第一个 `Encore.ImageView`；
    /// · 电台那种「图 = 一行三个大圆头像」⇒ 再退回 ≥48pt 的 `AvatarView`。
    ///
    /// ⚠️ 三档都落空 ⇒ 返回空数组，调用方**整支放过**。绝不拿"容器里所有图片都留"当兜底：
    /// 万一标题容器里也带图，那就等于什么都没藏；反过来把名单写宽一点又会把满幅图藏没。
    private static func fullbleedArtwork(in fullbleed: UIView) -> [UIView] {
        var kept: [UIView] = []
        forEachView(fullbleed) { view in
            if NSStringFromClass(type(of: view)).contains("ArtworkWrapper") {
                kept.append(view)
            }
        }
        if kept.isEmpty, let image = eeveeFindView(fullbleed, identifier: "Encore.ImageView") {
            kept.append(image)
        }
        // 电台那一类：满幅头里没有 `ArtworkWrapper`，图是**一行三个大圆头像**（`Encore.FaceKit.AvatarView`）
        // —— 只在上面两条都落空时才扫，且只认 ≥48pt 的（创建者那行的脸堆小得多）。
        if kept.isEmpty {
            forEachView(fullbleed) { view in
                guard NSStringFromClass(type(of: view)).contains("AvatarView"),
                      view.bounds.width >= 48 else { return }
                kept.append(view)
            }
        }
        return kept
    }

    /// 页头里那几个**大圆头像**（电台）。
    ///
    /// 三条收窄，防止误伤（创建者那行的脸堆里也全是 `AvatarView`）：
    /// · **至少 48pt 宽** —— 脸堆里的头像只有 24pt 上下；
    /// · 脸堆（`FacepileView`）里的一律不算，哪怕被放大；
    /// · 最多收 8 个（电台是三张，留点余量）。
    ///
    /// 性能：结果按 `layout` 缓存 —— 这一拍是**每帧**的，不能每帧走一遍 1500 节点的 BFS。
    private static func headerAvatars(in layout: UIView) -> [UIView] {
        // ⚠️ 只有"页头已经撑开"（>100pt）才认缓存：第一两拍头像还没量出宽度（0pt），
        // 那时扫出来的"没有头像"是假结论 —— 缓存住它，头像就永远不会被保护。
        let settled = layout.bounds.height > 100
        if settled, artworkScannedLayout === layout,
           cachedArtwork.allSatisfy({ $0.window != nil }) {
            return cachedArtwork
        }
        var found: [UIView] = []
        forEachView(layout) { view in
            guard found.count < 8 else { return }
            guard NSStringFromClass(type(of: view)).contains("AvatarView") else { return }
            guard view.bounds.width >= 48 else { return }
            var node: UIView? = view.superview
            var level = 0
            while let current = node, level < 4 {
                if NSStringFromClass(type(of: current)).contains("Facepile") { return }
                node = current.superview
                level += 1
            }
            found.append(view)
        }
        if settled {
            artworkScannedLayout = layout
            cachedArtwork = found
        }
        if found.count >= 2 {
            logOnce(
                "radioArtwork",
                "radio header: \(found.count) artist avatar(s) kept as the page artwork"
                    + " — Spotify's radio header is a row of avatars, not a cover"
            )
        }
        return found
    }

    /// 藏掉 `view` 这一支，**但绕开 `artwork` 里的图片区**。
    ///
    /// `eeveeConceal` 是"整支藏"（`layer.isHidden` + 空 mask）—— 只要这一支里装着头像，
    /// 整支藏就等于把头像一起删掉。所以这里改成：**容器里有要留的东西就往下走一层**，
    /// 只藏那些"不含图片区"的孩子。
    ///
    /// 最多 8 层；到不了底就整支放过 —— 宁可留一点 Spotify 的 chrome，
    /// 也不要再让头像消失。
    private static func concealInside(_ view: UIView, keeping artwork: [UIView], depth: Int = 0) {
        if artwork.contains(where: { $0 === view }) { return }
        guard artwork.contains(where: { $0.isDescendant(of: view) }) else {
            eeveeConceal(view)
            return
        }
        guard depth < 8 else { return }
        for sub in view.subviews {
            concealInside(sub, keeping: artwork, depth: depth + 1)
        }
    }

    // MARK: - 读文字

    private struct HeaderTexts {
        var title = ""
        var creator = ""
        var length = ""
        var about = ""
    }

    /// **上一拍认下的那四个标签**。
    ///
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
    /// ⚠️ 9.1.88 上 model 那条路的存在性**没证实**⇒ 一律 `responds(to:)` 守卫，
    /// 拿不到就退回标签启发式。**标签兜底才是这里的主路径**。
    /// 上一拍认下的四个标签还在那棵树上 ⇒ **只读 `.text`**（每帧一次，成本≈0）。
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

        // 官方生成歌单的创建者**不是脸堆**，而是专用插件元素：
        // · `…ThisIsArtistHeaderPluginImpl…ThisIsHeaderCreatorElementUI`（This Is xxx）
        // · `…EditorialHeaderPluginImpl…EditorialHeaderCreatorElementUI`（编辑歌单 / 电台那一类）
        // 脸堆那条路在这类页面上永远走空 ⇒ 页头会少一行"Spotify / 艺人"。
        // 这里按**类名**再找一次（认类名，不认 id）。
        if texts.creator.isEmpty {
            for marker in ["ThisIsHeaderCreator", "EditorialHeaderCreator"] {
                guard let element = firstView(withClassName: marker, in: block),
                      let label = firstLabel(in: element, skipping: nil) else { continue }
                texts.creator = label.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                views.creator = label
                break
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

    /// 子树里**类名**含某一段的第一个视图（不认 accessibility id —— 生成歌单的插件元素没有 id）。
    private static func firstView(withClassName marker: String, in root: UIView) -> UIView? {
        var found: UIView?
        forEachView(root) { view in
            guard found == nil else { return }
            if NSStringFromClass(type(of: view)).contains(marker) { found = view }
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
    //
    // 沿 responder 链找页面的 view model：先问 `defaultHeaderViewModel` / `headerViewModel`，
    // 再问 `headerController` 要一个。**每个 selector 都先 `responds(to:)`**。
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
    // 专辑页 / 艺人页那两条路都是**可选**的：类不在就少做一页（不能因为一个可选的类把整组拖垮）。
    let album = NSClassFromString(EntityPageAlbumLayoutHook.targetName) != nil
    let artist = NSClassFromString(EntityPageArtistLayoutHook.targetName) != nil
    // **生成歌单（This Is / 电台）的备用入口** —— 同样可选、同样单独一组。
    // 它不在 = 只影响"页头换了一套布局类名"那种情况；共用组里那几页照常。
    let playlistPage = NSClassFromString(EntityPagePlaylistPageHook.targetName) != nil
    if playlistPage { EntityPagePlaylistPageHookGroup().activate() }
    let bio = NSClassFromString(ArtistBiographyViewHook.targetName) != nil
    let bioCard = NSClassFromString(ArtistBiographyCardLayoutHook.targetName) != nil
    // ⚠️ 这一组**单独装**（见 `ArtistBioCardHookGroup` 的说明）：名字里带私有哈希，
    // 换一版就可能解析不到 —— 解析不到就只是少一条事件线，不能连累共用组。
    if bioCard { ArtistBioCardHookGroup().activate() }
    // Spotify 自己的「关于艺人」数据线（`SPTArtistAboutDataLoader`）——
    // 装得上就等于"一进页面就有**完整正文 + 真链接**"；装不上就退回界面读文字那条老路
    // ⚠️ 探测在 `ArtistAboutDataLoaderProbe` 里、不在 hook 类里 —— Orion 不准 hook 类
    // 带 `static func`（见那个 enum 的说明）。
    let aboutLoader = ArtistAboutDataLoaderProbe.canInstall(
        className: SPTArtistAboutDataLoaderHook.targetName
    )
    if aboutLoader { ArtistAboutDataHookGroup().activate() }
    let aboutEncoding = ArtistAboutDataLoaderProbe.typeEncoding(
        className: SPTArtistAboutDataLoaderHook.targetName
    )
    writeDebugLog(
        "[EntityPageHeader] on — AM header \(EntityPageHeaderManager.isEnabled ? "ON" : "OFF"),"
            + " page look \(EntityPageAppearance.isEnabled ? "ON" : "OFF")"
            + " (one layout pass drives both; playlist pages"
            + (album ? " + album pages" : "; album hook missing")
            + (artist ? " + artist pages)" : "; artist hook missing")
            + (bio ? "; about-artist hook on" : "; about-artist hook MISSING")
            + (bioCard ? " + card-layout hook on" : " + card-layout hook MISSING")
            + (aboutLoader ? " + about-data hook on" : " + about-data hook MISSING")
            + " (encoding \(aboutEncoding))"
            + (playlistPage ? "; playlist-page hook on" : "; playlist-page hook MISSING")
    )
}
