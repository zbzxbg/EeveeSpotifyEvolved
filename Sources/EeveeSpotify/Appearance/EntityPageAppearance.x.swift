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
///
/// ★ 2026-10-17：**顶部那一条"纱"**（`ensureScrim`）跟着「封面下缘溶解」这颗开关走 ——
/// 它是"满幅封面"这套外观的一部分，用户拍板时**没有**要单独一颗开关（他二选一里选的是 A，
/// 不是"两条都做成开关"的 C）⇒ 不新增 UserDefaults 键、不动 l10n。
enum EntityPageAppearance {

    static let logTag = "PageField"

    /// 页面 root 的候选 id（歌单页 root 的 id 还没拿到 ⇒ 用"占满屏"那条几何兜底）。
    ///
    /// ★ 2026-10-13（艺人页）：pw 的 `ArtistField.x` 逐字 —— 艺人页是 `TemplateKit.TemplateView`，
    /// 而它的 `accessibilityIdentifier` 就是 **`creator-page`**（`kPageIdentifier`）。加进来，
    /// `currentTarget()` 就能像认专辑页一样认它。
    private static let pageIdentifiers = [
        "CreativeWorkPlatform.CreativeWorkTemplateView",
        "creator-page",
    ]
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
    /// ★ 2026-10-17：**顶上那一条"带"** —— 用**这个页面的取色**画，照片从它里面化出来（见 `ensureScrim`）。
    private static var scrim: GradientView?
    /// 那一条里**完全不透明**的那一段占多高：`0.55 × (安全区顶 + 22)` ≈ 45pt ⇒ 正好盖住灵动岛/状态栏
    /// 那一条；剩下那截是"照片从色里长出来"的渐变，所以它既是缓冲区、也是渐变（用户两轮要的是同一件事）。
    private static let scrimSolidFraction: CGFloat = 0.55
    /// 那一条在"安全区顶"之外还要往下化开多少 —— 不留这一截的话，色带底沿会看到一条硬边。
    private static let scrimExtraFade: CGFloat = 22
    /// 那一条**当前用着哪个颜色**（`#RRGGBB`）：换封面才重写 layer，0.6s 那一拍不重复写。
    private static var scrimColourKey: String?
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
        // ⚠️ **只处理我们确实会铺 hero 的那几种页面**（专辑页 / 歌单页 / 艺人页）。
        //    它们都有 `Components.Header.UI.ArtworkImage` 或 `ArtWorkElement.WithCoverArt` 同名/同形的
        //    封面元素，判据只看**页面 root 的 id**，所以不会误伤别处。判据只沿祖先链走，
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
            if currentPage != nil || field != nil || hero != nil || sharpHero != nil
                || scrim != nil || concealedNativeCover != nil {
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
        } else if hero != nil || sharpHero != nil || scrim != nil
            || concealedNativeCover != nil || !centeredLabels.isEmpty {
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

        // ★★ 2026-10-06：**浅底时把文字翻成深色** —— 见 `textTone`（你报的"浅色背景下看不清
        //    账号名字 / 本月有 xxx 听众"）。与清底色同一条纪律：**每一拍补一次**。
        let light = isLight(color)
        textTone(in: page, isLight: light)

        // ★★ 2026-10-17：**状态栏也跟着翻** —— AM 的 118（亮底）是黑字、119（暗棕底）是白字，
        //    它就是靠这一条解决"照片铺到顶"的（不是靠留白）。我们原来一处都没碰过状态栏，
        //    于是在亮封面上白字直接消失（用户照片 115 的现场）。
        //    判据**复用同一个 `isLight`**，不另立阈值；值没变时 `apply` 只是一次比较。
        EntityPageStatusBar.apply(light ? .darkContent : .lightContent)

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

    /// 这片颜色**亮不亮**（决定底色往上抬还是往下压、也决定文字要不要反色）。
    private static func isLight(_ colour: UIColor) -> Bool {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 1
        guard colour.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return false }
        return (0.299 * red + 0.587 * green + 0.114 * blue) > 0.55
    }

    /// ★★ 2026-10-06（用户：「在浅色背景下，**看不清账号名字 / 本月有 xxx 听众** 这种信息」，
    /// 照片 111 就是那张白底专辑的白字）：**浅底时把页面里的浅色文字翻成深色**。
    ///
    /// 判据只有一条：我们铺的那块取色底**亮不亮**（`isLight`）。亮 ⇒ 白字改成近黑；
    /// 暗 ⇒ 一个字都不动（Spotify 本来就是白字）。
    ///
    /// ⚠️ 两条纪律与"清底色"完全一样：
    ///   · Spotify **每一拍都会把文字色写回去** ⇒ 这里也是**每一拍补一次**；
    ///   · 只改**本来就亮的**字（`white > 0.62`）—— 绿色的"正在播放"、彩色的标签一律不碰
    ///     （`getWhite` 对彩色返回 false，天然被排除）。
    ///
    /// 记原值是为了**撤得干净**：底一变暗（或页面换掉），`restoreTextTone` 逐个写回。
    private static var tonedLabels: [(label: UILabel, color: UIColor)] = []
    private static var tonedViews: Set<ObjectIdentifier> = []
    private static let maxToned = 400

    private static func textTone(in page: UIView, isLight light: Bool) {
        guard light else {
            restoreTextTone()
            return
        }
        var seen = 0
        func walk(_ node: UIView, _ depth: Int) {
            guard depth <= 5, seen < clearNodes, tonedLabels.count < maxToned else { return }
            seen += 1
            if let label = node as? UILabel, !(node is UIButton) {
                var white: CGFloat = 0, alpha: CGFloat = 1
                if label.textColor.getWhite(&white, alpha: &alpha), alpha > 0.5, white > 0.62 {
                    let identifier = ObjectIdentifier(label)
                    if !tonedViews.contains(identifier) {
                        tonedViews.insert(identifier)
                        tonedLabels.append((label, label.textColor))
                    }
                    let dark = UIColor(white: 0.09, alpha: 1)
                    if label.textColor != dark { label.textColor = dark }
                }
            }
            for sub in node.subviews { walk(sub, depth + 1) }
        }
        walk(page, 0)
    }

    private static func restoreTextTone() {
        guard !tonedLabels.isEmpty else { return }
        for entry in tonedLabels where entry.label.textColor != entry.color {
            entry.label.textColor = entry.color
        }
        tonedLabels.removeAll()
        tonedViews.removeAll()
    }

    /// 把颜色**按倍数压暗**（保留色相与饱和度）。
    ///
    /// ★★ 2026-10-06（照片 116/117：「渐变也有问题」，日志 92 逐字 `#B08FA8 → #B08DA7 → #A887A0`）：
    /// 那三段**几乎是同一个颜色**，所以整页看着是平的。原因是 `tinted` 只设**上限**——
    /// 基色亮度本来只有 0.65 时，`atMost: 0.88` 等于什么都没做，而 `0.66` 也只压掉一点点。
    /// 这里改成**乘一个系数**（往上抬不了就往下走），亮底与暗底都能拉开。
    private static func scaled(_ colour: UIColor, by factor: CGFloat) -> UIColor {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 1
        guard colour.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else {
            return colour
        }
        return UIColor(
            hue: hue,
            saturation: saturation,
            brightness: max(0.04, min(1, brightness * factor)),
            alpha: 1
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
        // ★★ 2026-10-06（照片 111：白底封面 + 白字标题 ⇒ 什么都看不见）：**不再一律压暗** ——
        //    **封面亮就给亮底**（AM 的艺人页正是这样：白底照片 ⇒ 白底页面 + 黑字），封面暗才压暗。
        //    这也是 `textTone` 反色的依据：底亮了，字才有得反。
        let light = isLight(color)
        // ★★ 2026-10-06：改用 `scaled`（乘系数）而不是 `tinted`（设上限）——
        //   上限对"本来就不亮的基色"毫无作用，那正是"渐变看不出渐变"的原因。
        let middle = scaled(color, by: light ? 0.86 : 0.72)
        let bottom = scaled(color, by: light ? 0.62 : 0.45)
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
        // ★★ 2026-10-13（用户看真机：「你已点赞、艺人之选什么的**都还是黑的**」）：**阈值 0.12 → 0.20**。
        //
        //   0.12 只够 `#121212`（列表底，0.071）那一档。而 Spotify 的**卡片**用的是"抬起一层"的
        //   深灰 `#282828`（**0.157**）—— 我们自己的真机树里逐字写着（艺人页）：
        //
        //   ```
        //   10.CreatorBiographyCardLayout@0,0,374,416,bg=#282828      ← 艺人简介卡
        //   11.OBJC_ONLY_Label id=Components.UI.CreatorBiographyCard.HeaderLabel
        //   14.ContainerView   id=Components.UI.CreatorBiographyCard.BiographyLabel
        //   ```
        //
        //   0.157 > 0.12 ⇒ 那些卡片**从来没被清过**；列表底清了、卡片没清 ⇒ 页面底色一变浅，
        //   卡片就变成一块块深灰（用户照片里"你已点赞"、"艺人之选"、"关于"全是这个问题）。
        //   0.20 正好收进 `#282828`（0.157）与 `#333333`（0.2），同时仍然要求"近灰"（互差 ≤ 0.03）。
        return brightest <= 0.20 && (brightest - darkest) <= 0.03
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
        // ★★ 2026-10-06（用户看真机：「专辑页上面是有缓冲了，但是缓冲**没有和封面上部分接上**，
        //    而且这个缓冲区**可能太大了**」）：**那条缓冲撤掉** —— 照片**铺到顶**。
        //
        //    缓冲区的正解不是"把照片往下挪"，而是"**照片铺满、内容避让**"：AM 的艺人页就是照片从
        //    屏幕最顶开始画、状态栏直接压在上面（`am1` 逐字如此），而标题与按钮本来就在页头底部、
        //    返回键是 Spotify 自己的（它会自己避让安全区）。
        //    上一版让照片的 y 让出 `safeAreaInsets.top`（≈59pt）⇒ 顶上露出一条**取色底**，
        //    照片与它之间那道缝就是用户看到的"没接上"。
        let frame = CGRect(x: 0, y: 0, width: container.bounds.width, height: height)

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
        ensureSharpHero(cover: cover, source: source, page: container, colour: target.color)
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
    private static func ensureSharpHero(cover: UIView, source: UIImage, page: UIView, colour: UIColor?) {
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

        // ★ 2026-10-13（艺人页）：**第三条宿主**。pw 的 `ArtistHeader.x` 把 hero 挂在 `TemplateKit` 的
        //    `HeaderContainer` 上（它的 `applyHero(UIView *container, …)`，容器由 `containerOf(header)`
        //    沿祖先链找"类名含 HeaderContainer"的那一个）。歌单页的 `_backgroundViewContainer`
        //    与专辑页的 `CreativeWorkHeader` 在艺人页**都不存在**。
        let artistContainer = ancestor(of: cover, classNameContains: "HeaderContainer")

        let host: UIView
        let layout: UIView
        /// 高度按**宿主**算、且**不要求封面已经量好**（专辑页与艺人页：封面可能这一拍还没布局）。
        let fillsHost: Bool
        /// 顶部留出状态栏那一条（= 把图**往下挪**，上面露出取色底）。★ 2026-10-06：**恒 false** ——
        /// 用户看真机后确认"缓冲没和封面接上、而且太大"，而 AM 与歌单页都是铺到顶的。
        /// ★ 2026-10-17（用户再问"怎么搞好"）：他二选一里选了**方案 A（照片照旧铺到顶 + 顶上叠一层纱）**
        /// ⇒ 这一条**仍然是 false**，顶上那件事由 `ensureScrim` 做。变量留着只作记录。
        let wantsTopInset: Bool

        if let plane, plane.bounds.width > 1 {
            host = plane
            layout = headerLayout(of: cover) ?? cover.superview ?? page
            fillsHost = false
            wantsTopInset = false
            concealWash(on: plane)
        } else if let albumHeader, albumHeader.bounds.height > 40 {
            host = albumHeader
            layout = albumHeader
            fillsHost = true
            wantsTopInset = false
            concealAlbumWash(in: page)
        } else if let artistContainer, artistContainer.bounds.height > 40 {
            host = artistContainer
            layout = artistContainer
            fillsHost = true
            wantsTopInset = false
        } else {
            return
        }

        let coverFrame = cover.convert(cover.bounds, to: layout)
        // 歌单页那条路要封面已经量好（帧都没量出来就别画）；另外两条铺满整个宿主，不依赖封面的帧。
        if !fillsHost {
            guard coverFrame.width > 40, coverFrame.height > 40 else { return }
        }

        concealNativeCover(cover)

        // 高度 = **到过的最深处**，下限 `minHeroHeight`，**只增不减** ——
        // pw：页头还在加载时 block 的位置偏高，取"当前值"会让图够不到标题、中间留一条裸色带。
        let reach = fillsHost
            ? max(minHeroHeight, host.bounds.height)
            : max(minHeroHeight, coverFrame.maxY + EntityPageHeaderMetrics.titleRise)
        let previous = (objc_getAssociatedObject(host, &heroHeightKey) as? NSNumber)?.doubleValue ?? 0
        let height = max(previous, reach)
        if height != previous {
            objc_setAssociatedObject(host, &heroHeightKey, NSNumber(value: height), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        // 缓冲（只有专辑页要，见 `wantsTopInset`）：把图从状态栏下面开始画。
        // ★ 2026-10-17：这条**永远是死路** —— 用户二选一里选了方案 A（图照旧铺到顶 + 顶上加纱），
        //    顶上那件事现在由 `ensureScrim` 做。算式留着，将来真要翻回"把图往下挪"时不用重推。
        let topInset = wantsTopInset ? page.safeAreaInsets.top : 0
        let frame = CGRect(
            x: 0,
            y: topInset,
            width: host.bounds.width,
            height: max(minHeroHeight, round(height) - topInset)
        )

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
                "[\(logTag)] sharp hero in \(type(of: host)) \(frameText(host.bounds))"
                    + " at \(frameText(frame))"
                    + " — the cover \(frameText(coverFrame)) measured in \(type(of: layout));"
                    + " the host carries it, so it moves with Spotify's own layout"
            )
        }

        if !view.frame.equalTo(frame) { view.frame = frame }
        if view.image !== source { view.image = source }
        applyDissolveMask(to: view, opaqueFraction: 0.54)

        // ★ 2026-10-17：照片**照旧铺到顶**，顶上那条由**页面取色**去化（不是黑纱）—— 见 `ensureScrim`。
        ensureScrim(in: host, above: view, page: page, colour: colour)
    }

    /// ★★ 2026-10-17（用户，第二轮 —— 看了 AM 的艺人页截图 118/119 之后）：
    /// 「am 是这么处理的：**用渐变来处理**，而往下滚就**一直保持渐变之后的颜色**。我们不是这个设计吧？
    /// 能不能做成这样。而且渐变之后的颜色**会根据艺人变化**的。比如 nanatsukaze 的就是淡灰色，
    /// 杰克逊的就是棕色。」
    ///
    /// ## 先厘清：这三句里有两句我们**早就是**了
    ///
    /// 真机日志逐字（`eeveespotify_debug_shared 93.log`）：
    ///
    /// ```
    /// [PageField] field colour is now #F2F7FB — top F2F7FB, 57% #D7DCE0, bottom #A1A5A8   ← Nanatsukaze 艺人页
    /// [PageField] field on TemplateView 0,0,414,896 ← cover colour #F2F7FB               ← field 是页面根的子视图
    /// [PageField] sharp hero in HeaderContainer 0,0,414,520 at 0,0,414,520
    /// ```
    ///
    /// ⇒ ① **渐变**：`paintField` 就是一条整页的取色渐变，照片再"化"进它（`applyDissolveMask`）；
    ///    ② **往下滚保持**：field 挂在**页面根**上（不在 scroll view 里）⇒ 内容滚、颜色不动；
    ///    ③ **随艺人变**：颜色是每页从封面/照片当场算的（`averageColor`），Nanatsukaze 的底正是
    ///      `#A1A5A8`（淡灰 ✓），另一张是 `#B08FA8`（粉紫 ✓）。这三条**不用改**。
    ///
    /// ## 真正缺的两件（这一轮补的就是它们）
    ///
    /// **① 顶上那一条不是黑的。** 上一版我按"方案 A"盖了一条 **黑 → 透明** 的纱（用户当时选的就是
    /// 它）—— 但 AM 不是这么干的：AM 顶上那一条**就是页面自己的颜色**，照片从这片颜色里"长"出来。
    /// 改成取色之后，同一条纱自动变成"这个艺人的颜色"，与下面 field 的顶色**一模一样**（
    /// `paintField` 的 0 号色就是它）⇒ 纱和 field 之间不可能有接缝。
    ///
    /// **② 状态栏明暗要跟着翻。** AM 的 118（Nanatsukaze）状态栏是**黑字**、119（Michael Jackson）
    /// 是**白字** —— 它就是靠这个解决"照片铺到顶"的，而不是靠留白。我们这边原来一处都没碰过状态栏
    /// ⇒ 亮封面上白字直接消失（照片 115 就是这个现场）。现在 `EntityPageStatusBar` 接手。
    ///
    /// ## 形状
    ///
    /// * 高 = `安全区顶 + 22`（与安全区同高那一段**不透明**，正好盖住灵动岛/状态栏那一条；
    ///   最后一截化开，照片从色里长出来 ⇒ 既是"缓冲区"也是"渐变"）。
    /// * 颜色 = 这个页面的取色（`colour`），取不到就不画（别用黑色顶替 —— 那正是上一版的问题）。
    /// * 插在 **`hero` 正上方、宿主的其余子视图之下**（`insertSubview(_:aboveSubview:)`）⇒
    ///   Spotify 自己的返回键、我们 pinned 的 ⋯、页头那些文字都在它**上面**，谁都不会被压暗。
    /// * 锚在宿主 y=0（跟着照片滚）。滚下去之后那一条由 Spotify 自己收起来的导航栏接手。
    ///
    /// ⚠️ 与 `wantsTopInset`（真正把图往下挪）仍**不是一回事**：那条 2026-10-06 被用户否过
    /// （"缓冲没和封面接上、而且太大"），现在仍然恒 `false`。
    private static func ensureScrim(in host: UIView, above hero: UIView, page: UIView, colour: UIColor?) {
        // 取不到颜色就**什么都不画**：宁可没有这一条，也不能拿一个错的颜色顶上去
        // （黑纱就是这么来的，AM 那边根本没有那一层）。
        guard let colour else { return }

        let view: GradientView
        if let scrim, scrim.superview === host {
            view = scrim
        } else {
            removeScrim()
            let fresh = GradientView()
            fresh.isUserInteractionEnabled = false
            fresh.accessibilityIdentifier = "eevee-page-scrim"
            let gradient = fresh.gradient
            gradient.startPoint = CGPoint(x: 0.5, y: 0)
            gradient.endPoint = CGPoint(x: 0.5, y: 1)
            host.insertSubview(fresh, aboveSubview: hero)
            scrim = fresh
            view = fresh
            writeDebugLog(
                "[\(logTag)] top band in \(type(of: host)) — the cover still runs full bleed to the top;"
                    + " the page's own colour holds the top \(Int(scrimSolidFraction * 100))% of it and"
                    + " dissolves into the picture below (AM's look, and the status bar flips with it)"
            )
        }

        // 颜色只在"换了一张封面"时才重写（每 0.6s 走一趟，不能每拍都写 layer）。
        let key = hex(of: colour)
        if key != scrimColourKey {
            scrimColourKey = key
            let gradient = view.gradient
            gradient.colors = [
                colour.withAlphaComponent(1).cgColor,
                colour.withAlphaComponent(1).cgColor,
                colour.withAlphaComponent(0).cgColor,
            ]
            gradient.locations = [
                NSNumber(value: 0),
                NSNumber(value: Double(scrimSolidFraction)),
                NSNumber(value: 1),
            ]
        }

        let safeTop = resolvedSafeAreaTop(in: host, page: page)
        let height = max(12, safeTop + scrimExtraFade)
        let frame = CGRect(x: 0, y: 0, width: host.bounds.width, height: height)
        if !view.frame.equalTo(frame) { view.frame = frame }
    }

    /// 顶上那一条安全区 —— **窗口那一份才是准的**（嵌在别人里的视图常常读到 0，
    /// 与 `EntityPageHeader.pinMoreButton` / `LyricsWordByWord.resolvedSafeAreaInsets` 同一条纪律）。
    private static func resolvedSafeAreaTop(in host: UIView, page: UIView) -> CGFloat {
        if let top = host.window?.safeAreaInsets.top, top > 0 { return top }
        if host.safeAreaInsets.top > 0 { return host.safeAreaInsets.top }
        return page.safeAreaInsets.top
    }

    private static func removeScrim() {
        scrim?.removeFromSuperview()
        scrim = nil
        scrimColourKey = nil
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

    /// 沿祖先链找**类名里含** `needle` 的那个视图。
    ///
    /// pw 的 `containerOf` / `SGRPlaylistPageOf` 都是这个形状：艺人页的页头容器（`HeaderContainer`）
    /// 与别的页面那些"认 id"的容器不同，**它身上没有 accessibility id**，只有类名可用。
    private static func ancestor(of view: UIView, classNameContains needle: String) -> UIView? {
        var node: UIView? = view.superview
        var level = 0
        while let current = node, level < 16 {
            level += 1
            if NSStringFromClass(type(of: current)).contains(needle) { return current }
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
    /// `if (hero && (v == hero || [v isDescendantOfView:hero])) return;`）——
    /// ★ 2026-10-17：**顶上那条纱（`scrim`）也一起跳**，理由见下面那一行。
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
            // ★ 2026-10-17：**顶上那条纱也是 `GradientView`** —— 不跳过的话，这一趟会把它当成
            //    Spotify 的 wash 藏掉（歌单页那条路每拍都走这里 ⇒ 纱永远不出现）。
            //    （专辑/艺人页那两条路不用管：它们的"藏"按 `eevee-` 前缀认自己人，见 `isOurs`。）
            if let scrim, view === scrim { continue }
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
        // ⚠️★ 2026-10-13（艺人页）：**在 `OverflowStackView` 里只能加空 mask、绝不能碰 hidden**。
        //    pw 在艺人页踩过这个坑，它的注释逐字：
        //    > `ios-creator-impl.context_menu_in_navigation_bar_enabled_artist` moves more out of the
        //    > header's row, and with it gone Spotify's OverflowStackView force-unwraps the tallest view
        //    > of a line that has none and traps as the page opens
        //    > (device crash 2026-09-18 19:09, SIGTRAP in -[OverflowStackView updateConstraints]).
        //    空 mask 本身就能让视图什么都不画，所以少一个 hidden 只是少一道保险，不会漏。
        let canHide = ancestor(of: cover, classNameContains: "OverflowStackView") == nil
        if concealedNativeCover?.view === cover {
            if canHide, !cover.layer.isHidden { cover.layer.isHidden = true }
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
        if canHide { cover.layer.isHidden = true }
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
        removeScrim()
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
        // 状态栏还回 app 自己那一档（我们只在"这个页面的取色"这件事上有意见）。
        EntityPageStatusBar.release()
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

    /// 最前面那个有内容的窗口（`EntityPageStatusBar` 也要用同一个判据，所以它是 internal 的）。
    static func frontWindow() -> UIWindow? {
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
