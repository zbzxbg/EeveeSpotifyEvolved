import Foundation
import SwiftUI
import UIKit

// 「歌词进播放器」：把**我们自己那套 Apple Music 逐词歌词**画进正在播放页的中段
// （播放器与底部控件之间那块，现在被 Spotify 的卡片占着）。
//
// ## 为什么复用现有的渲染层
//
// 那一层已经在真机上跑通了全屏页与内嵌预览两条路（同样的时间轴、同样的扫光、同样的 RTL），
// 所以这里**不另造渲染器**，直接用已经暴露出来的 `AppleMusicLyricsOverlayView` +
// 它自己的 `AppleMusicLyricsClock`。本文件只做三件事：算位置、搭宿主、把行模型喂进去。
//
// ## 与 `AppleMusicLyricsOverlayHost` 的关系：**不共用宿主**
//
// 那一个是 `shared` 单例，它的 `hostView` / `hostingController` 会被全屏页与内嵌预览
// 抢着用（仓库文档里有一段"抢宿主"的血泪）。播放器这一层要**长期常驻**，绝不能去抢它，
// 所以下面这个宿主是**本文件自己的**：各自的 hosting controller、各自的行模型版本号。
// 结构上照抄那边（同样的字段组合），但不共享实例。
//
// ## 位置（依据：日志 42 的 `[NPVTree] #20`，993 节点那份）
//
// ```
// 8.UIStackView@4,593,406,240,id=npv.bottomStackView      ← 播放器底部那一坨（标题/进度/控件/footer）
// ```
// 气泡就摆在它**上面**：顶边让开我们自己的那一行，底留 8pt 间隙。
// 量位置读**列表的 `layer.position`**（本仓库纪律：`frame` 在 transform 非恒等时不可信），
// 读不到就退回"页面高 − 那一坨的标准高度（240）"。
//
// ## 开关与可撤销
//
// 扩展功能 → 听歌页 →「歌词进播放器」，**默认关**。关掉 = 把我们的子视图拿走，
// **Spotify 的东西一个字节都没改**（我们只往页面根视图上加了一个自己的容器）。
// 日志 tag：`[NPVLyrics]`。

/// 只属于播放器这一层的歌词宿主。结构照抄 `AppleMusicLyricsOverlayHost`，但**不共享实例**
/// —— 那一个是给全屏页/内嵌预览用的单例，抢它的宿主是仓库里有记载的坑。
@available(iOS 26.0, *)
@MainActor
private final class NowPlayingLyricsHost {

    private var hostingController: UIHostingController<AppleMusicLyricsOverlayView>?

    /// 已经渲染进这一层的歌词版本号（`currentLyricsVersion` 随**歌词数据**自增）。
    private var renderedVersion: Int = -1
    /// 已经渲染的这一份**属于哪首歌**（防止切歌到新词到达之间显示上一首的逐词）。
    private var renderedTrackId: String = ""

    private let clock = AppleMusicLyricsClock()
    private let projection = AppleMusicLyricsPlaybackProjection {
        WordByWordPositionResolver.shared.currentPositionSeconds()
    }

    /// 有没有东西挂着。
    var isAttached: Bool { hostingController != nil }

    /// 这一刻是不是已经渲染到"当前歌词 + 当前曲目"了。
    func isCurrent(version: Int, trackId: String) -> Bool {
        isAttached && renderedVersion == version && renderedTrackId == trackId
    }

    /// 把宿主视图铺进 `container`（容器自己的 frame 由调用方算）。
    func mount(
        in container: UIView,
        lines: [LyricLine],
        version: Int,
        trackId: String,
        onSeek: ((TimeInterval) -> Void)?
    ) {
        let root = AppleMusicLyricsOverlayView(
            lines: lines,
            // `.card` = 内嵌那一档：**背景透明**（卡档不画背景），底下的取色底照样看得见。
            backdropStyle: .card,
            solidBackdrop: false,
            // 不做自绘壳：曲名/艺人/进度条/三键都交给 Spotify 自己那一排，
            // 我们只画歌词本身 —— 内嵌预览那一档就是这么用的。
            showsProviderFooter: false,
            sideInset: 20,
            previewHeaderInset: 0,
            onSeek: onSeek,
            trackTitle: "",
            trackArtist: "",
            clock: clock,
            projection: projection
        )

        let hosting = UIHostingController(rootView: root)
        hosting.view.backgroundColor = .clear
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

    /// 行模型换了（或换歌了）**就地更新**，不重建 hosting controller ——
    /// 重建会把滚动位置丢掉，下一帧用户就看到歌词跳回顶部（全屏页那边学来的教训）。
    func updateLines(_ lines: [LyricLine], version: Int, trackId: String) {
        guard let hosting = hostingController else { return }
        hosting.rootView.lines = lines
        renderedVersion = version
        renderedTrackId = trackId
    }

    /// 用当前位置驱动时间轴。**约每 0.3s 一拍**（蹭 `DeclutterChrome` 的节拍），不是每帧 ——
    /// 行与行之间的移动本身带 SwiftUI 动画，肉眼与每帧没差别，但省掉一个 CADisplayLink。
    func tick(seconds: TimeInterval?) {
        guard isAttached else { return }
        if let seconds {
            clock.submit(seconds: seconds)
        }
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

/// 「歌词进播放器」的对外门面（`DeclutterChrome` 的复查节拍与听歌页的 appear 都调它）。
enum NowPlayingLyricsPlate {

    static let logTag = "NPVLyrics"

    /// 我们的容器在页面上的 id（排查用）。
    private static let containerIdentifier = "eevee-npv-lyrics-container"

    /// 播放器底部那一坨的 id —— 与 `NowPlayingPageOverlay` 用的是同一个锚点。
    private static let bottomStackIdentifier = "npv.bottomStackView"

    /// 那一坨的**标准总高**（日志 42 的定向树：`npv.bottomStackView@4,593,406,240`）。
    /// 只在量不到锚点时才用它兜底。
    private static let bottomStackHeight: CGFloat = 240
    /// 气泡顶边离页面顶留多少（我们自己的覆盖层 / 状态栏那一行）。
    private static let topInset: CGFloat = 96
    /// 气泡与底部那一坨之间留的间隙。
    private static let bottomGap: CGFloat = 8
    /// 太矮就不画（横屏 / 转场中间帧）—— 宁可这一拍不显示，也不要糊一屏。
    private static let minimumHeight: CGFloat = 120

    private static var containerKey: UInt8 = 0

    private static weak var lastPage: UIView?
    private static weak var lastContainer: UIView?

    /// ★ **一个宿主，跟页面走**（不做"每容器一个"的表：那种表要么泄漏、要么得自己清理，
    /// 而页面本来就只有一张 —— 换页时 `apply(in:)` 会带新页面进来，那时把宿主重置）。
    private static var host: AnyObject?
    private static weak var hostPage: UIView?

    private static var didLogInstall = false

    static var isEnabled: Bool { UserDefaults.nowPlayingLyricsInPlayer }

    // MARK: - 对外入口

    /// 进听歌页时叫一次（蹭既有的 `NPVScrollViewControllerHook` 两个 appear 点）。
    static func apply(in pageView: UIView) {
        lastPage = pageView

        guard isEnabled else {
            remove(reason: "switch off")
            return
        }
        guard pageView.bounds.width > 1, pageView.bounds.height > 1 else { return }
        reconcile()
    }

    /// 设置页切开关时叫一次。
    static func reapply() {
        guard let page = lastPage, page.window != nil else { return }
        apply(in: page)
    }

    /// 蹭 `DeclutterChrome` 既有的复查节拍（**不新开定时器**，本仓库纪律）。
    ///
    /// 一拍做四件事，任何一件不成立就安静地什么都不做：
    /// 1. 没开开关 / 没在听歌页 → 走人（成本：两次 weak 读）；
    /// 2. 这一首没有**逐词**数据（`hasUsableWordLevelData` 为假）→ 不显示（一律用逐词那一档）；
    /// 3. 行模型属于**别的**曲目（切歌了、新词还没到）→ 收掉，宁可露原生；
    /// 4. 否则：版本变了就更新行模型，量位置，再驱动时间轴。
    @discardableResult
    static func reconcile() -> Bool {
        guard isEnabled else { return false }
        guard let page = lastPage, page.window != nil else { return false }

        guard #available(iOS 26.0, *) else { return false }
        // 与全屏/内嵌那两层**同一个门禁**：我们复用的就是那条渲染链的视图，
        // 而它只在「更好的逐词歌词」开着时才由那份数据驱动（整层还要求 iOS 26+）。
        // 不满足时安静收掉，而不是画一块莫名其妙的空白。
        guard NgzhwmSettingsViewModel.isBetterWordByWordLyricsEnabled else {
            remove(reason: "better word-by-word lyrics is off")
            return false
        }
        guard hasUsableWordLevelData(currentLyricsDto) else {
            remove(reason: "no word-level lyrics for this track")
            return false
        }

        let trackId = liveTrackId()
        let version = currentLyricsVersion

        // 行模型是不是别人的（切歌、而新歌词还没到）⇒ 收掉，别显示上一首。
        if !renderedTrackId.isEmpty, !trackId.isEmpty, renderedTrackId != trackId {
            remove(reason: "line model belongs to another track")
            return false
        }

        let lines = (currentLyricsDto?.toAppleMusicLyricLines()) ?? []
        guard !lines.isEmpty else {
            remove(reason: "no lines")
            return false
        }

        // 位置每一拍都重算：卡片折叠 / 换歌都会让底部那一坨动。
        let frame = plateFrame(in: page)
        guard frame.height >= minimumHeight else {
            remove(reason: "no room between the player and the bottom stack")
            return false
        }

        let container = ensureContainer(in: page, frame: frame)

        // 上下边缘渐隐：kumone 那一手（停点 0/0.12/0.85/1 早就落在
        // `NowPlayingMetrics.lyricFadeStops` 里，一直没人消费）。用 mask 做，
        // **不碰 Spotify 的任何东西** —— 只是我们自己这层的 layer.mask。
        applyEdgeFade(to: container)

        var changed = false

        if #available(iOS 26.0, *), let host = currentHost(for: page) {
            if host.isCurrent(version: version, trackId: trackId) {
                // 已经是最新的一份 → 这一拍只驱动时间轴。
            } else if host.isAttached, renderedTrackId == trackId {
                host.updateLines(lines, version: version, trackId: trackId)
                changed = true
                writeDebugLog("[\(logTag)] lines updated in place (\(lines.count) line(s), v\(version))")
            } else {
                host.mount(
                    in: container,
                    lines: lines,
                    version: version,
                    trackId: trackId,
                    onSeek: { seconds in
                        // 点歌词行 = 跳到那一行（与全屏页同一个动作原语）。
                        WordByWordSeeker.seek(toMs: Int((seconds * 1000).rounded()))
                    }
                )
                changed = true
                writeDebugLog(
                    "[\(logTag)] 已挂上 (\(Int(frame.width))x\(Int(frame.height)))"
                        + " — \(lines.count) 行逐词，v\(version)"
                )
            }

            renderedTrackId = trackId

            if container.frame != frame {
                container.frame = frame
                changed = true
                if !didLogInstall {
                    didLogInstall = true
                    writeDebugLog("[\(logTag)] 容器位置 \(frameText(frame))（播放器那一坨之上）")
                }
            }

            host.tick(seconds: WordByWordPositionResolver.shared.currentPositionSeconds())
        }

        return changed
    }

    /// 关掉开关 / 这一首没词时把我们的容器整个拿走（Spotify 那边一个字节都没改）。
    ///
    /// ⚠️ **什么都没挂时就什么都不做、也不打日志**：这个函数在复查节拍上会被反复调用
    /// （没开开关、这一首没逐词、位置不够……），不加这道闸门就会每 0.3s 刷一行日志
    /// —— 而且"本来就没事"会和"刚刚收掉"长得一模一样。
    static func remove(reason: String) {
        guard lastContainer != nil || !renderedTrackId.isEmpty else { return }

        if #available(iOS 26.0, *) {
            (host as? NowPlayingLyricsHost)?.detach()
        }
        lastContainer?.removeFromSuperview()
        lastContainer = nil
        renderedTrackId = ""
        didLogInstall = false
        writeDebugLog("[\(logTag)] 已收掉（reason=\(reason)）")
    }

    // MARK: - 位置

    /// 气泡该占哪块地方：底部那一坨**上面**，顶边让开我们自己的那一层。
    private static func plateFrame(in page: UIView) -> CGRect {
        let bottomTop = bottomStackTop(in: page) ?? (page.bounds.height - bottomStackHeight)

        let top = max(topInset, page.safeAreaInsets.top + 44)
        let bottom = min(bottomTop - bottomGap, page.bounds.height)

        return CGRect(
            x: 0,
            y: top,
            width: page.bounds.width,
            height: max(0, bottom - top)
        )
    }

    /// 底部那一坨在**页面坐标系**里的顶边。
    ///
    /// 读列表与那一坨的 `layer.position` 而不是 `frame`：本仓库纪律 —— `frame` 在 transform
    /// 非恒等时未定义（我们自己在标签栏上就写过 transform）。列表就是 `NowPlayingOneScreen`
    /// 认出来的那一张（判据只留一处，别处不重复实现）。
    private static func bottomStackTop(in page: UIView) -> CGFloat? {
        guard let list = NowPlayingOneScreen.pinnedList, list.window != nil else { return nil }
        guard let stack = findByIdentifier(bottomStackIdentifier, in: list) else { return nil }

        // 先换算列表自己在页面里的位置（一屏钉住只改 inset、不动 transform，但转场会动），
        // 再加上那一坨在列表里的位置。
        let listPosition = list.layer.position
        let listOriginY = listPosition.y - list.bounds.height / 2
        let stackTopInList = stack.layer.position.y - stack.bounds.height / 2

        return listOriginY + stackTopInList
    }

    /// 上下边缘渐隐（kumone 的停点，`NowPlayingMetrics.lyricFadeStops` = 0/0.12/0.85/1）。
    ///
    /// 用 `CAGradientLayer` 当**我们自己这层**的 `mask` —— 不碰 Spotify 任何东西。
    /// 位置/尺寸每次都同步（换歌、卡片折叠都会让容器变高）。
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
        // mask 不吃隐式动画（否则每次重排都会闪一下）。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = container.bounds
        CATransaction.commit()
    }

    /// 有界广度优先找 id（本仓库纪律：不给别人的视图树无界遍历）。
    private static func findByIdentifier(_ identifier: String, in root: UIView) -> UIView? {
        var visited = 0
        var queue: [UIView] = [root]
        let limit = 2000

        while !queue.isEmpty, visited < limit {
            let view = queue.removeFirst()
            visited += 1
            if view.accessibilityIdentifier == identifier { return view }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }

    // MARK: - 容器与宿主

    /// 我们的容器：**只加自己的子视图**（Spotify 的东西一个字节都不改）⇒ 拿走即完全还原。
    private static func ensureContainer(in page: UIView, frame: CGRect) -> UIView {
        if let existing = objc_getAssociatedObject(page, &containerKey) as? UIView {
            if existing.superview !== page {
                page.addSubview(existing)
            }
            // 与覆盖层同理：Spotify 换帧会重排 subviews，把我们挤下去。
            if page.subviews.last !== existing {
                page.bringSubviewToFront(existing)
            }
            lastContainer = existing
            return existing
        }

        let container = UIView(frame: frame)
        container.backgroundColor = .clear
        container.clipsToBounds = true
        container.accessibilityIdentifier = containerIdentifier
        container.isAccessibilityElement = false
        page.addSubview(container)
        page.bringSubviewToFront(container)

        objc_setAssociatedObject(page, &containerKey, container, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        lastContainer = container
        return container
    }

    /// 取这一刻该用的宿主：页面换了就重置（容器是挂在页面上的，宿主必须跟着页面走）。
    @available(iOS 26.0, *)
    private static func currentHost(for page: UIView) -> NowPlayingLyricsHost? {
        if let existing = host as? NowPlayingLyricsHost, hostPage === page {
            return existing
        }
        (host as? NowPlayingLyricsHost)?.detach()
        let fresh = NowPlayingLyricsHost()
        host = fresh
        hostPage = page
        return fresh
    }

    // MARK: - 辅助

    /// 当前播放器的曲目 id（与 `AppleMusicLyricsOverlayHost` 同源：两侧必须取自同一个来源）。
    private static func liveTrackId() -> String {
        (statefulPlayer?.currentTrack() ?? nowPlayingScrollViewController?.loadedTrack)?
            .trackIdentifier ?? ""
    }

    /// 这一层**当前渲染的**曲目 id（收掉之后清空）。
    private static var renderedTrackId: String = ""

    private static func frameText(_ frame: CGRect) -> String {
        "\(Int(frame.origin.x)),\(Int(frame.origin.y)),\(Int(frame.width)),\(Int(frame.height))"
    }
}
