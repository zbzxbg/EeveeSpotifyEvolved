import Foundation
import Orion
import UIKit
import ObjectiveC.runtime

extension EntityPageHeaderManager {
    // MARK: - 「艺人之选」/「最新发布」卡片（艺人页三颗按钮下面那张）
    //
    // 「艺人之选」读到的样子（标题 + 副标题 + 封面）。
    struct ArtistPick {
        let title: String
        let meta: String?
        let artwork: UIImage?
    }

    static var artistPickCache: [String: ArtistPick] = [:]
    static var didLogArtistPick = false
    /// 每一位艺人只发一次"最新发布"请求（数据源自己还有 TTL 缓存与在飞去重）。
    static var releaseArtist: String?

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
    static func sectionCard(
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
    static func firstNestedCell(in view: UIView) -> UIView? {
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
    static weak var releaseCardSource: UIView?
    /// 那一格属于**哪位艺人**。换了艺人但页面还留在导航栈里时，旧格子的 `window` 仍然非空
    /// ⇒ 只靠弱引用/`window` 判断会转发到上一页，这里再按名字卡一道。
    static var releaseCardSourceName: String?

    /// 记下"卡片现在的目标"（数据与点击共用同一格）。
    static func setReleaseCardSource(_ card: UIView, name: String) {
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

    static var releaseSectionCache: [String: ArtistPick] = [:]
    /// 每页试了几次"读页面那一块"——**只进日志**（真的闸门是 `scheduleLatestRelease` 里的墙钟）。
    static var releaseSectionMisses: [String: Int] = [:]
    static var didLogReleaseSection = false

    /// 那一块在 Spotify 里叫什么（多语言各写一条，与 `isPickHeading` 同一个思路）。
    static func isReleaseHeading(_ text: String) -> Bool {
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
    static func handleReleaseCardTap() {
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

    static var expandScheduledPages = Set<ObjectIdentifier>()

    /// 那一颗是 Spotify 的 `Components.UI.ListSectionFooter.Button`：它把"热门"那一段截在 6 行，
    /// 底部再盖一条往黑的渐变（`ScrollGradientOverlay`）让胶囊读得清 —— 看到的就是
    /// **半截的第 6 行 + 一条黑带**。⇒ 进页后**替用户点一次**：原地铺开。
    ///
    /// 进页的 1 秒里列表还在长（`contentSize` 每拍都在变）⇒ 那一拍 footer 很可能**还没建出来**，
    /// 所以试三轮（1.0 / 2.5 / 5.0s），点到就停。每页只排一次。
    static let expandAttemptDelays: [Double] = [1.0, 2.5, 5.0]

    static func scheduleSectionExpansion(in page: UIView) {
        let key = ObjectIdentifier(page)
        guard !expandScheduledPages.contains(key) else { return }
        expandScheduledPages.insert(key)
        attemptSectionExpansion(in: page, attempt: 0)
    }

    static func attemptSectionExpansion(in page: UIView?, attempt: Int) {
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
    static func isSectionFooter(_ control: UIControl) -> Bool {
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
    static func expandSectionFooters(in page: UIView) -> Bool {
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
    static weak var releaseCardHost: UIView?
    /// 那一格的高度（有卡片 106，没有 0 —— 收成 0 时列表自然回到原位）。
    static var releaseCardHeight: NSLayoutConstraint?
    static weak var releaseCardView: EntityPageHeaderReleaseCard?
    /// 这一格属于哪一份页头（换页就重建）。
    static weak var releaseCardOwner: EntityPageHeaderView?

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
    static func hideReleaseCard() {
        guard let card = releaseCardView else { return }
        card.isTappable = false
        if !card.isHidden { card.isHidden = true }
        if releaseCardHeight?.constant != 0 { releaseCardHeight?.constant = 0 }
    }

    /// 页头**下面**那一格（懒建）。返回 nil = 这页头的父层不是 stack，画不了。
    static func releaseCardHost(for headerView: EntityPageHeaderView) -> UIView? {
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
    static func stackSlot(for container: UIView) -> (stack: UIStackView, index: Int)? {
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
    static var releaseSectionFirstSeen: [String: Date] = [:]
    static let releaseFallbackDelay: TimeInterval = 6

    // MARK: - 「最新发布」：页面那一块是**懒加载**的，得有人按时去看

    static var releasePollTimer: Timer?
    static weak var releasePollPage: UIView?
    static var releasePollDeadline: Date?
    static var releasePollName = ""
    static let releasePollInterval: TimeInterval = 1.5
    static let releasePollLifetime: TimeInterval = 90

    /// **"时有时无"的根因** —— 卡片的数据要读页面里「热门新歌」那一块，而那一块在列表中很下面
    /// （标题在 **y≈1020pt**，窗口只有 896pt），Spotify 用的是**懒加载**：没滚到就一直是
    /// `RetrievalRowLoadingElementUI … 正在加载`。
    ///
    /// 而只靠**布局拍**（`applyToArtistPage` → `captureLatestRelease`）读不行 ——
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

    static func scheduleLatestRelease(for headerView: EntityPageHeaderView, name: String) {
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

    static func applyLatestRelease(_ release: ArtistLatestRelease, to headerView: EntityPageHeaderView) {
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
    static func applyPick(_ pick: ArtistPick, to headerView: EntityPageHeaderView) {
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
    static var releaseAlbumURI: String?
    static var releaseAlbumArtist: String?
    /// 已经画到哪一份页头上 —— 同一份页头只画一次（`updateRelease` 会重启封面下载，不能每拍都来）。
    static weak var webReleaseShownHeader: EntityPageHeaderView?
    /// 每位艺人取回来的那一张（**同步重画**用：离开再回来不用再问网络）。
    static var webReleaseApplied: [String: SpotifyArtistRelease] = [:]
    /// 每位艺人上一次问接口的**墙钟**（布局拍每帧都来，不能每帧都问）。
    static var webReleaseAskedAt: [String: Date] = [:]
    static var webReleaseAskCount: [String: Int] = [:]
    static let webReleaseRetryInterval: TimeInterval = 20

    /// 问一次 Web API（**墙钟节流**）。三道闸门：
    ///
    /// · 页面里已经有数据（艺人之选 / 热门新歌）⇒ 不问；
    /// · 这位艺人已经取回来过 ⇒ 只同步重画，不问；
    /// · 20s 之内问过 ⇒ 跳过（`webReleaseRetryInterval`；90s 的轮询因此最多问 4 次）。
    ///
    /// 由 `scheduleLatestRelease`（进页那一刻）与 `startReleasePolling` 的节拍各调一次。
    static func askSpotifyForLatestRelease(artist: String) {
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
    static func applyWebRelease(_ release: SpotifyArtistRelease?, artist: String) {
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
    static func applyWebReleaseCard(
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
    static func clearWebReleaseURI(reason: String) {
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
    static func isPickHeading(_ text: String) -> Bool {
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
    static func enclosingCell(of view: UIView) -> UIView? {
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
    static func makePick(from cell: UIView) -> ArtistPick? {
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

}
