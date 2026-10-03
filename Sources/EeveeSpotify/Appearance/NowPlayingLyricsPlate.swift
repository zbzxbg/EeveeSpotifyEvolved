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
// 缩略图离封面区顶 8 / 歌词离标题 20、离进度条 8 / 换歌宽限 3s。
// ⚠️ 上一版这里还写着"进场 0.3s（延迟 0.12）/ 退场 0.16"—— 那三个数在 2026-10-05 被
// pw 的 `SGRMotionLayout`（0.45s 弹簧、阻尼 1）取代，见下一节。
//
// ## ★ 2026-10-05：「封面往左上变小跑」这个动画到底怎么做（照 pw `PlayerLyrics.x` 重写）
//
// 上一版是 **`UIView.animate` 动 `frame`** —— 那是**错的形状**，理由两条：
//   1. `layoutAndMount` **每 0.3s 重跑一次**（`DeclutterChrome` 的复查节拍），
//      每次都要重写封面的布局；动画画在 `frame` 上时，那一拍就会**打断/拽回**动画；
//   2. 本仓库纪律：**`frame` 在 transform 非恒等时不可信**。
//
// pw 的形状（`place()` / `thumbTransform()` / `thumbRadius()` / `SGRMotionLayout`）：
//
// | 环节 | 做法 |
// |---|---|
// | 布局 | 容器**永远**按"Spotify 封面那个大小与位置"布局，用 **`bounds` + `center`**（不是 `frame`）—— pw 原话：*"moved by its transform alone, so a pass that runs while it is up **leaves it exactly where the eye has it**"* |
// | 位移 | **只写在容器的 `transform` 上**，且是 `CGAffineTransformConcat(Scale, Move)` = **先缩放、后平移**（关于自己的中心） |
// | 圆角 | ★ **缩放会把圆角一起缩放** ⇒ 想让缩略图"看起来"是 8pt，模型值要写 **8 / scale**（pw：*"divided by the shrink"*） |
// | 阴影 | 挂在**容器**上（容器不裁剪）⇒ 跟着 transform 一起走，*"instead of a shadow redrawn on every frame"* |
// | 动画 | pw 的 `SGRMotionLayout`：`0.45s + usingSpringWithDamping 1 + velocity 0`（**临界阻尼、不回弹**），options **`AllowUserInteraction` + `BeginFromCurrentState`**（后者是**连点两次不跳**的关键） |
// | 无障碍 | **Reduce Motion 打开时整段不做动画**（pw 也是 `performWithoutAnimation`） |
// | 换图那一刻 | *"Spotify's cover goes **the moment** the redesign's own takes its place"* —— 早一步露空档、晚一步两张同屏（一大一小） |
// | 拿不到图 | *"the cover stays and the lyrics wait"* ⇒ **不展开**（我们 `layoutAndMount` 返回 false 就是这条） |
//
// 收起的收尾（撤掉我们那张 + 把 Spotify 那条写回）**必须挂在动画 completion 上**，
// 而且要带一个令牌（`coverGeneration`）：动画没走完就又被点开时，这一次收尾要作废。
// ⚠️ `completion` 在"已经在对的位置"与"Reduce Motion"两条路上**也必须被调用**，
// 否则封面撤不掉、Spotify 那条永远停在 alpha 0。
//
// ## 与 pw 的两处不同（刻意的）
//
// | | pw | 我们 |
// |---|---|---|
// | 歌词绘制 | 它自己的 `SGRKaraokeView` | 复用 `AppleMusicLyricsOverlayView`（**透明档**，只有歌词） |
// | 封面缩略图 | 它自己再画一张封面并飞过去 | 一样（`Encode.ImageView` 的那张图） |
//
// 日志 tag：`[NPVLyrics]`。开关：扩展功能 → 听歌页 →「歌词进播放器」。
//
// ## ★ 2026-10-03 修（日志 48 判读）：那枚"歌词键"是**看不见的**，所以从来没人点到过
//
// **日志 48 的判决**（13008 行，01:47:41–01:49:03）：`[NPVLyrics]` 只有**两行** ——
// `不展开（找不到播放键…）`（第一次布局太早）与 `歌词键已就位 147,673,120,44`。
// **一次 `展开` 都没有**，连一条 `不展开（这首歌没有可用的歌词）` 都没有
// ⇒ `toggle()` 根本没被调用过 ⇒ 那枚键**从来没被点到**。
//
// **为什么**：上一版把它做成 `UIControl` + `.clear` 背景 + 无任何内容 —— 一块 120×44 的
// **完全透明热区**，位于播放键正上方；而它顺便还压在**进度条**（`SPTNowPlayingSliderV2`）
// 与**播放键上沿**上，会抢走拖动手势。用户找不到它，只能去点旁边那枚看得见的暂停键
//（顺手报了"点暂停键会闪烁"，那是另一处缺陷，见 `NowPlayingControlsPlate` 的文件头）。
//
// **修法**（用户 2026-10-03 拍板："做成看得见的按钮，仍然点了才展开"）：
//   1. **看得见**：44pt 圆角键 + 半透明白底 + `quote.bubble.fill` 字形（展开时换成 `chevron.down`）；
//   2. **让开**：挪到 `npv.bottomStackView` 的**最后一行（footer）**、水平居中 —— 那是 pw
//      放歌词字形的地方，也与原生控件（Connect / 分享 / 队列）不重叠；找不到 footer 才退回
//      "贴那一坨上面"（展开时靠右）再退回"由播放键反推同一条空带"。
//      ⚠️ **只借 footer 的 frame，键挂在 `page` 上** —— 塞进 Spotify 的 stack 会让它变成
//      `stack.subviews.last`，把"认 footer"这件事本身弄坏（复核时点出来的）。
//   3. **没词变灰**（pw：*"greyed out when the track has none"*）：`alpha = 0.35`，
//      点下去仍然会打一行说明为什么没反应（不留"按了没反应"的入口）。
//
// ⚠️ **顺序**：`apply` / `reconcile` 里必须先铺歌词（封面 / 标题 / 容器都会 `bringSubviewToFront`）
// **再**摆那枚键 —— 后写的赢，否则键会被我们自己的容器压住。
// ⚠️ 关掉开关 / 离开页面时那枚键**也要拿走**（上一版 `closeEverything` 的守卫会早退 ⇒ 键留在屏上）。

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
    /// 歌词区进场时从 0.96 放大到 1（pw 的 `kLyricsEnterScale`）。
    /// ⚠️ **本轮没做**：那要把容器也改成"只动 transform + bounds/center"（同封面那一套），
    /// 否则 `ensureContainer` 每拍写 `frame` 会和 transform 打架。留到下一轮。
    private static let enterScale: CGFloat = 0.96

    // MARK: 封面那两个"画出来"的圆角 + 移动用的弹簧（pw `SGRTokens`）

    /// 全尺寸封面时的圆角（pw：`SGRRadiusArtwork = 12`）。
    private static let coverFullRadius: CGFloat = 12
    /// ★ **缩略图在 72pt 下"看起来"的圆角**（pw：`SGRRadiusCover = 8`）。
    /// 注意：`transform` 的缩放会把圆角**一起缩放**，所以模型值要**除以 scale**
    /// —— pw 原话：*"a radius under a scale is drawn scaled, so the thumbnail asks for the radius
    /// it wants **divided by the shrink**"*。
    private static let thumbDrawnRadius: CGFloat = 8
    /// 移动/缩放用的时长与阻尼：pw 的 `SGRMotionLayout` 是
    /// `animateWithDuration:0.45 usingSpringWithDamping:1 initialSpringVelocity:0`
    /// —— **阻尼 1 = 临界阻尼、不回弹**（"a spring with no overshoot"）。
    private static let moveDuration: TimeInterval = 0.45

    /// 歌词区左右内缩。
    static let stageSideInset: CGFloat = 20
    /// 太低就不进场（还没布局完 / 横屏）。
    private static let livingHeight: CGFloat = 200
    /// 走查上限（本仓库纪律）。
    private static let maxNodes = 800

    // MARK: 「歌词键」那一枚（2026-10-03 从"隐形热区"改成"看得见的按钮"）

    /// 圆形键的边长（与 Spotify 自己的图标键同尺）。
    private static let toggleSide: CGFloat = 44
    /// 与"底部那一坨"的间距。
    private static let toggleGap: CGFloat = 6
    /// 播放键顶边到"底部那一坨"顶边的距离（真机树：控件行顶 701 − 那一坨顶 558 = 143，
    /// 而 64pt 的播放键在该行内居中 ⇒ 播放键顶 713，713 − 558 = **155**）。
    /// 兜底落点靠它把键放回"封面与那一坨之间那条空带"，而不是压在标题/进度条上。
    private static let playToBandTop: CGFloat = 155
    /// 这一首没歌词时那枚键的透明度（pw：没词变灰）。
    private static let toggleDisabledAlpha: CGFloat = 0.35
    /// 键上那个字形记的符号名（用来判断"要不要换图"）。
    private static var toggleSymbolKey: UInt8 = 0

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
    /// 我们自己那份封面：**外层容器**（承载 transform 与阴影）+ **里面的 imageView**（承载圆角与裁剪）。
    ///
    /// ★ 分两层是照 pw 的 `PlayerLyrics.x`：容器**永远按"Spotify 封面那个大小与位置"布局**
    /// （`bounds` + `center`），"缩小 + 往左上挪"**只写在容器的 `transform` 上**。
    /// 这样 `layoutAndMount` 每 0.3s 重排一次也**不会打断动画**；阴影与圆角跟着 transform 一起走，
    /// 不需要每帧重画。
    private static weak var coverHost: UIView?
    private static weak var coverImage: UIImageView?
    /// 收/开交叉时的令牌：**关闭动画走完才做收尾**（撤封面、把 Spotify 那条写回），
    /// 免得把紧接着又展开的那一次踢掉。
    private static var coverGeneration = 0
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
            // 关开关：**不动画**（用户多半在设置页，而且页面上可能正有转场）。
            closeEverything(reason: "switch off", animated: false)
            removeToggle()
            return
        }
        guard pageView.bounds.width > 1, pageView.bounds.height > 1 else { return }

        // ⚠️ 顺序要紧：先铺歌词（封面 / 标题 / 容器都会 `bringSubviewToFront`），
        // **再**摆那枚键 —— 后写的赢，否则键会被我们自己的容器压住。
        // 铺不上（拿不到封面图等）就**不认"已展开"**，别留半成品。
        if isOpen, !layoutAndMount(in: pageView) { isOpen = false }
        ensureToggleZone(in: pageView)
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
            // 可能因为"封面还没布局好"铺不上 —— 那时退回去（下一拍还会再试，直到成功）。
            if !layoutAndMount(in: page) { isOpen = false }
            ensureToggleZone(in: page)
            return isOpen
        }
        // 关着的时候只保证那枚键还在、还画得对（Spotify 换帧会重排 subviews），
        // 并**顺手把这一首的封面认下来**：点的时候就不用"现抓"，而现抓经常抓不到
        // （树里那张图可能是 `UIImageView(alpha=0.00)`）。幂等 —— 这一首已经认下就只查一次字典。
        if !isOpen { rememberArtworkIfNeeded(in: page) }
        ensureToggleZone(in: page)
        return false
    }

    /// 进/出页面：`viewWillDisappear` 里收掉（pw：关闭播放器前要撤销几何，否则迷你条对不上）。
    ///
    /// ⚠️ **必须无条件走 `closeEverything`**（哪怕看起来"没展开"）：标题行的位移是我们用
    /// `transform` 写上去的，**不撤销就会留在 Spotify 的元素上**（那一行此后永远偏上一截）。
    /// `closeEverything` 自己有空守卫，没展开时不会打日志。
    /// 那枚键也要一起拿走 —— 否则下次进来会叠一枚在上面。
    static func remove(reason: String) {
        // 页面要走了 ⇒ **不动画**：拖着 0.45s 才把 Spotify 那条封面写回去，会在转场里露一个空档。
        closeEverything(reason: reason, animated: false)
        removeToggle()
    }

    /// 那枚"歌词键"被点了。
    static func toggle() {
        guard let page = lastPage, page.window != nil else { return }

        if isOpen {
            // 用户自己点收起 ⇒ **放动画**（封面"飞回原位"）。
            closeEverything(reason: "tapped", animated: true)
            // 图标当场换回"歌词"，不等 0.5s 的复查节拍。
            ensureToggleZone(in: page)
            return
        }
        guard canShow(for: page) else {
            noteSkip("这首歌没有可用的歌词")
            ensureToggleZone(in: page)
            return
        }
        isOpen = true
        // 铺不上就当场认输（`noteSkip` 已经写清了原因），别把开关停在"展开但什么都没变"上。
        if !layoutAndMount(in: page) { isOpen = false }
        // ⚠️ 必须在铺完之后再摆一次：容器会 `bringSubviewToFront`，键会被压到它下面。
        ensureToggleZone(in: page)
    }

    // MARK: - 开关与几何

    /// 进场：把封面缩成缩略图、标题行上移贴边、歌词淡入到"标题之下、进度条之上"。
    ///
    /// **返回这一拍到底铺上了没有**。铺不上就**不认"已展开"**（`isOpen` 由调用方回退）——
    /// 否则会出现照片 51 那种"标题已经上移、歌词已经画出来、而原生封面还整张露着"的半成品。
    @discardableResult
    private static func layoutAndMount(in page: UIView) -> Bool {
        guard #available(iOS 26.0, *) else { return false }
        guard let geometry = measure(in: page) else {
            noteSkip("量不到封面区/标题行（还没布局完？）")
            return false
        }

        // ① 我们自己那份封面（同一张图，所以"换"看不出来）+ **把它动画到缩略图**。
        //    ⚠️ **它必须成功**：失败时原生封面就还露着，而下面两步会照样跑
        //    ⇒ 歌词与上移后的标题会被画在封面图上（照片 51 就是现场）。所以这里直接不展开。
        //    pw 也是这个取舍：*"without a picture there would be a hole where the cover was,
        //    so the cover stays and the lyrics wait."*
        guard let coverHostView = ensureCover(in: page, geometry: geometry),
              let coverImageView = coverImage else {
            noteSkip("拿不到那张封面（缩略图与"藏起原生封面"都做不了）—— 不展开")
            return false
        }
        applyCoverState(open: true, host: coverHostView, imageView: coverImageView, geometry: geometry)

        // ② 标题行上移 + 右移（transform —— 改约束会被 stack view 布局写回）。
        applyTitleTransform(geometry: geometry, page: page)

        // ③ 歌词区：标题之下、进度条之上。
        let frame = geometry.stage
        guard frame.height > livingHeight / 2 else {
            noteSkip("标题与进度条之间没有位置（\(Int(frame.height))pt）")
            return false
        }

        let container = ensureContainer(in: page, frame: frame)
        applyEdgeFade(to: container)

        guard let lines = currentLines(), let trackId = currentTrackId() else { return false }

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
        return true
    }

    /// 全部还原：封面动画回原位后拿走、标题位移撤销、我们自己的层拿走。
    ///
    /// - Parameter animated: 收起封面时**要不要放动画**。
    ///   `toggle()`（用户再点一下）= `true`，会看到封面"飞回原位"；
    ///   **切开关 / 页面消失 = `false`** —— 那两种情况下页面可能马上就不在了，
    ///   拖着 0.45s 的动画才把 Spotify 那条封面写回去，会在转场里露一个"没有封面"的帧。
    private static func closeEverything(reason: String, animated: Bool) {
        guard isOpen || lastContainer != nil || coverHost != nil else { return }

        isOpen = false

        // 封面：先让它**动回原位**（同图，所以这就是"飞回去"），动画走完再撤 + 把 Spotify 那条写回。
        if let host = coverHost, let imageView = coverImage {
            coverGeneration += 1
            let token = coverGeneration

            let cleanup = {
                // ⚠️ 收尾里要碰 `@MainActor` 的静态成员 ⇒ 走 `onMainThreadSync`（仓库成文规矩）。
                onMainThreadSync {
                    // 这中间用户又点开了 ⇒ 这一次的收尾作废（别把刚摆好的封面撤掉）。
                    guard token == coverGeneration else { return }
                    host.removeFromSuperview()
                    coverHost = nil
                    coverImage = nil
                    restoreSpotifyCover()
                }
            }

            if animated {
                applyCoverState(
                    open: false,
                    host: host,
                    imageView: imageView,
                    geometry: nil,
                    completion: cleanup
                )
            } else {
                host.layer.removeAllAnimations()
                host.transform = .identity
                imageView.layer.cornerRadius = coverFullRadius
                cleanup()
            }
        } else {
            restoreSpotifyCover()
        }

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

    /// 我们自己那份封面：**建/复用容器 + 里面的 imageView**，并**把 Spotify 那条藏起来**。
    ///
    /// ## ★ 动画的关键：容器永远按"Spotify 封面那个大小与位置"布局，位移只写在 `transform` 上
    ///
    /// 这是照 pw `PlayerLyrics.x` 的 `place()` 与 `thumbTransform()` 的做法（GPL-3.0）：
    ///
    /// > *"The thumbnail is laid out **at the size and place Spotify draws its cover at** and moved by
    /// > its transform alone, so a pass that runs while it is up **leaves it exactly where the eye has
    /// > it** … **Bounds and a centre, not a frame**, since both views can be under a transform."*
    ///
    /// 为什么不能像上一版那样动画 `frame`（上一版就是这么写的、而且**一次都没跑起来**）：
    ///   · `layoutAndMount` **每 0.3s 会重跑一次**（`DeclutterChrome` 的复查节拍），它要重写封面布局
    ///     —— 动画画在 `frame` 上时那一拍就会**打断/拽回**动画；画在 `transform` 上则改
    ///     `bounds`/`center` **完全不打扰动画**；
    ///   · 本仓库纪律：**`frame` 在 transform 非恒等时不可信** ⇒ 一律 `bounds` + `center`。
    ///
    /// ## 阴影放在**容器**上
    ///
    /// pw 原话：*"the **shadow and the corners travel with it** that way, instead of a shadow redrawn
    /// on every frame."* —— 容器带着 transform 走，阴影与圆角自动跟着，不用每帧重画。
    /// （所以：容器**不裁剪**（否则阴影没了），裁剪与圆角放在里面那层 imageView 上。）
    private static func ensureCover(in page: UIView, geometry: Geometry) -> UIView? {
        // 图片从 Spotify 那个 `Encore.ImageView` 里取（它下面挂着真正的 UIImageView）。
        //
        // ⚠️ **判据必须和 `measure()` 用的是同一个**（`visibleCover`）。上一版这里用的是
        // `findByIdentifier(coverImageIdentifier, …)` —— 那是**有界 BFS 的第一个匹配**，
        // 而页面上 `Encore.ImageView` 有一堆（48×48 的图标、64×64 的…），取到的往往**不是那张封面**
        // ⇒ 我们藏错了一个小图标、缩略图拿到的是别人的图，而 **Spotify 的封面一直整张露着**：
        // 上移后的标题与歌词就画在封面图上。**照片 51 就是这个现场**（标题上去了、歌词出来了、
        // 封面还全屏）。
        guard let list = findByIdentifier(listIdentifier, in: page),
              let source = visibleCover(in: list) else { return nil }
        // ★ **先吃缓存**（页面开着的时候就已经认下来的那张），再退回"现在去抓树"。
        //   后者在真机树里经常还没就绪（`UIImageView(alpha=0.00)`），那正是"点了没反应"的来源。
        guard let image = rememberArtworkIfNeeded(in: page)
                ?? firstImage(in: source)
                ?? anyCoverImage(in: list) else {
            noteSkip("那张封面里取不到图（\(NSStringFromClass(type(of: source)))）")
            return nil
        }

        let host: UIView
        let imageView: UIImageView
        if let existing = coverHost, let existingImage = coverImage {
            host = existing
            imageView = existingImage
        } else {
            host = UIView()
            host.isUserInteractionEnabled = false
            host.accessibilityIdentifier = "eevee-npv-cover-host"
            // 阴影挂在**容器**上（容器不裁剪）；跟着 transform 一起缩放/移动，不用每帧重画。
            host.layer.shadowColor = UIColor.black.cgColor
            host.layer.shadowOpacity = 0.35
            host.layer.shadowRadius = 20
            host.layer.shadowOffset = CGSize(width: 0, height: 12)
            host.layer.masksToBounds = false

            imageView = UIImageView(frame: host.bounds)
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.layer.cornerCurve = .continuous
            imageView.layer.cornerRadius = coverFullRadius
            imageView.isUserInteractionEnabled = false
            imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            imageView.accessibilityIdentifier = "eevee-npv-cover-thumb"
            host.addSubview(imageView)

            coverHost = host
            coverImage = imageView
        }

        imageView.image = image

        // ★ 布局：**按 Spotify 封面那个大小与位置**（`bounds` + `center`，不用 `frame`）。
        //   注意这**不是**每拍把封面"摆回去"——动画在 transform 上，所以这里随便重写都不打扰它。
        let coverFrame = geometry.cover
        host.bounds = CGRect(origin: .zero, size: coverFrame.size)
        host.center = CGPoint(x: coverFrame.midX, y: coverFrame.midY)
        host.layer.shadowPath = UIBezierPath(rect: host.bounds).cgPath

        if host.superview !== page { page.addSubview(host) }
        page.bringSubviewToFront(host)

        // Spotify 那条封面**在我们这张出现的同一瞬间隐去**（两张同图，所以看不出"换"）。
        // pw：*"Spotify's cover goes the moment the redesign's own takes its place"* ——
        // 早一步会露一个空档，晚一步会两张同屏（一大一小）。
        hideSpotifyCover(source, in: page)
        return host
    }

    /// 缩略图该有的 `transform`：**关于自己的中心**先等比缩小、再平移到目标中心。
    ///
    /// ⚠️ 顺序照 pw：`CGAffineTransformConcat(Scale, Move)` = **先 Scale 后 Move**
    /// （Swift 里是 `scale.concatenating(move)`；写成 `move.scaledBy(…)` 顺序就反了）。
    private static func thumbTransform(cover: CGRect, thumb: CGRect) -> CGAffineTransform {
        let scale = cover.width > 0 ? thumb.width / cover.width : 1
        let move = CGAffineTransform(
            translationX: (thumb.midX - cover.midX).rounded(),
            y: (thumb.midY - cover.midY).rounded()
        )
        return CGAffineTransform(scaleX: scale, y: scale).concatenating(move)
    }

    /// 圆角：**缩放会把圆角一起缩放**，所以想让它在缩略图尺寸下"看起来"是 `drawn`，
    /// 模型值就得**除以 scale**（pw：*"asks for the radius it wants divided by the shrink"*）。
    private static func radiusDrawnAs(_ drawn: CGFloat, coverWidth: CGFloat, thumbWidth: CGFloat) -> CGFloat {
        let scale = coverWidth > 0 ? thumbWidth / coverWidth : 1
        return scale > 0.01 ? drawn / scale : drawn
    }

    /// 把封面**动画地**放到"展开 / 收起"两个状态之一（两个状态都只改 `transform` + 圆角）。
    ///
    /// 动画参数照 pw 的 `SGRMotionLayout`：
    /// `duration 0.45 / usingSpringWithDamping 1（临界阻尼、不回弹）/ velocity 0`，
    /// options = **`AllowUserInteraction` + `BeginFromCurrentState`**
    /// —— `.beginFromCurrentState` 是**连点两次不跳**的关键（从当前呈现位置接着走）。
    /// 另外 pw 在 **Reduce Motion** 打开时整段不做动画（`performWithoutAnimation`），这里也照做。
    ///
    /// - Parameter completion: **保证会被调用**（动画结束 / 已经在对的位置 / Reduce Motion 三条路都调）。
    ///   收起那一路靠它做收尾（撤封面 + 把 Spotify 那条写回）—— 漏调就会永远留着一张封面。
    private static func applyCoverState(
        open: Bool,
        host: UIView,
        imageView: UIImageView,
        geometry: Geometry?,
        completion: (() -> Void)? = nil
    ) {
        if open { coverGeneration += 1 }

        let target: CGAffineTransform
        let radius: CGFloat
        if open, let geometry {
            target = thumbTransform(cover: geometry.cover, thumb: geometry.thumb)
            radius = radiusDrawnAs(
                thumbDrawnRadius,
                coverWidth: geometry.cover.width,
                thumbWidth: geometry.thumb.width
            )
        } else {
            target = .identity
            radius = coverFullRadius
        }

        let change = {
            host.transform = target
            imageView.layer.cornerRadius = radius
        }

        // 已经在对的位置（含"上一次动画已经把模型值设成终点"）⇒ 一个字节都不写。
        // `UIView.animate` 会把模型值**立刻**设成终点值，所以 0.3s 的复查节拍天然不会打断动画。
        guard host.transform != target || abs(imageView.layer.cornerRadius - radius) > 0.01 else {
            completion?()
            return
        }

        guard !UIAccessibility.isReduceMotionEnabled else {
            UIView.performWithoutAnimation(change)
            completion?()
            return
        }

        UIView.animate(
            withDuration: moveDuration,
            delay: 0,
            usingSpringWithDamping: 1,
            initialSpringVelocity: 0,
            options: [.allowUserInteraction, .beginFromCurrentState],
            animations: change,
            completion: { _ in completion?() }
        )
    }

    private static var hiddenCoverKey: UInt8 = 0

    // MARK: - 封面图缓存（**不依赖"点的那一瞬间"**）

    /// 我们按曲目 id 认下来的封面图（最多留 `artworkCacheLimit` 张）。
    ///
    /// **为什么要它**：`ensureCover` 原来是在**点"歌词"那一刻**才去 Spotify 的视图树里抓
    /// `UIImageView.image`；而真机树里那张图常常是 `alpha=0.00` 的壳 + `PlaceholderView`
    /// （日志 42/48 的 `[NPVTree]`：`15.ImageView@0,0,366,366,id=Encore.ImageView` 下面是
    /// `16.UIImageView@0,0,366,366,alpha=0.00` + `16.PlaceholderView`），那一刻 `image`
    /// 可能还是 nil ⇒ 我们只能**拒绝展开**（有日志、不留半成品，但功能会"有时候点了没反应"）。
    ///
    /// 现在改成：**页面开着的时候**每次复查（`DeclutterChrome` 的 0.3s 节拍，本来就在跑）
    /// 顺手把当前这首的封面认下来、按曲目 id 存住；点的时候**先用缓存**，树只当兜底。
    /// **不新增定时器、不新增取景时机。**
    ///
    /// ⚠️ 与 pw 还有距离：pw 是**完全自己持有**那张图（`SGRNowPlayingArtwork`：按 metadata 里的
    /// URL 下载 + 让屏幕把自己画的那张发布给它 + `…ArtworkDidChangeNotification` 通知重画）。
    /// 要再稳一档就复用仓库既有的 `LyricsArtworkResolver`（它已经把
    /// `spotify:image:<hex>` → `https://i.scdn.co/image/<hex>` 这条链走通了），
    /// 但那是**异步**的，要塞进一个同步返回 `Bool` 的 `layoutAndMount` 得先改结构 —— 本轮没做。
    private static let artworkCacheLimit = 8
    private static var artworkCache: [String: UIImage] = [:]
    private static var artworkCacheOrder: [String] = []

    /// 顺手认下当前这一首的封面（幂等：这一首已经有了就直接返回，不再走树）。
    @discardableResult
    private static func rememberArtworkIfNeeded(in page: UIView) -> UIImage? {
        guard let trackId = currentTrackId() else { return nil }
        if let cached = artworkCache[trackId] { return cached }

        guard let list = findByIdentifier(listIdentifier, in: page),
              let source = visibleCover(in: list),
              let image = firstImage(in: source) ?? anyCoverImage(in: list) else { return nil }

        artworkCache[trackId] = image
        artworkCacheOrder.append(trackId)
        while artworkCacheOrder.count > artworkCacheLimit {
            artworkCache.removeValue(forKey: artworkCacheOrder.removeFirst())
        }
        writeDebugLog(
            "[\(logTag)] 记下这一首的封面 \(Int(image.size.width))×\(Int(image.size.height))"
                + "（缓存 \(artworkCacheOrder.count)/\(artworkCacheLimit)）"
        )
        return image
    }

    /// ⚠️ 收的是**已经认准的那一个**（由 `visibleCover` 挑出来），不再自己按 id 找一遍 ——
    /// 上一版这里又 `findByIdentifier` 了一次，于是"挑封面"与"藏封面"用的是两个不同的视图。
    private static func hideSpotifyCover(_ source: UIView, in page: UIView) {
        var hidden = (objc_getAssociatedObject(page, &hiddenCoverKey) as? [UIView]) ?? []
        if !hidden.contains(where: { $0 === source }) { hidden.append(source) }
        source.alpha = 0
        // 它下面那层真正画图的 `UIImageView` 也一起（`Encore.ImageView` 只是壳）。
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

    /// 兜底：在整条列表子树里找**任意一张够大、看得见、真带图的** `UIImageView`。
    /// 判据与 `visibleCover` 同一个量级（≥200pt），走查有界（本仓库纪律）。
    private static func anyCoverImage(in list: UIView) -> UIImage? {
        var visited = 0
        var queue: [UIView] = [list]

        while !queue.isEmpty, visited < maxNodes {
            let view = queue.removeFirst()
            visited += 1

            if let imageView = view as? UIImageView,
               let image = imageView.image,
               imageView.bounds.width >= 200,
               !imageView.isHidden,
               imageView.alpha > 0.01 {
                return image
            }
            if view.isHidden { continue }
            queue.append(contentsOf: view.subviews)
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

    // MARK: - 歌词键（pw 把 glyph 放在 footer；我们照做 —— 而且**要看得见**）

    /// 那枚键的落点。三级判据。
    ///
    /// * **① 首选**：`npv.bottomStackView` 的**最后一行**（footer）的 frame、水平居中。
    ///   真机树（日志 42/48）里那一坨的子视图依次是「标题 / 进度 / 控件 / footer」，footer 恒为
    ///   **最后一个**（`UIView@0,231,406,44`；那一行只有两侧原生控件 —— Connect / 分享 / 队列 ——
    ///   中间是空的）。pw 也是把歌词字形放 footer 那一排。
    ///   ⚠️ 我们只**借它的 frame**，键本身挂在 `page` 上（不塞进 Spotify 的 stack ——
    ///   塞进去它会变成 `stack.subviews.last`，把"认 footer"这件事本身弄坏）。
    ///   ⇒ 代价：那一行自己重排时要等下一拍（≤0.3s）才跟上。
    /// * **② footer 不能用**（版式变了 / 它被藏了）：贴那一坨**上面**。展开时**靠右**
    ///   （歌词正文是居中排的，靠右能把"挡住歌词区、抢走点行跳转"的面积压到最小）。
    /// * **③ 那一坨都找不到**（进页面极早期）：由播放键反推同一条空带（`playToBandTop`）。
    ///
    /// ⚠️ **绝不放在"播放键正上方 44pt"**（上一版的落点）：那里是**标题行与进度条**，
    /// 既压住 Spotify 的内容（进度条的拖动会被抢），也看不出是个按钮。
    private static func toggleFrame(in page: UIView) -> CGRect? {
        let side = toggleSide
        let centeredX = ((page.bounds.width - side) / 2).rounded()

        if let stack = findByIdentifier(bottomStackIdentifier, in: page) {
            let stackFrame = stack.convert(stack.bounds, to: page)

            if let footer = stack.subviews.last, !footer.isHidden, footer.alpha > 0.01 {
                let row = footer.convert(footer.bounds, to: page)
                if row.height >= side, row.width >= side, row.maxY <= page.bounds.maxY + 1 {
                    return CGRect(
                        x: centeredX,
                        y: (row.midY - side / 2).rounded(),
                        width: side,
                        height: side
                    )
                }
            }

            let above = stackFrame.minY - toggleGap - side
            if above > page.bounds.minY + 8 {
                // 展开时我们的歌词区底边就在 stackTop−8：靠右摆，少挡正文、少抢点行跳转。
                let x = isOpen ? (page.bounds.maxX - side - 12).rounded() : centeredX
                return CGRect(x: x, y: above.rounded(), width: side, height: side)
            }
        }

        guard let play = findByIdentifier(playButtonIdentifier, in: page) else { return nil }
        let playFrame = play.convert(play.bounds, to: page)
        let y = max(page.bounds.minY + 8, playFrame.minY - playToBandTop - toggleGap - side)
        return CGRect(x: centeredX, y: y.rounded(), width: side, height: side)
    }

    /// 摆那枚键（幂等）。**看得见**：半透明圆底 + 歌词字形；展开中换成 `chevron.down`。
    ///
    /// ⚠️ **必须自己判 `#available(iOS 26.0, *)`**：这一整条链（渲染层 / `canShow` /
    /// `layoutAndMount`）都是 iOS 26 起的，而 `apply` 那条路**没有再包一层版本判断** ——
    /// 少这一道，iOS 14–25 上会摆出一枚**看得见但点了必然无效**的键
    ///（`canShow` 直接 false，还会打出误导人的"这首歌没有可用的歌词"）。独立复核抓到的。
    private static func ensureToggleZone(in page: UIView) {
        guard #available(iOS 26.0, *) else { return }
        guard let wanted = toggleFrame(in: page) else {
            noteSkip("找不到播放键，歌词键没处放")
            return
        }

        if let zone = lastToggleZone {
            if zone.frame != wanted { zone.frame = wanted }
            if zone.superview !== page { page.addSubview(zone) }
            applyToggleAppearance(to: zone)
            page.bringSubviewToFront(zone)
            return
        }

        let zone = UIControl(frame: wanted)
        zone.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        zone.layer.cornerRadius = toggleSide / 2
        zone.layer.cornerCurve = .continuous
        zone.clipsToBounds = true
        zone.accessibilityIdentifier = "eevee-npv-lyrics-toggle"
        zone.accessibilityLabel = "歌词"
        zone.addTarget(
            NowPlayingLyricsToggleTarget.shared,
            action: #selector(NowPlayingLyricsToggleTarget.tapped),
            for: .touchUpInside
        )

        let glyph = UIImageView(frame: zone.bounds)
        glyph.contentMode = .center
        glyph.isUserInteractionEnabled = false
        glyph.tintColor = .white
        glyph.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        glyph.accessibilityIdentifier = "eevee-npv-lyrics-toggle-glyph"
        zone.addSubview(glyph)

        page.addSubview(zone)
        applyToggleAppearance(to: zone)
        page.bringSubviewToFront(zone)
        lastToggleZone = zone
        let words = hasLyricsAvailable() ? "这一首有词" : "这一首没词 — 已变灰"
        writeDebugLog(
            "[\(logTag)] 歌词键已就位 \(frameText(wanted))（看得见的圆键；点它展开/收起；\(words)）"
        )
    }

    /// 那枚键长什么样：展开中换图标；这一首没词就变灰（**但仍然可点** —— 点了会说明原因）。
    private static func applyToggleAppearance(to zone: UIControl) {
        let symbol = isOpen ? "chevron.down" : "quote.bubble.fill"

        let glyph = zone.subviews
            .compactMap { $0 as? UIImageView }
            .first { $0.accessibilityIdentifier == "eevee-npv-lyrics-toggle-glyph" }

        if let glyph {
            if glyph.frame != zone.bounds { glyph.frame = zone.bounds }
            let drawn = objc_getAssociatedObject(glyph, &toggleSymbolKey) as? String
            if drawn != symbol {
                objc_setAssociatedObject(glyph, &toggleSymbolKey, symbol, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                // 兜底链：万一某个符号名在目标 iOS 上不存在，`UIImage(systemName:)` 会返回 nil
                // ⇒ 那枚键就变成"看得见但什么都没有"的空圆。本机没有运行时，只能这样防。
                let configuration = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
                let candidates = isOpen
                    ? ["chevron.down", "chevron.compact.down"]
                    : ["quote.bubble.fill", "quote.bubble", "text.alignleft"]
                let image = candidates
                    .compactMap { UIImage(systemName: $0, withConfiguration: configuration) }
                    .first
                glyph.image = image?.withRenderingMode(.alwaysTemplate)
            }
        }

        zone.alpha = hasLyricsAvailable() ? 1 : toggleDisabledAlpha
    }

    /// 把那枚键拿走（关开关 / 离开页面）。
    private static func removeToggle() {
        guard let zone = lastToggleZone else { return }
        zone.removeFromSuperview()
        lastToggleZone = nil
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

    /// 这一首**有没有能画的东西**（行级即可）—— 与 `canShow` 前两道门同一条判据，
    /// 但**不打日志**：那枚歌词键每 0.3s 复查一次都要问它，所以只能是几个 bool 读
    /// （`currentLines()` 会建整个数组，不能放在这条热路径上）。
    private static func hasLyricsAvailable() -> Bool {
        guard NgzhwmSettingsViewModel.isBetterWordByWordLyricsEnabled else { return false }
        return hasUsableWordLevelData(currentLyricsDto) || hasUsableLineLevelData(currentLyricsDto)
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
