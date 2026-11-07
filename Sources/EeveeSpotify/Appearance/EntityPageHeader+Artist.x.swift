import Foundation
import Orion
import UIKit
import ObjectiveC.runtime

extension EntityPageHeaderManager {
    /// 艺人页那条路（见 `applyToArtistPage`）：名字、月听众那行、照片、Follow —— 同样全走缓存。
    static var cachedArtistName: UIView?
    static var cachedArtistMeta: UIView?
    static var cachedArtistCover: UIView?
    static var cachedArtistFollow: UIView?
    /// 艺人页左边那颗 `i` 的转发目标：**艺人简介卡**（`CreatorBiographyCard`）。
    static var cachedArtistBio: UIView?
    /// Follow 点击后的延迟复查要用这两样（见 `refreshArtistFollow`）。
    /// 都是**弱引用**：离开艺人页之后不该把整页留住。
    static weak var lastArtistPage: UIView?
    static weak var lastArtistHeaderView: EntityPageHeaderView?

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

    static var artistStripState: ArtistStripState?
    /// 从页面根出发那条兜底搜索**每页只试两拍**（见 `applyToArtistPage`）——
    /// 这两个数就是它的记账（换页清零；主力是 `ArtistBiographyViewHook`）。
    static weak var artistBioSearchPage: UIView?
    static var artistBioSearchPasses = 0
    /// **读到过的艺人简介**按艺人名缓存（那一块是懒加载的，读一次就够；cell 一被回收文字就没了）。
    static var bioTexts: [String: String] = [:]
    /// 现在这一页的艺人名（`applyToArtistPage` 每拍写）—— "我们自己的艺人介绍"拿它当标题。
    static var artistNameStorage = ""

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
    static func storeArtistAbout(_ about: NSObject) {
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
    static func applyArtistAbout(
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

    static var bioLinks: [String: [ArtistBioLinkRef]] = [:]

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
    static func captureBioLinks(from root: UIView, name: String, limit: Int = 800) {
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
    static func relayoutAfterBioCapture(in page: UIView) {
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

    static var artistProbeReports = 0
    static var artistProbeLastPass: CFAbsoluteTime = 0
    static var artistProbeSignature = ""

    // MARK: - 艺人页
    //
    // 照片满幅铺到页面顶部并向底色渐隐，名字与月听众居中落在渐隐底部，
    // 下面一行 shuffle / Play 胶囊 / Follow（照 Apple Music）。
    //
    // 页面判据是 `creator-page`；页头容器是 TemplateKit 的 `HeaderContainer`，
    // 它身上没有 accessibility id，只能按类名认。节点形状：
    //
    // HeaderContainer(0,0,414,520) > ImageHeaderView
    //   > ShadowContainer `Components.Header.UI.ArtworkImage`（照片，414 全宽）+ GradientView
    //   → AdaptiveTitle（名字）→ Metadata（月听众）→ OverflowStackView（Follow 那一行）
    //   → play（`header-play-button`）
    //
    // ⚠️ 两处绝不能动：这里**只用空 mask 藏、绝不设 hidden** —— 页头在 `OverflowStackView`
    // 里，一行里最"高"的视图被 hidden 时它会 force-unwrap nil 并 trap（见 `eeveeBlank`）；
    // 同理不强制 `…context_menu_in_navigation_bar_enabled_artist` 那个 flag。
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
        probeCoverOverlap(cover: cover, headerView: headerView, root: header, anchored: false, role: "artist")

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
            // 判据用**真机树里那三个名字**（见 `eeveeArtistBioCard`）。不要把这个类排在
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
    static func probeArtistPageSections(in page: UIView) {
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
    static func artistHeaderContainer(in page: UIView) -> UIView? {
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
    static func captureBioTextOnSight(from view: UIView) {
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
    static func richerBioText(label: String?, block: String?) -> (text: String?, source: String) {
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

    static func lineCount(_ text: String?) -> Int {
        guard let text else { return 0 }
        return text.components(separatedBy: "\n").count
    }

    /// 往上找页面根那个 `creator-page`（与 `EntityPageAppearance.isArtistPage` 同一个判据）。
    static func isArtistPageAncestor(of view: UIView) -> Bool {
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
    static func blankArtistChrome(in root: UIView, avoiding cover: UIView?, skipping ours: UIView) {
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

    /// 把 Follow 那颗的**子树**打一次，看"已关注"到底画在哪个类上、状态挂在哪个属性上。
    /// 只打一次，60 个节点以内。
    ///
    /// ⚠️ 不能靠猜：`Encore.Button.Secondary` 是 Spotify 自己的按钮，标题可能不是 `UILabel`
    /// （SwiftUI 宿主 / 自绘都见过），状态也可能既不在 `isSelected` 也不在无障碍特征上。
    /// 这一行日志一次性把"类名 / id / label / value / 文字 / 选中特征"全列出来。
    static func probeFollowSubtree(_ follow: UIView?) {
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

}
