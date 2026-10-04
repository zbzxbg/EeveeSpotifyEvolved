import Foundation
import UIKit
import MediaPlayer
import ObjectiveC.runtime

/// 听歌页**我们自己的覆盖层** —— AM 页面（kumone 那种一屏播放器）的**地基**。
///
/// ## 它是什么、**不是什么**（这一段是纪律，别再踩 2026-10-02 的坑）
///
/// * **是**：一层**整页透明**的 `UIView`，挂在页面根视图的**最上面**。我们自己的控件
///   （音量条，以后还有头部一行 / 三个圆按钮）全放在它上面，用它当一个**统一的坐标系**。
/// * **不是**"自绘壳"：2026-10-02 那版是**加模糊 / 铺实心盖住原生内容**（照片 19/20 的糊底、
///   一整页空白），被整块删掉（`Tweak.x.swift:384-387`）。这一层**什么都不画** ——
///   透明、无背景、无内容，只提供坐标系。
/// * 容器**只在音量那一行的范围内**吃触摸（`NowPlayingOverlayView.point(inside:)`）：
///   Spotify 原生手势（下拉关闭 / 滚动 / 左右切歌）全部照常；只有放在它上面的**具体控件**才开交互。
///   ★ 2026-10-12：以前写的是"整层不吃触摸"，那会让里面那颗 `MPVolumeView` **也点不到**
///   （UIKit 的命中测试在父视图这一级就停了）—— 用户报的"音量键是个装饰"就是它。
/// * **不碰 Spotify 任何属性**（唯一会动的是"往它上面加我们自己的子视图"）⇒
///   关掉 = 把这一层拿掉，**天然完全还原**。
///
/// ## 怎么定位（依据：日志 38 的真机树，不是猜的）
///
/// 播放器底部那一坨五行（进度 / 标题 / 控件 / 图标）在
/// `13.UIStackView@4,560,406,273,id=npv.bottomStackView` 里 —— 它**有 accessibilityIdentifier**，
/// 所以我们靠 id 认它，不靠类名、不靠猜层级。控件的落点就从它的 frame 推：
/// 音量条放在它**下面**，左右各内缩 4pt；找不到锚就退回页面安全区底 ——
/// **宁可位置保守，也不要压到原生控件上**。
///
/// ## 开关
///
/// 扩展功能 → 听歌页 →「底部音量条」，**默认关**（先看效果，再决定默认值）。
/// 日志 tag：`[NPVPage]`。
enum NowPlayingPageOverlay {

    static let logTag = "NPVPage"

    /// 播放器底部那一坨在真机树里的 id（日志 38 的 `[Tree] #7`）。
    private static let bottomAnchorIdentifier = "npv.bottomStackView"
    /// 锚点走查上限（本仓库纪律）。
    private static let maxNodes = 2000
    /// 音量那一行的尺寸。
    ///
    /// ★ 2026-10-11（照片 69 → 照片 68）：**原来那一版"很难看"，因为它是系统原样的
    /// `MPVolumeView`** —— iOS 26 上那是一条玻璃胶囊轨 + 一颗大钮，铺满整宽（照片 69 里
    /// 就是那条横在页面最底、白钮贴左边缘的东西）。kumone 的（照片 68）是：
    /// **约 4pt 细轨 + 小圆钮（≈14pt）+ 两端各一个小喇叭图标**，整行**左右各内缩 ≈42pt**，
    /// 行高 24pt、夹在三键与三个圆钮之间。
    ///
    /// 我们照它的**观感**来（位置仍沿用既有锚点逻辑 —— 那是为"别压到原生控件/别撞 home indicator"
    /// 定的，先不动）：细轨、小钮、两端喇叭，行左右各内缩 24pt。
    private static let volumeRowHeight: CGFloat = 28
    private static let volumeRowInset: CGFloat = 24
    private static let volumeGlyphSize: CGFloat = 16
    private static let volumeGlyphGap: CGFloat = 10
    private static let volumeTrackHeight: CGFloat = 4
    private static let volumeThumbDiameter: CGFloat = 14
    private static let volumeRowIdentifier = "eevee-npv-volume-row"

    /// ★ 2026-10-11（用户报的）：两端小喇叭要**比行中线高多少 pt**。
    ///
    /// 用户原话：**「那两个扬声器的高度没有和那个调整音量的行一样高」** —— 对的。
    /// 照片 71 逐像素量（591px → 414pt，×0.7005）：
    ///
    /// | 东西 | 像素行 | 中线 |
    /// |---|---|---|
    /// | 音量**轨**（那 5 行实心像素） | y 1196…1200 | **839.3pt** |
    /// | **圆钮**（白色那 19 行，直径 13.3 ≈ 14pt） | y 1189…1207 | **839.2pt** |
    /// | **左**喇叭字形 | y 1196…1214 | **844.1pt** |
    /// | **右**喇叭字形 | y 1200…1211 | **844.4pt** |
    ///
    /// ⇒ 轨与圆钮**同心**（839.2 / 839.3），只有两个喇叭字形**低 ≈4.9pt**。
    /// 而代码里两者都是"按行中线居中"摆的
    /// （`slider.y = (28−28)/2 = 0`、`glyphY = (28−16)/2 = 6`）—— 所以偏差**不在我们这边**：
    /// **iOS 26 的 `MPVolumeView` 把那条轨画在它自己 frame 中线上方 ≈5pt**
    /// （行内局部坐标：轨在 ≈9.2，中线是 14）。
    ///
    /// 为什么用常量补偿而不是去问它的内部 `UISlider`：那枚 slider 是**私有层级**
    /// （本文件下方 `styleVolumeSlider` 那段注释里已经定过纪律：不猜内部结构）。
    /// ⇒ 只补偿我们**自己的**两个装饰字形（不吃触摸、不动系统那条音量条的位置），
    ///   并且把这一行的实际 frame 打进安装日志 —— 下一份日志 + 照片一对就能判。
    ///
    /// ⚠️ 这个数是**为 iOS 26 量的**；哪天系统把轨画回中线（或换了版式），把它改成 0 即可。
    private static let volumeGlyphLift: CGFloat = 5
    private static let gapBelowAnchor: CGFloat = 4

    private static var overlayKey: UInt8 = 0

    private static weak var lastPage: UIView?
    private static weak var lastOverlay: UIView?

    private static var didLogInstall = false

    static var isEnabled: Bool { UserDefaults.nowPlayingVolume }

    // MARK: - 对外入口

    /// 进听歌页时叫一次（蹭既有的 `NPVScrollViewControllerHook` 两个 appear 点）。
    static func apply(in pageView: UIView) {
        lastPage = pageView

        guard isEnabled else {
            remove(reason: "switch off")
            return
        }
        guard pageView.bounds.width > 1, pageView.bounds.height > 1 else { return }

        let overlay = attach(to: pageView)
        layout(overlay: overlay, in: pageView)
    }

    /// 蹭 `DeclutterChrome` 既有的复查节拍（**不新开定时器**）。
    ///
    /// 为什么需要：Spotify 的布局回合会重排 subviews（把我们的层挤回下面），
    /// 换歌 / 转场之后锚点的 frame 也会变。成本：没在听歌页时三次 weak 读；
    /// 在听歌页时几次 frame 比较（没变就一个字节都不写）。
    @discardableResult
    static func reconcile() -> Bool {
        guard isEnabled else { return false }
        guard let page = lastPage, page.window != nil else { return false }

        guard let overlay = lastOverlay, overlay.superview === page else {
            let overlay = attach(to: page)
            layout(overlay: overlay, in: page)
            return true
        }
        return layout(overlay: overlay, in: page)
    }

    /// 设置页切开关时叫一次：页面还挂着就**当场**落地，否则等下次进听歌页。
    static func reapply() {
        guard let page = lastPage, page.window != nil else { return }
        apply(in: page)
    }

    /// 关掉开关时把整层拿走（我们只加过自己的视图 ⇒ 不需要还原任何东西）。
    static func remove(reason: String) {
        guard let overlay = lastOverlay else { return }
        overlay.removeFromSuperview()
        lastOverlay = nil
        didLogInstall = false
        writeDebugLog("[\(logTag)] overlay removed (reason=\(reason))")
    }

    // MARK: - 建层

    /// 幂等：已经有就复用；被挤下去就重新置顶。
    private static func attach(to page: UIView) -> UIView {
        let overlay: UIView
        if let existing = objc_getAssociatedObject(page, &overlayKey) as? UIView {
            overlay = existing
        } else {
            overlay = NowPlayingOverlayView(frame: page.bounds)
            overlay.backgroundColor = .clear
            // ★★ 2026-10-12（用户：「目前那个调节音量的按键是个装饰，能不能让它真的可以调节音量」）：
            //   **不能再用 `isUserInteractionEnabled = false`。**
            //
            //   那一句当初是为了"不吃原生手势"（下拉关闭 / 滚动 / 左右切歌），但它有个
            //   UIKit 层面的副作用：命中测试**在父视图这一级就停了** —— 父视图关掉交互，
            //   **整个子树**都收不到触摸，包括里面那颗**真的** `MPVolumeView`
            //   ⇒ 音量条只能是装饰（用户报的正是这个）。
            //
            //   现在改成"整层开着交互、但**只有音量那一行的范围**返回 true"
            //   （`NowPlayingOverlayView.point(inside:)`）—— 与
            //   `NowPlayingLyricsContainerView.passThroughBottom` 同一个手法：
            //   范围之外照旧全部穿透给 Spotify。
            overlay.isUserInteractionEnabled = true
            overlay.clipsToBounds = false
            overlay.accessibilityIdentifier = "eevee-npv-overlay"
            overlay.isAccessibilityElement = false
            objc_setAssociatedObject(page, &overlayKey, overlay, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }

        if overlay.superview !== page || page.subviews.last !== overlay {
            // 放最上面：Spotify 重排 subviews 会把我们挤下去（同 `AmazonMusicLyricsOverlay`
            // 那条真机教训），所以每次进来都确保一次。
            page.addSubview(overlay)
        }
        lastOverlay = overlay
        return overlay
    }

    // MARK: - 布局

    /// 把覆盖层铺满、把音量条摆到锚点下面。**返回这一拍有没有真的改东西**。
    @discardableResult
    private static func layout(overlay: UIView, in page: UIView) -> Bool {
        var changed = false

        let wanted = CGRect(origin: .zero, size: page.bounds.size)
        if overlay.frame != wanted {
            overlay.frame = wanted
            changed = true
        }

        let target = volumeFrame(in: page, overlay: overlay)
        if overlay.subviews.first(where: { $0.accessibilityIdentifier == volumeRowIdentifier })?.frame != target {
            changed = true
        }
        layoutVolumeRow(in: overlay, frame: target)
        // ★ 2026-10-12：把"唯一吃触摸的范围"告诉覆盖层（见 `NowPlayingOverlayView`）——
        //   不更新它，音量条就还是没有触摸（这一层只在那一行里放行）。
        if let interactive = overlay as? NowPlayingOverlayView, interactive.interactiveFrame != target {
            interactive.interactiveFrame = target
            changed = true
        }

        if !didLogInstall {
            didLogInstall = true
            let anchor = findBottomAnchor(in: page)
            let anchorText = anchor.map { frameText($0.convert($0.bounds, to: page)) } ?? "not found (falling back to the safe-area bottom)"
            writeDebugLog(
                "[\(logTag)] overlay installed \(frameText(overlay.frame))"
                    + "; bottom anchor \(bottomAnchorIdentifier) = \(anchorText)"
                    + "; volume slider \(frameText(target))"
                    // ★ 2026-10-11：这一行的**实测**内部几何（系统那条 slider + 两个字形 + 抬了多少）——
                    //   用户报的"喇叭和轨不一样高"就是靠这一行 + 下一张照片对出来的。
                    + volumeRowInternals(in: overlay)
            )
        }
        return changed
    }

    /// 音量那一行的**实测**内部几何（只给安装日志用）。
    private static func volumeRowInternals(in overlay: UIView) -> String {
        guard let row = overlay.subviews.first(where: {
            $0.accessibilityIdentifier == volumeRowIdentifier
        }) else { return "; volume row not found" }

        let slider = row.subviews.compactMap { $0 as? MPVolumeView }.first
        let low = row.subviews.first { $0.accessibilityIdentifier == "eevee-npv-volume-glyph-low" }
        let high = row.subviews.first { $0.accessibilityIdentifier == "eevee-npv-volume-glyph-high" }

        let sliderText = slider.map { frameText($0.frame) } ?? "not found"
        let lowText = low.map { frameText($0.frame) } ?? "not found"
        let highText = high.map { frameText($0.frame) } ?? "not found"
        return "; volume row \(frameText(row.frame)) slider \(sliderText)"
            + " glyphLow \(lowText) glyphHigh \(highText)"
            + " (glyphs lifted \(Int(volumeGlyphLift))pt to meet the track)"
    }

    /// 把音量那一行摆好 + 给系统那条音量条**换皮**。
    ///
    /// 结构（我们自己的视图，Spotify 一个字节都不动）：
    /// ```
    /// eevee-npv-volume-row            ← 容器，不吃触摸
    ///   ├─ 左喇叭（speaker.fill）      ← 纯装饰
    ///   ├─ MPVolumeView                ← 唯一吃触摸的那个（系统音量只能靠它）
    ///   └─ 右喇叭（speaker.wave.3.fill）
    /// ```
    private static func layoutVolumeRow(in overlay: UIView, frame: CGRect) {
        let row = ensureVolumeRow(in: overlay)
        if row.frame != frame { row.frame = frame }

        let glyph = volumeGlyphSize
        let sliderX = glyph + volumeGlyphGap
        let sliderWidth = max(40, frame.width - sliderX * 2)
        let sliderFrame = CGRect(
            x: sliderX,
            y: (frame.height - volumeRowHeight) / 2,
            width: sliderWidth,
            height: volumeRowHeight
        )
        let slider = volumeSlider(in: row)
        if slider.frame != sliderFrame { slider.frame = sliderFrame }

        let left = row.subviews.first { $0.accessibilityIdentifier == "eevee-npv-volume-glyph-low" }
        let right = row.subviews.first { $0.accessibilityIdentifier == "eevee-npv-volume-glyph-high" }
        // ★ 2026-10-11：两个字形要**抬到轨那条线**上（见 `volumeGlyphLift`：iOS 26 的
        //   `MPVolumeView` 把轨画在它自己 frame 中线上方 ≈5pt，直接按行中线摆会低一颗）。
        let glyphY = (frame.height - glyph) / 2 - volumeGlyphLift
        left?.frame = CGRect(x: 0, y: glyphY, width: glyph, height: glyph)
        right?.frame = CGRect(x: frame.width - glyph, y: glyphY, width: glyph, height: glyph)
    }

    /// 幂等：那一行只建一次（`MPVolumeView` 走的是系统音量，Apple 自己的控件）。
    private static func ensureVolumeRow(in overlay: UIView) -> UIView {
        if let existing = overlay.subviews.first(where: {
            $0.accessibilityIdentifier == volumeRowIdentifier
        }) {
            return existing
        }

        let row = UIView(frame: .zero)
        // ★ 2026-10-12：**这一行必须吃触摸**，否则里面那颗 `MPVolumeView` 一样点不到
        //   （子视图能不能收到触摸，取决于**它和它的每一个祖先**都开着交互）。
        //   范围外的穿透由父层 `NowPlayingOverlayView.point(inside:)` 保证。
        row.isUserInteractionEnabled = true
        row.accessibilityIdentifier = volumeRowIdentifier

        row.addSubview(volumeGlyph(named: "speaker.fill", identifier: "eevee-npv-volume-glyph-low"))
        row.addSubview(volumeGlyph(named: "speaker.wave.3.fill", identifier: "eevee-npv-volume-glyph-high"))

        let slider = MPVolumeView(frame: .zero)
        slider.showsRouteButton = false          // 不要那枚 AirPlay 路由按钮（kumone 也没有）
        slider.isUserInteractionEnabled = true
        styleVolumeSlider(slider)
        row.addSubview(slider)

        overlay.addSubview(row)
        return row
    }

    private static func volumeSlider(in row: UIView) -> MPVolumeView {
        if let existing = row.subviews.compactMap({ $0 as? MPVolumeView }).first {
            return existing
        }
        let slider = MPVolumeView(frame: .zero)
        slider.showsRouteButton = false
        slider.isUserInteractionEnabled = true
        styleVolumeSlider(slider)
        row.addSubview(slider)
        return slider
    }

    /// 两端的小喇叭（纯装饰，不吃触摸）。
    private static func volumeGlyph(named symbol: String, identifier: String) -> UIImageView {
        let view = UIImageView()
        view.image = UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        )
        view.tintColor = UIColor.white.withAlphaComponent(0.55)
        view.contentMode = .scaleAspectFit
        view.isUserInteractionEnabled = false
        view.accessibilityIdentifier = identifier
        return view
    }

    // MARK: - 给系统音量条换皮（照片 68 的样子）

    /// ★ 2026-10-11：**只走公开接口**。
    ///
    /// `MPVolumeView` 内部那枚 `UISlider` 是私有层级（改 tint 属于"猜内部结构"），
    /// 而它有三条**公开**的图片接口：`setMinimumVolumeSliderImage(_:for:)`（已播放那段）、
    /// `setMaximumVolumeSliderImage(_:for:)`（未播放那段）、`setVolumeThumbImage(_:for:)`。
    /// 用可拉伸的图片喂进去 ⇒ 想要多细就多细，且**不会**碰到它的内部视图。
    private static func styleVolumeSlider(_ slider: MPVolumeView) {
        guard !styledVolumeSliders.contains(slider) else { return }
        styledVolumeSliders.add(slider)

        slider.setMinimumVolumeSliderImage(
            trackImage(color: UIColor.white.withAlphaComponent(0.92)),
            for: .normal
        )
        slider.setMaximumVolumeSliderImage(
            trackImage(color: UIColor.white.withAlphaComponent(0.22)),
            for: .normal
        )
        slider.setVolumeThumbImage(thumbImage(), for: .normal)
    }

    private static let styledVolumeSliders = NSHashTable<MPVolumeView>.weakObjects()

    /// 一条胶囊轨（两端半圆），中间可拉伸。
    private static func trackImage(color: UIColor) -> UIImage {
        let height = volumeTrackHeight
        let size = CGSize(width: height * 3, height: height)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            color.setFill()
            UIBezierPath(
                roundedRect: CGRect(origin: .zero, size: size),
                cornerRadius: height / 2
            ).fill()
        }
        let cap = height / 2
        return image.resizableImage(
            withCapInsets: UIEdgeInsets(top: 0, left: cap, bottom: 0, right: cap)
        )
    }

    /// 小圆钮（带一点投影，白钮在深色底上才站得住）。
    private static func thumbImage() -> UIImage {
        let side = volumeThumbDiameter
        let size = CGSize(width: side, height: side)
        return UIGraphicsImageRenderer(size: size).image { context in
            context.cgContext.setShadow(
                offset: CGSize(width: 0, height: 1),
                blur: 3,
                color: UIColor.black.withAlphaComponent(0.35).cgColor
            )
            UIColor.white.setFill()
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).fill()
        }
    }

    /// 音量条放哪：**锚点下面**；锚点不在（或空间不够）就贴安全区底。
    private static func volumeFrame(in page: UIView, overlay: UIView) -> CGRect {
        let width = max(120, page.bounds.width - volumeRowInset * 2)
        let x = (page.bounds.width - width) / 2

        // 安全区底：页面自己的 `safeAreaInsets` 就是最可靠的"别压到 home indicator"来源。
        let bottomLimit = page.bounds.height - page.safeAreaInsets.bottom - 4

        var y: CGFloat
        if let anchor = locateBottomAnchor(in: page) {
            let frame = anchor.convert(anchor.bounds, to: overlay)
            y = frame.maxY + gapBelowAnchor
        } else {
            y = bottomLimit - volumeRowHeight
        }

        // 越界就往回收，绝不叠到原生控件上。
        if y + volumeRowHeight > bottomLimit {
            y = max(0, bottomLimit - volumeRowHeight)
        }
        return CGRect(x: x, y: y, width: width, height: volumeRowHeight)
    }

    /// `npv.bottomStackView` 在哪：**页面 → 播放器列表 → 窗口**，三跳。
    ///
    /// 为什么要补中间那一跳（2026-10-04，日志 40/41/42/43 四次同样的现场）：
    /// 它**不在页面根视图的子树里**（日志 42 的定向树显示它在
    /// `scrolling_npv_collection_view_accessibility_identifier` 的子树里，`4,593,406,240`），
    /// 而"窗口"那一跳也没命中 ⇒ 每次进页面都退回安全区底。
    /// 列表这一跳用的是 `NowPlayingOneScreen` 认出来的那一张（判据只留一处）。
    private static func locateBottomAnchor(in page: UIView) -> UIView? {
        if let anchor = findBottomAnchor(in: page) { return anchor }
        if let list = NowPlayingOneScreen.pinnedList,
           let anchor = findBottomAnchor(in: list) {
            return anchor
        }
        guard let window = page.window else { return nil }
        return findBottomAnchor(in: window)
    }

    /// 按 `accessibilityIdentifier` 找播放器底部那一坨（有界广度优先）。
    private static func findBottomAnchor(in root: UIView) -> UIView? {
        var visited = 0
        var queue: [UIView] = [root]

        while !queue.isEmpty, visited < maxNodes {
            let view = queue.removeFirst()
            visited += 1

            if view.accessibilityIdentifier == bottomAnchorIdentifier { return view }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }

    // MARK: - 整页覆盖层（只让音量那一行吃触摸）

    /// 铺满整页、**只在音量那一行的范围内**吃触摸的透明层。
    ///
    /// ★★ 2026-10-12（用户：「目前那个调节音量的按键是个装饰，能不能让它真的可以调节音量」）：
    ///   这一层以前是 `isUserInteractionEnabled = false`（为了不吃原生手势），而 UIKit 的命中测试
    ///   **在父视图这一级就停了**：父层关掉交互 ⇒ **整个子树**（含那颗真的 `MPVolumeView`）
    ///   都收不到触摸 ⇒ 音量条只能是装饰。
    ///
    ///   现在：整层开着交互，靠 `point(inside:)` 把"可交互范围"限死在音量那一行
    ///   （`interactiveFrame` 每一拍由 `layout(overlay:in:)` 更新）—— 手法与
    ///   `NowPlayingLyricsContainerView.passThroughBottom` 完全一致。
    ///   范围之外返回 false ⇒ 照旧全部穿透给 Spotify（下拉关闭 / 滚动 / 左右切歌不受影响）。
    final class NowPlayingOverlayView: UIView {

        /// 唯一要吃到触摸的那条范围（本视图坐标系 = 页面坐标系，因为这一层就钉在页面原点）。
        /// `.null` ⇒ 整层穿透（音量条还没摆好时不抢任何触摸）。
        var interactiveFrame: CGRect = .null

        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            guard isUserInteractionEnabled, !isHidden, alpha > 0.01 else { return false }
            guard !interactiveFrame.isNull else { return false }
            // 上下各放宽 8pt：手指落在轨/钮边上一点也该算这一行（行高只有 28pt）。
            return interactiveFrame.insetBy(dx: -2, dy: -8).contains(point)
        }
    }

    // MARK: - 日志

    private static func frameText(_ frame: CGRect) -> String {
        "\(Int(frame.origin.x)),\(Int(frame.origin.y)),\(Int(frame.width)),\(Int(frame.height))"
    }
}
