import Foundation
import SwiftUI
import UIKit
import Orion
import ObjectiveC.runtime

// 「歌词进播放器」——**按 spoti.pw v0.21.1 的形状重做**（2026-10-05 第二轮）。
//
// ## 上一版错在哪（真机日志 47 + 照片 46/48 的教训）
//
// 上一版是"在播放器中段**常驻**一块 414×240 的歌词层"：
//   · 它和**封面抢同一块地方** ⇒ 看着像"糊在上面的一层"；
//   · 它复用了内嵌档的**模糊封面背景**（`LyricsBackdropRepresentable`，写死 `isBackdropOpaque`）
//     ⇒ 在取色底上又叠一层模糊，更糊（那层今天已修，但形状本身还是错的）。
//
// ## pw 的形状（`Redesigned/Player/PlayerLyrics.x`，GPL-3.0 隔离副本，代码自己写）
//
// 它文件头原话：*"the footer's lyrics glyph is the only way to them: it **shrinks the cover into a
// thumbnail** at the top of the artwork band, **lifts the track's title up beside it**, and fades the
// lines into the room that frees between the title and the progress bar. Tapping it again puts the
// cover back."*
//
// 关键三条（照抄思路）：
//   1. **不是常驻**：点一下才来，再点还原；
//   2. **封面让位**：Spotify 那条封面 → `alpha 0`，我们自己画一张（同一张图，所以看不出换），
//      用 `transform` 缩到 **72pt 缩略图**；标题行用 `transform` 上移 + 右移贴到缩略图旁边
//      （**transform 扛得住 stack view 的重排**，改约束会被写回）；
//   3. **位置是量出来的**：缩略图贴"封面区"左上，歌词区 = 标题之下、进度条之上那块。
//
// 它的常量（原样抄，单位 pt）：缩略图 72 / 缩略图—标题 16 / 标题—控件 12 / 标题尾渐隐 20 /
// 缩略图离封面区顶 8 / 歌词离标题 20、离进度条 8 / 进场 0.3s（延迟 0.12）/ 退场 0.16 / 换歌宽限 3s。
//
// ## 与 pw 的两处不同（刻意的）
//
// | | pw | 我们 |
// |---|---|---|
// | 歌词绘制 | 它自己的 `SGRKaraokeView` | 复用 `AppleMusicLyricsOverlayView`（**透明档**，只有歌词） |
// | 封面缩略图 | 它自己再画一张封面并飞过去 | 一样（`Encode.ImageView` 的那张图） |
//
// 日志 tag：`[NPVLyrics]`。开关：扩展功能 → 听歌页 →「歌词进播放器」。

// MARK: - 宿主（只属于这一层，不抢全屏页/卡片那个单例）

@available(iOS 26.0, *)
@MainActor
private final class NowPlayingLyricsHost {

    private var hostingController: UIHostingController<AppleMusicLyricsOverlayView>?
    private var renderedVersion: Int = -1
    private var renderedTrackId: String = ""

    private let clock = AppleMusicLyricsClock()
    private let projection = AppleMusicLyricsPlaybackProjection {
        WordByWordPositionResolver.shared.currentPositionSeconds()
    }

    var isAttached: Bool { hostingController != nil }

    func isCurrent(version: Int, trackId: String) -> Bool {
        isAttached && renderedVersion == version && renderedTrackId == trackId
    }

    func mount(
        in container: UIView,
        lines: [LyricLine],
        version: Int,
        trackId: String,
        onSeek: ((TimeInterval) -> Void)?
    ) {
        let root = AppleMusicLyricsOverlayView(
            lines: lines,
            // `.card` 与"透明档"一起用：不画任何背景（播放器这一档底下是整页取色底）。
            backdropStyle: .card,
            solidBackdrop: false,
            showsProviderFooter: false,
            sideInset: NowPlayingLyricsPlate.stageSideInset,
            previewHeaderInset: 0,
            onSeek: onSeek,
            trackTitle: "",
            trackArtist: "",
            // ⚠️ **参数顺序必须与结构体里的属性声明顺序完全一致** —— SwiftUI 的逐成员初始化器
            // 是位置敏感的（2026-10-05 CI 抓到：我把 `transparentBackdrop` 写在 `previewHeaderInset`
            // 后面，编译器报 "argument labels do not match"）。
            transparentBackdrop: true,
            clock: clock,
            projection: projection
        )

        let hosting = UIHostingController(rootView: root)
        // ⚠️ 必须写全 `UIColor.clear`：这里没有上下文类型，`.clear` 推断不出来
        // （CI 报 "cannot infer contextual base in reference to member 'clear'"）。
        hosting.view.backgroundColor = UIColor.clear
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        hosting.view.accessibilityIdentifier = "eevee-npv-lyrics"

        container.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        hostingController?.view.removeFromSuperview()
        hostingController = hosting
        renderedVersion = version
        renderedTrackId = trackId
    }

    func updateLines(_ lines: [LyricLine], version: Int, trackId: String) {
        guard let hosting = hostingController else { return }
        hosting.rootView.lines = lines
        renderedVersion = version
        renderedTrackId = trackId
    }

    func tick(seconds: TimeInterval?) {
        guard isAttached else { return }
        if let seconds { clock.submit(seconds: seconds) }
        projection.refresh()
    }

    func detach() {
        guard let hosting = hostingController else { return }
        hosting.view.removeFromSuperview()
        hostingController = nil
        renderedVersion = -1
        renderedTrackId = ""
    }
}

// MARK: - 门面

/// 「歌词进播放器」。（整个 enum `@MainActor`：下面持有的是 UIKit/SwiftUI 视图，
/// 而所有入口都在主线程 —— 与上一版同样的理由，见 `NowPlayingControlsPlate` 的注释。）
@MainActor
enum NowPlayingLyricsPlate {

    static let logTag = "NPVLyrics"

    // pw 的常量（原样抄；单位 pt）。
    private static let thumbSide: CGFloat = 72
    private static let thumbGap: CGFloat = 16
    private static let titleGap: CGFloat = 12
    private static let titleFade: CGFloat = 20
    private static let thumbTop: CGFloat = 8
    private static let lyricsTop: CGFloat = 20
    private static let lyricsBottom: CGFloat = 8
    private static let enterScale: CGFloat = 0.96
    private static let enterDuration: TimeInterval = 0.3
    private static let enterDelay: TimeInterval = 0.12
    private static let exitDuration: TimeInterval = 0.16

    /// 歌词区左右内缩。
    static let stageSideInset: CGFloat = 20
    /// 太低就不进场（还没布局完 / 横屏）。
    private static let livingHeight: CGFloat = 200
    /// 走查上限（本仓库纪律）。
    private static let maxNodes = 800

    // 判据（全部来自真机树，日志 42/47）
    private static let listIdentifier = "scrolling_npv_collection_view_accessibility_identifier"
    private static let bottomStackIdentifier = "npv.bottomStackView"
    private static let coverImageIdentifier = "Encore.ImageView"
    private static let titleLabelIdentifier = "now-playing-title-label"
    private static let playButtonIdentifier = "SPTNowPlayingPlayButton"

    // 关联对象
    private static var containerKey: UInt8 = 0
    private static var coverKey: UInt8 = 0
    private static var toggleKey: UInt8 = 0
    private static var titleMaskKey: UInt8 = 0

    private static weak var lastPage: UIView?
    private static weak var lastContainer: UIView?
    private static weak var lastCover: UIImageView?
    private static weak var lastToggleZone: UIControl?
    private static weak var lastUnit: UIView?
    private static weak var lastTitleElement: UIView?

    private static var host: AnyObject?
    private static weak var hostPage: UIView?

    /// 歌词是否展开（pw 的 `sg_open`）。
    private static var isOpen = false
    private static var didLogInstall = false
    private static var lastSkipReason = ""

    static var isEnabled: Bool { UserDefaults.nowPlayingLyricsInPlayer }

    // MARK: - 对外入口

    static func apply(in pageView: UIView) {
        lastPage = pageView

        guard isEnabled else {
            closeEverything(reason: "switch off")
            return
        }
        guard pageView.bounds.width > 1, pageView.bounds.height > 1 else { return }

        // 挂那枚"歌词键"（在播放键上方）：**只有它被点才会展开** —— pw 的形状。
        ensureToggleZone(in: pageView)

        guard isOpen else { return }
        layoutAndMount(in: pageView)
    }

    /// 设置页切开关时叫一次。
    static func reapply() {
        guard let page = lastPage, page.window != nil else { return }
        apply(in: page)
    }

    /// 蹭 `DeclutterChrome` 的 0.3s 复查节拍：**展开期间**每拍把几何重新施加一遍
    /// （pw：`The geometry is re-applied on every layout pass of the units` —— 换歌会重建元素）。
    @discardableResult
    static func reconcile() -> Bool {
        guard isEnabled else { return false }
        guard let page = lastPage, page.window != nil else { return false }
        guard #available(iOS 26.0, *) else { return false }

        if isOpen {
            layoutAndMount(in: page)
            return true
        }
        // 关着的时候只保证那枚键还在（Spotify 换帧会重排 subviews）。
        ensureToggleZone(in: page)
        return false
    }

    /// 进/出页面：`viewWillDisappear` 里收掉（pw：关闭播放器前要撤销几何，否则迷你条对不上）。
    ///
    /// ⚠️ **必须无条件走 `closeEverything`**（哪怕看起来"没展开"）：标题行的位移是我们用
    /// `transform` 写上去的，**不撤销就会留在 Spotify 的元素上**（那一行此后永远偏上一截）。
    /// `closeEverything` 自己有空守卫，没展开时不会打日志。
    static func remove(reason: String) {
        closeEverything(reason: reason)
    }

    /// 那枚"歌词键"被点了。
    static func toggle() {
        guard let page = lastPage, page.window != nil else { return }

        if isOpen {
            closeEverything(reason: "tapped")
            return
        }
        guard canShow(for: page) else {
            noteSkip("这首歌没有可用的歌词")
            return
        }
        isOpen = true
        layoutAndMount(in: page)
    }

    // MARK: - 开关与几何

    /// 进场：把封面缩成缩略图、标题行上移贴边、歌词淡入到"标题之下、进度条之上"。
    private static func layoutAndMount(in page: UIView) {
        guard #available(iOS 26.0, *) else { return }
        guard let geometry = measure(in: page) else {
            noteSkip("量不到封面区/标题行（还没布局完？）")
            return
        }

        // ① 我们自己画的那张封面（同一张图，所以"换"看不出来）。
        let cover = ensureCover(in: page, geometry: geometry)

        // ② 标题行上移 + 右移（transform —— 改约束会被 stack view 布局写回）。
        applyTitleTransform(geometry: geometry, page: page)

        // ③ 歌词区：标题之下、进度条之上。
        let frame = geometry.stage
        guard frame.height > livingHeight / 2 else {
            noteSkip("标题与进度条之间没有位置（\(Int(frame.height))pt）")
            return
        }

        let container = ensureContainer(in: page, frame: frame)
        applyEdgeFade(to: container)

        guard let lines = currentLines(), let trackId = currentTrackId() else { return }

        if let host = currentHost(for: page) {
            let version = currentLyricsVersion
            if host.isCurrent(version: version, trackId: trackId) {
                // 最新 → 这一拍只驱动时间轴。
            } else if host.isAttached {
                host.updateLines(lines, version: version, trackId: trackId)
            } else {
                host.mount(
                    in: container,
                    lines: lines,
                    version: version,
                    trackId: trackId,
                    onSeek: { seconds in
                        WordByWordSeeker.seek(toMs: Int((seconds * 1000).rounded()))
                    }
                )
            }
            host.tick(seconds: WordByWordPositionResolver.shared.currentPositionSeconds())
        }

        if !didLogInstall {
            didLogInstall = true
            writeDebugLog(
                "[\(logTag)] 展开 — 缩略图 \(Int(geometry.thumb.width))pt、"
                    + "歌词区 \(frameText(frame))、封面从 \(frameText(geometry.cover)) 缩过来"
            )
        }
        _ = cover
    }

    /// 全部还原：标题与封面的 transform/alpha 写回、我们的层拿走。
    private static func closeEverything(reason: String) {
        guard isOpen || lastContainer != nil || lastCover != nil else { return }

        isOpen = false

        if let cover = lastCover {
            cover.removeFromSuperview()
            lastCover = nil
        }
        // Spotify 那条封面写回可见。
        restoreSpotifyCover()
        // 标题行的位移撤销。
        lastUnit?.transform = .identity
        lastTitleElement?.transform = .identity
        clearTitleMask()
        lastTitleElement = nil

        if #available(iOS 26.0, *) {
            (host as? NowPlayingLyricsHost)?.detach()
        }
        lastContainer?.removeFromSuperview()
        lastContainer = nil
        didLogInstall = false
        writeDebugLog("[\(logTag)] 收起（reason=\(reason)）")
    }

    // MARK: - 量几何（pw 的 `layoutIn`）

    private struct Geometry {
        var cover: CGRect       // Spotify 现在把封面画在哪
        var thumb: CGRect       // 缩略图该在哪
        var stage: CGRect       // 歌词区
        var lift: CGFloat       // 标题行上移多少（负数）
        var shift: CGFloat      // 标题右移多少
        var titleRow: UIView?   // 标题所在的那一行（要位移的）
        var titleElement: UIView?
    }

    private static func measure(in page: UIView) -> Geometry? {
        guard page.bounds.height >= livingHeight else { return nil }
        guard let list = findByIdentifier(listIdentifier, in: page) else { return nil }

        // 封面：列表子树里第一个**看得见**的 `Encore.ImageView`，且宽度像封面（>=200）。
        guard let coverView = visibleCover(in: list) else { return nil }
        let cover = coverView.convert(coverView.bounds, to: page)

        // 标题行：`now-playing-title-label` 所在的那个 element 视图 + 它的父行。
        let titleLabel = findByIdentifier(titleLabelIdentifier, in: list)
        let titleElement = titleLabel?.superview
        let titleRow = titleElement?.superview

        // 缩略图：贴"封面区"左上 —— 我们用封面自己的左上 + `thumbTop`（pw 用 `SGRPlayerArtworkAreaIn`，
        // 我们量不到那个 band，就用封面的顶；差别只是几 pt，且换歌会重算）。
        let leading = titleElement.map { untransformed($0, in: page).minX } ?? (cover.minX + 20)
        let thumb = CGRect(
            x: leading,
            y: cover.minY + thumbTop,
            width: thumbSide,
            height: thumbSide
        )

        // 标题行：缩略图右侧垂直居中（找不到标题就贴在缩略图下面）。
        let rowFrame = titleRow.map { untransformed($0, in: page) }
        let top = rowFrame.map { thumb.midY - $0.height / 2 } ?? (thumb.maxY + 12)
        let lift = top - (rowFrame?.minY ?? top)
        let shift = rowFrame == nil ? 0 : thumbSide + thumbGap

        // 歌词区：缩略图/标题之下 → 进度条之上。
        let barTop = bottomStackTop(in: list, page: page) ?? (page.bounds.height - 240)
        let stageTop = max(thumb.maxY, top + (rowFrame?.height ?? 0)) + lyricsTop
        let stage = CGRect(
            x: stageSideInset,
            y: stageTop,
            width: page.bounds.width - stageSideInset * 2,
            height: barTop - lyricsBottom - stageTop
        )

        guard stage.height > livingHeight / 2, lift < 0 else { return nil }

        return Geometry(
            cover: cover,
            thumb: thumb,
            stage: stage,
            lift: lift,
            shift: shift,
            titleRow: titleRow,
            titleElement: titleElement
        )
    }

    /// 列表里那个"看得见的封面"（队列是一格一张封面，离屏的是 hidden —— pw 同判据）。
    private static func visibleCover(in list: UIView) -> UIView? {
        var visited = 0
        var queue: [UIView] = [list]

        while !queue.isEmpty, visited < maxNodes {
            let view = queue.removeFirst()
            visited += 1

            if view.accessibilityIdentifier == coverImageIdentifier,
               !view.isHidden, view.alpha > 0.01, view.window != nil,
               view.bounds.width >= 200 {
                return view
            }
            // hidden 的子树不往下走（离屏的那些封面一格一个，不必要）。
            if view.isHidden { continue }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// 底部那一坨的顶边（页面坐标系）——与上一版同一个判据（列表 + `layer.position`）。
    private static func bottomStackTop(in list: UIView, page: UIView) -> CGFloat? {
        guard let stack = findByIdentifier(bottomStackIdentifier, in: list) else { return nil }
        let listPosition = list.layer.position
        let listOriginY = listPosition.y - list.bounds.height / 2
        return listOriginY + (stack.layer.position.y - stack.bounds.height / 2)
    }

    /// 去掉我们自己写上去的位移之后的 frame（pw 的 `untransformed`）。
    private static func untransformed(_ view: UIView, in host: UIView) -> CGRect {
        let frame = view.convert(view.bounds, to: host)
        let t = view.transform
        return frame.offsetBy(dx: -t.tx, dy: -t.ty)
    }

    // MARK: - 封面与标题

    /// 我们自己画的那张缩略图封面（同图 ⇒ 看不出"换"），并**把 Spotify 那条藏起来**。
    private static func ensureCover(in page: UIView, geometry: Geometry) -> UIImageView? {
        // 图片从 Spotify 那个 `Encore.ImageView` 里取（它下面挂着真正的 UIImageView）。
        guard let source = findByIdentifier(coverImageIdentifier, in: page),
              let image = firstImage(in: source) else { return nil }

        let cover: UIImageView
        if let existing = lastCover {
            cover = existing
        } else {
            cover = UIImageView()
            cover.contentMode = .scaleAspectFill
            cover.clipsToBounds = true
            cover.layer.cornerCurve = .continuous
            cover.layer.cornerRadius = 10
            cover.isUserInteractionEnabled = false
            cover.accessibilityIdentifier = "eevee-npv-cover-thumb"
            page.addSubview(cover)
            lastCover = cover
        }
        cover.image = image
        if cover.superview !== page { page.addSubview(cover) }
        page.bringSubviewToFront(cover)

        // 进场动画：从封面的位置缩到缩略图（pw 是"飞过去"，我们做帧动画，效果同源）。
        let target = geometry.thumb
        if cover.frame != target {
            let first = cover.frame == .zero
            if first {
                cover.frame = geometry.cover
                cover.layer.cornerRadius = 10
                UIView.animate(withDuration: enterDuration, delay: enterDelay, options: [.curveEaseOut]) {
                    cover.frame = target
                }
            } else {
                UIView.animate(withDuration: exitDuration) { cover.frame = target }
            }
        }

        // Spotify 那条封面**透明掉**（不是 hidden：Encore 的布局会因 hidden 重排）。
        hideSpotifyCover(in: page)
        return cover
    }

    private static var hiddenCoverKey: UInt8 = 0

    private static func hideSpotifyCover(in page: UIView) {
        guard let source = findByIdentifier(coverImageIdentifier, in: page) else { return }
        var hidden = (objc_getAssociatedObject(page, &hiddenCoverKey) as? [UIView]) ?? []
        if !hidden.contains(where: { $0 === source }) { hidden.append(source) }
        source.alpha = 0
        // 它下面那层真正画图的 `UIImageView` 也一起（`Encode.ImageView` 只是壳）。
        for sub in source.subviews where sub.alpha > 0.01 && sub.bounds.width >= 200 {
            if !hidden.contains(where: { $0 === sub }) { hidden.append(sub) }
            sub.alpha = 0
        }
        objc_setAssociatedObject(page, &hiddenCoverKey, hidden, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private static func restoreSpotifyCover() {
        guard let page = lastPage else { return }
        let hidden = (objc_getAssociatedObject(page, &hiddenCoverKey) as? [UIView]) ?? []
        for view in hidden { view.alpha = 1 }
        objc_setAssociatedObject(page, &hiddenCoverKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// 在壳里找真正的 `UIImageView`（`Encore.ImageView` 自己不画图）。
    private static func firstImage(in view: UIView) -> UIImage? {
        if let imageView = view as? UIImageView, let image = imageView.image { return image }
        for sub in view.subviews {
            if let image = firstImage(in: sub) { return image }
        }
        return nil
    }

    /// 标题行上移 + 右移 + 尾部渐隐（pw 的 `placeTitleRow` / `clipTitle`）。
    private static func applyTitleTransform(geometry: Geometry, page: UIView) {
        guard let row = geometry.titleRow else { return }
        lastUnit = row

        let rise = CGAffineTransform(translationX: 0, y: geometry.lift.rounded())
        if row.transform != rise { row.transform = rise }

        if let title = geometry.titleElement {
            lastTitleElement = title
            let slide = CGAffineTransform(translationX: geometry.shift.rounded(), y: 0)
            if title.transform != slide { title.transform = slide }
            // 长标题向右会撞到"加号"：**用 mask 渐隐**，不改宽度（Spotify 的 marquee 会把宽度写回）。
            applyTitleMask(to: title, page: page)
        }
    }

    /// 渐隐宽度 = 标题可用宽度（到右边那排控件为止）—— 量不到就整行不遮。
    private static func applyTitleMask(to title: UIView, page: UIView) {
        let bounds = title.bounds
        guard bounds.width > 1, bounds.height > 1 else { return }

        let limit = trailingControlX(in: title, page: page)
        let room = limit.map { $0 - titleGap } ?? bounds.width
        let width = min(bounds.width, max(0, room))
        guard width < bounds.width - 0.5 else {
            title.layer.mask = nil
            return
        }

        let mask: CAGradientLayer
        if let existing = title.layer.mask as? CAGradientLayer {
            mask = existing
        } else {
            mask = CAGradientLayer()
            mask.colors = [UIColor.white.cgColor, UIColor.white.cgColor, UIColor.clear.cgColor]
            mask.startPoint = CGPoint(x: 0, y: 0.5)
            mask.endPoint = CGPoint(x: 1, y: 0.5)
            title.layer.mask = mask
        }
        let fade = min(titleFade, width)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        mask.locations = [0, NSNumber(value: width > 0 ? (width - fade) / width : 0), 1]
        CATransaction.commit()
    }

    private static func clearTitleMask() {
        lastTitleElement?.layer.mask = nil
    }

    /// 标题右边那排控件的起点（找不到就不遮）。
    private static func trailingControlX(in title: UIView, page: UIView) -> CGFloat? {
        guard let row = title.superview else { return nil }
        let titleLeft = untransformed(title, in: page).minX
        var limit: CGFloat?

        for sub in row.subviews {
            if sub === title || sub.isHidden || sub.alpha < 0.01 || sub.bounds.width < 1 { continue }
            let x = untransformed(sub, in: page).minX
            if x > titleLeft, limit == nil || x < limit! { limit = x }
        }
        return limit
    }

    // MARK: - 歌词键（pw 把 glyph 放在 footer；我们放在播放键上方 —— 那里既稳又不挡进度条）

    private static func ensureToggleZone(in page: UIView) {
        // 位置：播放键上方 40pt，宽 120、高 44（一个看得见提示都没有的"热区"）。
        guard let play = findByIdentifier(playButtonIdentifier, in: page) else {
            noteSkip("找不到播放键，歌词键没处放")
            return
        }
        let playFrame = play.convert(play.bounds, to: page)
        let wanted = CGRect(
            x: playFrame.midX - 60,
            y: playFrame.minY - 44,
            width: 120,
            height: 44
        )

        if let zone = lastToggleZone {
            if zone.frame != wanted { zone.frame = wanted }
            if zone.superview !== page { page.addSubview(zone) }
            page.bringSubviewToFront(zone)
            return
        }

        let zone = UIControl(frame: wanted)
        zone.backgroundColor = .clear
        zone.accessibilityIdentifier = "eevee-npv-lyrics-toggle"
        zone.accessibilityLabel = "歌词"
        zone.addTarget(NowPlayingLyricsToggleTarget.shared, action: #selector(NowPlayingLyricsToggleTarget.tapped), for: .touchUpInside)
        page.addSubview(zone)
        page.bringSubviewToFront(zone)
        lastToggleZone = zone
        writeDebugLog("[\(logTag)] 歌词键已就位 \(frameText(wanted))（点它展开/收起）")
    }

    // MARK: - 我们自己的容器

    private static func ensureContainer(in page: UIView, frame: CGRect) -> UIView {
        if let existing = objc_getAssociatedObject(page, &containerKey) as? UIView {
            if existing.superview !== page { page.addSubview(existing) }
            if existing.frame != frame { existing.frame = frame }
            // 歌词要能点（点行跳转），但**容器之外不吃触摸**；容器本身只占歌词区。
            existing.isUserInteractionEnabled = true
            page.bringSubviewToFront(existing)
            lastContainer = existing
            return existing
        }

        let container = UIView(frame: frame)
        container.backgroundColor = .clear
        container.clipsToBounds = true
        container.accessibilityIdentifier = "eevee-npv-lyrics-container"
        container.isAccessibilityElement = false
        page.addSubview(container)
        page.bringSubviewToFront(container)
        objc_setAssociatedObject(page, &containerKey, container, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        lastContainer = container
        return container
    }

    private static func applyEdgeFade(to container: UIView) {
        let mask: CAGradientLayer
        if let existing = container.layer.mask as? CAGradientLayer {
            mask = existing
        } else {
            mask = CAGradientLayer()
            mask.colors = [
                UIColor.clear.cgColor,
                UIColor.white.cgColor,
                UIColor.white.cgColor,
                UIColor.clear.cgColor,
            ]
            mask.locations = NowPlayingMetrics.lyricFadeStops
            mask.startPoint = CGPoint(x: 0.5, y: 0)
            mask.endPoint = CGPoint(x: 0.5, y: 1)
            container.layer.mask = mask
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = container.bounds
        CATransaction.commit()
    }

    // MARK: - 宿主与数据

    @available(iOS 26.0, *)
    private static func currentHost(for page: UIView) -> NowPlayingLyricsHost? {
        if let existing = host as? NowPlayingLyricsHost, hostPage === page { return existing }
        (host as? NowPlayingLyricsHost)?.detach()
        let fresh = NowPlayingLyricsHost()
        host = fresh
        hostPage = page
        return fresh
    }

    /// 这一首有没有能画的东西（行级即可 —— 与上一版放宽后的门禁一致）。
    private static func canShow(for page: UIView) -> Bool {
        if #available(iOS 26.0, *) {} else { return false }
        guard NgzhwmSettingsViewModel.isBetterWordByWordLyricsEnabled else {
            noteSkip("「更好的逐词歌词」是关的")
            return false
        }
        guard hasUsableWordLevelData(currentLyricsDto) || hasUsableLineLevelData(currentLyricsDto) else {
            noteSkip("这首歌没有可用的歌词")
            return false
        }
        return currentLines() != nil
    }

    private static func currentLines() -> [LyricLine]? {
        let lines = (currentLyricsDto?.toAppleMusicLyricLines()) ?? []
        return lines.isEmpty ? nil : lines
    }

    private static func currentTrackId() -> String? {
        let id = (statefulPlayer?.currentTrack() ?? nowPlayingScrollViewController?.loadedTrack)?
            .trackIdentifier ?? ""
        return id.isEmpty ? nil : id
    }

    // MARK: - 日志与小工具

    private static func noteSkip(_ reason: String) {
        guard lastSkipReason != reason else { return }
        lastSkipReason = reason
        writeDebugLog("[\(logTag)] 不展开（\(reason)）")
    }

    private static func frameText(_ frame: CGRect) -> String {
        "\(Int(frame.origin.x)),\(Int(frame.origin.y)),\(Int(frame.width)),\(Int(frame.height))"
    }

    private static func findByIdentifier(_ identifier: String, in root: UIView) -> UIView? {
        var visited = 0
        var queue: [UIView] = [root]

        while !queue.isEmpty, visited < maxNodes {
            let view = queue.removeFirst()
            visited += 1
            if view.accessibilityIdentifier == identifier { return view }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }
}

/// 歌词键的手势目标（`UIControl` 的 target 必须是 ObjC 对象）。
final class NowPlayingLyricsToggleTarget: NSObject {

    static let shared = NowPlayingLyricsToggleTarget()

    @objc func tapped() {
        onMainThreadSync { NowPlayingLyricsPlate.toggle() }
    }
}
