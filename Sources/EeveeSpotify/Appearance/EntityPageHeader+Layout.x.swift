import Foundation
import Orion
import UIKit
import ObjectiveC.runtime

extension EntityPageHeaderManager {
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
    static func wrapperFor(_ control: UIView?, in stop: UIView) -> UIView? {
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

    /// 那一块"文字 + 控件"：`HeaderContentLayout` 里**宽度接近整页**的那个孩子
    /// （封面方形与满幅图都排除掉）。
    ///
    /// 按宽度取而不是"取最靠下的"：Liked Songs 的 layout 里还有一个 45pt 的图标槽位，
    /// 加载途中它会落在 block 下面，按"最靠下"会把它当成 block（页头就会画两遍）。
    static func blockIn(_ layout: UIView, cover: UIView?, fullbleed: UIView?) -> UIView? {
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
    static func textBlockAroundBiggestLabel(
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
    static func headerArtwork(in layout: UIView, cover: UIView?, fullbleed: UIView?) -> [UIView] {
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
    static func fullbleedArtwork(in fullbleed: UIView) -> [UIView] {
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

    /// 满幅页头里**那层渐变**（生成歌单一族靠它把页头颜色化进页面）。
    ///
    /// 单独一个函数、**由调用方只在"已经认出了图"时合并**：`concealInside` 的"名单为空 ⇒ 整支放过"
    /// 是一条安全阀（认不出图时整支不藏，否则会把满幅图一起藏没），不能因为多了一条渐变就失效。
    static func fullbleedGradients(in fullbleed: UIView) -> [UIView] {
        var kept: [UIView] = []
        forEachView(fullbleed) { view in
            let name = NSStringFromClass(type(of: view))
            if name.contains("Gradient") || name.contains("BlurView") {
                kept.append(view)
            }
        }
        return kept
    }

    // MARK: - 满幅图的底沿化开
    //
    // 生成歌单（音乐全纪录 / This Is / 电台）的满幅图**直接收在一条水平线上**：图下面是
    // 页面底色，两者之间没有任何过渡（Spotify 那层 `GradientView` 不保证存在 ——
    // `fullbleedGradients` 可能返回空，而我们的底色又不能去盖它）。
    // ⇒ 我们自己补一条 `clear → 页面底色` 的纱，压在图的下沿、贴着这一块的上沿。
    //
    // 只对"留下的是 Spotify 那张满幅图"这一支生效：hero 接手（`fullbleedHandedOver`）时
    // 图是我们自己画的、自带化开；电台那一族是一行大圆头像，糊下半截反而难看。
    //
    // ⚠️ **建纱要颜色，颜色比布局晚到**：纱的颜色是 `EntityPageAppearance.currentFieldColour`，
    // 它由 0.6s 的取色定时器算（封面取色是 CoreGraphics，不能进每帧的布局回合），而建纱只在
    // `applyOnce`（`HeaderContentLayout.layoutSubviews`）里跑。进入这一页时页头的最后几拍布局
    // 往往**早于**第一次取色 ⇒ 那一拍 `colour` 还是 nil、纱没建；页面静止后不再有布局回合，
    // 下沿就一直停在硬边上，直到下一次滚动带来新的布局拍。
    // ⇒ 落点与开关存在这里，`EntityPageAppearance.tick` 每拍调一次 `refreshArtworkFade` 补建。

    static var artworkFade: GradientView?
    /// 上一次写进那层纱的底色 —— 底色每拍都可能是同一个值，不必每拍重设（会触发重绘）。
    static var artworkFadeColour: UIColor?
    /// 布局回合留下的落点与开关（`refreshArtworkFade` 用它们补建）。
    static weak var artworkFadeHost: EntityPageHeaderView?
    /// 满幅页头里那张图 —— 纱的**下沿**跟着它，不跟着页头。
    static weak var artworkFadePicture: UIView?
    static var artworkFadeEnabled = false
    /// 已就成纱的那一份页头 —— 建成的第一行只记一次。
    static weak var artworkFadeLogged: EntityPageHeaderView?

    static func updateArtworkFade(in header: EntityPageHeaderView, enabled: Bool, source: String) {
        // 蒙版不依赖底色，先挂：它是"图的下沿不硬"的唯一保证 —— 纱画在页头里，而满幅页头那张图
        // 在我们这一层之上，所以纱只能兜底，真正起作用的是改图自己的蒙版。
        if enabled, let picture = artworkFadePicture, picture.window != nil {
            applyArtworkMask(to: picture, depth: EntityPageHeaderMetrics.artworkFadeHeight)
        } else if !enabled {
            clearArtworkMask()
        }

        guard enabled, let colour = EntityPageAppearance.currentFieldColour else {
            removeArtworkFade()
            return
        }

        let fade: GradientView
        if let existing = artworkFade, existing.superview === header {
            fade = existing
        } else {
            removeArtworkFade()
            let fresh = GradientView(frame: .zero)
            fresh.isUserInteractionEnabled = false
            fresh.isAccessibilityElement = false
            fresh.accessibilityIdentifier = "eevee-header-art-fade"
            fresh.gradient.startPoint = CGPoint(x: 0.5, y: 0)
            fresh.gradient.endPoint = CGPoint(x: 0.5, y: 1)
            fresh.gradient.locations = [0, 1]
            // 插在最底层：它画在本视图 bounds 之外（上方），但万一某页的排版把它挤进
            // bounds 里，也不该压住标题。
            header.insertSubview(fresh, at: 0)
            artworkFade = fresh
            artworkFadeColour = nil
            fade = fresh
        }

        // 图的下沿**不在**本视图顶边：满幅图常常比页头的内容块矮一截（生成歌单里图和标题之间
        // 还隔着一道渐变），对着页头顶边画，纱最透明的那一段正好压在图的下沿上，硬边就露出来。
        // ⇒ 下落点改成"图的下沿"，量不到时才退回页头顶边。
        let height = EntityPageHeaderMetrics.artworkFadeHeight
        let bottom = artworkFadeBottom(in: header)
        let frame = CGRect(x: 0, y: bottom - height, width: header.bounds.width, height: height)
        if fade.frame != frame { fade.frame = frame }

        if artworkFadeColour != colour {
            fade.gradient.colors = [colour.withAlphaComponent(0).cgColor, colour.cgColor]
            artworkFadeColour = colour
        }

        if artworkFadeLogged !== header {
            artworkFadeLogged = header
            let inWindow = fade.convert(fade.bounds, to: nil)
            writeDebugLog(
                "[EntityPageHeader] full-bleed art fade — built on the \(source) pass:"
                    + " \(Int(fade.frame.width))x\(Int(fade.frame.height))pt at"
                    + " \(Int(inWindow.minY))..\(Int(inWindow.maxY))pt"
            )
        }
    }

    /// 满幅图在页头坐标系里的下沿。量不到就返回 0（= 页头顶边，旧的落点）。
    ///
    /// 换算而不是记绝对值：这一页的页头高度会随滚动变化，图相对页头的位置反而稳定。
    static func artworkFadeBottom(in header: EntityPageHeaderView) -> CGFloat {
        guard let picture = artworkFadePicture, picture.window != nil, header.window != nil,
              picture.bounds.height > 1, header.bounds.height > 1
        else { return 0 }
        let rect = picture.convert(picture.bounds, to: header)
        guard rect.maxY.isFinite, abs(rect.maxY) < header.bounds.height else { return 0 }
        return rect.maxY
    }

    /// 图自身的下缘化开：给满幅页头那张图挂一层竖直 alpha 蒙版。
    ///
    /// 为什么不只盖一层纱：那张图在页头之上（它是页头内容那一支，晚于我们挂上），插在页头里的纱
    /// 画在它下面 —— 屏上还是硬边。蒙版改的是**图自己**，与 z 序无关。Spotify 的布局会写回图层
    /// 属性，所以每一拍重挂一次；挂的是同一个对象，属性没变时不重设（避免每拍触发重绘）。
    static weak var artworkMaskPicture: UIView?

    static func applyArtworkMask(to picture: UIView, depth: CGFloat) {
        let size = picture.bounds.size
        guard size.width > 1, size.height > depth + 1 else { return }

        let mask: CAGradientLayer
        let isNew = !(picture.layer.mask is CAGradientLayer)
        if let existing = picture.layer.mask as? CAGradientLayer {
            mask = existing
        } else {
            mask = CAGradientLayer()
            mask.startPoint = CGPoint(x: 0.5, y: 0)
            mask.endPoint = CGPoint(x: 0.5, y: 1)
            picture.layer.mask = mask
        }
        artworkMaskPicture = picture

        if mask.frame != picture.bounds { mask.frame = picture.bounds }
        let start = 1 - depth / size.height
        let locations: [NSNumber] = [0, NSNumber(value: Double(start)), 1]
        let same = (mask.locations as? [NSNumber])?
            .elementsEqual(locations, by: { $0.doubleValue == $1.doubleValue }) ?? false
        if !isNew, same, mask.colors != nil { return }
        mask.colors = [UIColor.white.cgColor, UIColor.white.cgColor, UIColor.clear.cgColor]
        mask.locations = locations
    }

    /// 收掉我们挂的蒙版（换页时）。只撤自己那一种，别人的蒙版不动。
    static func clearArtworkMask() {
        guard let picture = artworkMaskPicture else { return }
        if picture.layer.mask is CAGradientLayer { picture.layer.mask = nil }
        artworkMaskPicture = nil
    }

    /// 取色定时器那一拍：颜色到了就把纱补建出来（见上面"建纱要颜色"那段）。
    ///
    /// 与 `refreshPinnedMore` 同一条理由 —— 停在页面上不动时没有布局回合。幂等：颜色没变时
    /// `updateArtworkFade` 只更新帧，不重设 layer（`artworkFadeColour` 挡着）。
    static func refreshArtworkFade() {
        guard let header = artworkFadeHost, let live = currentHeader, header === live,
              header.window != nil, header.superview != nil
        else {
            clearArtworkFade()
            return
        }
        updateArtworkFade(in: header, enabled: artworkFadeEnabled, source: "tick")
    }

    /// 离页 / 页头换掉时收掉纱，并把落点清掉（`EntityPageAppearance.tick` 找不到目标时调）。
    static func clearArtworkFade() {
        artworkFadeHost = nil
        artworkFadePicture = nil
        artworkFadeEnabled = false
        artworkFadeLogged = nil
        clearArtworkMask()
        removeArtworkFade()
    }

    static func removeArtworkFade() {
        artworkFade?.removeFromSuperview()
        artworkFade = nil
        artworkFadeColour = nil
    }

    /// 页头里那几个**大圆头像**（电台）。
    ///
    /// 三条收窄，防止误伤（创建者那行的脸堆里也全是 `AvatarView`）：
    /// · **至少 48pt 宽** —— 脸堆里的头像只有 24pt 上下；
    /// · 脸堆（`FacepileView`）里的一律不算，哪怕被放大；
    /// · 最多收 8 个（电台是三张，留点余量）。
    ///
    /// 性能：结果按 `layout` 缓存 —— 这一拍是**每帧**的，不能每帧走一遍 1500 节点的 BFS。
    static func headerAvatars(in layout: UIView) -> [UIView] {
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
    static func concealInside(_ view: UIView, keeping artwork: [UIView], depth: Int = 0) {
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

    struct HeaderTexts {
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
    struct TextViews {
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
    static func headerTexts(block: UIView, headerRoot: UIView) -> HeaderTexts {
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
    static func headerTextsSlow(block: UIView, headerRoot: UIView) -> (HeaderTexts, TextViews?) {
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

    static func metadataView(_ block: UIView) -> UIView? {
        eeveeFindView(block, identifier: "Components.Header.UI.Metadata*")
    }

    /// 字号最大的那个标签（页头里最大的字就是标题）。返回**标签本身**而不是文本 ——
    /// 调用方要把它当引用缓存下来，之后每一拍只读 `.text`（见 `TextViews`）。
    static func biggestLabel(in root: UIView, skipping skip: [UIView?]) -> UILabel? {
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
    static func unclaimedLabels(in block: UIView, facepile: UIView?, metadata: UIView?) -> [UILabel] {
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
    static func firstLabel(in root: UIView, skipping skip: UIView?, longerThan minimum: Int = 1) -> UILabel? {
        var found: UILabel?
        forEachView(root) { view in
            guard found == nil, let label = view as? UILabel else { return }
            if let skip, view.isDescendant(of: skip) { return }
            let text = (label.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count > minimum { found = label }
        }
        return found
    }

}
