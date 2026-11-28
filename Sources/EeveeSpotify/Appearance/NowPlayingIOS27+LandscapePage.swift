// 横屏「歌词自己的屏」—— 这一屏由我们自己搭。
//
// 旧的横屏做法是**改 Spotify 的原生几何**：把 `npv.bottomStackView` 收窄到左栏、压低它的
// 横向约束优先级、再把歌名 / 进度 / 传输三行搬出栈自己摆。那条路每一拍都在跟布局回合打架
// （真机上宽度与横位都没留住，盒子仍是 272pt），封面只能吃剩下的高度，而**歌词的左沿是从
// 左栏右边沿加一个间隙推出来的** —— 左栏一塌到下限，歌词就跟着滑到页面正中间。
//
// 这一层换做法：横屏时铺一屏**我们自己的**东西。
// · 歌名 / 艺人 / 进度 / 传输由这里画（文案读原生标签，动作走 `WordByWordPlaybackControl`
//   与 `WordByWordSeeker`，原生那一页仍然连着真实播放管线）；
// · 歌词还是那一份 SwiftUI 宿主（`NowPlayingLyricsPlate.mountLyricsOnly`），位置由这里给；
// · 原生那一坨（歌名 / 进度 / 传输 / 收藏 / 工具行）整块 `alpha = 0` 按下去，只当状态源；
// · 封面仍由 `updateArtwork` 画（那张图本来就是我们自己的），位置取本层的 `cover`。
//
// 几何**只由页面尺寸与安全区推**，不读 Spotify 的任何一坨 ⇒ 换歌 / 换页 / 转屏都不会让
// 歌词再挪位置。右栏口径：右沿落在右上那颗 ⋯ 与它下面三颗字形之内侧，宽度封顶
// `landscapeLyricsMaxWidth`（多出来的宽度**放到左边**，不往中间挤）。
//
// 手指在歌词上滑动时，这一列（歌名 / 艺人 / 进度 / 传输）一起淡出，停手 1.6s 再淡回 ——
// 判据只能是**手势**：歌词每帧自动滚，按 `contentOffset` 判会永远收着。纯文本那一档不自动滚，
// 所以它要**内容真的滚了**才收（判据在 `LandscapeScrollHideRule`）：整段词放得下、没得滚时按一下也不收。
//
// 歌名 / 艺人是我们自己的 label（原生标题行整块被按着），所以点击也在这里接：
// 歌名 → 专辑页，艺人 → 艺人页。
//
// 开关 `landscapePageEnabled`：关掉退回旧的两栏路径（`placeLandscapeStack` + `LandscapeRows`），
// 便于并排对比两版。日志 tag：`[iOS27]`，一次性一行 `landscape page — …`。
import Foundation
import SwiftUI
import UIKit
import ObjectiveC.runtime

@MainActor
extension NowPlayingIOS27 {

    /// 横屏自建页这一档开不开。关掉走旧路径（收窄底排 + 搬行）。
    static let landscapePageEnabled = true

    // MARK: - 几何

    /// 横屏这一屏的框（页面坐标）。只由页面尺寸与安全区推出来。
    struct LandscapePageGeometry {
        var column: CGRect
        var cover: CGRect
        var title: CGRect
        var artist: CGRect
        /// 进度 / 两端时间 / 传输那一条（SwiftUI 控件自带内部排版）。
        var controls: CGRect
        var lyrics: CGRect

        /// 交给 `landscapeLayout` 的那一份：封面与歌词都从它取（见 `artworkFrame` / `lyricsStageFrame`）。
        var shared: LandscapeLayout {
            LandscapeLayout(
                column: column,
                cover: cover,
                lyrics: lyrics,
                stackLeft: column.minX,
                stackInset: 24,
                stackContentHeight: 0
            )
        }
    }

    /// 自建页的几何；竖屏 / 页面太矮 / 开关关着时 nil。
    ///
    /// 左栏自上而下：封面 → 歌名 → 艺人 → 进度 → 时间 → 传输。封面吃的是
    /// 「可用高 − 这一列控件 − 空隙」，所以它和这一列是互相约束的（不是写死的）。
    static func landscapePageGeometry(in page: UIView) -> LandscapePageGeometry? {
        guard landscapePageEnabled, isLandscapeTwoColumn(page) else { return nil }
        let bounds = page.bounds
        let insets = page.safeAreaInsets
        let left = max(12, insets.left + 16)
        let top = max(16, insets.top + 8)
        let bottom = bounds.height - max(12, insets.bottom + 6)
        let usable = bottom - top
        // 右缘那一列（右上角的 ⋯ 与它下面三颗字形）由这里让出去。
        let rightRail = bounds.width - max(24, insets.right + 64)
        guard usable > 220, rightRail - left > 320 else { return nil }

        let titleHeight: CGFloat = 24
        let artistHeight: CGFloat = 18
        let controlsHeight: CGFloat = 104
        let textGap: CGFloat = 4
        let rowGap: CGFloat = 10
        let bandHeight = titleHeight + textGap + artistHeight + rowGap + controlsHeight
        var coverSide = min(
            LayoutGeometry.landscapeCoverMaxSide,
            usable - bandHeight - LayoutGeometry.landscapeCoverStackGap
        )
        coverSide = max(LayoutGeometry.landscapeMinCoverSide, coverSide)
        let columnWidth = min(max(coverSide, LayoutGeometry.landscapeColumnMinWidth), rightRail - left)

        let column = CGRect(x: left, y: top, width: columnWidth, height: usable)
        let cover = CGRect(x: left, y: top, width: coverSide, height: coverSide)
        var y = cover.maxY + LayoutGeometry.landscapeCoverStackGap
        let title = CGRect(x: left, y: y, width: columnWidth, height: titleHeight)
        y = title.maxY + textGap
        let artist = CGRect(x: left, y: y, width: columnWidth, height: artistHeight)
        y = artist.maxY + rowGap
        let controls = CGRect(x: left, y: y, width: columnWidth, height: controlsHeight)

        // 歌词贴右：右沿落在 rail 上，宽度封顶。多出来的宽度**留在左边**（不去中间）。
        let room = rightRail - (column.maxX + LayoutGeometry.landscapeColumnGap)
        guard room > 200 else { return nil }
        let lyricsWidth = min(room, landscapeLyricsMaxWidth)
        let lyrics = CGRect(x: rightRail - lyricsWidth, y: top, width: lyricsWidth, height: usable)

        return LandscapePageGeometry(
            column: column,
            cover: cover,
            title: title,
            artist: artist,
            controls: controls,
            lyrics: lyrics
        )
    }

    // MARK: - 状态

    /// 我们自己那一屏（透明的承载层 + 两行会滚动的文字 + 一条 SwiftUI 控件）。
    static var landscapePageView: LandscapePageView?
    static var landscapePageTitle: LandscapePageMarqueeView?
    static var landscapePageArtist: LandscapePageMarqueeView?
    static var landscapePageControls: UIHostingController<LandscapePageControls>?
    /// 被整块按下去的原生底排（收回时要按原值写回）。
    static weak var landscapeHiddenStack: UIView?
    static var didLogLandscapePage = false

    /// 歌名 / 艺人那两行的点击处理器（手势的 target 必须被强引用住）。
    static let landscapeTitleTapHandler = LandscapePageTapHandler(kind: .album)
    static let landscapeArtistTapHandler = LandscapePageTapHandler(kind: .artist)

    /// 播放状态投影：时间 / 时长 / 是否在播（`AppleMusicLyricsPlaybackControl` 里那份）。
    static let landscapePageProjection = AppleMusicLyricsPlaybackProjection {
        WordByWordPositionResolver.shared.currentPositionSeconds()
    }

    // MARK: - 滚动歌词时收控件
    //
    // 手指在歌词上滑动 ⇒ 歌名 / 艺人 / 控件带一起淡出，停手 `restoreDelay` 之后再淡回来。
    // 这样歌词滚动时屏幕上只剩封面与词，和 Chroma 横屏歌词页那一条一致。
    //
    // 判据**只能用手势**，不能看 `contentOffset`：歌词是每帧自动滚的（逐词跟唱），
    // 偏移量一直在变 ⇒ 按偏移判会永远收着。这里把观察者**挂到宿主自己那条 pan 上**
    // （`addTarget`），不新建手势、不抢 delegate，滚动手感一点不变。
    //
    // 纯文本那一档是例外里的一半：它也走这条 pan，内容却可能短到放得下（没得滚）。
    // 所以它额外要求"手势期间内容真的挪过"（`landscapeScrollStartOffsetY` 那条增量），
    // 判据收在 `LandscapeScrollHideRule` 里。

    static let landscapeControlsFadeDuration: TimeInterval = 0.18
    static let landscapeControlsRestoreDelay: TimeInterval = 1.6
    static let landscapeScrollWatcher = LandscapeScrollWatcher()
    static weak var landscapeWatchedScrollView: UIScrollView?
    static weak var landscapeWatchedPan: UIPanGestureRecognizer?
    static var landscapeControlsHidden = false
    static var landscapeControlsRestoreWork: DispatchWorkItem?
    /// 手势开始那一刻的滚动位置 / 这一档是不是纯文本 —— 都在 `began` 时取一次
    /// （`landscapeLyricsAreStatic()` 会建数组，不能每帧调）。
    static var landscapeScrollStartOffsetY: CGFloat?
    static var landscapeScrollIsStatic = false

    /// 挂观察者（只在宿主换了一条滚动视图时重挂）。
    private static func attachLandscapeScrollWatcher() {
        guard let container = NowPlayingLyricsPlate.lastContainer else { return }
        if let watched = landscapeWatchedScrollView, watched.window != nil,
           watched.isDescendant(of: container) {
            return
        }
        guard let scroll = firstScrollView(in: container) else { return }
        landscapeScrollWatcher.didBegin = { noteLandscapeScrollBegan() }
        landscapeScrollWatcher.didMove = { distance in noteLandscapeScrollMoved(distance) }
        landscapeScrollWatcher.didEnd = { noteLandscapeScrollEnded() }
        let pan = scroll.panGestureRecognizer
        pan.addTarget(
            landscapeScrollWatcher,
            action: #selector(LandscapeScrollWatcher.handlePan(_:))
        )
        landscapeWatchedScrollView = scroll
        landscapeWatchedPan = pan
        writeDebugLog(
            "[\(logTag)] landscape scroll — watcher attached on \(NSStringFromClass(type(of: scroll)))"
                + (landscapeLyricsAreStatic() ? " (plain lyrics: hides only when the text really moves)" : "")
        )
    }

    /// 这一档歌词**没有时间轴**（纯文本，比如 Genius / 无时间戳的词）：它不跟唱，
    /// 划动时只有"内容真的滚了"才收控件 —— 内容短到放得下时按一下不能收。
    /// 判据与 `mountLyricsOnly` 里那次 `isStatic` 一致。
    private static func landscapeLyricsAreStatic() -> Bool {
        let timed = NowPlayingLyricsPlate.currentLines() ?? []
        return timed.isEmpty && NowPlayingLyricsPlate.currentUntimedLines() != nil
    }

    private static func firstScrollView(in root: UIView) -> UIScrollView? {
        var queue: [UIView] = [root]
        var visited = 0
        while !queue.isEmpty, visited < 400 {
            let node = queue.removeFirst()
            visited += 1
            if let scroll = node as? UIScrollView { return scroll }
            queue.append(contentsOf: node.subviews)
        }
        return nil
    }

    /// 手指按下就记一笔（状态 + 滚动位置），但**先不收**：要等真的划出距离（见 `noteLandscapeScrollMoved`）。
    private static func noteLandscapeScrollBegan() {
        landscapeScrollIsStatic = landscapeLyricsAreStatic()
        landscapeScrollStartOffsetY = landscapeWatchedScrollView?.contentOffset.y
        landscapeControlsRestoreWork?.cancel()
        landscapeControlsRestoreWork = nil
    }

    /// 划出 `LandscapeScrollHideRule.dragThreshold` 之后才把这一列收起来。
    ///
    /// 为什么不看"手势开始"：轻点、误触、以及**没有可滚内容**的那一档都会开始一条 pan，
    /// 那时收控件等于"没划动也消失"。纯文本那一档还要求内容真的挪过（见那份规则）。
    private static func noteLandscapeScrollMoved(_ drag: CGFloat) {
        let offsetDelta: CGFloat
        if let start = landscapeScrollStartOffsetY {
            offsetDelta = (landscapeWatchedScrollView?.contentOffset.y ?? start) - start
        } else {
            offsetDelta = 0
        }
        guard LandscapeScrollHideRule.shouldHide(
            isStatic: landscapeScrollIsStatic,
            dragDistance: drag,
            contentOffsetDelta: offsetDelta
        ) else { return }
        applyLandscapeControlsHidden(true)
    }

    private static func noteLandscapeScrollEnded() {
        guard landscapeControlsHidden else { return }
        landscapeScrollStartOffsetY = nil
        landscapeControlsRestoreWork?.cancel()
        let work = DispatchWorkItem { applyLandscapeControlsHidden(false) }
        landscapeControlsRestoreWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + landscapeControlsRestoreDelay,
            execute: work
        )
    }

    private static func applyLandscapeControlsHidden(_ hidden: Bool) {
        guard hidden != landscapeControlsHidden else { return }
        landscapeControlsHidden = hidden
        setLandscapePageChromeAlpha(hidden ? 0 : 1, animated: true)
        if let view = landscapePageView {
            view.hitRects = hidden ? [] : view.visibleHitRects
        }
    }

    /// 顶上那一列（歌名 / 艺人 / 控件）的透明度；`animated` 只在手势那两下用。
    private static func setLandscapePageChromeAlpha(_ alpha: CGFloat, animated: Bool) {
        var views: [UIView] = []
        if let title = landscapePageTitle { views.append(title) }
        if let artist = landscapePageArtist { views.append(artist) }
        if let controls = landscapePageControls?.view { views.append(controls) }
        guard !views.isEmpty, views.contains(where: { $0.alpha != alpha }) else { return }
        if animated {
            UIView.animate(
                withDuration: landscapeControlsFadeDuration,
                delay: 0,
                options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]
            ) {
                for view in views { view.alpha = alpha }
            }
        } else {
            for view in views { view.alpha = alpha }
        }
    }

    // MARK: - 每拍入口

    /// 把这一屏摆好；不在横屏 / 开关关着时收走。
    ///
    /// ⚠️ 必须排在 `updateLyricsStage` 之前（歌词容器按 `landscapeLayout` 的 `lyrics` 铺）。
    @discardableResult
    static func placeLandscapePage(in page: UIView) -> Bool {
        guard let geometry = landscapePageGeometry(in: page) else {
            clearLandscapePage()
            return false
        }
        // 这一档不搬行：上一档留下的三行先放回底排（否则底排里的槽位是空的）。
        if landscapeTitleRow != nil || landscapeProgressRow != nil || landscapeTransportRow != nil {
            restoreLandscapeRows()
        }

        let view = ensureLandscapePageView(in: page)
        var changed = false
        if view.frame != page.bounds {
            view.frame = page.bounds
            changed = true
        }

        let titleText = landscapePageText(identifier: NowPlayingLyricsPlate.titleLabelIdentifier, in: page)
        if updateLandscapePageText(landscapePageTitle, text: titleText, frame: geometry.title) {
            changed = true
        }
        let artistText = landscapePageText(identifier: NowPlayingLyricsPlate.subtitleLabelIdentifier, in: page)
        if updateLandscapePageText(landscapePageArtist, text: artistText, frame: geometry.artist) {
            changed = true
        }
        if let controls = landscapePageControls, controls.view.frame != geometry.controls {
            controls.view.frame = geometry.controls
            changed = true
        }
        // 滚动歌词时这一列是收起来的：每拍只保证 alpha / 命中区与状态一致，不重复做动画。
        var hitRects: [CGRect] = [geometry.controls]
        if let text = landscapePageTitle?.text, !text.isEmpty {
            hitRects.append(geometry.title)
        }
        if let text = landscapePageArtist?.text, !text.isEmpty {
            hitRects.append(geometry.artist)
        }
        if view.visibleHitRects != hitRects {
            view.visibleHitRects = hitRects
        }
        setLandscapePageChromeAlpha(landscapeControlsHidden ? 0 : 1, animated: false)
        // 兜底：手势的 `ended` 没回来（宿主重建 / 手势被打断）时别把这一列永远收着。
        if landscapeControlsHidden, landscapeControlsRestoreWork == nil,
           let pan = landscapeWatchedPan,
           pan.state != .began, pan.state != .changed {
            applyLandscapeControlsHidden(false)
        }
        let wantedHits: [CGRect] = landscapeControlsHidden ? [] : hitRects
        if view.hitRects != wantedHits {
            view.hitRects = wantedHits
        }
        // 歌词容器是这一拍稍后才挂的 ⇒ 观察者在下一拍才会挂上，够了。
        attachLandscapeScrollWatcher()
        // 位置 / 时长 / 是否在播：这一拍先刷一次（进度条就按这一拍的节拍走）。
        landscapePageProjection.refresh()

        if !didLogLandscapePage {
            didLogLandscapePage = true
            let titleNote = titleText == nil ? "missing" : "ok"
            let artistNote = artistText == nil ? "missing" : "ok"
            writeDebugLog(
                "[\(logTag)] landscape page — cover \(Int(geometry.cover.width))pt at"
                    + " \(landscapeRectText(geometry.cover)),"
                    + " lyrics \(Int(geometry.lyrics.minX))…\(Int(geometry.lyrics.maxX)),"
                    + " title \(titleNote), artist \(artistNote)"
            )
        }
        return changed
    }

    /// 自建页这一档"可以亮歌词"：我们自己的封面已经在页上，不再等 Spotify 的标题行
    /// （那一行整块被我们按着，`titleRowPlaced` 永远不过）。
    static func landscapePageSceneReady(in page: UIView) -> Bool {
        guard landscapePageGeometry(in: page) != nil else { return false }
        return landscapePageView?.window != nil && artworkOnPage(in: page)
    }

    /// 把这一屏收走（回竖屏 / 关页面）。原生那一坨按原值放回来。
    static func clearLandscapePage() {
        // 滚动词收控件那条：停掉待办的淡入、把观察者从宿主的手势上摘掉。
        landscapeControlsRestoreWork?.cancel()
        landscapeControlsRestoreWork = nil
        landscapeControlsHidden = false
        if let pan = landscapeWatchedPan {
            pan.removeTarget(
                landscapeScrollWatcher,
                action: #selector(LandscapeScrollWatcher.handlePan(_:))
            )
        }
        landscapeWatchedScrollView = nil
        landscapeWatchedPan = nil
        landscapeScrollStartOffsetY = nil
        landscapeScrollIsStatic = false
        if landscapePageControls != nil {
            landscapePageControls?.view.removeFromSuperview()
            landscapePageControls = nil
        }
        if landscapePageView != nil {
            landscapePageView?.removeFromSuperview()
            landscapePageView = nil
        }
        landscapePageTitle = nil
        landscapePageArtist = nil
        didLogLandscapePage = false
        revealLandscapeHiddenStack()
    }

    // MARK: - 原生底排的按 / 放

    /// 把原生那一坨整块按下去（**位置不碰**）。返回这一拍有没有写东西。
    static func hideLandscapeNativeStack(_ stack: UIView) -> Bool {
        landscapeHiddenStack = stack
        return hideChrome(stack)
    }

    /// 只把这一坨按原值放回来（不碰导航 chrome —— 那是 `placeNavChrome` 的账）。
    static func revealLandscapeHiddenStack() {
        guard let stack = landscapeHiddenStack else { return }
        landscapeHiddenStack = nil
        let key = ObjectIdentifier(stack)
        guard let original = chromeAlphas[key] else { return }
        if stack.alpha != original { stack.alpha = original }
        chromeAlphas.removeValue(forKey: key)
        hiddenChrome.remove(stack)
    }

    // MARK: - 视图

    /// 自建页的承载层：透明、**只在 `hitRects` 里吃触摸**，其余放行。
    final class LandscapePageView: UIView {
        var hitRects: [CGRect] = []
        /// 这一列**看得见时**吃触摸的那几块（控件带 / 有字的歌名 / 有字的艺人）。
        /// 滚动歌词把这一列收起来时 `hitRects` 清空，放回来就恢复成它。
        var visibleHitRects: [CGRect] = []

        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            for rect in hitRects where rect.contains(point) { return true }
            return false
        }
    }

    private static func ensureLandscapePageView(in page: UIView) -> LandscapePageView {
        if let existing = landscapePageView, existing.superview === page { return existing }
        landscapePageView?.removeFromSuperview()
        let view = LandscapePageView(frame: page.bounds)
        view.backgroundColor = UIColor.clear
        view.isOpaque = false
        view.clipsToBounds = false
        view.accessibilityIdentifier = "eevee-ios27-landscape-page"

        let title = makeLandscapePageText(
            identifier: "eevee-ios27-landscape-title",
            size: 17,
            weight: .bold
        )
        let artist = makeLandscapePageText(
            identifier: "eevee-ios27-landscape-artist",
            size: 13,
            weight: .semibold
        )
        // 歌名点开专辑、艺人点开艺人页 —— 与竖屏页内歌词那两颗透明按钮同一套动作。
        attachLandscapePageTap(to: title, handler: landscapeTitleTapHandler)
        attachLandscapePageTap(to: artist, handler: landscapeArtistTapHandler)
        view.addSubview(title)
        view.addSubview(artist)
        page.addSubview(view)
        landscapePageView = view
        landscapePageTitle = title
        landscapePageArtist = artist
        _ = ensureLandscapePageControls(in: view)
        return view
    }

    private static func makeLandscapePageText(
        identifier: String,
        size: CGFloat,
        weight: UIFont.Weight
    ) -> LandscapePageMarqueeView {
        let view = LandscapePageMarqueeView(
            font: .systemFont(ofSize: size, weight: weight),
            color: UIColor.white
        )
        view.accessibilityIdentifier = identifier
        view.isAccessibilityElement = true
        view.accessibilityTraits = .button
        return view
    }

    private static func attachLandscapePageTap(
        to view: UIView,
        handler: LandscapePageTapHandler
    ) {
        view.addGestureRecognizer(
            UITapGestureRecognizer(
                target: handler,
                action: #selector(LandscapePageTapHandler.handleTap(_:))
            )
        )
    }

    private static func updateLandscapePageText(
        _ view: LandscapePageMarqueeView?,
        text: String?,
        frame: CGRect
    ) -> Bool {
        guard let view else { return false }
        var changed = false
        if view.frame != frame {
            view.frame = frame
            changed = true
        }
        let wanted = text ?? ""
        if view.text != wanted {
            view.text = wanted
            view.accessibilityLabel = wanted.isEmpty ? nil : wanted
            changed = true
        }
        return changed
    }

    private static func ensureLandscapePageControls(
        in container: UIView
    ) -> UIHostingController<LandscapePageControls>? {
        if let existing = landscapePageControls, existing.view.superview === container {
            return existing
        }
        landscapePageControls?.view.removeFromSuperview()
        let root = LandscapePageControls(projection: landscapePageProjection) { seconds in
            WordByWordSeeker.seek(toMs: Int((seconds * 1000).rounded()))
        }
        let hosting = UIHostingController(rootView: root)
        hosting.view.backgroundColor = UIColor.clear
        hosting.view.isOpaque = false
        // 这一条由我们给框（几何从 `landscapePageGeometry` 来），不让 Auto Layout 参与。
        hosting.view.translatesAutoresizingMaskIntoConstraints = true
        hosting.view.accessibilityIdentifier = "eevee-ios27-landscape-controls"
        container.addSubview(hosting.view)
        landscapePageControls = hosting
        return hosting
    }

    // MARK: - 读原生标签 / 打日志

    /// 原生那颗标签的文字。
    ///
    /// `now-playing-title-label` 在部分版本里挂在**包着 label 的包装层**上，所以往下找
    /// 第一颗有文字的 `UILabel`，而不是要求命中的那个视图自己就是 label。
    private static func landscapePageText(identifier: String, in page: UIView) -> String? {
        guard let root = NowPlayingLyricsPlate.findByIdentifier(identifier, in: page) else {
            return nil
        }
        var queue: [UIView] = [root]
        var visited = 0
        while !queue.isEmpty, visited < 40 {
            let node = queue.removeFirst()
            visited += 1
            if let label = node as? UILabel, let text = label.text, !text.isEmpty {
                return text
            }
            queue.append(contentsOf: node.subviews)
        }
        return nil
    }

    private static func landscapeRectText(_ rect: CGRect) -> String {
        "\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))×\(Int(rect.height))"
    }
}

// MARK: - 会滚动的歌名 / 艺人
//
// 宽度够就静止。超出时不是"一直向左滚"，而是**分段读**（时间表在 `LandscapeMarqueeTimeline`）：
// 贴左端停一下 → 左移一段停一下 → … → 尾端贴右端停一下 → 一帧跳回开头 → 再走。
// 这样两端的字都完整露过，中间也能停下来看；右端留一条渐隐，滚动的字不硬切在边上。
//
// 用 `CAKeyframeAnimation` 而不是 `UIView.animate`：这一层每 0.3s 会被写一次 frame，
// 逐拍重建的 UIView 动画会被打断；挂在 `track.layer` 上的 CA 动画与 frame 写入无关。
// 只有"文字宽 / 视口宽"变了才重建，否则每一拍都会把动画从头再来一遍。

final class LandscapePageMarqueeView: UIView {

    /// 右端渐隐的宽度。
    private static let fadeWidth: CGFloat = 14
    private static let scrollKey = "marquee"

    private let track = UIView()
    private let label: UILabel
    private let fade = CAGradientLayer()
    /// 正在播的那份时间表是按哪组几何算出来的（变了才重建动画）。
    private var scrollingGeometry: (overflow: CGFloat, viewport: CGFloat)?

    var text: String = "" {
        didSet {
            guard text != oldValue else { return }
            label.text = text
            setNeedsLayout()
        }
    }

    init(font: UIFont, color: UIColor) {
        label = LandscapePageMarqueeView.makeLabel(font: font, color: color)
        super.init(frame: .zero)
        clipsToBounds = true
        isUserInteractionEnabled = true
        track.isUserInteractionEnabled = false
        addSubview(track)
        track.addSubview(label)
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        layer.mask = fade
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func makeLabel(font: UIFont, color: UIColor) -> UILabel {
        let label = UILabel()
        label.font = font
        label.textColor = color
        label.numberOfLines = 1
        // 这一行是**滚**的，不要省略号：省略号会把"还有下文"说成"没有下文"。
        label.lineBreakMode = .byClipping
        label.isUserInteractionEnabled = false
        return label
    }

    private var measuredWidth: CGFloat {
        guard !text.isEmpty, let font = label.font else { return 0 }
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        // 留一点余量，免得最后一个字贴着边裁一半。
        return width.rounded(.up) + 2
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = bounds.size
        guard size.width > 1, size.height > 1 else { return }

        fade.frame = bounds
        let fadeRatio = min(0.5, max(0.06, Self.fadeWidth / size.width))
        fade.locations = [
            NSNumber(value: 0),
            NSNumber(value: 1 - Double(fadeRatio)),
            NSNumber(value: 1),
        ]
        fade.colors = [
            UIColor.white.cgColor,
            UIColor.white.cgColor,
            UIColor.clear.cgColor,
        ]

        let textWidth = measuredWidth
        let needsScroll = textWidth > size.width + 0.5
        label.frame = CGRect(
            x: 0,
            y: 0,
            width: needsScroll ? textWidth : size.width,
            height: size.height
        )
        track.frame = CGRect(x: 0, y: 0, width: label.frame.width, height: size.height)
        guard needsScroll else {
            stopScrolling()
            return
        }
        let geometry = (overflow: textWidth - size.width, viewport: size.width)
        if let current = scrollingGeometry,
           abs(current.overflow - geometry.overflow) < 0.5,
           abs(current.viewport - geometry.viewport) < 0.5,
           track.layer.animation(forKey: Self.scrollKey) != nil {
            return
        }
        startScrolling(geometry: geometry)
    }

    private func startScrolling(geometry: (overflow: CGFloat, viewport: CGFloat)) {
        stopScrolling()
        guard let timeline = LandscapeMarqueeTimeline.timeline(
            overflow: geometry.overflow,
            viewportWidth: geometry.viewport
        ) else { return }
        scrollingGeometry = geometry
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.values = timeline.values.map { NSNumber(value: Double($0)) }
        animation.keyTimes = timeline.keyTimes.map { NSNumber(value: $0) }
        animation.duration = CFTimeInterval(timeline.duration)
        animation.repeatCount = .infinity
        animation.calculationMode = .linear
        animation.isRemovedOnCompletion = false
        track.layer.add(animation, forKey: Self.scrollKey)
    }

    private func stopScrolling() {
        scrollingGeometry = nil
        track.layer.removeAnimation(forKey: Self.scrollKey)
    }
}

// MARK: - 歌名 / 艺人的点击
//
// 自建页上的两行是**我们自己的 label**（原生标题行整块被按着），所以点击也由这里接：
// 歌名 → 当前曲目的专辑页，艺人 → 当前曲目的艺人页。动作本身复用竖屏页内歌词那一套
// （`openCurrentAlbum` / `openCurrentArtist`：先走链接分发器，拿不到 URI 再转发给原生行）。

/// 歌名 / 艺人共用的点击处理器：两个实例只差 `kind`。
final class LandscapePageTapHandler: NSObject {

    enum Kind {
        case album
        case artist
    }

    private let kind: Kind

    init(kind: Kind) {
        self.kind = kind
    }

    @objc func handleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        // `NowPlayingIOS27` 是 `@MainActor` 的，这一层不是。手势回调本来就只在主线程来，
        // 但静态检查需要把"就在主线程"显式表达出来（同一套写法见 `onMainThreadSync`）。
        switch kind {
        case .album:
            onMainThreadSync { NowPlayingIOS27.openCurrentAlbum() }
        case .artist:
            onMainThreadSync { NowPlayingIOS27.openCurrentArtist() }
        }
    }
}

// MARK: - 滚动手势观察者
//
// 只挂到歌词宿主自己那条 `UIPanGestureRecognizer` 上（`addTarget`）：不新建手势、不抢 delegate，
// 所以滚动手感、惯性与"点某一行跳播"全都不变。它在手势结束时就回来，不需要自己判静止。

/// 歌词滚动的手势观察者。
///
/// `began` / `changed` / `ended` 三段都报：`changed` 带**累计位移**（纵向），这样调用方可以只在
/// "真的划出距离"之后才动作 —— 轻点、误触、以及没有可滚内容的那一档都会开一条 pan。
final class LandscapeScrollWatcher: NSObject {

    var didBegin: (() -> Void)?
    var didMove: ((CGFloat) -> Void)?
    var didEnd: (() -> Void)?

    @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            didBegin?()
        case .changed:
            didMove?(gesture.translation(in: gesture.view).y)
        case .ended, .cancelled, .failed:
            didEnd?()
        default:
            break
        }
    }
}

// MARK: - 控件带
//
// 进度条 + 两端时间 + 上一首 / 播放 / 下一首。三个动作走 `WordByWordPlaybackControl`
// （原生那一页仍然连着真实播放管线，我们只是把它盖住），拖动走 `WordByWordSeeker`。
// 这一条**不带** `@available(iOS 26.0, *)`：它只用 SwiftUI 与现有动作层。

/// 横屏自建页的控制带。
struct LandscapePageControls: View {

    @ObservedObject var projection: AppleMusicLyricsPlaybackProjection
    /// 拖动进度条 → 跳到该位置（秒）。
    let onSeek: (TimeInterval) -> Void

    @State private var scrubbedFraction: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            progressBar
                .frame(height: 18)
            HStack(spacing: 0) {
                Text(Self.clock(projection.time))
                Spacer(minLength: 8)
                Text(remainingText)
            }
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundColor(Color.white.opacity(0.66))
            .padding(.top, 2)
            Spacer(minLength: 8)
            transportRow
        }
    }

    // MARK: 进度

    private var progressBar: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let fraction = displayedFraction
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.26))
                    .frame(height: 4)
                Capsule()
                    .fill(Color.white.opacity(0.95))
                    .frame(width: max(0, width * fraction), height: 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            // 轨道只有 4pt：命中区上下各撑 8pt，手指才按得准（不改外观）。
            .contentShape(Rectangle().inset(by: -8))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        scrubbedFraction = min(max(value.location.x / width, 0), 1)
                    }
                    .onEnded { _ in
                        if let fraction = scrubbedFraction, projection.duration > 0 {
                            onSeek(fraction * projection.duration)
                        }
                        scrubbedFraction = nil
                    }
            )
        }
    }

    private var displayedFraction: Double {
        if let scrubbedFraction { return scrubbedFraction }
        guard projection.duration > 0 else { return 0 }
        return min(max(projection.time / projection.duration, 0), 1)
    }

    private var remainingText: String {
        guard projection.duration > 0 else { return "" }
        return "-" + Self.clock(max(projection.duration - projection.time, 0))
    }

    // MARK: 三键

    private var transportRow: some View {
        HStack(spacing: 0) {
            glyph("backward.fill", size: 18, box: 44) {
                WordByWordPlaybackControl.skipToPrevious()
            }
            Spacer(minLength: 0)
            glyph(projection.isPlaying ? "pause.fill" : "play.fill", size: 26, box: 52) {
                WordByWordPlaybackControl.togglePlayPause()
            }
            Spacer(minLength: 0)
            glyph("forward.fill", size: 18, box: 44) {
                WordByWordPlaybackControl.skipToNext()
            }
        }
        .frame(height: 52)
    }

    private func glyph(
        _ systemName: String,
        size: CGFloat,
        box: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: box, height: box)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// `m:ss`，与 Spotify 原生一致（不补零到 `mm:ss`）。
    private static func clock(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }
}
