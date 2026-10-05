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

    /// Spotify 的 base surface（真机树里处处是 `bg=#121212`）。
    private static let baseSurfaceRGB: CGFloat = 0x12 / 255
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
    /// 高斯模糊半径 —— **按原图宽度算**，不是固定值。
    ///
    /// ⚠️ **照片 93 的教训**：封面原图只有 262px 宽，用固定 **28px** 半径去糊 = 糊掉图宽的 10%
    /// ⇒ 铺满顶部之后**只剩一片纯色渐变、完全看不出是哪张封面** ✗（用户要的是 pw 那样
    /// "看得出是这张封面、但化开了"）。改成原图宽度的 **3.5%**（262px ⇒ 约 9px）。
    private static let heroBlurRatio: CGFloat = 0.035

    // MARK: - 状态

    private static var timer: Timer?
    private static var currentPage: UIView?
    private static var field: GradientView?
    /// 我们自己画的"封面化开"大图（见 `ensureHero`）。
    private static var hero: UIImageView?
    /// 被按透明藏起来的 **Spotify 自己那张封面**（记原 alpha，关开关写回）。
    private static var concealedCover: (view: UIView, alpha: CGFloat)?
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
    /// 行内那两颗（每行的「+」「…」）**id 还没读到过**，但按同样的片段规则能一起命中；
    /// 命不中也不会有副作用，而且**藏了哪些 id 会打进日志**，下一份日志就能看到行内那两颗叫什么。
    private static let chromeIdentifierFragments = [
        "AddToButton",
        "DownloadButton",
        "ContextMenuButton",
        "WatchFeedEntityExplorerButton",
    ]
    private static var hiddenChrome: [(view: UIView, alpha: CGFloat)] = []
    private static var hiddenChromeViews: Set<ObjectIdentifier> = []
    private static let maxHiddenChrome = 400
    private static var didReport = false
    private static var lastLoggedHex: String?

    // MARK: - 入口

    static func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.6, repeats: true) { _ in tick() }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        writeDebugLog(
            "[\(logTag)] armed — page field \(UserDefaults.entityPageField ? "ON" : "OFF"),"
                + " cover dissolve \(UserDefaults.entityPageDissolve ? "ON" : "OFF")"
        )
    }

    private static func tick() {
        let wantsField = UserDefaults.entityPageField
        let wantsDissolve = UserDefaults.entityPageDissolve

        guard let target = currentTarget() else {
            // 页面走了：把上一页留下的东西全部还原（切页/退出都不留残迹）。
            if currentPage != nil || field != nil || hero != nil || concealedCover != nil {
                restore(reason: "left the page")
            }
            return
        }

        if target.page !== currentPage {
            restore(reason: "another page")
            currentPage = target.page
        }

        if wantsField {
            ensureField(on: target)
        } else if field != nil {
            restore(reason: "field switch off")
        }

        if wantsDissolve {
            ensureHero(on: target)
        } else if hero != nil || concealedCover != nil {
            removeHero()
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

    /// 竖直渐变：顶部是封面取色 → 到 `fieldColorEnd` 处变成 base surface → 到底还是它（看不出接缝）。
    private static func paintField(_ view: GradientView, color: UIColor) {
        let base = UIColor(red: baseSurfaceRGB, green: baseSurfaceRGB, blue: baseSurfaceRGB, alpha: 1)
        let layer = view.gradient
        layer.startPoint = CGPoint(x: 0.5, y: 0)
        layer.endPoint = CGPoint(x: 0.5, y: 1)
        layer.locations = [
            NSNumber(value: 0),
            NSNumber(value: Double(fieldColorEnd)),
            NSNumber(value: 1),
        ]
        layer.colors = [color.cgColor, base.cgColor, base.cgColor]
        let key = hex(of: color)
        if key != lastLoggedHex {
            lastLoggedHex = key
            writeDebugLog("[\(logTag)] field colour is now #\(key)")
        }
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

    private static func isBaseSurface(_ color: UIColor) -> Bool {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return false }
        return alpha > 0.9
            && abs(red - baseSurfaceRGB) < 0.02
            && abs(green - baseSurfaceRGB) < 0.02
            && abs(blue - baseSurfaceRGB) < 0.02
    }

    // MARK: - ② 封面溶进背景

    /// 用户 2026-10-13 指着 pw 的 playlist 截图：「**pw 的做法是把封面溶进背景**」——
    /// 封面放大铺满页面顶部、向下**化开**成一片颜色，标题与文字就压在这片颜色上
    /// （pw 的 `Redesigned/Playlist/PlaylistHeader.x` 与 `AlbumHeader.x` 做的同一件事）。
    ///
    /// 这里**只做加法、不动布局**：自己画一张大图，垫在 field **之上**、页面内容**之下**；
    /// 把 Spotify 自己那张小封面**按透明藏起来**（原 alpha 记着，关开关写回）——
    /// 文字与按钮还在原处，于是正好压在这片化开的颜色上，就是截图里那个样子。
    private static func ensureHero(on target: Target) {
        guard let cover = target.cover,
              let source = coverImage(in: cover) else { return }
        let container = target.page

        let height = max(180, min(container.bounds.height * heroHeightRatio, 560))
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
            concealSpotifyCover(cover)
            writeDebugLog(
                "[\(logTag)] hero \(frameText(frame)) in \(type(of: container))"
                    + " — the cover \(frameText(cover.convert(cover.bounds, to: container)))"
                    + " is enlarged and dissolved into the field; Spotify's own cover is concealed"
                    + " (its alpha \(String(format: "%.2f", cover.alpha)) was remembered and goes back"
                    + " when the switch is turned off)"
            )
        }

        if !view.frame.equalTo(frame) { view.frame = frame }

        // ★ 2026-10-13（**照片 94** 的教训）：**藏封面这件事必须每一拍补一次** ——
        //   Spotify 自己的布局会把它写回 1（我们只在挂上那一拍置 0，于是它又冒出来了 ✗：
        //   照片里我们那片化开的颜色上，端端正正又压着它那张小方封面）。
        if cover.alpha != 0 { cover.alpha = 0 }

        // 模糊一次、按"哪张图"缓存（同一张封面不重复跑 CoreImage；失败就退回原图，不能因此不画）。
        if cachedHeroSource !== source {
            cachedHeroSource = source
            cachedHeroImage = blurred(source) ?? source
            view.image = cachedHeroImage
        }

        // 向下化开：上 55% 不透明 → 底全透明（露出后面那片取色底）。
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
                NSNumber(value: 0.55),
                NSNumber(value: 1),
            ]
            view.layer.mask = layer
            mask = layer
        }
        if !mask.frame.equalTo(view.bounds) { mask.frame = view.bounds }
    }

    private static func removeHero() {
        if let record = concealedCover {
            record.view.alpha = record.alpha
            concealedCover = nil
        }
        hero?.removeFromSuperview()
        hero = nil
        cachedHeroSource = nil
        cachedHeroImage = nil
    }

    private static func concealSpotifyCover(_ cover: UIView) {
        guard concealedCover == nil else { return }
        // ⚠️ **读到的 alpha 不可信**（照片 94 的日志里它是 `0.00`，而那张封面明明是可见的；
        //    探针在另一张图上还读到过 `1.17`）⇒ 只有"明显大于 0"才当原值，否则按 1 记，
        //    免得关开关时把封面**永久留在透明状态** ✗。
        let original = cover.alpha > 0.01 ? cover.alpha : 1
        concealedCover = (view: cover, alpha: original)
        cover.alpha = 0
    }

    /// 封面元素里那张真图。
    private static func coverImage(in root: UIView) -> UIImage? {
        firstImageView(in: root)?.image
    }

    /// 高斯模糊（一次一张封面，缓存住）。失败返回 nil —— 调用方退回原图，**绝不能因为模糊失败就不画**。
    private static func blurred(_ image: UIImage) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let input = CIImage(cgImage: cgImage)
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(max(4, image.size.width * heroBlurRatio), forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage,
              let rendered = ciContext.createCGImage(output, from: input.extent) else { return nil }
        return UIImage(cgImage: rendered)
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
