import Foundation
import Orion
import UIKit
import ObjectiveC.runtime

/// 听歌页「卡片类」清爽开关 —— 把 Spotify 塞在听歌页滚动区里的**推荐卡**折起来。
///
/// ## 为什么是"折起来"而不是 `isHidden`
///
/// 这些卡片不是普通子视图，是 `NowPlaying_ScrollAPI` 那套 collection view 的 **cell**。
/// 给 cell 设 `isHidden` 只会把内容藏掉、**高度还在**，页面上留下一片空白；本文件
/// （机制移植自上游 `Player/PlayerDeclutter.x.swift`）拦截
/// `preferredLayoutAttributesFittingAttributes(_:)`，把返回尺寸的**高度改成 0** ——
/// 卡片真的被折掉，后面的内容顶上来。
///
/// ## 判定方式：marker 表 + 每格缓存
///
/// 一个 hook 挂在 `_TtC12Element_List18CollectionViewCell` 上；判定是"把这一格子树里
/// 所有类名 + 无障碍 id 拼成一个字符串，看它包含哪个 marker"：
///
///   · 先要求串里出现 `NowPlaying_ScrollAPI` —— 只认听歌页那个滚动列表，别处同款 cell 不碰；
///   · 再按 `PlayerCard.markers` 逐条匹配，命中且**这张卡被关掉**才折；
///   · 总开关（`hidePlayerCards`）只对"不属于 `NowPlaying_ModesImpl`"的格子生效 ——
///     那三个 unit 是播放控件/信息区，不属于"卡片"。
///
/// marker 全部在 `dump-9.1.88.txt` 里逐条查过（2026-10-13）。
///
/// ⚠️ **故意不做按钮类**（shuffle / repeat / addTo / queue / share / connect / 歌词预览）：
/// 藏掉按钮等于功能没了，而用户 2026-10-11 亲手点名在用其中几颗。这一批只折卡片。
///
/// ## 开关是运行期读的
///
/// `isHidden(_:)` 每次都读 UserDefaults ⇒ 开关一改，下一次 layout 就生效；
/// `refresh()` 再补一次"当场生效"（作废缓存 + 让那个 collection view 重新问尺寸）。
struct PlayerCardsDeclutterGroup: HookGroup {}

enum PlayerCard: String, CaseIterable {
    // 顺序 = 匹配顺序，与上游 `PlayerPart.cards` 一致，不要随手调。
    case lyricsCard, aboutArtist, relatedVideos, songDNA, liveEvents
    case exploreArtist, releaseCountdown, credits, merch, recommendations

    /// 判定用 marker：命中元素子树里任意类名 / 无障碍 id 的**子串**。
    ///
    /// 为什么不写全名：这些是 Swift mangled 名（`_TtC22Lyrics_CardElementImpl19LyricsCardElementUI`
    /// 之类），模块名那一段才是稳定的、也是上游实测过的判据。
    var markers: [String] {
        switch self {
        case .lyricsCard: return ["Lyrics_CardElementImpl"]
        case .aboutArtist: return ["CreatorBiography"]
        case .relatedVideos: return ["VideoRecommendations"]
        case .songDNA: return ["SongDNA"]
        case .liveEvents: return ["LiveEvents_", "OnTourEventCard"]
        case .exploreArtist: return ["WatchFeed"]
        case .releaseCountdown: return ["Prerelease"]
        case .credits: return ["Creator_Credits"]
        case .merch: return ["Merch_"]
        case .recommendations: return ["RelatedContentRecommendations"]
        }
    }

    /// 这张卡自己的 UserDefaults 键（每张一个扁平键，与仓库其它开关一致）。
    var key: String {
        switch self {
        case .lyricsCard: return "hidePlayerCardLyrics"
        case .aboutArtist: return "hidePlayerCardAboutArtist"
        case .relatedVideos: return "hidePlayerCardRelatedVideos"
        case .songDNA: return "hidePlayerCardSongDNA"
        case .liveEvents: return "hidePlayerCardLiveEvents"
        case .exploreArtist: return "hidePlayerCardExploreArtist"
        case .releaseCountdown: return "hidePlayerCardReleaseCountdown"
        case .credits: return "hidePlayerCardCredits"
        case .merch: return "hidePlayerCardMerch"
        case .recommendations: return "hidePlayerCardRecommendations"
        }
    }

    /// 设置页那一行的 l10n 键。
    var labelKey: String { "player_card_\(rawValue)" }
}

enum PlayerCardsDeclutter {

    /// 总开关：一次折掉所有卡片。
    static let masterKey = "hidePlayerCards"

    /// 进 `UserDefaults.ownedKeys` 白名单的全部键（备份 / 完全重置要认识它们）。
    static var allKeys: [String] { [masterKey] + PlayerCard.allCases.map(\.key) }

    static var masterHidden: Bool {
        get { flag(masterKey) }
        set { UserDefaults.container.set(newValue, forKey: masterKey) }
    }

    static func isHidden(_ card: PlayerCard) -> Bool { flag(card.key) }

    static func setHidden(_ card: PlayerCard, _ value: Bool) {
        UserDefaults.container.set(value, forKey: card.key)
    }

    /// 有任何一张卡被关掉（含总开关）⇒ `activatePlayerCardsDeclutter` 才装 hook。
    static var isActive: Bool {
        masterHidden || PlayerCard.allCases.contains { isHidden($0) }
    }

    /// 当前全部卡片的开关快照 —— 设置页的影子值用它，**加一张卡片不用改设置页**。
    static func snapshot() -> [PlayerCard: Bool] {
        Dictionary(uniqueKeysWithValues: PlayerCard.allCases.map { ($0, isHidden($0)) })
    }

    private static func flag(_ key: String) -> Bool {
        UserDefaults.container.object(forKey: key) as? Bool ?? false
    }

    // MARK: - 判定缓存

    /// 一次判定结果。
    ///
    /// 为什么要缓存：`preferredLayoutAttributesFittingAttributes(_:)` 在滚动时会被**每一格
    /// 每一拍**问到，而判定要遍历整格子树（几十到几百个视图）。上游实测这层缓存是必需的。
    ///
    /// 为什么要 `generation`：开关一改，**旧判定立刻作废** —— 否则"刚被折过的格子"会一直
    /// 复用 `collapse=true`，用户关掉开关卡片也不回来。`refresh()` 里自增。
    private final class Verdict {
        let generation: Int
        weak var content: UIView?
        let collapse: Bool
        let settled: Bool
        let born: CFTimeInterval
        let time = CACurrentMediaTime()

        init(generation: Int, content: UIView?, collapse: Bool, settled: Bool, born: CFTimeInterval) {
            self.generation = generation
            self.content = content
            self.collapse = collapse
            self.settled = settled
            self.born = born
        }
    }

    private static var cacheKey: UInt8 = 0
    private static var generation: Int = 0
    private static let retryWindow: CFTimeInterval = 5
    private static var logged = Set<String>()

    /// 最近一次判定过的格子 —— 只用来在 `refresh()` 里找到"那个" collection view。
    private static weak var lastCell: UICollectionViewCell?

    /// 这一格要不要折起来。（hook 每次布局都会问它。）
    static func shouldCollapse(_ cell: UIView) -> Bool {
        if let collectionCell = cell as? UICollectionViewCell { lastCell = collectionCell }

        let content = (cell as? UICollectionViewCell)?.contentView.subviews.first
        let now = CACurrentMediaTime()
        var born = now

        if let verdict = objc_getAssociatedObject(cell, &cacheKey) as? Verdict,
           verdict.generation == generation,
           verdict.content === content,
           content != nil {
            // 卡片的内容视图可能比第一次检查**晚到** ⇒ "没命中且没定案"的判定 1 秒内重试。
            if verdict.collapse || verdict.settled || now - verdict.time < 1 { return verdict.collapse }
            born = verdict.born
        }

        let (collapse, matched, known) = classify(cell)
        let settled = content != nil && (known || now - born >= retryWindow)
        objc_setAssociatedObject(
            cell,
            &cacheKey,
            Verdict(generation: generation, content: content, collapse: collapse, settled: settled, born: born),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )

        if collapse, logged.insert(matched?.rawValue ?? "all").inserted {
            writeDebugLog("[PlayerCards] collapsed \(matched?.rawValue ?? "all cards")")
        }
        return collapse
    }

    private static func classify(_ cell: UIView) -> (collapse: Bool, matched: PlayerCard?, known: Bool) {
        // 嵌套的同类型 cell（横向轮播里再套一格）= 不是我们要判的那一层。
        var ancestor = cell.superview
        while let view = ancestor {
            if type(of: view) == type(of: cell) { return (false, nil, true) }
            ancestor = view.superview
        }

        var names = ""
        var queue = [cell]
        while !queue.isEmpty {
            let view = queue.removeFirst()
            // 子树里嵌的 collection view 可能还没布局过，名字取不全 ⇒ 先催一拍。
            if view !== cell, view is UICollectionView { view.layoutIfNeeded() }
            names += NSStringFromClass(type(of: view))
            if let id = view.accessibilityIdentifier { names += id }
            queue += view.subviews
        }

        // 只认听歌页的滚动列表；别处的同款 cell 一律不碰。
        guard names.contains("NowPlaying_ScrollAPI") else { return (false, nil, false) }

        let matched = PlayerCard.allCases.first { card in
            card.markers.contains { names.contains($0) }
        }

        let collapse: Bool
        if let matched, isHidden(matched) {
            collapse = true
        } else if masterHidden, !names.contains("NowPlaying_ModesImpl") {
            // 总开关：把"卡片"全折掉，但播放控件/信息区那三个 unit 不算卡片。
            collapse = true
        } else {
            collapse = false
        }

        // `known`：已经能确定这一格是什么（命中 marker，或者它本来就是控件区）⇒ 不必再重试。
        return (collapse, matched, matched != nil || names.contains("NowPlaying_ModesImpl"))
    }

    // MARK: - 当场生效

    /// 开关被切换后调用：让已判定过的格子**重新问一次**尺寸。
    ///
    /// 两件事：① 作废全部缓存判定（见 `Verdict.generation`）；② 让最近见过的那个听歌页
    /// collection view 失效布局 —— 它会重新逐格调用
    /// `preferredLayoutAttributesFittingAttributes(_:)`，于是"打开就折、关掉就回来"。
    ///
    /// 找不到那个 collection view 时什么都不做：下一次 layout 本来也会重算。
    static func refresh() {
        generation += 1
        guard let cell = lastCell, let collection = enclosingCollectionView(of: cell) else { return }
        collection.collectionViewLayout.invalidateLayout()
    }

    /// 逐层向上找最近的 collection view（深度有上限，找不到就算了）。
    private static func enclosingCollectionView(of view: UIView) -> UICollectionView? {
        var node: UIView? = view.superview
        var depth = 0
        while let current = node, depth < 8 {
            if let collection = current as? UICollectionView { return collection }
            node = current.superview
            depth += 1
        }
        return nil
    }
}

/// 挂在听歌页滚动列表的 cell 上，把要藏的卡片**折成 0 高**。
class PlayerCardCellHook: ClassHook<UICollectionViewCell> {
    typealias Group = PlayerCardsDeclutterGroup
    static let targetName = "_TtC12Element_List18CollectionViewCell"

    func preferredLayoutAttributesFittingAttributes(
        _ attributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
        let result = orig.preferredLayoutAttributesFittingAttributes(attributes)
        guard PlayerCardsDeclutter.shouldCollapse(target) else { return result }
        result.size = CGSize(width: result.size.width, height: 0)
        // 折起来之后内容仍在视图里，不裁剪的话会溢到相邻格子上。
        target.clipsToBounds = true
        return result
    }
}

func activatePlayerCardsDeclutter() {
    guard PlayerCardsDeclutter.isActive else { return }

    let target = PlayerCardCellHook.targetName
    guard NSClassFromString(target) != nil else {
        writeDebugLog("[PlayerCards] skipped: \(target) not found on this Spotify build")
        return
    }

    let start = CFAbsoluteTimeGetCurrent()
    PlayerCardsDeclutterGroup().activate()

    let hiddenCards = PlayerCard.allCases.filter { PlayerCardsDeclutter.isHidden($0) }
    let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
    writeDebugLog(
        "[PlayerCards] on — all=\(PlayerCardsDeclutter.masterHidden ? "YES" : "no")"
            + " cards=[\(hiddenCards.map(\.rawValue).joined(separator: ", "))]"
            + " (\(String(format: "%.2f", elapsed)) ms)"
    )
}
