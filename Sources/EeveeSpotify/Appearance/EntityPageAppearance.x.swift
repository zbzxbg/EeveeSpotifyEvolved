import CoreImage
import Foundation
import UIKit

/// 专辑页 / 歌单页的 **AM 化**：① 取色底 field　② 封面下缘溶解。
///
/// ── 为什么是这两件（证据）──────────────────────────────────────────────────
///
/// · **AM 的专辑/歌单页 = 封面取色的渐变场 + 封面"溶"进那片颜色**（不是全屏播放器那套
///   Metal 流体渐变 —— 那是播放器的，查证见 aadishv.dev/music）。pw 的 `AlbumField` 就是
///   照 AM 做的，它的文件头逐字写着树里的实情：
///   *"the header's colour wash (a LegacyUI HeaderView the height of the header, with Spotify's
///   GradientView in it)"* ⇒ **Spotify 本来就有头部色晕**，所以 AM 的差别是"**整页**那片颜色
///   + 封面溶进去"，不是"有没有色底"。
/// · **必须清底色**：pw 同一条注释里点名 —— list 与**每个 cell** 都会自己画一层 base surface
///   （`#121212`）；不清掉，铺在页面最底层的 field **根本看不见**。这是"整页变黑"那条老坑的近亲，
///   所以这里清得**非常死**：只清"颜色恰好等于 `#121212`"的那些视图，而且只在这个页面子树里
///   （深度 ≤ 7、节点 ≤ 600），关掉开关**逐个写回原色**。
/// · **不碰 header 的 alpha**：专辑页那次淡入淡出在**父**元素
///   `CreativeWorkPlatform.Header` 上（日志 77：`alpha=-0.42 → 0.59 → -0.05`），
///   `CreativeWorkHeader` 自己是 1.00 ⇒ 谁去动 alpha 谁就跟它打架。
///
/// ── 找谁（日志 78 的探针实测，不是猜的）────────────────────────────────────
///
/// | 页面 | 页面 root | 封面 |
/// |---|---|---|
/// | 专辑 | `CreativeWorkPlatform.CreativeWorkTemplateView` | `CreativeWorkPlatform.Components.UI.ArtWorkElement.WithCoverArt`（248×248 @ 83,62） |
/// | 歌单 | 往上找到"占满屏"的那一层（页面 root 的 id 我们还没拿到） | `Components.Header.UI.ArtworkImage`（262×262 @ 76,62），里面有 `EditableHeaderArtworkElement.ImageView` |
///
/// ── 开关 ─────────────────────────────────────────────────────────────────
///
/// 扩展功能 →「**页面取色底（AM 化）**」两颗，各自独立：
///   · 「封面取色底」`UserDefaults.entityPageField`（默认开）
///   · 「封面下缘溶解」`UserDefaults.entityPageDissolve`（默认开）
/// 两颗都关掉 = **一个字节都不改**（清过的底色逐个写回、两层视图撤掉）。
/// 日志 tag：`[PageField]`。
enum EntityPageAppearance {

    static let logTag = "PageField"

    /// 页面 root 的候选 id（歌单页 root 的 id 还没拿到 ⇒ 用"占满屏"那条几何兜底）。
    private static let pageIdentifiers = ["CreativeWorkPlatform.CreativeWorkTemplateView"]
    /// 封面元素的候选 id。
    private static let coverIdentifiers = [
        "CreativeWorkPlatform.Components.UI.ArtWorkElement.WithCoverArt",
        "Components.Header.UI.ArtworkImage",
    ]
    /// 清底色时往下走几层 / 最多看多少个节点（**宁可漏，不可错**）。
    private static let clearDepth = 7
    private static let clearNodes = 600
    /// 取色底占页面高度的比例（再往下就是 base surface，看不出接缝）。
    private static let fieldColorEnd: CGFloat = 0.58
    /// 封面化开成的那片背景占页面高度的比例（pw 那张 playlist 截图约 45%，这里给到 52%）。
    private static let heroHeightRatio: CGFloat = 0.52
    /// 底子的模糊半径 —— **照 MeloX 的常数**：它是 `filter.radius = 18`，
    /// 而且作用在"**先缩到最长边 160px**"的那张图上（`makeBlurredBackdrop` ✓）。
    /// 先缩再糊 = 半径的相对强度可控、也快 ✓。
    private static let meloxBlurRadius: CGFloat = 18
    /// 先降采样到的目标最长边（MeloX 的 `downsampled` 就是 `160 / max(width, height)`）。
    private static let meloxDownsampleEdge: CGFloat = 160

    // MARK: - 状态

    private static var timer: Timer?
    private static var currentPage: UIView?
    private static var field: GradientView?
    /// 底子那张**模糊**封面（见 `ensureHero` ①）。
    private static var hero: UIImageView?
    /// ★ 2026-10-13：铺在最上面的那张**清晰满幅**封面（见 `ensureHero` ②）。
    private static var sharpHero: UIImageView?
    /// 满幅 hero 的**单调高度**（"到过的最深处"），存在**那块 plane** 上（pw 的 `kHeroHeightKey`）。
    private static var heroHeightKey: UInt8 = 0
    /// hero 的最小高度（pw 的 `kMinHero = 120`）：比这矮就不画，免得出来一条细带。
    private static let minHeroHeight: CGFloat = 120
    /// 被我们藏掉的 wash 视图（**记原值**，关开关原样撤回）—— 见 `concealWash` / `revealWash`。
    private static var concealedWash: [
        (view: UIView, layerHidden: Bool, hadMask: Bool, interactive: Bool, accessibilityHidden: Bool)
    ] = []
    /// Spotify 自己那张封面 —— 被我们**让位**藏起来的那张。
    ///
    /// ⚠️ 记的是"**我们改了什么**"，关开关时只撤回这些（Spotify 自己的 hidden 一律不碰）——
    /// 与 `DeclutterChrome` 同一条纪律。
    private static var concealedNativeCover: NativeCoverRecord?

    private struct NativeCoverRecord {
        let view: UIView
        let layerHidden: Bool
        let hadMask: Bool
        let interactive: Bool
        let accessibilityHidden: Bool
    }
    /// 模糊结果按"哪张图"缓存一次（同一张封面不重复跑 CoreImage）。
    private static var cachedHeroSource: UIImage?
    private static var cachedHeroImage: UIImage?
    private static let ciContext = CIContext(options: nil)
    /// 我们清过的底色（**记原值**：关开关要逐个写回 —— 与 `DeclutterChrome` 同一条纪律）。
    private static var clearedBackgrounds: [(view: UIView, color: UIColor)] = []
    /// 已经清过的**对象**（懒建的 cell 每拍都要查一遍，但只记一次；`ObjectIdentifier` 不做强引用）。
    private static var clearedViews: Set<ObjectIdentifier> = []
    /// 上面两张表的上限（封死，不让它随着滚动无限长）。
    private static let maxCleared = 1200
    /// 「专辑页找到了、但封面图还没加载出来」只报一次（否则那 0.6s 的节拍会刷屏）。
    private static var didReportMissingColour = false
    /// Spotify 自己的按键里，**这些 id 片段**的一律藏掉（见 `hideChrome`）。
    ///
    /// ⚠️ **按片段匹配、不按整串**：真机日志 78 里头部那几颗是
    /// `Components.UI.AddToButton` / `DownloadButton.Granular.None` /
    /// `Components.UI.ContextMenuButton-2iyK0BOpYVMJUpDkAwVhph`（**带一段随机后缀**）/
    /// `Components.UI.WatchFeedEntityExplorerButton` —— 整串比对会漏掉带后缀的那种 ✗。
    ///
    /// ⛔ **`ContextMenuButton` 故意不在这张名单里**（2026-10-13 自查发现）：
    /// 它就是**右上那颗「…」**，而 pw 的整套做法**恰恰骑在它上面** ——
    /// `PlaylistMenu.x` 逐字写着 Spotify 的那七颗 pill 里有五颗
    /// （`Add / Notes / Video / Edit / Name & details`）**⋯ 菜单本来就有**，
    /// pw 只把缺的 `Sort` / `Mix` 补进这张 sheet 的 header，点的还是 Spotify 自己那颗 pill。
    /// ⇒ 把「…」藏掉 = 把我们要往里加东西的那个面板弄没了 ✗（早期的名单里就有它，这里撤回）。
    ///
    /// ⚠️ 剩下的三项（AddTo / Download / WatchFeed）**藏之前要确认 ⋯ 里确实有对应的行** ——
    /// 这正是 pw 反复强调的"只做加法"；行内那两颗（每行的「+」「…」）**id 还没读到过**，
    /// 命不中也不会有副作用，而且**藏了哪些 id 会打进日志**，下一份日志就能看到它们叫什么。
    private static let chromeIdentifierFragments = [
        "AddToButton",
        "DownloadButton",
        "WatchFeedEntityExplorerButton",
    ]
    private static var hiddenChrome: [(view: UIView, alpha: CGFloat)] = []
    private static var hiddenChromeViews: Set<ObjectIdentifier> = []
    private static let maxHiddenChrome = 400
    private static var didReport = false
    /// "清掉了一个页面容器"只报一次（见 `clearPageContainers`）。
    private static var didReportContainerClear = false
    private static var lastLoggedHex: String?

    // MARK: - 入口

    static var isEnabled: Bool { UserDefaults.entityPageDissolve }

    /// 缓存"这一拍那棵树里的封面元素"（见 `layoutPass`），省掉每帧一次子树搜索。
    private static var layoutCoverKey: UInt8 = 0

    /// **每一帧的轻量入口**（从 `HeaderContentLayout.layoutSubviews` 调，见 `EntityPageHeader.x.swift`）。
    ///
    /// 治的是用户 2026-10-13 报的：「刚进歌单页的时候，原本有的小歌单封面会短暂展现一会」——
    /// 我们原来只有 0.6s 的 `Timer` 会调 `concealNativeCover`，而 Spotify 那张 262×262 的封面
    /// **在第一帧就已经画出来了** ⇒ 最坏 0.6s 的可见窗口。
    ///
    /// pw 的 `PlaylistHeader.x` 是从 `HeaderContentLayout.layoutSubviews` 每帧调 `applyHero` 的，
    /// 而 `applyHero` 的最后一行就是 `conceal(cover)` ⇒ **第一帧就藏**。这里照做，但只做这一件
    /// **幂等且便宜**的事：取色 / 模糊 / 建 field 那些重活仍留在 `tick` 里（0.6s 一次）。
    static func layoutPass(in layout: UIView) {
        guard isEnabled else { return }
        guard layout.bounds.width > 120, layout.bounds.height > 40 else { return }
        // ⚠️ **只处理我们确实会铺 hero 的那两种页面**（专辑页 / 歌单页）。
        //    艺人页的头也是 `HeaderContentLayout`，封面元素也正好叫
        //    `Components.Header.UI.ArtworkImage`（pw 的 `ArtistHeader.x` 同样这么找）——
        //    我们**没有**给艺人页铺替补，误藏就是"艺人页照片不见了"。判据只沿祖先链走，
        //    比 `currentTarget()` 便宜，也足够安全。
        guard recognizesPage(of: layout) else { return }

        let cover: UIView?
        if let cached = objc_getAssociatedObject(layout, &layoutCoverKey) as? UIView,
           cached.window != nil, cached.isDescendant(of: layout) {
            cover = cached
        } else {
            cover = firstView(in: layout, withAnyIdentifier: coverIdentifiers)
            objc_setAssociatedObject(layout, &layoutCoverKey, cover, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        guard let cover else { return }
        concealNativeCover(cover)
    }

    /// `layout` 是不是我们要接管的那两种页面之一：专辑页（页面 root 带 id）或歌单页（页头 id `PL.Header`）。
    private static func recognizesPage(of layout: UIView) -> Bool {
        var node: UIView? = layout
        var level = 0
        while let current = node, level < 24 {
            level += 1
            if let identifier = current.accessibilityIdentifier,
               pageIdentifiers.contains(identifier) || identifier == "PL.Header" {
                return true
            }
            node = current.superview
        }
        return false
    }

    static func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.6, repeats: true) { _ in tick() }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        writeDebugLog(
            "[\(logTag)] armed — Melox page look \(UserDefaults.entityPageDissolve ? "ON" : "OFF"),"
                + " hiding Spotify's repeated buttons \(UserDefaults.entityPageHideChrome ? "ON" : "OFF")"
        )
    }

    private static func tick() {
        // ★ 2026-10-13（用户：「有些选项可以改改或者删掉了」）：**「封面取色底」并进这一颗了** ——
        //   在用户眼里"模糊封面底"与"整页取色底"就是同一件事的两半（都是拿封面的颜色铺底），
        //   设置页因此从**三颗减到两颗**；代码里两条路径**留着**（要单独排查时能只关一半）。
        let wantsField = UserDefaults.entityPageDissolve
        let wantsDissolve = UserDefaults.entityPageDissolve

        guard let target = currentTarget() else {
            // 页面走了：把上一页留下的东西全部还原（切页/退出都不留残迹）。
            if currentPage != nil || field != nil || hero != nil || sharpHero != nil || concealedNativeCover != nil {
                restore(reason: "left the page")
            }
            // 底色拦截器也一起松手（照片 103 的那条硬边就是它要治的：Spotify 重画底色 ⇒ 丢这次写入）。
            EntityPageRepaint.root = nil
            return
        }

        if target.page !== currentPage {
            restore(reason: "another page")
            currentPage = target.page
        }
        EntityPageRepaint.root = target.page

        if wantsField {
            ensureField(on: target)
        } else if field != nil {
            restore(reason: "field switch off")
        }

        if wantsDissolve {
            ensureHero(on: target)
            // ④ 头部居中（Melox 的三段式）—— 与"模糊底"同属这一颗开关下的"页面样式"。
            centerHeaderLabels(in: target.page)
        } else if hero != nil || sharpHero != nil || concealedNativeCover != nil || !centeredLabels.isEmpty {
            removeHero()
            restoreCentering()
        }

        // ③ Spotify 自己那些按键（用户 2026-10-13：「spotify 本身的那些按键都还在，看起来不咋地」）。
        if UserDefaults.entityPageHideChrome {
            hideChrome(in: target.page)
        } else if !hiddenChrome.isEmpty {
            restoreChrome(reason: "chrome switch off")
        }
    }

    // MARK: - ① 取色底

    private static func ensureField(on target: Target) {
        guard let color = target.color else { return }
        let page = target.page

        let view: GradientView
        if let field, field.superview === page {
            view = field
        } else {
            view = GradientView(frame: page.bounds)
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.isUserInteractionEnabled = false
            view.accessibilityIdentifier = "eevee-page-field"
            page.insertSubview(view, at: 0)
            field = view
            clearBaseSurfaces(in: page)
        }

        if !view.frame.equalTo(page.bounds) { view.frame = page.bounds }
        paintField(view, color: color)

        // ★ 2026-10-13（**日志 79** 实测只有 7 处被清之后发现）：**每一拍都要补清**。
        //   cell 是**随滚动懒建**的 —— 只在建场那一拍清一次的话，往下滚出来的新 cell 会自己再画一层
        //   `#121212`，把 field **重新盖住**（pw 那边也是持续在清：它的注释点名 list 与每个 cell）。
        //   已经清过的按对象记住，不会重复记、也不会重复写。
        clearBaseSurfaces(in: page)
        // ★ 2026-10-13（照片 110）：**页面直接子视图那一层也要清** —— 见 `clearPageContainers`。
        clearPageContainers(in: page)

        guard !didReport else { return }
        didReport = true
        writeDebugLog(
            "[\(logTag)] field on \(type(of: page)) \(frameText(page.bounds))"
                + " ← cover colour #\(hex(of: color))"
                + "; cleared \(clearedBackgrounds.count) base-surface background(s)"
                + " (only the ones equal to #121212, inside this page, depth ≤ \(clearDepth));"
                + " gradient stops 0 / \(Int(fieldColorEnd * 100))% / 100%"
        )
    }

    /// 竖直渐变：顶部是封面取色 → 中段压暗 → **到底仍然留着这片颜色**。
    ///
    /// ⚠️ **照片 95-97 的教训**：原来 57% 之后就是纯 `#121212` ⇒ 用户看到的是"**下半部分还是黑的**" ✗。
    /// pw 的字段是 `bleed = {600, 0, 600, 0}`（**比整页还大一圈**，见 `AlbumField.x` / `PlaylistField.x`），
    /// 整页都带着那片颜色 ⇒ 这里改成**三段同色相**：取色 → 压暗 → 更暗，全程带色、只是越往下越沉。
    private static func paintField(_ view: GradientView, color: UIColor) {
        // ★ 2026-10-13（照片 110：「专辑页往下滑，是全黑的，没有颜色」）：两个上限原来分别是
        //   0.26 / 0.14 —— 14% 亮度基本就是黑，所以越往下越"没颜色"。抬到 0.42 / 0.28：
        //   全程看得出是封面的色相，到底仍然是"这片颜色"而不是 #121212。
        let middle = tinted(color, atMost: 0.42)
        let bottom = tinted(color, atMost: 0.28)
        let layer = view.gradient
        layer.startPoint = CGPoint(x: 0.5, y: 0)
        layer.endPoint = CGPoint(x: 0.5, y: 1)
        layer.locations = [
            NSNumber(value: 0),
            NSNumber(value: Double(fieldColorEnd)),
            NSNumber(value: 1),
        ]
        layer.colors = [color.cgColor, middle.cgColor, bottom.cgColor]
        let key = hex(of: color)
        if key != lastLoggedHex {
            lastLoggedHex = key
            writeDebugLog(
                "[\(logTag)] field colour is now #\(key) — top \(key),"
                    + " \(Int(fieldColorEnd * 100))% #\(hex(of: middle)), bottom #\(hex(of: bottom))"
                    + " (the whole page keeps the cover's tint; it never fades to plain #121212)"
            )
        }
    }

    /// 同一**色相**压暗（保住"就是这片颜色"的观感，而不是褪成中性灰 ✗）。
    private static func tinted(_ color: UIColor, atMost ceiling: CGFloat) -> UIColor {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else {
            return UIColor(white: ceiling, alpha: 1)
        }
        return UIColor(
            hue: hue,
            saturation: min(1, saturation * 1.05),
            brightness: min(brightness, ceiling),
            alpha: 1
        )
    }

    /// **只清那些颜色恰好是 `#121212` 的视图**（pw 的教训：list 与每个 cell 都自己画这层）。
    ///
    /// ⚠️ **每一拍都调**：新 cell 是懒建的，清一次不够（见 `ensureField` 里的调用点）。
    /// 清过的按对象记下来，第二次走到它就不重复记；上限封死，不会无限长。
    private static func clearBaseSurfaces(in page: UIView) {
        guard clearedBackgrounds.count < maxCleared else { return }
        var seen = 0

        func walk(_ node: UIView, _ depth: Int) {
            guard depth <= clearDepth, seen < clearNodes, clearedBackgrounds.count < maxCleared else { return }
            seen += 1
            let identifier = ObjectIdentifier(node)
            if let color = node.backgroundColor, isBaseSurface(color), !clearedViews.contains(identifier) {
                clearedViews.insert(identifier)
                clearedBackgrounds.append((view: node, color: color))
                node.backgroundColor = .clear
            }
            for sub in node.subviews { walk(sub, depth + 1) }
        }

        walk(page, 0)
    }

    /// 判"这是不是 Spotify 画的那层 base surface"。
    ///
    /// ⚠️ **照片 95-97 的教训**：原来卡在 `#121212` ±0.02 ⇒ **同一列表里有的 cell 被清、有的没被清**,
    /// 于是出现"一横条一横条"的色差 —— 用户原话「**有几条线，看起来很怪**」✗。
    /// 改成"**很暗的中性色都算**"（三通道互差 ≤ 0.03、最亮通道 ≤ 0.12）⇒ 一致性回来了。
    /// （现在字段整页带色，多清一点不会有副作用 ✓。）
    private static func isBaseSurface(_ color: UIColor) -> Bool {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha), alpha > 0.9 else {
            return false
        }
        let brightest = max(red, max(green, blue))
        let darkest = min(red, min(green, blue))
        return brightest <= 0.12 && (brightest - darkest) <= 0.03
    }

    /// ★ 2026-10-13（照片 110：专辑页往下滑**整片黑**）：`clearBaseSurfaces` 只清"**恰好等于** `#121212`"
    /// 而且只走到 `depth ≤ 7` —— 而盖住 field 的那一层是**页面的直接子视图**（列表的祖先容器，
    /// 也就是 pw 树里那个 `CreativeWorkPlatform.Tab`）：它比 7 层浅，但颜色不是 `#121212`，
    /// 所以日志 89 那行 `cleared 0 base-surface background(s)` 一个都没命中，它就一直不透明地压着 field。
    ///
    /// 这里对**页面的每个直接子视图**单独来一遍，判据放宽到"近黑近灰"，而且**不递归**
    /// （只清容器那一层，不碰内容，免得把 cell 里该有的深色也清掉）。
    private static func clearPageContainers(in page: UIView) {
        for sub in page.subviews where sub !== field {
            guard let colour = sub.backgroundColor else { continue }
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            guard colour.getRed(&red, green: &green, blue: &blue, alpha: &alpha), alpha > 0.5 else { continue }
            let brightest = max(red, max(green, blue))
            let darkest = min(red, min(green, blue))
            guard brightest <= 0.25, (brightest - darkest) <= 0.04 else { continue }
            if !didReportContainerClear {
                didReportContainerClear = true
                writeDebugLog(
                    "[\(logTag)] cleared a page container: \(type(of: sub)) \(frameText(sub.frame))"
                        + " had \(hex(of: colour)) — that was the layer covering the field"
                )
            }
            sub.backgroundColor = .clear
        }
    }

    // MARK: - ② 封面溶进背景

    /// 用户 2026-10-13 指着 pw 的 playlist 截图：「**pw 的做法是把封面溶进背景**」——
    /// 封面放大铺满页面顶部、向下**化开**成一片颜色，标题与文字就压在这片颜色上
    /// （pw 的 `Redesigned/Playlist/PlaylistHeader.x` 与 `AlbumHeader.x` 做的同一件事）。
    ///
    /// 这里**只做加法、不动布局**：自己画大图，垫在 field **之上**、页面内容**之下** ——
    /// 文字与按钮还在原处，于是正好压在这片化开的颜色上。
    ///
    /// 两张图，各管一半：
    ///   · ① **模糊**那张（本函数）铺满页面顶部，负责"化开之后露出来的那片颜色"；
    ///   · ② **清晰**那张（`ensureSharpHero`）是**满幅的封面本身**，底部 54% 起化开 ——
    ///     于是"整张封面融进底子"，而不是"模糊底 + 原地一张小卡"。
    private static func ensureHero(on target: Target) {
        guard let cover = target.cover else { return }
        // ★ 2026-10-13：**图还没到也要先把 Spotify 那张小封面藏掉**。原来这里和 `let source`
        //   一起 guard，于是"封面元素在、图还没加载出来"的那几拍里原生封面一直亮着
        //   （`layoutPass` 每帧补的那一次能盖住大部分，这里是第二道保险）。
        concealNativeCover(cover)
        guard let source = coverImage(in: cover) else { return }
        let container = target.page

        let height = max(180, min(container.bounds.height * heroHeightRatio, 560))
        // ★ 2026-10-13（用户：「专辑封面直接铺到手机顶部…所有 app 都会留一块缓冲区（刘海、灵动岛、
        //   状态栏）」）：**专辑页从状态栏下面开始**。pw 的专辑页也是这样 —— 它的树注释逐字：
        //   `UIView {0, 78} the top inset, the status bar and the navigation bar's room`，
        //   hero 就插在那个头里，所以封面本来就避开了状态栏那一条。
        //   歌单页**不动**：pw 的歌单页是铺到顶的（hero 在 wash plane 里，plane 从 y=-134 起）。
        let onAlbumPage = firstView(
            in: container,
            withAnyIdentifier: ["CreativeWorkPlatform.Components.UI.CreativeWorkHeader"]
        ) != nil
        let topInset = onAlbumPage ? container.safeAreaInsets.top : 0
        let frame = CGRect(
            x: 0,
            y: topInset,
            width: container.bounds.width,
            height: max(minHeroHeight, height - topInset)
        )

        let view: UIImageView
        if let hero, hero.superview === container {
            view = hero
        } else {
            removeHero()
            view = UIImageView()
            view.contentMode = .scaleAspectFill
            view.clipsToBounds = true
            view.isUserInteractionEnabled = false
            view.accessibilityIdentifier = "eevee-page-hero"
            if let field, field.superview === container {
                container.insertSubview(view, aboveSubview: field)
            } else {
                container.insertSubview(view, at: 0)
            }
            hero = view
            writeDebugLog(
                "[\(logTag)] hero \(frameText(frame)) in \(type(of: container))"
                    + " — blurred backdrop for the colour the dissolve fades into;"
                    + " the sharp full-bleed cover goes on top of it (see `ensureSharpHero`)"
            )
        }

        if !view.frame.equalTo(frame) { view.frame = frame }

        // 模糊一次、按"哪张图"缓存（同一张封面不重复跑 CoreImage；失败就退回原图，不能因此不画）。
        if cachedHeroSource !== source {
            cachedHeroSource = source
            cachedHeroImage = blurred(source) ?? source
            view.image = cachedHeroImage
        }

        // 向下化开：上 54% 不透明 → 底全透明（露出后面那片取色底/模糊底）。
        applyDissolveMask(to: view, opaqueFraction: 0.54)

        // ② ★ 2026-10-13（用户看真机后：「也不是把封面整个融进底子」）：
        //    **把清晰的封面本身铺成满幅**、底部化进下面那片颜色 —— 这才是 pw 的结构
        //    （`PlaylistHeader.x`：the cover runs full bleed across the top of the page and
        //    dissolves into the page's colour）。上一版是"模糊底 + 原地一张小卡"的 Melox 结构，
        //    而用户要的是"整张封面融进去" ⇒ Spotify 自己那张小封面**让位**（按层藏，可原样撤回）。
        ensureSharpHero(cover: cover, source: source, page: container)
    }

    /// 满幅那张清晰封面。
    ///
    /// ★ 2026-10-13 **第二版**（用户真机反馈：「刚进去没封面，往下滑才有，而且封面一直在底部」）——
    /// **照 pw 的定位方式重写**（`PlaylistHeader.x` 的 `applyBackground` + `applyHero`，v0.21.1 / GPL-3.0）。
    ///
    /// 我第一版按"封面在**页面根**坐标里的 y"来摆，三条都错，而且都源自同一个错：
    ///   · 进场时封面的帧还没定、图也还没来 ⇒ 什么都不画（"刚进去没封面"）；
    ///   · 位置不跟着 Spotify 自己那块裁剪面走 ⇒ 滑一下才读到一个帧，而且停在错的地方（"一直在底部"）。
    ///
    /// pw 的做法是**把图塞进 Spotify 自己画那层颜色 wash 的 plane 里**，坐标用 **plane 自己的 (0,0)**，
    /// 高度只取"到过的最深处"（单调增），移动**交给 Spotify 的 plane**。它的原话：
    ///
    /// > the hero belongs in the plane Spotify's own colour wash is drawn on … So the picture needs
    /// > no help to move — Core Animation carries it with the plane, in the same motion Spotify gives
    /// > the cover itself. … the hero is measured once … and its [movement] is the plane's movement,
    /// > which is Spotify's to make and ours to sit still inside.
    ///
    /// ⚠️ `_backgroundViewContainer` 里那些 wash 的 `GradientView` 必须**一起藏掉**：pw 的 issue #53
    /// 就是"wash 的 alpha 被抬高之后，不透明的一层把整张图整个盖住"。
    private static func ensureSharpHero(cover: UIView, source: UIImage, page: UIView) {
        // ★ 2026-10-13（照片 104：专辑页只有一片颜色、没有封面）：**宿主分两种** ——
        //   · 歌单页：Spotify 画页面颜色 wash 的那块 plane（pw 的 `PlaylistHeader.x` 做法）；
        //   · 专辑页：**头自己**（pw 的 `AlbumHeader.x` 逐字：`[header insertSubview:hero atIndex:0]`）。
        //
        //   专辑页**没有** `_backgroundViewContainer`（那是歌单页的结构；它的 wash 是页面里那个
        //   `LegacyUI…HeaderView` + `GradientView`，见 pw 的 `AlbumField.x`）⇒ 原来这里
        //   `guard let plane … else { return }` 一句直接返回 ⇒ **整条 sharpHero 静默不装**：
        //   日志 87 里就只剩 `hero …`（模糊底）而**没有** `sharp hero …` 那一行，
        //   用户看到的正是"只有背景色、没有封面"。
        let plane = washPlane(for: cover)
        let albumHeader = firstView(
            in: page,
            withAnyIdentifier: ["CreativeWorkPlatform.Components.UI.CreativeWorkHeader"]
        )

        let host: UIView
        let layout: UIView
        let onAlbumPage: Bool
        if let plane, plane.bounds.width > 1 {
            host = plane
            layout = headerLayout(of: cover) ?? cover.superview ?? page
            onAlbumPage = false
            concealWash(on: plane)
        } else if let albumHeader, albumHeader.bounds.height > 40 {
            host = albumHeader
            layout = albumHeader
            onAlbumPage = true
            concealAlbumWash(in: page)
        } else {
            return
        }

        let coverFrame = cover.convert(cover.bounds, to: layout)
        // 歌单页那条路要封面已经量好（帧都没量出来就别画）；专辑页铺满整个头，不依赖封面的帧
        // （它可能这一拍还没布局 —— 那正是原来"专辑页永远等不到"的一部分）。
        if !onAlbumPage {
            guard coverFrame.width > 40, coverFrame.height > 40 else { return }
        }

        concealNativeCover(cover)

        // 高度 = **到过的最深处**，下限 `minHeroHeight`，**只增不减** ——
        // pw：页头还在加载时 block 的位置偏高，取"当前值"会让图够不到标题、中间留一条裸色带。
        let reach = onAlbumPage
            ? max(minHeroHeight, host.bounds.height)
            : max(minHeroHeight, coverFrame.maxY + EntityPageHeaderMetrics.titleRise)
        let previous = (objc_getAssociatedObject(host, &heroHeightKey) as? NSNumber)?.doubleValue ?? 0
        let height = max(previous, reach)
        if height != previous {
            objc_setAssociatedObject(host, &heroHeightKey, NSNumber(value: height), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        let frame = CGRect(x: 0, y: 0, width: host.bounds.width, height: round(height))

        let view: UIImageView
        if let sharpHero, sharpHero.superview === host {
            view = sharpHero
        } else {
            sharpHero?.removeFromSuperview()
            let fresh = UIImageView()
            fresh.contentMode = .scaleAspectFill
            fresh.clipsToBounds = true
            fresh.isUserInteractionEnabled = false
            fresh.accessibilityIdentifier = "eevee-page-hero-sharp"
            host.insertSubview(fresh, at: 0)
            sharpHero = fresh
            view = fresh
            writeDebugLog(
                "[\(logTag)] sharp hero in \(onAlbumPage ? "the album header" : "Spotify's wash plane")"
                    + " \(frameText(host.bounds))"
                    + " — the cover \(frameText(coverFrame)) measured in \(type(of: layout));"
                    + (onAlbumPage
                        ? " the header carries it, so it moves with Spotify's own layout"
                        : " the plane carries it, so it moves with Spotify's own layout")
            )
        }

        if !view.frame.equalTo(frame) { view.frame = frame }
        if view.image !== source { view.image = source }
        applyDissolveMask(to: view, opaqueFraction: 0.54)
    }

    /// 专辑页的 wash：页面里那个 `LegacyUI…HeaderView`（头的高度），里面是 Spotify 的 `GradientView`。
    ///
    /// pw 的 `AlbumHeader.x` `applyWash` 逐字：按**类名**找 `HeaderView`（**排除 `NavigationBar`**），
    /// 藏掉它下面的 `GradientView`。歌单页那块 `_backgroundViewContainer` 在专辑页上不存在 ——
    /// 两条路各找各的。
    ///
    /// ⚠️ 不藏的话它照旧画在我们的图**之上**（pw 的 issue #53 就是"不透明的一层把整张图整个盖住"）。
    /// 这里直接复用 `concealWash(on:)`：它拿参数的 **superview** 当容器递归 —— 传 GradientView 进去，
    /// 容器就是那个 HeaderView，正好是它要清的那一块。
    private static func concealAlbumWash(in page: UIView) {
        for sub in page.subviews {
            let name = NSStringFromClass(type(of: sub))
            guard name.contains("HeaderView"), !name.contains("NavigationBar") else { continue }
            for inner in sub.subviews where NSStringFromClass(type(of: inner)).contains("GradientView") {
                concealWash(on: inner)
                return
            }
        }
    }

    /// pw 的 `applyBackground` 逐字：沿**封面的祖先链**找 id = `_backgroundViewContainer` 的容器，
    /// 那块画页面颜色 wash 的 plane 就是**它的第一个子视图**。
    private static func washPlane(for cover: UIView) -> UIView? {
        var node: UIView? = cover
        var guardCount = 0
        while let current = node, guardCount < 12 {
            guardCount += 1
            for sub in current.subviews where sub.accessibilityIdentifier == "_backgroundViewContainer" {
                return sub.subviews.first
            }
            node = current.superview
        }
        return nil
    }

    /// 包着封面的那个 `HeaderContentLayout`（用来把封面的帧换算到"页头自己的坐标系"里）。
    private static func headerLayout(of cover: UIView) -> UIView? {
        var node: UIView? = cover
        while let current = node {
            if NSStringFromClass(type(of: current)).contains("HeaderContentLayout") { return current }
            node = current.superview
        }
        return nil
    }

    /// 把 wash 的 `GradientView` 藏掉。
    ///
    /// ★ 2026-10-13 **第二版**（用户照片 101：整片空泥棕、清晰封面完全看不见）：第一版只看了
    /// **直接子视图**（`container.subviews`），而 Spotify 那层洗色在更深的地方 ⇒ 它照旧画在我们的图
    /// 之上，把整张封面盖掉。pw 的 `applyBackground` 用的是 **`SGForEachView(container, …)`（递归）** ——
    /// 这里照它改成递归，并且**跳过我们自己的 hero 及其子树**（pw 同样跳：
    /// `if (hero && (v == hero || [v isDescendantOfView:hero])) return;`）。
    ///
    /// pw 在同一段里还会把"底色漆"从容器里每个视图上擦掉（issue #53：wash 的 alpha 被抬高后
    /// 不透明的一层会盖住图），这里一并做，并且**把原值记下来**（我们有开关，关掉要还原）。
    private static func concealWash(on plane: UIView) {
        guard let container = plane.superview else { return }

        var queue: [UIView] = [container]
        var visited = 0
        while !queue.isEmpty, visited < 200 {
            let view = queue.removeFirst()
            visited += 1
            queue.append(contentsOf: view.subviews)

            if let hero = sharpHero, view === hero || view.isDescendant(of: hero) { continue }
            if view === plane { continue }

            if NSStringFromClass(type(of: view)).contains("GradientView") {
                recordWash(view)
                continue
            }

            // 底色漆（Spotify 的 base surface）：擦成透明，原色记着。
            if let colour = view.backgroundColor, isBaseSurface(colour) {
                clearedBackgrounds.append((view: view, color: colour))
                view.backgroundColor = .clear
            }
        }
    }

    /// 记下一个被我们藏掉的 wash 视图（**只记我们改的那几样**，见 `revealWash`）。
    private static func recordWash(_ view: UIView) {
        guard !concealedWash.contains(where: { $0.view === view }) else { return }
        concealedWash.append(
            (view: view,
             layerHidden: view.layer.isHidden,
             hadMask: view.layer.mask != nil,
             interactive: view.isUserInteractionEnabled,
             accessibilityHidden: view.accessibilityElementsHidden)
        )
        eeveeConceal(view)
    }

    /// 原样撤回（开关关掉 / 离开页面时）。
    private static func revealWash() {
        for record in concealedWash {
            record.view.layer.isHidden = record.layerHidden
            if !record.hadMask { record.view.layer.mask = nil }
            record.view.isUserInteractionEnabled = record.interactive
            record.view.accessibilityElementsHidden = record.accessibilityHidden
        }
        concealedWash.removeAll()
    }

    // ⚠️ 「底面色」的判据**只留一份**：`isBaseSurface(_:)`（参数是 `UIColor`，在 `clearBaseSurfaces`
    // 那一节里）。我第一版在这里又写了一份一模一样的 —— Swift 只看签名（`isBaseSurface(_:)`），
    // 参数名一个 color 一个 colour 也算重复声明，编译器直接报 `invalid redeclaration`。


    /// 向下化开：上 `opaqueFraction` 不透明 → 底全透明。两张 hero 共用这一份（改一处就够）。
    private static func applyDissolveMask(to view: UIView, opaqueFraction: CGFloat) {
        let mask: CAGradientLayer
        if let existing = view.layer.mask as? CAGradientLayer {
            mask = existing
        } else {
            let layer = CAGradientLayer()
            layer.startPoint = CGPoint(x: 0.5, y: 0)
            layer.endPoint = CGPoint(x: 0.5, y: 1)
            layer.colors = [
                UIColor.white.cgColor,
                UIColor.white.cgColor,
                UIColor.clear.cgColor,
            ]
            layer.locations = [
                NSNumber(value: 0),
                NSNumber(value: opaqueFraction),
                NSNumber(value: 1),
            ]
            view.layer.mask = layer
            mask = layer
        }
        if !mask.frame.equalTo(view.bounds) { mask.frame = view.bounds }
    }

    /// 让 Spotify 自己那张封面**让位**：**改层不改属性**（Spotify 会用 `setHidden:NO` 把视图写回来）
    /// + 空 mask 双保险（Spotify 不碰 mask）。原值全记在 `concealedNativeCover` 里，关开关原样撤回。
    private static func concealNativeCover(_ cover: UIView) {
        // ★ 2026-10-13：这一张**已经记过**时每拍补一次 —— Spotify 会在按下 Play 之类的时候用
        //   `setHidden:NO` 把它写回来（pw 的 `conceal()` 就是每帧无条件补），原来这里直接 return，
        //   于是"写回来之后就再也不藏了"。但**不再覆盖原值记录**，否则关开关还原时会把我们自己
        //   写进去的 hidden 当成"Spotify 的原值"。
        if concealedNativeCover?.view === cover {
            if !cover.layer.isHidden { cover.layer.isHidden = true }
            if cover.layer.mask == nil { cover.layer.mask = CALayer() }
            if cover.isUserInteractionEnabled { cover.isUserInteractionEnabled = false }
            if !cover.accessibilityElementsHidden { cover.accessibilityElementsHidden = true }
            return
        }
        revealNativeCover()

        concealedNativeCover = NativeCoverRecord(
            view: cover,
            layerHidden: cover.layer.isHidden,
            hadMask: cover.layer.mask != nil,
            interactive: cover.isUserInteractionEnabled,
            accessibilityHidden: cover.accessibilityElementsHidden
        )
        cover.layer.isHidden = true
        if cover.layer.mask == nil { cover.layer.mask = CALayer() }
        cover.isUserInteractionEnabled = false
        cover.accessibilityElementsHidden = true
    }

    /// 只撤回**我们**改的那几样（Spotify 自己的 hidden 不碰）。
    private static func revealNativeCover() {
        guard let record = concealedNativeCover else { return }
        record.view.layer.isHidden = record.layerHidden
        if !record.hadMask { record.view.layer.mask = nil }
        record.view.isUserInteractionEnabled = record.interactive
        record.view.accessibilityElementsHidden = record.accessibilityHidden
        concealedNativeCover = nil
    }

    private static func removeHero() {
        revealNativeCover()
        revealWash()
        // 单调高度是记在**那块 plane** 上的（换页面时 plane 可能被复用）⇒ 撤的时候一起清掉，
        // 否则下一个页面的 hero 会一上来就是上一个页面那么高。
        if let plane = sharpHero?.superview {
            objc_setAssociatedObject(plane, &heroHeightKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        sharpHero?.removeFromSuperview()
        sharpHero = nil
        hero?.removeFromSuperview()
        hero = nil
        cachedHeroSource = nil
        cachedHeroImage = nil
    }

    /// 封面元素里那张真图。
    private static func coverImage(in root: UIView) -> UIImage? {
        firstImageView(in: root)?.image
    }

    /// 底子那张模糊封面 —— **照 MeloX 的三步**（`MeloX/Core/Artwork/ArtworkAccentColorProvider.swift`）：
    ///
    /// 1. **先把图缩到最长边 160px**（Lanczos，它的 `downsampled`）—— 先缩再糊，半径的相对强度才可控 ✓
    ///    （我上一版直接糊原图 ✗，只能拿"图宽的百分比"凑半径，效果飘）；
    /// 2. **`clampedToExtent()` 再糊** —— 不 clamp 的话边缘会被糊成透明，铺满整页时四周发虚 ✗；
    /// 3. **半径 18**（它的常数 ✓），作用在那张 160px 的图上。
    ///
    /// 它算完**按封面 URL 缓存**，整页当背景铺 ✓ —— 我们这里同样按"哪张图"缓存一次 ✓。
    private static func blurred(_ image: UIImage) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let source = CIImage(cgImage: cgImage)
        let sourceExtent = source.extent.integral
        guard !sourceExtent.isEmpty, !sourceExtent.isInfinite else { return nil }

        // ① 先降采样（最长边 160）—— 与 MeloX 的 `downsampled` 同一件事。
        var prepared = source
        let longest = max(sourceExtent.width, sourceExtent.height)
        if longest > meloxDownsampleEdge, let lanczos = CIFilter(name: "CILanczosScaleTransform") {
            lanczos.setValue(source, forKey: kCIInputImageKey)
            lanczos.setValue(meloxDownsampleEdge / longest, forKey: kCIInputScaleKey)
            lanczos.setValue(1, forKey: kCIInputAspectRatioKey)
            if let scaled = lanczos.outputImage { prepared = scaled }
        }

        // ② clamp 边缘 + ③ 半径 18，都作用在那张小图上。
        let preparedExtent = prepared.extent.integral
        guard !preparedExtent.isEmpty, !preparedExtent.isInfinite,
              let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(prepared.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(meloxBlurRadius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage,
              let rendered = ciContext.createCGImage(output, from: preparedExtent) else { return nil }
        return UIImage(cgImage: rendered)
    }

    // MARK: - ④ 头部居中（Melox 的三段式）

    /// Melox / AM 的头部是**居中**的：标题、艺人、元信息各占一行、行行居中。
    /// Spotify 是**左对齐**（日志 78 的探针逐字：`TitleRow 16,326,192,34`、`ParentRow 16,368,64,24`、
    /// `MetadataRow 16,400,382,19` —— 全都贴着 x=16 ✗）。
    ///
    /// 做法**不动约束、只写属性**（所以可逆、也不会跟 Auto Layout 打架）：
    ///   · `textAlignment = .center`（换行后也跟着居中）
    ///   · 再给一个**水平位移**，把这个 label 的中心挪到页面中线
    ///
    /// ⚠️ 位移量按 **`label.center`** 算 —— 那个值**不受 transform 影响**（受影响的只有 `frame`）
    /// ⇒ 每拍重设同一个值是幂等的、**不会累加** ✓（这正是"每拍补一次"能安全用的前提）。
    private static let centeredIdentifiers = [
        "CreativeWorkPlatform.Components.UI.PreTitleRow",
        "CreativeWorkPlatform.Components.UI.TitleRow",
        "CreativeWorkPlatform.Components.UI.ParentRow",
        "CreativeWorkPlatform.Components.UI.MetadataRow",
    ]
    private static var centeredLabels: [ObjectIdentifier: (label: UILabel, alignment: NSTextAlignment)] = [:]
    private static var centeredViews: Set<ObjectIdentifier> = []

    private static func centerHeaderLabels(in container: UIView) {
        var seen = 0
        var newlyCentered: [String] = []

        func walk(_ node: UIView, _ depth: Int) {
            guard depth <= clearDepth, seen < clearNodes, centeredLabels.count < 40 else { return }
            seen += 1
            let identifier = node.accessibilityIdentifier ?? ""
            if !identifier.isEmpty, centeredIdentifiers.contains(identifier),
               let label = node as? UILabel,
               !centeredViews.contains(ObjectIdentifier(node)) {
                centeredViews.insert(ObjectIdentifier(node))
                centeredLabels[ObjectIdentifier(node)] = (label: label, alignment: label.textAlignment)
                newlyCentered.append(identifier)
            }
            for sub in node.subviews { walk(sub, depth + 1) }
        }
        walk(container, 0)

        for entry in centeredLabels.values {
            let label = entry.label
            if label.textAlignment != .center { label.textAlignment = .center }
            guard let superview = label.superview else { continue }
            let middle = container.convert(CGPoint(x: container.bounds.midX, y: 0), to: superview).x
            let delta = middle - label.center.x
            if abs(delta) > 0.5 {
                label.transform = CGAffineTransform(translationX: delta, y: 0)
            }
        }

        if !newlyCentered.isEmpty {
            writeDebugLog(
                "[\(logTag)] centred \(newlyCentered.count) header row(s) — \(newlyCentered.joined(separator: ", "))"
                    + " (Spotify leaves them against the left margin; Melox centres them;"
                    + " alignment and transform both go back when the switch is turned off)"
            )
        }
    }

    private static func restoreCentering() {
        guard !centeredLabels.isEmpty else { return }
        for entry in centeredLabels.values {
            entry.label.textAlignment = entry.alignment
            entry.label.transform = .identity
        }
        centeredLabels.removeAll()
        centeredViews.removeAll()
    }

    // MARK: - ③ 藏掉 Spotify 自己那些按键

    /// AM 的专辑 / 歌单页没有这些：每行的「+」「…」、头部的下载 / 加入 / 菜单 / 观看信息。
    ///
    /// 与清底色同一套纪律：**每拍补一次**（行是懒建的）、按对象只记一次、记原 `alpha` 以便逐个还原。
    /// **不动 play / shuffle** —— 那两只是真的功能，AM 自己也有（`play` 相关的一律不碰）。
    private static func hideChrome(in page: UIView) {
        var seen = 0
        var newlyHidden: [String] = []

        func walk(_ node: UIView, _ depth: Int) {
            guard depth <= clearDepth, seen < clearNodes, hiddenChrome.count < maxHiddenChrome else { return }
            seen += 1
            if let id = node.accessibilityIdentifier, !id.isEmpty,
               chromeIdentifierFragments.contains(where: { id.contains($0) }),
               !hiddenChromeViews.contains(ObjectIdentifier(node)) {
                hiddenChromeViews.insert(ObjectIdentifier(node))
                hiddenChrome.append((view: node, alpha: node.alpha))
                node.alpha = 0
                newlyHidden.append(id)
            }
            for sub in node.subviews { walk(sub, depth + 1) }
        }

        walk(page, 0)

        if !newlyHidden.isEmpty {
            writeDebugLog(
                "[\(logTag)] hid \(newlyHidden.count) chrome view(s) — \(newlyHidden.joined(separator: ", "))"
                    + "; kept play / shuffle (those are real controls, Apple Music has them too)"
            )
        }
    }

    /// 逐个写回原 `alpha`（不是一律写 1：有的本来就是半透明）。
    private static func restoreChrome(reason: String) {
        guard !hiddenChrome.isEmpty else { return }
        for entry in hiddenChrome { entry.view.alpha = entry.alpha }
        writeDebugLog("[\(logTag)] restored \(hiddenChrome.count) chrome view(s) (\(reason))")
        hiddenChrome.removeAll()
        hiddenChromeViews.removeAll()
    }

    // MARK: - 还原（关开关 / 切页都走这里）

    private static func restore(reason: String) {
        removeHero()
        restoreCentering()
        restoreChrome(reason: reason)
        field?.removeFromSuperview()
        field = nil
        if !clearedBackgrounds.isEmpty {
            for entry in clearedBackgrounds { entry.view.backgroundColor = entry.color }
            writeDebugLog(
                "[\(logTag)] restored \(clearedBackgrounds.count) background(s) (\(reason))"
            )
        }
        clearedBackgrounds.removeAll()
        clearedViews.removeAll()
        currentPage = nil
        didReport = false
        didReportMissingColour = false
        lastLoggedHex = nil
    }

    // MARK: - 找页面 / 找封面 / 取色

    private struct Target {
        let page: UIView
        let cover: UIView?
        let color: UIColor?
    }

    private static func currentTarget() -> Target? {
        guard let window = frontWindow() else { return nil }

        // 专辑页：root 有 id，封面元素也有 id。
        if let page = firstView(in: window, withAnyIdentifier: pageIdentifiers) {
            let cover = firstView(in: page, withAnyIdentifier: coverIdentifiers)
            let color = cover.flatMap(coverColor)
            // ⚠️ 拿不到颜色时**不许静默**（日志 79 里专辑页一次都没出现，就是被我"悄悄 return"藏掉了）：
            //    报一次，说明是"页面认出来了、图还没加载"还是"封面元素压根没找到"。
            if color == nil, !didReportMissingColour {
                didReportMissingColour = true
                writeDebugLog(
                    "[\(logTag)] album page \(type(of: page)) found, but no cover colour yet"
                        + " (cover element \(cover == nil ? "not found at all" : "found, its image is still empty"))"
                        + " — waiting for the artwork, nothing was changed"
                )
            }
            return Target(page: page, cover: cover, color: color)
        }

        // 歌单页：root 的 id 还没拿到 ⇒ 从封面元素往上找"占满屏"的那一层。
        if let art = firstView(in: window, withAnyIdentifier: coverIdentifiers),
           let page = pageRoot(from: art, in: window) {
            return Target(page: page, cover: art, color: coverColor(art))
        }
        return nil
    }

    /// 从封面元素往上走，找到**真正该垫底的那一层**。
    ///
    /// ⚠️ **照片 89 的教训**：那片横在列表中间的灰带，就是"底跟着内容一起滚"的现场 ✗。
    /// 歌单页的 root 我没有 id（专辑页有），原先按"占满屏"猜 ⇒ 猜中的那一层**在 scroll view 里**
    /// ⇒ 垫上去的渐变随内容滚，滚到哪就脏到哪。
    /// 所以改成：先沿着祖先链找到**最外层那个 scroll view**，垫在**它的父视图**上（那一层不滚 ✓）；
    /// 封面上方本来就不滚的页面（专辑页）才走"占满屏"那条几何。
    private static func pageRoot(from view: UIView, in window: UIView) -> UIView? {
        var outermostScroll: UIScrollView?
        var node: UIView? = view
        while let current = node, current !== window {
            if let scroll = current as? UIScrollView { outermostScroll = scroll }
            node = current.superview
        }
        if let scroll = outermostScroll {
            if let container = scroll.superview, container.bounds.height >= window.bounds.height * 0.5 {
                return container
            }
            return scroll
        }

        // 不在 scroll view 里（= 页面本来就不滚）⇒ 沿用"占满屏"那条几何。
        node = view
        while let current = node, current !== window {
            let frame = current.convert(current.bounds, to: window)
            if frame.width >= window.bounds.width - 1,
               frame.height >= window.bounds.height * 0.8,
               frame.minY <= 2 {
                return current
            }
            node = current.superview
        }
        return nil
    }

    /// 封面元素里那张真图 → 平均色。
    private static func coverColor(_ root: UIView) -> UIColor? {
        guard let imageView = firstImageView(in: root), let image = imageView.image else { return nil }
        return averageColor(of: image)
    }

    private static func firstImageView(in root: UIView) -> UIImageView? {
        if let imageView = root as? UIImageView, imageView.image != nil { return imageView }
        for sub in root.subviews {
            if let hit = firstImageView(in: sub) { return hit }
        }
        return nil
    }

    /// 1×1 重绘 = 平均色（与听歌页那条路同一个思路，省掉一遍像素遍历）。
    private static func averageColor(of image: UIImage) -> UIColor? {
        guard let cgImage = image.cgImage else { return nil }
        var pixel: [UInt8] = [0, 0, 0, 0]
        guard let context = CGContext(
            data: &pixel,
            width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return UIColor(
            red: CGFloat(pixel[0]) / 255,
            green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255,
            alpha: 1
        )
    }

    // MARK: - 小工具

    private static func frontWindow() -> UIWindow? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .filter { !$0.isHidden && $0.alpha > 0.01 }
        return windows.first { $0.isKeyWindow } ?? windows.first
    }

    private static func firstView(in root: UIView, withAnyIdentifier identifiers: [String]) -> UIView? {
        if let id = root.accessibilityIdentifier, identifiers.contains(id) { return root }
        for sub in root.subviews {
            if let hit = firstView(in: sub, withAnyIdentifier: identifiers) { return hit }
        }
        return nil
    }

    private static func hex(of color: UIColor) -> String {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return "?" }
        return String(
            format: "%02X%02X%02X",
            Int(red * 255), Int(green * 255), Int(blue * 255)
        )
    }

    private static func frameText(_ rect: CGRect) -> String {
        "\(Int(rect.minX.rounded())),\(Int(rect.minY.rounded()))"
            + ",\(Int(rect.width.rounded())),\(Int(rect.height.rounded()))"
    }
}

/// 一条竖直线性渐变（`CAGradientLayer` 当自己的 layer，改颜色/位置一句话）。
final class GradientView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    var gradient: CAGradientLayer { layer as! CAGradientLayer }
}
