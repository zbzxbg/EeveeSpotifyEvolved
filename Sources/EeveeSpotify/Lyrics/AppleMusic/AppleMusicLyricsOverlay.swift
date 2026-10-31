import SwiftUI
import UIKit

// 本项目新增（非 MeloX 移植件）：把 Apple Music 风格歌词页接进 Spotify 的歌词容器。
//
// 门禁：整层 iOS 26+（唯一硬性原因见 `LyricAttributedText.swift` 的说明 ——
// 注册自定义 TextAttribute 需要 iOS 26 的 `attributedTextFormattingDefinition`）。
// 老系统上 `WordByWordHost` 会走原来的 UIKit overlay，行为与改动前完全一致。
//
// MARK: - 点行跳转（**只有这一份**，两个调用点共用）
//
// 点某一行歌词 ⇒ 跳到**那一行的内部**（不是它的边界上）。
//
// ⚠️把它提成一份，是因为**同一个 bug 犯了两次**。
//
// 两个细节都有来历，别再各抄一份：
// · `rounded` 而不是 `Int` 截断 —— `line.time` 是 `TimeInterval(offsetMs) / 1000`，
// 双精度存不下 26.622 这种值，会落在略小的一侧（26.621999999999999…），
// `Int` 截断成 26621，比这一行的起点**少 1 毫秒**；
// · **+5ms** —— 播放器 seek 之后回报的位置可能略早，而时间轴的判定是
// `time <= playbackTime`：落在边界上就会被判成**上一行**。
// 全屏页那条路就踩过并修了（当时只写在 `makeRootView` 的闭包里）；
// 而"歌词进播放器"那一档是**另写的一份**、只 `rounded` 没 `+5` ⇒
// 我选中某一行歌词，定位到上一行歌词去了**。
// ⇒ 现在两处都调这一个函数，不可能再各走各的。
//
// （`+5ms` 若哪天仍不够，只**改这一个数**：它是"往这一行里面多走一点"的安全余量。）
func seekToTappedLyricLine(_ time: TimeInterval) {
    WordByWordSeeker.seek(toMs: Int((time * 1000).rounded()) + 5)
}

// MARK: - 挂载管理
//
// 把 `AppleMusicLyricsOverlayView` 挂到 Spotify 的歌词容器上，并在换歌 / 切屏时就地更新。
//
// ⚠️ `@MainActor` 是**必须**的，拆分时别丢：它持有 `UIHostingController` 与 SwiftUI
// 状态，而 `WordByWordHost` 那些调用点全在主线程上（见 `LyricsChromeVisibility` 的说明）。
@available(iOS 26.0, *)
@MainActor
final class AppleMusicLyricsOverlayHost {

    static let shared = AppleMusicLyricsOverlayHost()

    private var hostingController: UIHostingController<AppleMusicLyricsOverlayView>?
    private weak var hostView: UIView?

    /// 当前挂着的 overlay 视图。关闭全屏时要给它拍一张静态替身
    /// （见 `WordByWordHost.handOffToInlineKeepingStandIn`）。
    var overlayView: UIView? { hostingController?.view }
    private let clock = AppleMusicLyricsClock()
    /// 播放状态投影（自绘壳用）。
    ///
    /// 位置来源故意**复用** `WordByWordPositionResolver`，与歌词高亮同一个数据源 ——
    /// 两处各读一次播放器很容易错拍（进度条和歌词差半秒那种）。
    private lazy var projection = AppleMusicLyricsPlaybackProjection {
        WordByWordPositionResolver.shared.currentPositionSeconds()
    }
    private var currentLines: [LyricLine] = []
    private var currentVersion: Int = -1
    private var currentSideInset: CGFloat = -1
    private var currentShowsProviderFooter: Bool = false
    /// 当前背景是不是"实心"档（全屏用）。变了要就地更新 rootView。
    private var currentSolidBackdrop: Bool = false
    /// 当前预览卡片标题栏的高度（全屏时为 0）。
    private var currentPreviewHeaderInset: CGFloat = 0
    /// 换歌时要跟着变的壳文本。
    private var currentTrackTitle: String = ""
    private var currentTrackArtist: String = ""
    /// 这份行模型**属于哪首歌**（`SPTPlayerTrack.trackIdentifier`，重建行模型时记下）。
    ///
    /// 为什么要它：`currentLines` 只在 `currentLyricsVersion` 变化后重建，而那个版本号是随
    /// **歌词数据**自增的 —— 切歌到新词到达之间，模型还是上一首的，挂上去就是
    /// "预览歌词显示上一首歌的逐词歌词"（PL / MXM / AMLL 三个源都能复现：窗口长度＝取词耗时，
    /// 两次请求的源更明显）。有了它就能在**渲染前**判断"这份模型是不是当前这首歌的"。
    private var currentModelTrackId: String = ""

    private init() {}

    /// 是否应该由本层接管（开关开启 + 系统版本够 + 有词级时间轴）。
    static var isAvailable: Bool {
        guard #available(iOS 26.0, *) else { return false }
        guard NgzhwmSettingsViewModel.isBetterWordByWordLyricsEnabled else { return false }
        return true
    }

    /// 挂载或刷新。挂载时调用一次，之后由 `tick(ms:)` 每帧驱动时间。
    /// - Parameters:
    /// - view: 挂到哪个视图上。全屏页传 VC 的根视图（整屏），内嵌预览传歌词容器。
    /// - solidBackdrop: 背景是否走"实心"档（全屏为 true）。
    ///
    /// ⚠️ 这个参数存在的理由，是那套"接管原生视图"的方案被真机否掉了。
    ///
    /// 最初的目标是"让背景盖住 Spotify 的壳（品红）"。我试过三条路，全错：
    /// 1. 让背景溢出容器 → 不可能，子视图出不了父视图 bounds；
    /// 2. 隐藏原生歌词容器 → 全屏页根视图里**一个子视图都没有**（dump 实测），
    /// header / 歌词 / 控件栏都不在这一层，藏一个等于藏整页 → 整页空白；
    /// 3. 清宿主底色 + 把整层插到最底 → 摘掉的是这一页**唯一**的背景层
    /// （dump: `stripped 1 background layer(s): CALayer`）→ 连底都没了。
    ///
    /// 结论：全屏页一个原生视图都不能碰。要盖住底下的东西，只能靠自己够暗 ——
    /// 于是有了这个参数：全屏时把舞台式暗化提到"实心"档（见
    /// `LyricsBackdropView.solidStageScrimAlpha`），原生 UI 则原样浮在我们上面。
    func update(
        in view: UIView,
        sideInset: CGFloat,
        showsProviderFooter: Bool,
        solidBackdrop: Bool = false,
        previewHeaderInset: CGFloat = 0
    ) {
        // ⚠️ 行模型属于**别的**曲目（切歌了、而新歌词还没到）→ 什么都不挂。
        //
        // 这是"预览歌词显示上一首歌的逐词歌词"的直接修复：露出来的原生层
        // （Spotify 渲染我们注入的那份 payload）内容是正确的，比挂一份别人的行模型好。
        //
        // ⚠️更正：以前这里只 `detach` 就返回，靠注释里那句"新歌词到达后
        // 版本号会变，`update` 会重建模型并记下新曲目 id，自然恢复"——**那句是错的**：
        // 重建就在下面，而它被这个 guard 挡着，模型 id 永远不会更新（死锁）。
        // 现在改走 `dropForeignLineModel`：作废模型 → 下一次 `update` 必然重建。
        if hasForeignLineModel {
            dropForeignLineModel(reason: "update skipped — the line model belongs to another track")
            return
        }

        // 数据变了就重建行模型（换歌 / 重新取词）。
        let lyricsChanged = currentVersion != currentLyricsVersion
        if lyricsChanged {
            currentVersion = currentLyricsVersion
            currentLines = (currentLyricsDto?.toAppleMusicLyricLines()) ?? []
            refreshShellMetadata()
            writeDebugLog("[AppleMusicLyrics] rebuilt with \(currentLines.count) line(s)")
            dumpLinesIfDebugEnabled(currentLines)
        }

        let lines = currentLines
        guard !lines.isEmpty else {
            detach()
            return
        }

        // 宿主没变时**就地更新**，不重建 hosting controller。
        //
        // 之前这里重建 rootView：代价是整页 SwiftUI 状态（滚动位置）被丢掉，
        // 于是全屏 ↔ 预览切换后歌词回到顶部、不再居中于当前行。
        // 改成 var 属性写入后，SwiftUI 只重新计算布局，页面身份与滚动位置都保留。
        let insetChanged = sideInset != currentSideInset
        let footerChanged = showsProviderFooter != currentShowsProviderFooter
        let headerInsetChanged = previewHeaderInset != currentPreviewHeaderInset
        // 全屏 ↔ 预览会换背景档（card ↔ stage，以及实心档），这里要一起处理。
        let backdropChanged = solidBackdrop != currentSolidBackdrop
            || (showsProviderFooter ? LyricsBackdropView.Style.stage : .card)
                != (currentShowsProviderFooter ? .stage : .card)
        // 宿主变了（内嵌预览的歌词容器 → 全屏页的 vc.view）→ 需要**搬**视图，
        // 但依然不重建：`removeFromSuperview` + `addSubview` 会把子视图和约束一起带走，
        // SwiftUI 的页面身份与滚动位置都留着。
        let hostChanged = hostingController?.view.superview !== view

        if let hostingController, !backdropChanged, !hostChanged {
            currentSideInset = sideInset
            currentShowsProviderFooter = showsProviderFooter
            currentSolidBackdrop = solidBackdrop
            currentPreviewHeaderInset = previewHeaderInset

            if insetChanged || footerChanged || headerInsetChanged {
                hostingController.rootView.sideInset = sideInset
                hostingController.rootView.showsProviderFooter = showsProviderFooter
                hostingController.rootView.previewHeaderInset = previewHeaderInset
            }
            // ⚠️ 换歌时**必须把新的行模型写回 rootView**。
            //
            // 这条提前返回的路径不重建 hosting controller（为的是保住滚动位置），
            // 而 `lines` 以前是 `let`、这里也没有任何地方更新它 —— 于是出现
            // "壳上的曲名/歌手换了，歌词却还是上一首的"。
            // 现在 `lines` 是 `var`，行模型与壳文本在同一个地方一起对齐。
            if lyricsChanged {
                hostingController.rootView.lines = lines
                writeDebugLog("[AppleMusicLyrics] lines updated in place (\(lines.count) line(s))")
            }
            // 换歌时壳上的曲名 / 歌手也要跟着换（歌词数据变了就说明换歌了）。
            if hostingController.rootView.trackTitle != currentTrackTitle {
                hostingController.rootView.trackTitle = currentTrackTitle
            }
            if hostingController.rootView.trackArtist != currentTrackArtist {
                hostingController.rootView.trackArtist = currentTrackArtist
            }
            // ⚠️ 每帧置于最前，不只是挂载时。
            //
            // 预览挂在卡片容器上时，卡片里的原生内容（歌词视图、Element 那些层）
            // 会在换帧时重排 subviews，把我们挤回下面 —— 表现就是"壳又被盖住了"。
            // 开销只是一次数组操作。
            if hostingController.view.superview === view {
                view.bringSubviewToFront(hostingController.view)
            }
            return
        }

        let hosting: UIHostingController<AppleMusicLyricsOverlayView>
        if let existing = hostingController, !hostChanged {
            hosting = existing
            // 就地改这些参数：背景是 body 里按它们现算的，所以改完即为最新。
            hosting.rootView.backdropStyle = showsProviderFooter ? .stage : .card
            hosting.rootView.solidBackdrop = solidBackdrop
            hosting.rootView.sideInset = sideInset
            hosting.rootView.showsProviderFooter = showsProviderFooter
            hosting.rootView.previewHeaderInset = previewHeaderInset
            // 壳文本也一起对齐（换歌 + 换挂载点可能同时发生）。
            hosting.rootView.trackTitle = currentTrackTitle
            hosting.rootView.trackArtist = currentTrackArtist
            // 行模型同理：就地复用的那条路上也要写回新歌词。
            if lyricsChanged {
                hosting.rootView.lines = lines
            }
        } else {
            detach()
            hosting = UIHostingController(
                rootView: makeRootView(
                    lines: lines,
                    sideInset: sideInset,
                    showsProviderFooter: showsProviderFooter,
                    solidBackdrop: solidBackdrop,
                    previewHeaderInset: previewHeaderInset
                )
            )
            hosting.view.backgroundColor = .clear
            hosting.view.translatesAutoresizingMaskIntoConstraints = false
            // 让 SwiftUI 内容透传触摸：只有歌词行自己是可点的。
            hosting.view.isUserInteractionEnabled = true
            // ⚠️ 打个"自己人"标记：`WordByWordPlaybackControl` 按无障碍标签在窗口里
            // 找原生控件时会跳过这条链上的控件，避免"自己点自己"（真机爆栈崩过）。
            hosting.view.accessibilityIdentifier = "eevee-lyrics-shell"
        }

        currentSideInset = sideInset
        currentShowsProviderFooter = showsProviderFooter
        currentSolidBackdrop = solidBackdrop
        currentPreviewHeaderInset = previewHeaderInset

        hosting.view.removeFromSuperview()

        view.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        // ⚠️ 必须**每帧**置于最前，而不只是挂载时。
        //
        // 预览时我们挂在卡片容器上，而卡片里的原生内容（歌词视图、Element 那些层）
        // 会在换帧时重排 subviews —— 一次 `bringSubviewToFront` 会被它们挤回下面，
        // 表现就是"粉杠又回来了 / 我们的壳被盖住"。这里的开销只是一次数组操作。
        view.bringSubviewToFront(hosting.view)

        hostingController = hosting
        hostView = view
        writeDebugLog(
            "[AppleMusicLyrics] overlay attached (Apple Music path)"
                + " host=\(NSStringFromClass(type(of: view)))"
                + " solidBackdrop=\(solidBackdrop)"
                + " shell=\(showsProviderFooter)"
        )

        // 全屏自绘壳挂上后，把"这一刻窗口里所有可点控件 + 每个动作会选中谁"
        // 打进日志。三键的目标是靠标签选的，真机上出现过选错/选空，
        // 这份 dump 是唯一能看清原因的东西。只在开了日志记录时输出。
        if showsProviderFooter {
            WordByWordPlaybackControl.dumpControlCandidates()
        }
    }

    func detach() {
        guard hostingController != nil else { return }
        hostingController?.view.removeFromSuperview()
        hostingController = nil
        hostView = nil
        writeDebugLog("[AppleMusicLyrics] overlay detached")
    }

    /// 歌词换了一首（或重新取到）时叫一次：把新行模型就地写进已挂着的层。
    ///
    /// 为什么需要这个入口：`update` 只在挂载时被调用，而切歌时宿主没变、
    /// `WordByWordHost.attach` 的提前返回不会放行 —— 全屏页开着不动切歌的话，
    /// 新歌词永远推不进这一层（"壳上的曲名换了、歌词还是上一首"）。
    /// 用上次挂载的参数重放一次 `update` 即可，什么都不用记第二份。
    func refreshLinesIfNeeded() {
        guard let host = hostView, currentVersion != currentLyricsVersion else { return }
        update(
            in: host,
            sideInset: currentSideInset,
            showsProviderFooter: currentShowsProviderFooter,
            solidBackdrop: currentSolidBackdrop,
            previewHeaderInset: currentPreviewHeaderInset
        )
    }

    /// 换歌时更新壳上的曲名 / 歌手。
    ///
    /// 为什么从 `SPTPlayerTrack` 取而不是从歌词数据：歌词里没有歌手名，
    /// 而曲名在 TTML 里也不一定准（`musicName` 可能是别的语言写法）。
    /// 直接问播放器拿，和手机其他界面显示的一致。
    private func refreshShellMetadata() {
        let track = statefulPlayer?.currentTrack() ?? nowPlayingScrollViewController?.loadedTrack
        // 行模型与壳文本一起对齐：这一份模型从此就"属于"这首歌（见 `hasForeignLineModel`）。
        currentModelTrackId = track?.trackIdentifier ?? ""
        currentTrackTitle = track?.trackTitle() ?? ""
        currentTrackArtist = (EeveeSpotify.hookTarget == .lastAvailableiOS14
            ? track?.artistTitle()
            : track?.artistName()) ?? ""
        writeDebugLog("[Shell] metadata \"\(currentTrackTitle)\" — \"\(currentTrackArtist)\"")
    }

    /// 当前播放器的曲目 id。判据两侧必须取自**同一个来源**。
    private func liveTrackId() -> String {
        (statefulPlayer?.currentTrack() ?? nowPlayingScrollViewController?.loadedTrack)?
            .trackIdentifier ?? ""
    }

    /// 行模型是不是"**别的**曲目"的。
    ///
    /// 任一侧为空时返回 false —— 拿不到 id 的时候不该把层摘掉（宁可不动，也不误伤）。
    private var hasForeignLineModel: Bool {
        let live = liveTrackId()
        guard !currentModelTrackId.isEmpty, !live.isEmpty else { return false }
        return currentModelTrackId != live
    }

    /// 判定"行模型属于别的曲目"之后**把模型整个作废**，而不是只摘掉视图。
    ///
    /// ⚠️修的是一个**死锁**：
    /// `currentModelTrackId` 只在 `update` 的重建路径里（`refreshShellMetadata`）写入，
    /// 而 `update` 在重建**之前**就被 `hasForeignLineModel` 挡回去 —— 于是模型一旦过期
    /// 就再也刷不新：每次 `update` 都静默 `detach`，屏幕上一直没有我们这层，
    /// 直到播放器报的曲目 id 恰好又变回旧值。
    ///
    /// 作废这四样之后 `hasForeignLineModel` 恒为 false（总有一侧为空），
    /// 下一次 `update` 必然重建模型并重挂 —— 自愈只差这一步。
    private func dropForeignLineModel(reason: String) {
        let live = liveTrackId()
        writeDebugLog(
            "[AppleMusicLyrics] \(reason) (model=\(currentModelTrackId.isEmpty ? "<none>" : currentModelTrackId)"
                + " live=\(live.isEmpty ? "<none>" : live)) — dropping the line model"
        )
        detach()
        currentLines = []
        currentModelTrackId = ""
        currentVersion = -1
    }

    // MARK: 为什么不"接管"原生视图
    //
    // 这里曾经有一整套代码：`stripHostBackground` / `restoreHostBackground`
    // （清宿主 backgroundColor 与 layer 上的底色层）、`strippedLayers` /
    // `clearedBaseColors` 两张还原表、`dumpFullscreenHierarchy` /
    // `scheduleFullscreenSecondPass` 诊断、以及把整层 `sendSubviewToBack` 的逻辑。
    //
    // 全部删掉了。真机 + dump 的证据是：全屏页的根视图里**一个子视图都没有**，
    // header / 歌词 / 控件栏都不在这一层，所以
    // · 隐藏任何一个"看起来像歌词容器"的视图 → 整页内容一起消失（整页空白）；
    // · 清根视图的底色/层 → 摘掉这一页唯一的背景层，页面连底都没了。
    //
    // 一句话：这一页不是"我们的层 + 它的壳"两层结构，而是一整块我们看不透的视图，
    // 任何"刮掉一层让位"的做法都会把它刮坏。要盖住它，只能靠自己的背景够暗 ——
    // 见 `LyricsBackdropView.solidStageScrimAlpha`。
    //
    // CADisplayLink 每帧回调入口。由 `WordByWordPlaybackClock.tickHandler` 驱动，
    // 避免新层自带时钟与主时钟错拍。
    func tick(ms: Double) {
        guard hostView != nil, !currentLines.isEmpty else { return }
        // 行模型已经不是当前这首歌的了（切歌、而新歌词还没到）→ **立刻收掉**。
        //
        // 必须每帧判：切歌不一定伴随新的歌词请求（客户端可能直接吃自己那份缓存），
        // 所以只靠"请求到达时清理"会漏。收掉之后露出来的原生层内容是正确的。
        // 新歌词到达时 `update` 会重建模型并重新挂上，所以这不是永久降级。
        if hasForeignLineModel {
            dropForeignLineModel(reason: "tick — the line model belongs to another track")
            return
        }
        // ⚠️ "每帧置于最前"这件事**只能在这里做**。
        //
        // `update` 里那句 `bringSubviewToFront` 只在挂载/刷新时才跑，而预览卡片里的
        // 原生内容（歌词视图、Element 那些层）会在滚动、换行、cell 复用时**重排
        // subviews**，一次置前会被它们挤回去 —— 表现就是"预览里的逐词层时不时被盖住"。
        // 这一句把注释里的承诺兑现掉；已经是最前时只花一次指针比较，不重排。
        if let hostingView = hostingController?.view,
           let host = hostingView.superview,
           host.subviews.last !== hostingView {
            host.bringSubviewToFront(hostingView)
        }
        clock.submit(seconds: ms / 1000)
        // 自绘壳的进度条 / 时间 / 播放键状态也走同一个时钟。
        projection.refresh()
    }

    /// 逐行打印时间戳与文本，**只在 rebuild 时各打一次**。
    ///
    /// 用途：分辨「一行的文本在数据里就是短的」与「一行被折成了两行」——
    /// 前者是两个独立行对象，后者才是换行算法问题。
    /// 旧实现（`LyricsWordByWordOverlayView`）本来每帧打一条诊断，
    /// 换成新渲染层后那条日志没了，排查时等于盲的。
    ///
    /// 不需要额外的开关：`writeDebugLog` 自己就受设置里的「开启日志记录」控制，
    /// 关着的时候这里一行都不会输出（一次 rebuild 约 65 行，不刷屏）。
    private func dumpLinesIfDebugEnabled(_ lines: [LyricLine]) {
        writeDebugLog("[AppleMusicLyrics] ---- \(lines.count) line(s) ----")
        for (index, line) in lines.enumerated() {
            let start = String(format: "%.2f", line.time)
            let kind = line.syllables.isEmpty ? "line" : "word(\(line.syllables.count))"
            let bg = line.backgroundVocal == nil ? "" : " +bg"
            writeDebugLog(
                "[AppleMusicLyrics] L\(index) t=\(start) \(kind)\(bg) \"\(line.text)\""
            )
        }
        writeDebugLog("[AppleMusicLyrics] ---- end ----")
    }

    private func makeRootView(
        lines: [LyricLine],
        sideInset: CGFloat,
        showsProviderFooter: Bool,
        solidBackdrop: Bool,
        previewHeaderInset: CGFloat
    ) -> AppleMusicLyricsOverlayView {
        AppleMusicLyricsOverlayView(
            lines: lines,
            backdropStyle: showsProviderFooter ? .stage : .card,
            solidBackdrop: solidBackdrop,
            showsProviderFooter: showsProviderFooter,
            sideInset: sideInset,
            previewHeaderInset: previewHeaderInset,
            onSeek: { time in
                // 点行跳转的算法**只有一份**（见文件开头 `seekToTappedLyricLine`）：
                // `rounded` + **5ms**，两个细节缺一个就会"点这一行、跳到上一行"。
                seekToTappedLyricLine(time)
            },
            trackTitle: currentTrackTitle,
            trackArtist: currentTrackArtist,
            clock: clock,
            projection: projection,
            // 这一档**保持原行为** —— 卡片预览是 17pt，副唱缩到 ~11pt 看不清；
            // 全屏（带页脚）才画。被解绑的是"歌词进播放器"那一档（见 `NowPlayingLyricsHost`）。
            showsBackgroundVocals: showsProviderFooter
        )
    }
}
