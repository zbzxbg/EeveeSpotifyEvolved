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
// ## pw 的形状（`Redesigned/Player/PlayerLyrics.x`，GPL-3.0 隔离副本；来源与许可见「开源许可」页）
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
    /// ★ 2026-10-11：这一份挂上去的是**静态档**（没有时间轴）吗 —— 换档要重挂。
    private var renderedStatic = false
    /// ★ 2026-10-11：挂上去那一份的**罗马化开关指纹** —— 变了要就地重写行模型。
    ///
    /// 为什么需要：罗马字是在 `LyricLinesAdapter` 里算进 `LyricLine` 的（按版本缓存），
    /// 而"日文/中文/韩文罗马化"三个开关只写 `UserDefaults`、**不会让版本号变**
    /// ⇒ 不做这件事的话，用户在设置里一开，得等下一次取词（换歌）才看得到。
    private var renderedRomanization = -1

    private let clock = AppleMusicLyricsClock()
    private let projection = AppleMusicLyricsPlaybackProjection {
        WordByWordPositionResolver.shared.currentPositionSeconds()
    }

    var isAttached: Bool { hostingController != nil }

    /// 罗马化那三个开关的**指纹**（逐语言，就是"歌词页面里的选择"）。
    ///
    /// ⚠️ 实现**只有一份**：`romanizationSwitchesFingerprint()`（`LyricLinesAdapter.swift` 开头）——
    /// 同一个判据抄两份，迟早只修一份（2026-10-11 那个 `seekToTappedLyricLine` 就是教训）。
    ///
    /// 它进 `isCurrent` ⇒ 用户一改开关，下一拍（≤0.3s）就会走 `updateLines` 把行模型重写一遍，
    /// 罗马字立刻出现/消失，不用等换歌。
    static func romanizationFingerprint() -> Int {
        romanizationSwitchesFingerprint()
    }

    func isCurrent(version: Int, trackId: String, isStatic: Bool) -> Bool {
        isAttached && renderedVersion == version && renderedTrackId == trackId
            && renderedStatic == isStatic
            && renderedRomanization == Self.romanizationFingerprint()
    }

    func mount(
        in container: UIView,
        lines: [LyricLine],
        version: Int,
        trackId: String,
        isStatic: Bool,
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
            // ★ 2026-10-09（照片 60）：**不画**预览标题栏那一行。
            //
            // 用户报"「歌词 · 分享 · 打开全屏歌词」这几个按钮还在" —— 那一行是
            // `AppleMusicLyricsOverlayView.previewHeader`（我们自己画的），不是 Spotify 的原生入口。
            // 上一次我判成了原生（`lyrics-share-button` 那一批）并去藏它，于是日志里有了
            // `hid 1 native lyrics affordance(s)` 而屏幕上那一行纹丝不动。
            // 实测几何定案：容器 20,210,374,378 + 内边距 14 + 两个 40×32 的按钮 ⇒
            // 分享键中心 319pt / 全屏键中心 364pt，照片 60 里量的就是 319 / 364。
            showsPreviewHeader: false,
            onSeek: onSeek,
            trackTitle: "",
            trackArtist: "",
            // ⚠️ **参数顺序必须与结构体里的属性声明顺序完全一致** —— SwiftUI 的逐成员初始化器
            // 是位置敏感的（2026-10-05 CI 抓到：我把 `transparentBackdrop` 写在 `previewHeaderInset`
            // 后面，编译器报 "argument labels do not match"）。
            transparentBackdrop: true,
            clock: clock,
            projection: projection,
            // ★ 2026-10-11：「没有时间轴」那一档 —— 见 `AppleMusicLyricsPage.isStatic`。
            isStatic: isStatic
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
        renderedStatic = isStatic
        renderedRomanization = Self.romanizationFingerprint()
    }

    func updateLines(_ lines: [LyricLine], version: Int, trackId: String, isStatic: Bool) {
        guard let hosting = hostingController else { return }
        hosting.rootView.lines = lines
        hosting.rootView.isStatic = isStatic
        renderedVersion = version
        renderedTrackId = trackId
        renderedStatic = isStatic
        renderedRomanization = Self.romanizationFingerprint()
    }

    func tick(seconds: TimeInterval?) {
        guard isAttached else { return }
        if let seconds { clock.submit(seconds: seconds) }
        projection.refresh()
    }

    // MARK: - ★ 2026-10-08：逐词歌词改用**每帧时钟**

    private var usingPerFrameClock = false

    /// 用户报："在逐词歌词的情况下，歌词的性能似乎有些低了，看起来一卡一卡的。"
    ///
    /// **原因是明的**：`tick(seconds:)` 以前**只**由 `DeclutterChrome` 那条 **≈0.5s** 的复查节拍
    /// 调用 ⇒ 逐**词**高亮只有 **2Hz**，肉眼就是一格一格跳。
    /// （逐**行**看不出来，因为行与行之间本来就有 SwiftUI 动画兜着 ——
    /// 旧注释"肉眼与每帧没差别"在**逐词**这一档不成立。）
    ///
    /// 仓库既有的 `WordByWordPlaybackClock`（`CADisplayLink`）**就是干这个的**，不是新定时器。
    /// ⚠️ 但它的 `tickHandler` **只有一个槽**，旧 overlay 那条路（`LyricsWordByWord.x.swift`）
    /// 也在用 ⇒ **占不到就不抢**，退回节拍并打一行日志，绝不把别人的时钟顶掉。
    func usePerFrameClockIfAvailable() {
        guard !usingPerFrameClock else { return }
        let shared = WordByWordPlaybackClock.shared
        guard shared.tickHandler == nil else {
            writeDebugLog(
                "[\(NowPlayingLyricsPlate.logTag)] per-frame clock is taken by another overlay"
                    + " - word-by-word lyrics stay on the 0.5s review tick (choppier)"
            )
            return
        }
        shared.tickHandler = { @MainActor [weak self] ms in
            self?.tick(seconds: ms / 1000)
        }
        shared.start()
        usingPerFrameClock = true
        writeDebugLog("[\(NowPlayingLyricsPlate.logTag)] word-by-word lyrics are now driven per frame (shared CADisplayLink)")
    }

    /// 只停**我们自己**启动的那个时钟（`usingPerFrameClock` 就是这条账）。
    func releasePerFrameClock() {
        guard usingPerFrameClock else { return }
        usingPerFrameClock = false
        let shared = WordByWordPlaybackClock.shared
        shared.tickHandler = nil
        shared.stop()
    }

    func detach() {
        releasePerFrameClock()
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
    //
    // ★ 2026-10-04（用户：「当歌曲名字过长时…右侧的晃动区超过屏幕的右侧了」）：
    //   **缩略图与它的间距各收 8pt / 4pt**（72 + 16 → 64 + 12）。不是审美偏好，是**算术**：
    //   · 展开时标题行要右移 `thumbSide + thumbGap` 给缩略图让位，而那一行自己是 **308pt 宽**
    //     （真机 `28,601,308,51`）⇒ 28 + 72 + 16 + 308 = **424 > 414** ⇒ 长标题的 marquee
    //     有 **10pt 落在屏幕右边之外**（正是用户报的那一条）；
    //   · 28 + 64 + 12 + 308 = **412 ≤ 414** ✓ 全在屏内。
    //   顺带：kumone 照片 40 里那颗缩略图逐像素量出来就是 **64pt**（x 48…140px、y 95…185px），
    //   所以这一改不是"为了凑数"，而是**同时更像参照图**。
    private static let thumbSide: CGFloat = 64
    private static let thumbGap: CGFloat = 12
    private static let titleGap: CGFloat = 12
    private static let titleFade: CGFloat = 20
    private static let thumbTop: CGFloat = 8
    /// header 与歌词之间那段**空气**。
    ///
    /// ★ 2026-10-11（照片 67/68）：kumone 的 header 到歌词之间空 **109pt**（133 → 242），
    /// 那块空地就是"原来放封面、现在让给呼吸"的位置 —— 也是它看起来"松"的原因之一。
    /// 我们的 header 下沿落在 ≈176（缩略图 72pt 从 104 起）⇒ 取 **66** 让歌词正好从 242 开始。
    ///
    /// ★ 2026-10-04（用户：「现在的歌词视图，往上淡出的部分可以再高点」）：**66 → 24**。
    ///   缩略图收到 64pt 之后 header 下沿落到 168，`stageTop = 168 + 24 = 192`（原来 242）
    ///   ⇒ 歌词块整体上移 ≈50pt，顶部那条淡出带**跟着一起上移**（它就是这块区域的一个比例），
    ///   一屏多看约 1–2 行。下面的 `lyricFadeStops` 同时从 0.12 收到 0.10，
    ///   这样"第一行"（块顶 + 48pt 内边距）仍落在淡出带**之外**，不会被新位置吃掉。
    private static let lyricsTop: CGFloat = 24
    private static let lyricsBottom: CGFloat = 8
    /// 歌词块底边与进度条之间的**让位**（kumone：歌词 623 / 进度条 642 ⇒ 19pt）。
    private static let lyricGapAboveProgress: CGFloat = 19
    /// 导航条那一行的判据（id）：真机每一份 `[NPVTree]` 里都有
    /// `Tertiary@0,0,48,48,id=now-playing-minimize-button`。
    private static let minimizeButtonIdentifier = "now-playing-minimize-button"
    /// 进度条单元的判据（id）：真机树里是
    /// `AutoLayoutStackView@0,0,358,41,id=Components.UI.ProgressBarUnitNowPlaying`。
    private static let progressUnitIdentifier = "Components.UI.ProgressBarUnitNowPlaying"

    // MARK: ★ 控件条（2026-10-11 第二轮：照片 71/72/73 的方案）

    // 用户 2026-10-11 的第二版方案（原话）：
    //   > 照片 71 我圈的两个，一放分享按钮，二放歌词开关，然后那个绿色勾就让它呆在那里。
    //   > 其他的按键也不用改了。但是这个方案要解决一个问题（照片 72）：一这个位置会占用
    //   > 不开歌词进入播放器这个功能不开启时，歌手/歌曲名字会挡住。所以（照片 73）：可以和
    //   > kumone 一样，在不开展示歌词的情况下，就把歌曲/歌手放到左上角，在开启展示歌词之后，
    //   > 封面再到左上角，然后歌曲/歌手往右让位。
    //
    // ⇒ 这一条空带（进度条上方、绿色 ✓ 本来就在的那一条）变成**控件条**：
    //     [分享 58]   [我们的歌词键 215]   [绿色 ✓ 371 —— 不动]
    //   而"关着歌词时标题/歌手要挪走"那件事见 `applyClosedTitleTransform`。

    /// 控件条的**中线**（页面坐标 y）。来源：照片 71/72/75 里绿色 ✓ 的中心 ≈626pt
    /// （那是 Spotify 自己的位置，**我们不动它**）—— 另外两颗对齐到同一条线。
    private static let controlBandMidY: CGFloat = 626

    /// 控件条那一条的**半高**（44pt 高的键 ⇒ 上沿 = `controlBandMidY − 22` = 604）。
    ///
    /// 两个地方要用同一个口径，所以抽出来（原来 22 只写在 `applyContainerPassThrough` 里）：
    ///   · 歌词容器从这一条起**放行触摸**（容器底边压在控件条上，不撞的话收藏/分享键点不到）；
    ///   · 单行歌词摆在这条上沿与封面底边的**中点**（见 `layoutSingleLyric`）。
    private static let controlBandHalfHeight: CGFloat = 22

    /// 下面那一排里某一颗按钮的**中线 x**（页面坐标）—— 控件条要和它**同一条竖线**。
    ///
    /// 为什么不写死坐标：用户的判据是"和下面那颗对齐"（照片 75），而这排的位置是
    /// Spotify 按屏宽排的（414pt 上 shuffle 39.9 / 播放 208）。量不到（那一颗被藏了 /
    /// 页面还没铺完）才退回兜底常量 —— 宁可回到常量，也不要摆一个左右不齐的键。
    private static func transportColumnX(_ identifier: String, in page: UIView) -> CGFloat? {
        // 起点从小到大：整页 BFS 要先趟过列表里那些格子，800 的预算可能在到那儿之前就用完
        // （`visibleShareButton` 上面记过同一件事）。
        var roots: [UIView] = []
        if let player = findByIdentifier(nowPlayingViewIdentifier, in: page) { roots.append(player) }
        roots.append(page)

        for root in roots {
            guard let button = findByIdentifier(identifier, in: root) else { continue }
            let frame = untransformed(button, in: page)
            guard frame.width > 1, frame.midX > 0, frame.midX < page.bounds.width else { continue }
            return frame.midX
        }
        return nil
    }

    /// 分享键的目标中心 x（**兜底值**）。运行时优先量下面那一颗（见 `transportColumnX`）。
    ///
    /// ★ 2026-10-11（用户，照片 75）：「分享按键并不和下面的**选择随机播放**按键同一条直线」——
    /// 对的：照片 75 逐列量出来，分享键中心 **57.4pt**、下面那颗 shuffle 中心 **39.9pt**。
    /// 所以这一格改成**和 shuffle 同一条竖线**；这个常量只是"量不到 shuffle 时"的兜底。
    private static let shareButtonCenterX: CGFloat = 40

    /// 歌词键的目标中心 x（**兜底值**）。运行时优先量 `SPTNowPlayingPlayButton`。
    ///
    /// ★ 同上（照片 75）：「歌词按键不和下面的**暂停键**同一条直线」——
    /// 量出来歌词键 **214pt**、播放/暂停 **208pt** ⇒ 改成和它同一条竖线。
    private static let toggleCenterX: CGFloat = 208

    /// 控件条要和**下面那一排**对齐，这是那两颗的 id。
    ///
    /// shuffle：日志 54 的 `[NPVTree]` 里是 `EncoreButton@0,0,48,48,id=Components.UI.ShuffleButton`；
    /// 播放键：`PlayButtonView@0,0,64,64,id=SPTNowPlayingPlayButton`（本文件早就在用它）。
    private static let shuffleButtonIdentifier = "Components.UI.ShuffleButton"

    /// 分享键的判据（id）：`EncoreButton@0,0,44,44,id=ShareButtonNowPlayingView`（日志 54 的 `[NPVTree]`）。
    ///
    /// ⚠️ 页里也有**两份**（日志 54 逐字：一份 `alpha=0.50`、一份全亮）⇒ 和收藏键同一条纪律：
    /// 判据是"**看得见、而且在屏上**的那一份"，不是"按 id 找到的第一份"。
    private static let shareButtonIdentifier = "ShareButtonNowPlayingView"

    /// 关着歌词时，标题行放在导航条下沿**下面多少 pt**（照片 73 的 kumone 位）。
    ///
    /// 照片 72 实测：导航条下沿 ≈96、**原生大封面顶边 = 145** ⇒ 标题行（24 + 22 = 46pt）只有
    /// 96…145 这 49pt 可用。取 2 ⇒ 行占 **98…144**，正好卡在中间，不压封面。
    ///
    /// ⚠️ **那个"行高 46"是估的**（树里只有 `MarqueeLabel 24` + `22` 两个字号，没有行的 frame）。
    /// 真机日志 57 量的**行高是 51**（`28,98,308,51`）⇒ 下沿 **149**，而封面顶 146
    /// ⇒ **压住 3pt**。用户 2026-10-04 报的「大封面有时候会把歌手的名字的下半部分挡住」
    /// 就是这 3pt（被压住的正好是第二行 = 歌手那一行的下半截）。见 `closedTitleCoverGap`。
    private static let closedTitleTopInset: CGFloat = 2

    /// 收起态标题行下沿与大封面顶边之间**至少**留这么多 pt（见 `applyClosedTitleTransform`）。
    ///
    /// 这道夹子是**兜底**：大封面缩到 242pt（`restingCoverSide`）之后它自己的顶边会落到 ≈208，
    /// 离标题行 59pt，本来就不压了；但"封面量不到 / 缩放没生效 / 别的机型"那几种情况下
    /// 这一行仍可能压到封面上 —— 那就往上让 6pt，而不是把歌手名字埋掉。
    private static let closedTitleCoverGap: CGFloat = 6

    /// 歌手那一行的判据（id）：真机树里是
    /// `MarqueeLabel@0,24,308,22,id=now-playing-subtitle-label`（标题是 `now-playing-title-label`）。
    private static let subtitleLabelIdentifier = "now-playing-subtitle-label"

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

    // 判据（全部来自真机树，日志 42/47/51）
    private static let listIdentifier = "scrolling_npv_collection_view_accessibility_identifier"
    private static let bottomStackIdentifier = "npv.bottomStackView"
    private static let coverImageIdentifier = "Encore.ImageView"
    private static let titleLabelIdentifier = "now-playing-title-label"
    private static let playButtonIdentifier = "SPTNowPlayingPlayButton"
    /// 播放器**自己**那份视图。★ 2026-10-07：它是"我们要的封面"最硬的那条判据 ——
    /// 播放器的每一件都在它里面（`npv.bottomStackView` 8 / 进度条 13 / 三颗按钮 14 / 标题行 15），
    /// 而**卡片自己的封面在它外面**（与它平级）。从 2026-09-30 起每份日志都有。
    private static let nowPlayingViewIdentifier = "SPTNowPlayingView"

    // 关联对象
    private static var containerKey: UInt8 = 0
    private static var coverKey: UInt8 = 0
    private static var toggleKey: UInt8 = 0
    private static var titleMaskKey: UInt8 = 0
    /// 歌词区底沿那条**署名**（SL 条款 §6 要的可点署名，见 `ensureCreditLabel`）。
    private static var creditLabelKey: UInt8 = 0
    /// 记着那条署名（摘的时候不查 `lastPage`，见 `removeCreditLabel`）。
    private static weak var lastCreditLabel: UILabel?

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

    /// ★ 2026-10-11 第二轮：被我们搬进**控件条**的那一份分享键（离开页面时只撤它的位移）。
    private static weak var bandShareButton: UIView?
    /// 接管它之前它自己的 `transform`（还原时**原样写回**，不假设它一定是 identity）。
    private static var bandShareOriginalTransform: CGAffineTransform?
    /// 一次开合只报一行（搬到哪里 / 会不会被裁 / 点不点得到）——按 `clearControlBand` 重置。
    private static var didLogBandShare = false
    /// "这一页现在没有看得见的分享键"也只报一次（页面还没铺完时会问一次）。
    private static var didLogBandShareMissing = false
    /// ★ 关着歌词时被我们挪到左上角的那一行（离开页面 / 关开关时撤回来）。
    private static weak var closedTitleRow: UIView?
    /// 同一行里被横向挪开的那个元素（收尾时也要还回去，见 `clearClosedTitleTransform`）。
    private static weak var closedTitleElement: UIView?
    /// "找不到标题行"只报一次（进页面的头几拍可能还量不到）。
    private static var didLogClosedTitleMissing = false
    /// "关着态那一行摆上了"只报一次（一次一页一行，下一份日志靠它判）。
    private static var didLogClosedTitle = false
    /// ★ 2026-10-11：我们贴到歌手那一行右边的那一段（`"（NetEase）"`），收尾时按它精确摘掉。
    private static var lastArtistSuffix: String?
    /// "贴了一次 / 被 binder 写回了一次"各留一行日志（免得变成"改了没生效"）。
    private static var didLogArtistProvider = false
    private static var didLogArtistReset = false
    /// ★ 2026-10-11：分享键的**替身热区**（那颗键自己点不到，见 `ensureShareRelay`）。
    private static weak var bandShareRelay: UIControl?

    private static var host: AnyObject?
    private static weak var hostPage: UIView?

    /// 歌词是否展开（pw 的 `sg_open`）。
    ///
    /// ⚠️ 这是**当前这一页实例的实时状态**，页面一走就被 `closeEverything` 清成 `false`。
    /// "离开再回来还是展开的"那件事**不靠它** —— 靠下面那条**落盘的意图**
    /// （`UserDefaults.nowPlayingLyricsExpanded`），见 `rememberExpanded(_:)` / `reopenIfRemembered(in:)`。
    private static var isOpen = false

    /// ★★ 2026-10-10（照片 66）：**「我们打算铺着」** —— 比 `isOpen` 宽一档。
    ///
    /// 为什么必须有它：`isOpen` 只有在**铺成功**之后才为真，而进页面那一下
    /// （`viewWillAppear` → `apply` → `reopenIfRemembered` → `openAndMount`）
    /// **第一拍经常量不到**（日志 55 逐字：`not expanding (cannot find a visible artwork
    /// wide enough (>=200pt) inside the player list)`），于是 `isOpen` 当场被回退，
    /// 而"按住原生封面"那条路（`coverDidLayOut` / `keepNativeCoverHidden`）的门禁里
    /// 写的正是 `isOpen || coverHost != nil || lastContainer != nil` ⇒ **那一整段窗口里
    /// 没有人去按封面** ⇒ 进入播放器的转场里就是**原生大封面在动**（照片 66 的闪）。
    ///
    /// ⇒ 意图一立就置 `true`（点开、或记忆要展开），**只有用户收起 / 切开关 / 页面收尾才清**。
    ///   门禁用它，于是"打算铺"的那一刻起，原生封面就已经被按住了。
    private static var wantsOpen = false

    /// ★★ 2026-10-04（用户：「用按键来切换歌曲的时候，会漏歌曲大封面」）：**意图要有寿命。**
    ///
    /// 现场（代码实证）：`openAndMount` 失败时**只回退 `isOpen`**（见 `openAndMount` 里那句
    /// `isOpen = false`），`wantsOpen` **一个字都不动**；而 `reconcile` 关着那一支原来写的是
    /// `if wantsOpen { keepNativeCoverHidden(in: page) }` ⇒ 从那一刻起**每一拍**都去按住原生封面，
    /// 而 `coverHost` 一直是 nil（我们**什么都没画**）。
    /// 于是换歌时，新封面**在它自己第一次 `layoutSubviews` 就被按成 `alpha = 0`**
    /// （`coverDidLayOut` 那道门禁里也有 `wantsOpen`）—— 屏幕上就是"大封面漏了"，
    /// 而且**是永久的**：唯一会清 `wantsOpen` 的地方是 `closeEverything`，而那时页面已经不在。
    /// （"不许留永久空白态"是本仓库明文纪律，这条正好违反它。）
    ///
    /// 两道保险：
    ///   ① 意图只在**进场那一小段**算数（`wantsOpenNow()`）—— 够覆盖照片 66 那个转场窗口，
    ///      也就是它当初被加进来的唯一理由；
    ///   ② 过期而我们还什么都没铺上 ⇒ `reconcile` **自己撤意图 + 把封面写回去**。
    private static var wantsOpenUntil: CFAbsoluteTime = 0

    /// 意图的寿命（秒）。取 1.0：`pendingOpenWindow`（2.5s ≈ 5 拍）的第一拍就足够量到，
    /// 而 1s 之内量不到就说明这一程本来就不该铺（没图 / 没词 / 页面没布局完）。
    private static let wantsOpenLifetime: CFAbsoluteTime = 1.0

    /// ★★ 2026-10-10（照片 65）：`viewWillDisappear` 只把这一位置 `true`，**什么都不收**。
    ///
    /// 退出转场里页面**还在屏幕上**（滑下去 / 缩回迷你条）。原来的写法是
    /// `viewWillDisappear` 当场 `closeEverything(animated: false)` ⇒ 封面立刻 `alpha = 1`
    /// ⇒ 整个退出动画里都是**原生那张大封面**（照片 65 的闪）。
    /// 现在把收尾推迟到"**页面真的不在窗口里**"那一刻（`reconcile` 那条既有节拍负责），
    /// 于是退出动画里页面一直是**我们的样子**；等它真的走了，才在屏幕外写回封面、摘掉我们的层。
    /// （pw 的做法同源：它的 morph 在 `tearDown` 里才 `SGRPlayerSetCoverHidden(NO)`，
    ///   见 `.spotify-ipa/spotipw-v0.21.1/.../PlayerMorph.x:215`。）
    private static var pageLeaving = false

    /// 「点开了但这一拍没铺上」的**重试窗口**。
    ///
    /// ★★ 这就是日志 50「点歌词键没反应」的**根因**，而且它是**本轮新引入的回归**。
    ///
    /// 取证：`measure()` 在 `f906512`（日志 49 那个构建）与 HEAD 上**逐字节相同**
    /// （`git diff f906512..HEAD` 里那段没有一行改动）。差别在**调用方**：
    ///
    /// | | 旧（`f906512`，日志 49） | 新（`4215e8e` 之后，日志 50） |
    /// |---|---|---|
    /// | `toggle()` | `isOpen = true; layoutAndMount(...)` —— **不看返回值** | `if !layoutAndMount(...) { isOpen = false }` |
    /// | `reconcile()` | `if isOpen { layoutAndMount(...) }` —— **每拍都重试** | 同上，但失败后 `isOpen` 已经是 `false` ⇒ **再也不进这一支** |
    ///
    /// ⇒ 旧代码"这一拍量不到就下一拍再量"，所以日志 49 里用户点得晚一点就成了
    /// （02:58:44 `展开 — 缩略图 72pt、歌词区 20,204,374,346`，而且 02:58:46 收起、
    /// 02:58:47 又展开，两次都成）。新代码**第一次量不到就永久认死**：日志 50 里用户
    /// 在页面出现后 **1 秒**（04:34:54 出现、04:34:55 点）就点了，那一拍量不到
    /// ⇒ 这枚键在整个会话里再也没活过来。
    ///
    /// `4215e8e` 的**本意是对的**（别留"标题已经上移、歌词已经画出来、封面还整张露着"的半成品，
    /// 照片 51 就是那个现场），它只是**少了另一半**：失败之后要接着试。
    /// 这一段就是把那另一半补回来 —— 窗口很短（2.5s ≈ 5 拍），
    /// 而且**不新开定时器**（蹭 `DeclutterChrome` 既有那条节拍）。
    private static var pendingOpenUntil: CFAbsoluteTime = 0
    private static let pendingOpenWindow: CFAbsoluteTime = 2.5

    private static var didLogInstall = false
    private static var lastSkipReason = ""

    /// 这一层参不参与：**只看「歌词进播放器」**。
    ///
    /// ★★ 2026-10-12（用户报「歌词按钮点不动」→ 追问「自己画的这套视图塞不进去单纯的逐词吗」）：
    ///
    /// 这里**一度**（就在今天上午）还挂了「更好的逐词歌词」，因为 `canShow()` 里本来也要它 ——
    /// 那是**把门禁放错了地方**：这一层**本身就是** Apple Music 那套渲染（SwiftUI 页 + 逐词高亮），
    /// 而「更好的逐词歌词」真正管的是 **Spotify 原生歌词页**用哪套渲染
    /// （`AppleMusicLyricsOverlay` ↔ 旧 UIKit overlay `LyricsWordByWord`），
    /// 跟"播放器这层要不要存在"没关系。挂在这里的后果很具体：
    /// 只开「逐词歌词」时**整层退出** —— kumone 那套版式全没了（缩封面 / 标题左上 / 控件条 /
    /// 单行歌词），而用户要的恰恰是"版式留着、歌词照画"。⇒ 恢复成只判这一颗。
    ///
    /// 渲染能力由 `canShow()` 里那条 **iOS 26** 判据兜着（这一整条链本就是 iOS 26 起的）。
    static var isEnabled: Bool { UserDefaults.nowPlayingLyricsInPlayer }

    // MARK: - 对外入口

    static func apply(in pageView: UIView) {
        lastPage = pageView
        // 进页面 = 这一程开始（上一次的"要走了"作废）。
        pageLeaving = false

        guard isEnabled else {
            // 关开关：**不动画**（用户多半在设置页，而且页面上可能正有转场）。
            closeEverything(reason: "switch off", animated: false)
            removeToggle()
            // ★ 关掉功能 = **页面回到 Spotify 原样**：控件条与"标题行去左上角"都要撤。
            clearControlBand()
            clearClosedTitleTransform()
            // ★ 2026-10-04：大封面那个缩放也是我们写的，一起还回去。
            restoreCoverScale()
            // ★ 2026-10-04：单行歌词也是我们的东西。
            removeSingleLyric()
            // ★ 2026-10-12：触摸替身也一样（它的 `row` 是别人的视图，不能留着乱转发）。
            removeTitleRelay()
            // ★ 2026-10-13：署名（挂在页面上的我们自己的 label）同样要摘干净。
            removeCreditLabel()
            // ★ 2026-10-12：**为什么没参与**要留在日志里（否则"歌词键不见了"没法判）。
            //   一次一页只报一行（`lastEnabledSkipReason`）。
            noteDisabledReason()
            return
        }
        guard pageView.bounds.width > 1, pageView.bounds.height > 1 else { return }

        // ★★ 2026-10-10：进页面先收拾**上一程的残留**。
        //
        // 为什么会有残留：退出时我们把收尾**推迟**到"页面真的不在窗口里"那一刻（照片 65 的修法）。
        // 万一那一拍没赶上（比如 Spotify 把这一页留在窗口里、只是不再显示），残留就会跟着进来：
        // 我们的缩略图 + 被按住的封面 —— 而这一次**没有**要求展开（用户上次是收起的）
        // ⇒ 屏幕上是一个"大封面没了、歌词也没有"的半成品（照片 57 那一类）。
        if !isOpen, coverHost != nil || lastContainer != nil || wantsOpen {
            closeEverything(reason: "left over from the previous visit", animated: false)
        }

        // ⚠️ 顺序要紧：先铺歌词（封面 / 标题 / 容器都会 `bringSubviewToFront`），
        // **再**摆那枚键 —— 后写的赢，否则键会被我们自己的容器压住。
        // 铺不上（拿不到封面图等）就**不认"已展开"**，别留半成品 —— 但会由 `openAndMount`
        // 开一个 2.5s 的重试窗口，下一拍接着试。
        if isOpen {
            openAndMount(in: pageView)
        } else if UserDefaults.nowPlayingLyricsExpanded {
            // ★ 2026-10-10：**页面记忆** —— 上次离开这一页时是"展开"状态，这次进来就还铺上。
            //   见 `reopenIfRemembered`。顺序同样要在 `ensureToggleZone` 之前（后写的赢）。
            reopenIfRemembered(in: pageView)
        }
        // ★ 2026-10-11 第二轮：控件条**两个状态都摆**；"标题行贴左上角"只在**关着**时摆
        //   （展开时标题行的位置由 `applyTitleTransform` 管，两者写的是同一行的 `transform`，
        //    后面那个赢 —— 所以这里必须先判 `isOpen`）。
        applyControlBand(in: pageView)
        // ★ 2026-10-04：大封面的尺寸也要在**这一拍就位**，否则下面 `applyClosedTitleTransform`
        //   量到的还是 366pt 的封面（顶边 146）⇒ 标题行会被那道"别压封面"的夹子多抬 9pt，
        //   下一拍再弹回来。顺序：先摆封面，再摆跟着封面走的那一行。
        applyCoverRestingScale(in: pageView)
        if !isOpen {
            applyClosedTitleTransform(in: pageView)
            // ★ 2026-10-04：收起态也要有 `歌手（提供商）`（见 `reconcile` 里同一处）。
            applyProviderToArtistLine(in: pageView)
        }
        // ★ 2026-10-04：封面与歌词键之间那一行居中歌词（用户建议的第二条）。
        //   `applySingleLyric` 自己会在"展开着 / 没词"时把它收起来。
        applySingleLyric(in: pageView)
        // ★ 2026-10-12：被移走的标题行**还能点**（点歌名/歌手跳专辑/歌手页）。
        applyTitleRelay(in: pageView)
        ensureToggleZone(in: pageView)
    }

    /// ★ 2026-10-10（照片 65）：页面**要**走了 —— 只记一笔，**什么都不收**。
    ///
    /// 收尾（撤销几何、把原生封面写回、摘掉我们的层与那枚键）交给 `reconcile` 在
    /// **"页面真的不在窗口里"**那一刻做 —— 这样整个退出转场里页面都是我们的样子。
    static func pageWillLeave() {
        pageLeaving = true
    }

    /// ★★ 2026-10-10（用户提的「页面记忆」）：进页面时若记得"上次是展开的"，就把它铺回去。
    ///
    /// 用户原话：
    /// > 是不是没有那种页面记忆的功能。就是假如说我当时正在打开歌词的这个页面（照片 63），
    /// > 退出之后再重进也还是在这个页面，不是那个大封面
    ///
    /// 改动前的实证：展开状态只活在 `isOpen` 里，而 `remove(reason:)`（`viewWillDisappear`）
    /// 会走 `closeEverything` 把它清掉 ⇒ 重进必然是大封面。
    ///
    /// 门禁（缺一不可）：
    ///   · 开关开着（`apply` 已经判过，这里再判一次是为了 `reapply()` 那条路）；
    ///   · 记的是"展开"；
    ///   · **这一首有能画的东西**（`canShow`）—— 没词就保持大封面，只打一行日志，
    ///     别把 `openAndMount` 的重试窗口浪费在一首没词的歌上（与 `toggle()` 同一条纪律）。
    private static func reopenIfRemembered(in page: UIView) {
        guard isEnabled, UserDefaults.nowPlayingLyricsExpanded else { return }
        guard canShow(for: page) else {
            guard !didLogRememberedWithoutLyrics else { return }
            didLogRememberedWithoutLyrics = true
            writeDebugLog(
                "[\(logTag)] re-entering the player while the remembered state is"
                    + " \"expanded\", but this track has nothing to draw - staying on the cover"
            )
            return
        }
        writeDebugLog("[\(logTag)] re-entering the player expanded (remembered choice)")
        // ★ 意图立刻立起来：这样从**这一帧**起，`coverDidLayOut` / `reconcile` 就会按住原生封面
        //   （照片 66 的闪：进页面的第一拍量不到，但封面已经被按住了）。
        // ★ 2026-10-04：连带**寿命**一起立（见 `wantsOpenUntil`）—— 意图不许再永久挂着。
        wantsOpen = true
        wantsOpenUntil = CFAbsoluteTimeGetCurrent() + wantsOpenLifetime
        openAndMount(in: page)
    }

    private static var didLogRememberedWithoutLyrics = false

    /// ★ 记下"用户上一次选的展开状态"。**只有用户点那枚键时才会调它** ——
    /// 离开页面 / 切歌 / 收起动画都不许动它（那正是"记忆"的含义）。
    private static func rememberExpanded(_ expanded: Bool) {
        guard UserDefaults.nowPlayingLyricsExpanded != expanded else { return }
        UserDefaults.nowPlayingLyricsExpanded = expanded
        writeDebugLog(
            "[\(logTag)] remembering the player's lyrics state: "
                + (expanded ? "expanded (re-entering comes back here)" : "collapsed (re-entering starts from the cover)")
        )
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

        // ★★ 2026-10-10（照片 65）：**收尾推迟到这一刻** —— 页面真的不在窗口里了。
        //
        // 顺序要紧：这一段必须在下面那个 `guard let page, page.window != nil` **之前**，
        // 否则页面一走那条 guard 就直接 return，我们永远等不到收尾（我们的层、被按住的封面、
        // 标题行的位移就全留在那一页上了）。
        guard let leavingPage = lastPage else { return false }
        if leavingPage.window == nil {
            // ★ 2026-10-12（独立复核）：**这一段的条件必须把"我们写过的每一处"都算上**。
            //   它原来只认展开态那几样（封面 / 容器 / 分享键 / 标题行），而这一轮新增了三处
            //   写在**别人的视图或页面上**的东西：封面缩放、歌手行的提供商、那一行单行歌词。
            //   漏掉它们的后果很具体：页面走掉时该跑的那次收尾**整段被跳过**
            //   ⇒ 封面缩着不回、歌手行永远挂着「（NetEase）」、我们的标签留在树上
            //   （而 `singleLyric` 若还是强引用，连那一页的标签都一起钉住）。
            guard pageLeaving || isOpen || coverHost != nil || lastContainer != nil
                || bandShareButton != nil || closedTitleRow != nil || wantsOpen
                || !scaledCoverBase.isEmpty || lastArtistSuffix != nil || singleLyric != nil
                || titleRelay != nil
            else { return false }
            // 页面已经不在屏幕上了 ⇒ 现在写回封面 / 撤销几何 / 摘掉我们的层与那枚键，什么都看不见。
            closeEverything(reason: "page disappeared", animated: false)
            removeToggle()
            // ★ 2026-10-11 第二轮：写在**别人的控件**上的那两处位移也要还回去
            //   （分享键的平移、标题行的左上角）。
            clearControlBand()
            clearClosedTitleTransform()
            // ★ 2026-10-04：大封面那个缩放同样是我们写的 ⇒ 一起还回原值。
            restoreCoverScale()
            // ★ 2026-10-04：单行歌词也要拿走（页面都走了，别把它留在树上）。
            removeSingleLyric()
            // ★ 2026-10-12：触摸替身一起拿走（页面没了，它转发给谁都不知道）。
            removeTitleRelay()
            return false
        }

        guard let page = lastPage else { return false }
        guard #available(iOS 26.0, *) else { return false }

        // 转场里（`viewWillDisappear` 已记一笔，但页面还在窗口里）⇒ **保持现状**：
        // 不写回封面、不撤销几何 —— 整个退出动画里页面都是我们的样子。
        if pageLeaving {
            ensureToggleZone(in: page)
            return isOpen
        }

        // ★ 2026-10-11 第二轮：控件条**两个状态都摆**（它和 `isOpen` 无关）。
        applyControlBand(in: page)
        // ★ 2026-10-04：大封面收成 242pt（kumone 照片 41 的尺寸）。**两个状态都摆**：
        //   换歌会换一个新的封面对象，旧的缩放跟着对象一起作废。
        applyCoverRestingScale(in: page)

        if isOpen {
            // 可能因为"封面还没布局好"铺不上 —— 那时退回去，并由 `openAndMount` 开重试窗口。
            openAndMount(in: page)
            // ★ 不管上面成没成：只要我们的层还在，就**每拍**把当前那张主封面按掉
            //   （换歌会换一个新的封面对象，见 `keepNativeCoverHidden`）。
            keepNativeCoverHidden(in: page)
            ensureToggleZone(in: page)
            // ★ 2026-10-04：整页歌词就在眼前，封面那一行居中的单行歌词要收起来（不然是重复的）。
            hideSingleLyric()
            // ★ 2026-10-12：展开态那一行也被移走了（缩略图右边）⇒ 同样点不到，替身一样要摆。
            applyTitleRelay(in: page)
            return isOpen
        }

        // ★ 2026-10-11 第二轮（照片 72/73）：**关着歌词时，标题行贴左上角** ——
        //   给控件条让地方（否则分享键会压在歌名/歌手上面）。
        applyClosedTitleTransform(in: page)
        // ★ 2026-10-04（用户：「歌词提供商并没有在歌手的后面展示」+"两个状态都显示"）：
        //   收起态也要把 `歌手（提供商）` 摆上 —— 以前只有"展开"那条路会贴，
        //   而用户平时看的就是收起这一屏。
        applyProviderToArtistLine(in: page)

        // ★ 2026-10-04：封面与歌词键之间那一行**居中歌词**（用户建议的第二条）——
        //   它的 y 是"封面底边与控件条上沿的中点"，所以必须排在 `applyCoverRestingScale`
        //   （封面缩到 242pt）**之后**，否则量到的还是 366pt 那张的底边。
        applySingleLyric(in: page)
        // ★ 2026-10-12：被移走的标题行**还能点**（点歌名/歌手跳专辑/歌手页）。
        applyTitleRelay(in: page)

        // ★ 2026-10-10（照片 66）：**"打算铺但还没铺上"**的那段窗口里也要按住原生封面 ——
        //   否则进入播放器的转场里就是原生大封面在动（这一拍 `isOpen` 还是 false）。
        // ★ 2026-10-04：但这段窗口**必须过期** —— 用户报的「按键换歌漏大封面」就是它没过期
        //   （见 `wantsOpenUntil` 的来龙去脉）。过期而这一路什么都没铺上 ⇒
        //   **当场撤意图 + 把 Spotify 那张封面写回去**，绝不留"封面被按着、我们又没画"的永久空白。
        if wantsOpenNow() {
            keepNativeCoverHidden(in: page)
        } else if wantsOpen {
            wantsOpen = false
            wantsOpenUntil = 0
            restoreSpotifyCover()
            noteSkip("the open intent expired with nothing drawn - Spotify's cover is back")
        }

        // ★ 2026-10-10：顺手把那两颗胶囊认下来。**从这一页的子树里找**（按 id）——
        //   整窗 BFS 会被首页那棵大树吃掉预算（日志 55 那行 `visited 6 node(s)` 是启动瞬间的，
        //   而页面自己这棵树只有几百个节点，一定够用）。认下来之后 `DeclutterChrome` 会一直盯着。
        DeclutterChrome.adoptNowPlayingPills(from: page)
        // ★ 2026-10-07：「**点开了但没铺上**」的重试（见 `pendingOpenUntil` 的说明）。
        //   没有这一段，日志 50 里那一次点击就是这枚键的**最后一次**机会。
        //   ⚠️ 重试**也要过门禁**：`openAndMount` 里没有 `canShow`，而换歌之后
        //   "这一首有没有词"是会变的 —— 没词了就把窗口清掉，别拿一首没词的歌空转五拍。
        if CFAbsoluteTimeGetCurrent() < pendingOpenUntil {
            // ★ 2026-10-11：`noticeText()` 也算"有东西可画"（用户要的是键随时能按）——
            //   否则一首没词的歌在"第一拍量不到封面"之后就再也没人重试了。
            //   ⚠️ 同一天又加了"没有时间轴 ⇒ 静态歌词"那一档 ⇒ 判据换成 `hasSomethingToShow()`
            //   （它把三档都算进来：有时间轴 / 静态歌词 / 一句说明）。
            if hasSomethingToShow() {
                openAndMount(in: page)
                // ★ 2026-10-04：按住原生封面这件事**跟着意图的寿命**走（见 `wantsOpenNow()`）——
                //   意图过期 ⇒ 这一程本来就铺不上，那就别再把封面按着
                //   （否则正是"我们自己制造一片空白"，用户报的漏封面就是这个味道）。
                //   ⚠️ 铺成功那一拍 `coverHost` 已经在 ⇒ `wantsOpenNow()` 仍为真，不受影响。
                if wantsOpenNow() { keepNativeCoverHidden(in: page) }
            } else {
                pendingOpenUntil = 0
            }
            ensureToggleZone(in: page)
            return isOpen
        }
        // ★ 半成品护栏：`isOpen` 是 `false`、但我们的封面/容器**还挂在屏上**
        //   （某拍失败留下的）⇒ 也要继续按着原生封面，并接着试着铺回来。
        //   这一条正是照片 57 那种"大封面回来了、我们的东西还压在上面"的兜底。
        if coverHost != nil || lastContainer != nil {
            keepNativeCoverHidden(in: page)
            ensureToggleZone(in: page)
            return false
        }
        // 关着的时候只保证那枚键还在、还画得对（Spotify 换帧会重排 subviews），
        // 并**顺手把这一首的封面认下来**：点的时候就不用"现抓"，而现抓经常抓不到
        // （树里那张图可能是 `UIImageView(alpha=0.00)`）。幂等 —— 这一首已经认下就只查一次字典。
        rememberArtworkIfNeeded(in: page)
        ensureToggleZone(in: page)
        return false
    }

    /// 立刻收掉（**页面离开的那条路已经不用它了** —— 见 `pageWillLeave()`：退出转场里页面
    /// 还在屏幕上，当场收尾会闪出原生大封面，照片 65）。
    ///
    /// 现在它只服务两类"当场"的场合：
    ///   · 设置页把「歌词进播放器」**关掉**（`EeveeExtrasSettingsView`）；
    ///   · `reconcile` 判到"页面真的不在窗口里了"之后的收尾。
    ///
    /// ⚠️ **必须无条件走 `closeEverything`**（哪怕看起来"没展开"）：标题行的位移是我们用
    /// `transform` 写上去的，**不撤销就会留在 Spotify 的元素上**（那一行此后永远偏上一截）。
    /// `closeEverything` 自己有空守卫，没展开时不会打日志。
    /// 那枚键也要一起拿走 —— 否则下次进来会叠一枚在上面。
    static func remove(reason: String) {
        // 页面要走了 ⇒ **不动画**：拖着 0.45s 才把 Spotify 那条封面写回去，会在转场里露一个空档。
        closeEverything(reason: reason, animated: false)
        removeToggle()
        // ★ 2026-10-11 第二轮：这条路现在只服务"设置页把开关关掉" ⇒ 关掉功能 = **页面回到
        //   Spotify 原样**：分享键还回 footer、标题行还回它的位置。
        //   （上面那句 `closeEverything` 里的"摆回关着的样子"会被 `isEnabled` 挡掉，所以这里必须
        //    显式清 —— 否则关掉开关之后，分享键还留在控件条上、标题行还贴在左上角。）
        clearControlBand()
        clearClosedTitleTransform()
        // ★ 2026-10-04：大封面的缩放也是我们写上去的，关掉功能 = 连它一起还回去。
        restoreCoverScale()
        // ★ 2026-10-04：单行歌词同样是我们摆上去的。
        removeSingleLyric()
        // ★ 2026-10-12：标题行的触摸替身也是我们的。
        removeTitleRelay()
    }

    /// 那枚"歌词键"被点了。
    static func toggle() {
        guard let page = lastPage, page.window != nil else { return }

        // ⚠️ 折叠的条件**不能只看 `isOpen`**：如果某一拍 `measure()` 失败而屏幕上还挂着
        //    我们的封面（`isOpen` 已被回退），只看 `isOpen` 会让这一下变成"**再展开一次**"
        //    ⇒ 用户**关不掉**（独立只读复核点出来的死角）。
        //    "屏幕上有我们的东西"与 `closeEverything` 的守卫用的是同一组判据。
        if isOpen || coverHost != nil || lastContainer != nil {
            // 用户自己点收起 ⇒ **放动画**（封面"飞回原位"）。
            closeEverything(reason: "tapped", animated: true)
            // ★ 2026-10-10：**用户这一下就是"记忆"** —— 下次进播放器还是大封面。
            rememberExpanded(false)
            // 图标当场换回"歌词"，不等 0.5s 的复查节拍。
            ensureToggleZone(in: page)
            return
        }
        guard canShow(for: page) else {
            // ⚠️ 这里**不许**说成"这首歌没有可用的歌词"：`canShow` 自己已经把**真正的原因**
            //    写进日志了（关着的开关 / 没有可画的东西），再补一句笼统的会把原因盖掉。
            //    ★ 2026-10-12（用户报「歌词按钮点不动」那条）：以前这里写的就是那句笼统的话，
            //      而真正的原因往往在上面一行 —— 两条一起看才不误导。
            noteSkip("the lyrics button was tapped but our layer cannot open (see the reason above)")
            // ⚠️ 用户刚被告知"这首没词" ⇒ 把可能还挂着的重试窗口**清掉**，
            //    别让下一拍拿同一首歌再空转五回。
            pendingOpenUntil = 0
            ensureToggleZone(in: page)
            return
        }
        // 铺不上就当场认输（`noteSkip` 已经写清了原因），别把开关停在"展开但什么都没变"上。
        // ⚠️ 但**不认死** —— `openAndMount` 会顺手开一个 2.5s 的重试窗口。
        // ★ 2026-10-10：**先记"用户要展开"**，再铺。这样即便第一拍量不到（2.5s 重试窗口接手），
        //   下次进页面也还是"记得要展开"——记忆跟的是**用户的意图**，不是这一拍的成功与否。
        //   `wantsOpen` 同时把"按住原生封面"提前到这一帧（照片 66 的闪就是这么来的）。
        rememberExpanded(true)
        wantsOpen = true
        // ★ 2026-10-04：意图带寿命（见 `wantsOpenUntil`）—— 铺不上就让它过期，
        //   别让"大封面被永久按住"变成用户看到的那件事。
        wantsOpenUntil = CFAbsoluteTimeGetCurrent() + wantsOpenLifetime
        openAndMount(in: page)
        // ⚠️ 必须在铺完之后再摆一次：容器会 `bringSubviewToFront`，键会被压到它下面。
        ensureToggleZone(in: page)
    }

    /// 「我们打算铺着」这个意图**现在还作数吗**（见 `wantsOpenUntil`）。
    ///
    /// 三种情况：
    ///   · 没立意图 ⇒ `false`；
    ///   · **已经铺上了**（我们的封面 / 歌词容器在屏幕上）⇒ 一直作数（这时按住原生封面本来就是对的）；
    ///   · 还在"点了但没铺上"的那段窗口里（≤ `wantsOpenLifetime`）⇒ 作数（照片 66 的转场靠它）。
    ///
    /// 过了窗口又什么都没铺上 ⇒ `false`，**调用方负责撤意图并把封面写回去**（别在这里写状态，
    /// 因为 `coverDidLayOut` 也会问它，而那个回调是别人的 `layoutSubviews`）。
    private static func wantsOpenNow() -> Bool {
        guard wantsOpen else { return false }
        if coverHost != nil || lastContainer != nil { return true }
        return CFAbsoluteTimeGetCurrent() < wantsOpenUntil
    }

    /// ★ 只要我们的层还在屏幕上，就**每一拍**把 Spotify 当前那张主封面按掉。
    ///
    /// ## 为什么必须独立于 `layoutAndMount`（照片 57 的现场）
    ///
    /// 换歌时 Spotify 会把封面换成**新的那一个对象**，而我们之前藏的是**旧对象**
    /// ⇒ 新封面整张露出来，而我们的缩略图 / 上移后的标题 / 歌词还挂在那儿
    /// —— **照片 57 就是这个现场**（大封面正中，上面叠着旧缩略图、标题和一行歌词）。
    ///
    /// 以前 `ensureCover` 恰好在"这一首有没有词"那道门**之前**跑，顺手就把新封面按住了；
    /// **2026-10-07 我把那道门提到最前面**（为了让失败"零副作用"，独立复核建议的），
    /// 于是这个必需的副作用一起被拿掉了 —— **那是我引入的回归**。日志 52 的证据：
    ///
    /// ```
    /// 07:00:46  [PLAYER] track changed — pos=0.0s dur=168.0s
    /// 07:00:47  [NPVLyrics] not expanding (no lyric lines to draw right now (the line model is not ready))
    /// ```
    ///
    /// 那道门一失败就**直接 return**，于是从这一刻起再也没有人藏封面 ⇒ 半成品一直挂着，
    /// 直到用户再点一下。现在把它拆出来**无条件**每拍做。
    @discardableResult
    private static func keepNativeCoverHidden(in page: UIView) -> Bool {
        guard let list = findByIdentifier(listIdentifier, in: page),
              let source = visibleCover(in: list, page: page) else { return false }
        hideSpotifyCover(source)
        return true
    }

    // ★★ 2026-10-09：**`hideNativeLyricsAffordances` 整块已删**（照片 60 定案）。
    //
    // 它当初要藏的是「歌词 · 分享 · 全屏」那一行，理由是"那是 Spotify 的原生入口
    // （`lyrics-expand-button` / `lyrics-share-button` / `lyrics-translations-button`）"。
    // 日志 53 证明**这个判断是错的**，而且做法本身有害：
    //
    //   ① **屏幕上那一行是我们自己画的**（`AppleMusicLyricsOverlayView.previewHeader`）。
    //      几何对得上：容器 20,210,374,378 + 内边距 14 + 两个 40×32 的按钮
    //      ⇒ 分享键中心 319pt、全屏键中心 364pt；照片 60 量出来正是 319 / 364。
    //      所以藏原生那一批**屏幕上什么都不会变**——日志里 `hid 1 native lyrics affordance(s)`
    //      与"那一行还在"同时成立，就是这个原因。
    //   ② 原生那三颗按钮所在的卡在**列表里**、而且被「一屏」折成了 0 高：
    //      日志 53 的 `[NPVTree]` 是 `2.CollectionViewCell@20,838,374,0` →
    //      `5.CardView@0,0,374,0,alpha=0.00,id=lyrics-card-view` → `7.CardHeaderView@0,0,342,38`。
    //      它们本来就不在屏上，**根本不需要藏**。
    //   ③ 而 `widestRowAncestor`（≥350pt 宽）从那三颗按钮往上走，第一个够宽的是
    //      **`CardView` 本身**（374 宽）⇒ 我们实际藏的是**整张歌词卡的根**。
    //      那张卡正是 `WordByWordHost` 内嵌预览的宿主
    //      （日志里的 `[PreviewShell] card container (card)=Lyrics_CardElementImpl.CardView`）
    //      ⇒ 一旦「一屏」没折它、或用户关掉「一屏」，我们就会把**自己的**预览歌词
    //      一起 `alpha = 0` 掉。这是本轮**顺手拆掉的隐患**。
    //
    // 结论：不对别人的入口下手。真正要消失的那一行，去改**我们自己**的画法
    // （`AppleMusicLyricsOverlayView.showsPreviewHeader`）。

    /// ★★ 2026-10-10（照片 64，pw 的手法）：**封面自己布局的那一刻，就地按住它自己的那张图。**
    ///
    /// ## 为什么上一版还不够（照片 64 的现场）
    ///
    /// 上一版挂的是同一个 hook，但动作是 **`keepNativeCoverHidden`** —— 也就是"在整棵树里
    /// **再找一遍**哪张是当前封面"（`visibleCover` 那三趟判据：`Encore.ImageView` + 在
    /// `SPTNowPlayingView` 里 + 祖先没被折成 0 ……）。换歌那一瞬间这**必然失手**：
    /// 新封面可能还在淡入（`alpha` 还是 0）、或被 tier 判据排除 ⇒ `visibleCover` 挑中的
    /// 是**上一张（已经 alpha=0 的）** ⇒ `alpha = 0` 写在旧对象上，**新封面整张露着**。
    /// 照片 64 就是这一帧：原生大封面（新歌的图）+ 我们的缩略图（上一首的图）同屏。
    ///
    /// ## pw 怎么做（`.spotify-ipa/spotipw-v0.21.1/.../PlayerArtwork.x`）
    ///
    /// 它**不搜索**：`%hook CoverArtTiltView` 的 `layoutSubviews` 里
    /// ① `bounds.width >= 200` 且 ② `inCoverCell(tilt)`（祖先里有 `CoverArtCellImpl`），
    /// 然后 `coverIn(tilt)` = **它自己那个和 tilt 等大的直接子视图**，对它下手。
    /// 局部、无竞态、不依赖"哪一张现在可见"。
    ///
    /// ⇒ 这里沿用同一套（v0.21.1 是 GPL-3.0，与本仓库一致；来源、许可与改动见「开源许可」页）：
    ///   · 门禁：开关开 + **我们确实铺着** + tilt 在窗口里且够大 + **祖先里有 `CoverArtCellImpl`**
    ///     （这一条把迷你条/卡片里那些 tilt 一次滤掉 —— pw 同款）；
    ///   · 动作：把"和 tilt 等大的那个直接子视图"写成 `alpha = 0`（**同一个 `hideSpotifyCover`
    ///     的还原表**，关开关/离页时照旧写回）；
    ///   · **不做节流**：动作是局部的（几次子视图比较），比走查便宜一个量级，
    ///     而且节流正是"闪一下"的来源。
    static func coverDidLayOut(from tilt: UIView) {
        guard isEnabled, #available(iOS 26.0, *) else { return }
        // ★ `wantsOpen` 必须在门禁里（照片 66）：进页面第一拍 `isOpen` 还是 false，
        //   而那时原生封面已经在转场里动着了 —— 这条门禁原来把那一整段窗口漏掉了。
        // ★ 2026-10-04：换成 `wantsOpenNow()` —— 意图**过期**之后这里不许再按住封面，
        //   否则新封面在它自己第一次 `layoutSubviews` 就被按掉，而屏幕上什么都没有
        //   （用户报的「按键换歌漏大封面」，见 `wantsOpenUntil`）。
        guard isOpen || coverHost != nil || lastContainer != nil || wantsOpenNow() else { return }
        guard !pageLeaving else { return }
        guard tilt.window != nil, tilt.bounds.width >= 200 else { return noteCoverGuardReject() }
        guard isInsideCoverCell(tilt) else { return noteCoverGuardReject() }
        guard let cover = sameSizeChild(of: tilt), cover.alpha > 0.01 else {
            return noteCoverGuardReject()
        }
        guard let page = lastPage, page.window != nil else { return noteCoverGuardReject() }

        hideSpotifyCover(cover)

        coverLocalHides += 1
        guard coverLocalHides == 1 || coverLocalHides % 20 == 0 else { return }
        writeDebugLog(
            "[\(logTag)] hid the native cover from its own tilt (local path) — hide #\(coverLocalHides),"
                + " \(coverLocalRejects) gate rejection(s) so far"
        )
    }

    /// 门禁没过的计数 + 一次总结。
    ///
    /// ★ 为什么必须有（独立复核指出这条新路**原来一行日志都没有**）：日志里只有
    /// `[CoverGuard] armed on …`（装没装），却分不清"tilt 从来没布局过"与"布局了但门禁一直不过"。
    /// 后面那条正是照片 64 复发时最需要知道的事。
    private static var coverLocalHides = 0
    private static var coverLocalRejects = 0
    private static var reportedCoverGuardReject = false
    private static let coverGuardRejectReportAfter = 60

    private static func noteCoverGuardReject() {
        coverLocalRejects += 1
        guard !reportedCoverGuardReject, coverLocalRejects >= coverGuardRejectReportAfter else { return }
        reportedCoverGuardReject = true
        writeDebugLog(
            "[\(logTag)] the cover-tilt guard rejected \(coverLocalRejects) layout(s) and never hid anything"
                + " — check the gates (window / width / CoverArtCellImpl ancestor / same-size child)"
        )
    }

    /// pw 的 `inCoverCell(tilt)`：祖先里有 `NowPlaying_ContentLayersImpl.CoverArtCellImpl`。
    ///
    /// 为什么认这个类：contentlayer 里**真正的封面**住在 `CoverArtCellImpl` 这个 cell 里
    /// （日志 53：`10.CoverArtCellImpl@…,id=nowplaying-contentlayer-cell-5000` 换到 `-5001`），
    /// 而迷你条、列表卡片里那些 tilt 不在其内 ⇒ 一条判据同时解决"是哪张"与"要不要管"。
    ///
    /// ⚠️ 用 **`isKind(of:)`（= pw 的 `isKindOfClass:`）而不是比较类名字符串**（独立复核指出）：
    /// 字符串比较只在**恰好**是那个类时成立，Spotify 一旦派生子类就静默失效 ——
    /// 而 `NSClassFromString` 一次拿到类对象，之后 `isKind` 连子类一起认。
    /// 走查有界（8 跳），拿不到就放弃（宁可漏，不可误伤）。
    private static func isInsideCoverCell(_ tilt: UIView) -> Bool {
        guard let cellClass = coverCellClass else { return false }
        var node: UIView? = tilt.superview
        var hops = 0
        while let current = node, hops < 8 {
            if current.isKind(of: cellClass) { return true }
            node = current.superview
            hops += 1
        }
        return false
    }

    /// 只查**一个**类（不是运行时类枚举，本仓库纪律 1）。
    private static let coverCellClass: AnyClass? =
        NSClassFromString("NowPlaying_ContentLayersImpl.CoverArtCellImpl")

    /// pw 的 `coverIn(tilt)`：**和 tilt 等大的那个直接子视图**就是封面
    /// （`CoverArtTiltView 354x354 > 一个同样大小的 ElementView > ImageViewProxy >
    /// `Encore.ImageView` > 真正画图的 `UIImageView`，见 pw 那份 `PlayerArtwork.x` 的树注）。
    ///
    /// ⚠️ 用 `bounds` 比大小，不用 `frame`：tilt 被 inspect 手势转过时 `frame` 会变、`bounds` 不变
    /// （pw 同款注释，也是本仓库规矩 8）。
    private static func sameSizeChild(of tilt: UIView) -> UIView? {
        for sub in tilt.subviews where CGSizeEqualToSize(sub.bounds.size, tilt.bounds.size) {
            return sub
        }
        return nil
    }

    /// 铺一次；失败就退回"未展开"并**开重试窗口**。
    ///
    /// 所有"要展开"的入口都走这里（`apply` / `reconcile` / `toggle`）—— 免得像旧代码那样，
    /// 只有 `toggle()` 那一条路会因为**一次**失败而永久认死。
    @discardableResult
    private static func openAndMount(in page: UIView) -> Bool {
        // ★ 「屏幕上已经有我们的东西」时，这次量不到**不许改意图**。
        //   否则会出现独立只读复核点出来的那个死角：歌词明明还开着、而 `isOpen` 已经是
        //   `false` ⇒ 用户再点走的是"展开"那一支 ⇒ **关不掉**。
        //   这种情况下保持 `isOpen = true`，让 `reconcile` 的 `isOpen` 那一支每拍接着试。
        let wasLive = coverHost != nil || lastContainer != nil

        isOpen = true
        if layoutAndMount(in: page) {
            pendingOpenUntil = 0
            return true
        }
        if wasLive {
            pendingOpenUntil = 0
            return false
        }
        isOpen = false

        // ⚠️ **只武装一次**，不往后推。
        //
        // 第一版这里是 `pendingOpenUntil = now + window` 无条件重写，而 `reconcile`
        // 每 ~0.5s 就会再进来一次 ⇒ 每次失败都把 deadline 推远 ⇒ 这个"2.5s 窗口"
        // **永远不会到期**，等于在听歌页上无限轮询（独立只读复核抓到的）。
        // 真正想要的是"**从第一次失败起** 2.5s ≈ 5 拍"。
        let now = CFAbsoluteTimeGetCurrent()
        if now >= pendingOpenUntil { pendingOpenUntil = now + pendingOpenWindow }
        return false
    }

    // MARK: - 开关与几何

    /// 进场：把封面缩成缩略图、标题行上移贴边、歌词淡入到"标题之下、进度条之上"。
    ///
    /// **返回这一拍到底铺上了没有**。铺不上就**不认"已展开"**（`isOpen` 由调用方回退）——
    /// 否则会出现照片 51 那种"标题已经上移、歌词已经画出来、而原生封面还整张露着"的半成品。
    @discardableResult
    private static func layoutAndMount(in page: UIView) -> Bool {
        guard #available(iOS 26.0, *) else { return false }

        // ★ 2026-10-06：`measure()` 从"返回 `Geometry?`"改成"返回带原因的两种结局"。
        //
        // 为什么必须改：旧写法把**四种完全不同的失败**压成同一句话
        // （`cannot measure the artwork area / title row (layout not finished yet?)`），
        // 日志 50 里那唯一一次点击就只留下那一行 —— 事后**分不出**是封面没量到、
        // 还是标题行没量到、还是歌词区太矮、还是"标题行已经在缩略图线上方"。
        // 仓库规矩是「静默分支不许静默」，这里是它的变体：**一个分支不许盖住四种死法**。
        let geometry: Geometry
        switch measure(in: page) {
        case .ok(let measured):
            geometry = measured
        case .failed(let reason):
            noteSkip(reason)
            return false
        }

        // ★ 2026-10-06：把"这一首有没有得画"这道门**提到所有副作用之前**。
        //
        // 它只读歌词模型与播放器状态，**不碰任何视图**；而下面 ①②③ 全是**副作用**
        // （藏掉 Spotify 那条封面、位移标题行、建我们的容器）。旧顺序把这道门放在 ①②③
        // **之后** ⇒ 那一步一旦失败就会留下"封面藏了、标题移了、而 `isOpen` 还是 false"
        // 的半成品（只能等离页时 `closeEverything` 去收）。
        // ⚠️ 本轮加了重试窗口之后这一点更要紧：这条路径一晚会走好几回。
        // ★ 2026-10-11（用户要求）：**没有歌词可画时不再"点了没反应"** ——
        //   键照样能开，打开之后在歌词的位置居中写一句说明。
        //   于是这里从"必须要行模型"放宽成"要么有行，要么有一句可说的事"。
        let notice = noticeText()
        guard let trackId = currentTrackId() else {
            noteSkip("no track id yet (the player has not reported one)")
            return false
        }
        let timedLines = currentLines() ?? []
        // ★ 2026-10-11（用户问的「歌词呢」+「不是复用有时间轴的逻辑吗」）：
        //   **没有时间轴**那一档不再自己画——把文本包成**合成行**（时间全 0、无音节）
        //   交给**同一个渲染层**，由 `isStatic` 告诉它"不高亮、不跟随、点行不跳"。
        //   这样字号 / 行距 / 左右内边距 / 滚动 / 底部留白（120pt，正好躲开控件条）全部同一套。
        let staticTexts = currentUntimedLines()
        let isStatic = timedLines.isEmpty && staticTexts != nil
        let lines = isStatic ? Self.staticLines(from: staticTexts ?? []) : timedLines
        if lines.isEmpty, notice == nil {
            noteSkip("no lyric lines to draw right now (the line model is not ready)")
            return false
        }

        // ① 我们自己那份封面（同一张图，所以"换"看不出来）+ **把它动画到缩略图**。
        //    ⚠️ **它必须成功**：失败时原生封面就还露着，而下面两步会照样跑
        //    ⇒ 歌词与上移后的标题会被画在封面图上（照片 51 就是现场）。所以这里直接不展开。
        //    pw 也是这个取舍：*"without a picture there would be a hole where the cover was,
        //    so the cover stays and the lyrics wait."*
        guard let coverHostView = ensureCover(in: page, geometry: geometry),
              let coverImageView = coverImage else {
            // ⚠️ 这行原来是中文 + **ASCII 双引号**做强调（`与"藏起原生封面"都做不了`），
            //    字面量被那两个引号提前截断 ⇒ CI 报 `expected ',' separator` /
            //    `cannot find '藏起原生封面' in scope` / `extra argument in call`。
            //    **日志文案一律用英文**（用户 2026-10-05 定下的规矩），中文强调改用「」也不会再踩这个坑。
            noteSkip("no artwork for this track (cannot build the thumbnail or hide Spotify's cover) - not opening")
            return false
        }
        applyCoverState(open: true, host: coverHostView, imageView: coverImageView, geometry: geometry)

        // ② 标题行上移 + 右移（transform —— 改约束会被 stack view 布局写回）。
        applyTitleTransform(geometry: geometry, page: page)

        // ②b ★ 2026-10-11（用户）：**歌手右边写上歌词提供商**——`歌手（提供商）`。
        //     只在这条"展开"的路上贴；收起时由 `settleAfterClosing` 还原。
        applyProviderToArtistLine(in: page)

        // ③ 歌词区：标题之下、进度条之上。
        //
        // ★ 2026-10-13（用户）：「把滚动歌词的下部分抬高，确保歌词不会穿过这个上传者什么的」
        //   —— 底部先为**底沿那行署名**让出 `stageBottomReserve`（≈62pt，见那几个常量）。
        //   不让的话最后几行会从署名底下穿过去：照片 98 里罗马字与日文那两行正好压在
        //   "Spicy Lyrics" 上。收窄容器（而不是只加内部留白）的好处是**底部渐隐带**
        //   也跟着上移，于是"最后一行淡出"和"署名"不会落在同一块区域里。
        var frame = geometry.stage
        frame.size.height = max(0, frame.size.height - Self.stageBottomReserve(for: geometry.stage))
        guard frame.height > livingHeight / 2 else {
            noteSkip("no room between the title and the progress bar (\(Int(frame.height))pt)")
            return false
        }

        let container = ensureContainer(in: page, frame: frame)
        applyEdgeFade(to: container)
        // ★ 2026-10-13：歌词区**底沿**那条可点署名（Spicy Lyrics 条款 §6）。必须在
        //   `ensureContainer` 之后 —— 它要把自己 `bringSubviewToFront` 到容器上面才点得到。
        ensureCreditLabel(in: page, lyricsFrame: frame)
        // ★ 2026-10-11：说明文案写在这一块**正中间**（用户原话：「写歌词的正中间最好」）。
        applyNoticeLabel(notice, in: container)

        if let host = currentHost(for: page) {
            let version = currentLyricsVersion
            if host.isCurrent(version: version, trackId: trackId, isStatic: isStatic) {
                // 最新 → 这一拍只驱动时间轴。
            } else if host.isAttached {
                host.updateLines(lines, version: version, trackId: trackId, isStatic: isStatic)
            } else {
                host.mount(
                    in: container,
                    lines: lines,
                    version: version,
                    trackId: trackId,
                    isStatic: isStatic,
                    onSeek: { seconds in
                        // ★ 2026-10-11（用户：「我选中某一行歌词，定位到上一行歌词去了」）：
                        //   这里以前是**另写的一份** `Int((seconds * 1000).rounded())` ——
                        //   少了那 5ms ⇒ 落在行边界上 ⇒ 被判成上一行。
                        //   现在两处都走 `seekToTappedLyricLine`（定义在
                        //   `AppleMusicLyricsOverlay.swift` 开头，理由都写在那儿）。
                        seekToTappedLyricLine(seconds)
                    }
                )
            }
            host.tick(seconds: WordByWordPositionResolver.shared.currentPositionSeconds())
            // ★ 2026-10-08：逐词歌词改用**每帧**驱动（原来只有那条 0.5s 的复查节拍 ⇒ 2Hz ⇒ 一格一格跳）。
            //   占不到共享时钟就不抢，退回节拍（有日志）。
            host.usePerFrameClockIfAvailable()
        }

        if !didLogInstall {
            didLogInstall = true
            // ⚠️ 不要用嵌套的双引号字面量（`\(a ? "x" : "y")` 那种）—— 本仓库第 6 条自检
            //    `swift_string_check.py` 是按"闭合引号后面跟了什么字符"扫的，嵌套字面量会被它
            //    当成"字符串被提前关掉"（2026-10-05 那次 CI 红就是这么来的）。先算成变量再插。
            let titleNote: String
            if geometry.titleRow == nil {
                titleNote = "not found (no lift, expanding anyway)"
            } else {
                titleNote = "lifted \(Int(geometry.lift))pt / shifted \(Int(geometry.shift))pt"
            }
            let staticNote: String
            if isStatic {
                staticNote = " static lyrics \(lines.count) line(s) (this track has no timeline;"
                    + " same renderer, static mode)"
            } else {
                staticNote = ""
            }
            // ★ 2026-10-11（用户：「把罗马字和歌词翻译接上去吧」）：这两档各写了多少行也打进日志 ——
            //   否则下一次又是"接了没生效、不知道卡在哪"（译文要过设置那道门、罗马字要过语言那道门）。
            let translationCount = lines.filter { $0.translation?.isEmpty == false }.count
            let romanizationCount = lines.filter { $0.romanization?.isEmpty == false }.count
            let supplementalNote = " translation \(translationCount)/\(lines.count)"
                + " romanization \(romanizationCount)/\(lines.count)"
            writeDebugLog(
                "[\(logTag)] expanded — thumbnail \(Int(geometry.thumb.width))pt at \(frameText(geometry.thumb)), "
                    + "lyrics area \(frameText(frame)), cover shrunk in from \(frameText(geometry.cover)), "
                    + "title row \(titleNote)"
                    + staticNote
                    + supplementalNote
                    // ★ 2026-10-11：三个锚点的**实测值**（`measure()` 里算的，这里只管打印）——
                    //   照片 67→68 那两片几何全靠它对齐，下一份日志一眼就能看出量到没有。
                    + " " + lastAnchorText
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
        // ⚠️ 这三行必须在那个 `guard` **之前**：重试窗口要在"关掉 / 离开页面"时**无条件**清掉，
        //    否则页面都走了它还挂着一个 deadline（虽然 `page.window` 会挡住，但账要算清）。
        let hadSomethingVisible = isOpen || lastContainer != nil || coverHost != nil
        isOpen = false
        wantsOpen = false
        wantsOpenUntil = 0
        pendingOpenUntil = 0
        pageLeaving = false
        // ★★ 2026-10-11 第二轮（修用户报的「短暂重合」，照片 74 就是那一帧）：
        //   "关着的样子"（控件条 + 标题行贴左上角）**必须最后摆**。
        //
        //   以前这一段放在这里（函数中段），而下面还有一句
        //   `lastUnit?.transform = .identity`（撤销展开时那段位移）—— 它会把我们刚摆好的
        //   "标题去左上角"**当场撤销** ⇒ 关掉之后的 0.3s 里标题回到**原生位置**（618），
        //   正好压在控件条第 ① 处的分享键（58,626）上。用户拍的正是那一帧。
        //
        //   用 `defer`：无论从哪条路返回（含"没铺过东西"的提前 return）都在**最后**执行一次，
        //   而且它自己会判断"页面还在不在"，见 `settleAfterClosing()`。
        defer { settleAfterClosing() }
        // 封面判据的日志预算**按"一次开合"重置** —— 否则开合三次就把 12 行用光，
        // 正好在下一个 bug 出现时看不见了（独立复核指出）。
        chosenCoverLogs = 0
        lastLoggedCover = nil
        guard hadSomethingVisible else { return }

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

        // 标题行的位移**不在这里撤** —— 见 `settleAfterClosing()`：
        //   页面还在时要让那一行**从缩略图右边滑回左上角**（用户要的动画），
        //   先在这儿撤成 identity 就会先跳一下（照片 74 那 0.3s 的重合就是这么来的）。
        clearTitleMask()
        lastTitleElement = nil

        if #available(iOS 26.0, *) {
            (host as? NowPlayingLyricsHost)?.detach()
        }
        lastContainer?.removeFromSuperview()
        lastContainer = nil
        // ★ 2026-10-13：署名跟着歌词一起收（它只在展开态出现，见 `ensureCreditLabel`）。
        removeCreditLabel()
        didLogInstall = false
        writeDebugLog("[\(logTag)] collapsed (reason=\(reason))")
    }

    /// `closeEverything` 的最后一步（`defer` 里跑）：决定"关掉之后屏幕上是哪一副样子"。
    ///
    /// 两种结局：
    ///   · **页面还在窗口里**（功能也开着）⇒ 摆"关着的样子"：控件条就位、标题行回左上角。
    ///     这里**故意不先撤**展开时那段位移 —— 让那一行直接从"缩略图右边"滑到左上角
    ///     （用户 2026-10-11 要的动画；以前是先跳回原生位置再被下一拍挪走 = 照片 74 那 0.3s 的重合）。
    ///   · **页面不在 / 功能关了** ⇒ 把写在别人视图上的两段位移**全部撤掉**
    ///     （这也是原来那句 `lastUnit?.transform = .identity` 的职责）。
    private static func settleAfterClosing() {
        // ★ 2026-10-04：**「（提供商）」跟着页面走**，不再跟着"展开 / 收起"走。
        //
        // 用户这次报的第 2 条是「歌词提供商并没有在歌手的后面展示」，并选了
        // **"展开和收起都显示"** ⇒ 这一段以前那句无条件 `restoreArtistLine` 就是反的：
        // 它把收起态（也就是用户平时看到的那一屏）的提供商摘掉了。
        // 现在只在**页面要走 / 功能关了**时摘；页面还在就留着，下面那段会把它摆回去。
        let pageStays = isEnabled && (lastPage?.window != nil)
        if !pageStays, let page = lastPage {
            restoreArtistLine(in: page)
        }

        if pageStays, let page = lastPage {
            applyControlBand(in: page)
            applyProviderToArtistLine(in: page)
            if applyClosedTitleTransform(in: page) {
                lastUnit = nil
                lastTitleElement = nil
                return
            }
        }
        // 兜底：摆不上（量不到导航条 / 找不到那一行）或页面已经不在 ⇒ 把两段位移都撤掉，
        // 别留在别人的视图上（"关着态"那两段由 `clearClosedTitleTransform` 管）。
        if let row = lastUnit, row.transform != .identity { row.transform = .identity }
        if let element = lastTitleElement, element.transform != .identity {
            element.transform = .identity
        }
        lastUnit = nil
        lastTitleElement = nil
        clearClosedTitleTransform()
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

    /// `measure()` 的两种结局（见 `layoutAndMount` 里那段说明）。
    private enum MeasureOutcome {
        case ok(Geometry)
        case failed(String)
    }

    private static func measure(in page: UIView) -> MeasureOutcome {
        guard page.bounds.height >= livingHeight else {
            return .failed(
                "the page is too short to hold lyrics (\(Int(page.bounds.height))pt < \(Int(livingHeight))pt)"
            )
        }
        guard let list = findByIdentifier(listIdentifier, in: page) else {
            return .failed("cannot find the player list (\(listIdentifier)) inside the page")
        }

        // 封面：列表子树里第一个**看得见**的 `Encore.ImageView`，且宽度像封面（>=200）。
        // ⚠️ 这一条**必须**在列表里找：封面是列表里那些格子的内容。
        guard let coverView = visibleCover(in: list, page: page) else {
            return .failed("cannot find a visible artwork wide enough (>=200pt) inside the player list")
        }
        let cover = coverView.convert(coverView.bounds, to: page)

        // 标题行：`now-playing-title-label` 所在的那个 element 视图 + 它的父行。
        //
        // ★ 2026-10-06：改从 **`page`** 找（以前只从 `list` 找）。
        //
        // ⚠️ **先纠正一条我读错过、差点写进文档的结论**：
        //    「那一行在 `npv.bottomStackView` 里，而那一坨是列表的兄弟 ⇒ 从 `list` 永远找不到」
        //    —— **这是错的**。日志 49（旧代码）明明展开成功过：
        //    `歌词区 20,204,374,346` ⇒ `barTop = 346 + 8 + 204 = 558`，
        //    正好等于 `npv.bottomStackView` 的顶边 ⇒ `bottomStackTop(in: list)` 当时**找得到**它
        //    ⇒ 那一坨**就在列表子树里**，标题行自然也找得到。
        //    真正让日志 50 点不开的是 `isOpen` 被一次失败清掉之后**再也不重试**
        //    （见 `openAndMount` 与 `pendingOpenUntil`）—— 那是一个**本轮新引入的回归**。
        //
        // 那为什么还是改？因为从 `page` 找是**严格超集**……**但只在预算够的时候才是**：
        // `findByIdentifier` 有 `maxNodes = 800`，而 BFS 是**先宽后深** —— 从 `page` 起走
        // 要先趟过整页的宽度（那些卡片）才轮到这一行的深度。所以顺序是
        // **先 `list`（日志 49 已证明走得通、子树小得多），再 `page` 兜底**。
        // （独立只读复核抓到的：反过来写有可能因为预算耗尽而**比原来更差**。）
        let titleLabel = findByIdentifier(titleLabelIdentifier, in: list)
            ?? findByIdentifier(titleLabelIdentifier, in: page)
        let titleElement = titleLabel?.superview
        let titleRow = titleElement?.superview

        // 缩略图：贴"封面区"左上 —— 我们用封面自己的左上 + `thumbTop`（pw 用 `SGRPlayerArtworkAreaIn`，
        // 我们量不到那个 band，就用封面的顶；差别只是几 pt，且换歌会重算）。
        // ⚠️ **`leading` 必须夹住**：`titleElement` 现在**真的量得到**了（以前这条路几乎总是
        //    走 `?? (cover.minX + 20)`），而它可能是个 marquee（`transform.tx` 是**模型值**、
        //    `UIView.animate` 会立刻写上去）或者右对齐的行 ⇒ 量出来的 `minX` 可能是负的、
        //    或者每拍都在跳。它直接喂给 `thumbTransform`，后果有两条：
        //      ① 缩略图飞到画面外；② `applyCoverState` 的收敛判据是**精确比较**，
        //      每拍一个新 `target` 就会每 0.5s 重启一次 0.45s 的动画
        //      （看起来就是"封面永远停不下来"）。
        //    （独立只读复核抓到的。）
        let rawLeading = titleElement.map { untransformed($0, in: page).minX } ?? (cover.minX + 20)
        let leading = min(
            max(rawLeading, page.bounds.minX + stageSideInset),
            page.bounds.maxX - thumbSide - stageSideInset
        )
        // ★ 2026-10-11（照片 67 → 68）：缩略图**不再跟着原生封面**，改成**贴导航条下沿**。
        //
        // 原来 `thumb.y = cover.minY + 8`：日志 55 的 `cover.minY = 161` ⇒ 169，
        // 也就是把 96（导航条下沿）到 161 那 **65pt 白扔**；而 kumone 的 header 是贴着自己那根
        // 横条下面的（67–133）。我们上面有 Spotify 的 96pt 导航条躲不开 ⇒ 目标 = 96 + 8 = 104
        // （能达到的最近位置）。导航条用 **id** 量（`now-playing-minimize-button`），
        // 量不到就退回旧算法（宁可回到旧行为，也不要一张都摆不出来）。
        let navBottom = navBarBottom(in: page)
        let thumbY = navBottom.map { $0 + thumbTop } ?? (cover.minY + thumbTop)
        let thumb = CGRect(
            x: leading,
            y: thumbY,
            width: thumbSide,
            height: thumbSide
        )

        // 标题行：缩略图右侧垂直居中（找不到标题就贴在缩略图下面）。
        let rowFrame = titleRow.map { untransformed($0, in: page) }
        let top = rowFrame.map { thumb.midY - $0.height / 2 } ?? (thumb.maxY + 12)
        let lift = top - (rowFrame?.minY ?? top)
        // ★ 2026-10-04（用户：「当歌曲名字过长时…右侧的晃动区超过屏幕的右侧了」）：
        //   右移给缩略图让位的量**不许把那一行的右边缘推出屏幕**。
        //   算术（真机：页面 414pt、那一行 308pt、原来 72+16）：28+72+16+308 = **424 > 414**
        //   ⇒ 长标题的 marquee 有 10pt 在屏幕右边之外（这就是用户报的那一条）。
        //   常量已经收到 64+12（= 412，正好进得去），这里再夹一道**上限**兜别的机型/更宽的行：
        //   右边缘最多到页面右沿 − 4pt —— 宁可挤掉几 pt 的 gap，也不许晃动区出屏。
        let wantedShift = thumbSide + thumbGap
        let shiftLimit = (page.bounds.maxX - 4) - (rowFrame?.maxX ?? page.bounds.maxX)
        let shift = rowFrame == nil ? 0 : max(0, min(wantedShift, shiftLimit))

        // 歌词区：缩略图/标题之下 → **进度条之上**。
        //
        // ★ 2026-10-11：原来锚在 `npv.bottomStackView` 的**顶边**（≈593）⇒ 歌词 261–584，
        // 而进度条在 ≈680 ⇒ 中段白空 80–100pt；kumone 是"歌词一直排到进度条上方 19pt"
        // （623 / 642）。改成锚**进度条单元**的顶边（id），量不到才退回旧锚点。
        let stageBottom: CGFloat
        let progressTop = progressUnitTop(in: list, page: page)
        // 这一次走查**同时**服务"退路"与日志（别为了打日志再走一遍）。
        let stackTop = bottomStackTop(in: list, page: page)
        if let progressTop {
            stageBottom = progressTop - lyricGapAboveProgress
        } else {
            stageBottom = (stackTop ?? (page.bounds.height - 240)) - lyricsBottom
        }
        // 三个锚点的实测值（只给 `[NPVLyrics] expanded — …` 那一行用；**不编造**：量不到就打 not found）。
        lastAnchorText = "(anchors: navBottom=\(anchorText(navBottom)),"
            + " progressTop=\(anchorText(progressTop)),"
            + " bottomStackTop=\(anchorText(stackTop)))"
        let stageTop = max(thumb.maxY, top + (rowFrame?.height ?? 0)) + lyricsTop
        let stage = CGRect(
            x: stageSideInset,
            y: stageTop,
            width: page.bounds.width - stageSideInset * 2,
            height: stageBottom - stageTop
        )

        guard stage.height > livingHeight / 2 else {
            return .failed("the lyrics area would be too short (\(Int(stage.height))pt)")
        }
        // ⚠️ ★ `lift` **只有量到标题行时**才配当判据。
        //
        // 量不到标题行时，上面那句 `let lift = top - (rowFrame?.minY ?? top)` 恒等于 **0**
        // —— 旧代码写的是 `guard …, lift < 0`，于是这条判据**自己把自己否掉**，
        // 报出来的还是"量不到封面/标题行"那句更含糊的话：一个 nil 合并表达式
        // 悄悄变成了一条"永远失败"的判据。
        // 量不到标题行 = 这一页没有要上移的东西 ⇒ **照常展开**，只是不做标题位移。
        //
        // ⚠️ 反过来，`rowFrame != nil && lift >= 0` 这条**必须留着**：日志 50 那次失败
        // 极可能就是它 —— 那一拍 `npv.bottomStackView` **已经在树里但还没落位**
        // （frame 还在 (0,0)）⇒ `rowFrame.minY ≈ 0` 而 `top ≈ 缩略图中线` > 0
        // ⇒ `lift > 0` ⇒ 拒绝。这一条**不能放宽**（把一个还没落位的标题行"上移"到
        // 错的地方比不展开更糟），要治的是"下一秒再试一次"—— 那正是 `openAndMount` 的窗口。
        if rowFrame != nil, lift >= 0 {
            return .failed("the title row has not settled yet (lift=\(Int(lift))pt) - will retry next tick")
        }

        return .ok(Geometry(
            cover: cover,
            thumb: thumb,
            stage: stage,
            lift: lift,
            shift: shift,
            titleRow: titleRow,
            titleElement: titleElement
        ))
    }

    /// 列表里那个"看得见的封面"。**三趟**，一趟比一趟宽。
    ///
    /// **第一趟（最硬）**：必须**在 `SPTNowPlayingView` 里面**，且祖先里没有被折成 0 的。
    ///
    /// `id=SPTNowPlayingView` 是**结构性身份**，不是几何猜的：真机 `[NPVTree]` 里
    /// 播放器的每一件都在它里面 —— 底部那一坨（level 8）、进度条（13）、三颗按钮（14）、
    /// 标题行（15）；而**卡片自己的封面**（`7.ImageView@0,-62,374,374`）在 level 7、
    /// 与它**平级**，**不在它里面**。这个 id 从 2026-09-30 起每一份日志都有。
    ///
    /// **第二趟**：只要"祖先里没有被折成 0 的"（= 上一版的做法）。
    /// **第三趟**：旧判据（**宁可回到老行为，也不要一张都挑不出来**）。
    private static func visibleCover(in list: UIView, page: UIView) -> UIView? {
        if let owner = findByIdentifier(nowPlayingViewIdentifier, in: page),
           let inside = firstVisibleCover(in: list, skippingCollapsedAncestors: true, inside: owner) {
            noteChosenCover(inside, tier: "inside SPTNowPlayingView")
            return inside
        }
        if let strict = firstVisibleCover(in: list, skippingCollapsedAncestors: true) {
            noteChosenCover(strict, tier: "no collapsed ancestor")
            return strict
        }
        guard let fallback = firstVisibleCover(in: list, skippingCollapsedAncestors: false) else {
            return nil
        }
        noteChosenCover(fallback, tier: "legacy predicate")
        return fallback
    }

    /// 一趟有界 BFS。`skippingCollapsedAncestors = true` 时跳过"祖先里被折成 0 的"那些；
    /// `inside` 非空时只认它的后代。
    ///
    /// ★ 2026-10-04（用户：「按键换歌漏大封面」+「封面有时候加载失败」）：
    ///   **优先挑"这一趟里真的落在页面范围内"的那一张。**
    ///
    ///   现场（真机日志逐字）：`artwork picked … 366×366 at -369264,147,366,366` ——
    ///   页面里同时存在两个同尺寸的 `Encore.ImageView`，BFS 挑中的那个 x 是 **-369264**：
    ///   它 `window != nil`（所以老判据认它），可它**整张在屏幕外**。
    ///   `hideSpotifyCover` 于是把 `alpha = 0` 写在它身上 ⇒ **屏幕上那张封面一点没变**
    ///   （"漏了/还在"两种说法都是这个），而且 `measure()` 也会拿它的 frame 当地理。
    ///
    ///   ⚠️ 只用来**挑**，不做硬门禁：一趟走完只有离屏那一张 ⇒ 照旧用它
    ///   （转场中途真封面也可能暂时飞到页面外 —— 宁可漏，不误判）。
    private static func firstVisibleCover(
        in list: UIView,
        skippingCollapsedAncestors: Bool,
        inside owner: UIView? = nil
    ) -> UIView? {
        var visited = 0
        var queue: [UIView] = [list]
        var firstCandidate: UIView?

        while !queue.isEmpty, visited < maxNodes {
            let view = queue.removeFirst()
            visited += 1

            if view.accessibilityIdentifier == coverImageIdentifier,
               !view.isHidden,
               view.alpha > 0.01 || isHiddenByUs(view),
               view.window != nil,
               view.bounds.width >= 200,
               isInsideOwner(owner, view),
               !(skippingCollapsedAncestors && hasCollapsedAncestor(view, root: list)) {
                if isWithinReach(view, host: list) { return view }
                if firstCandidate == nil { firstCandidate = view }
            }
            // hidden 的子树不往下走（离屏的那些封面一格一个，不必要）。
            if view.isHidden { continue }
            queue.append(contentsOf: view.subviews)
        }
        return firstCandidate
    }

    /// 这个视图**是不是落在宿主画得出的范围里**（给 80pt 的容差：转场中途的位移不算"跑飞了"）。
    ///
    /// 与 `isOnScreen(_:in:)` 同一套想法，区别是宿主可以是列表（走查那一层手里只有列表），
    /// 而且**带容差** —— 这一条只用来排序候选，不该把"正在飞进来的封面"判死。
    private static func isWithinReach(_ view: UIView, host: UIView) -> Bool {
        let frame = untransformed(view, in: host)
        guard frame.width >= 1, frame.height >= 1 else { return false }
        return frame.intersects(host.bounds.insetBy(dx: -80, dy: -80))
    }

    /// `owner` 为空 ⇒ 不设限；否则要求 `view` 是它的后代（`isDescendant(of:)` 含"就是自己"）。
    private static func isInsideOwner(_ owner: UIView?, _ view: UIView) -> Bool {
        guard let owner else { return true }
        return view.isDescendant(of: owner)
    }

    /// 这个视图**在祖先里有没有被"折没"**：任一祖先 `hidden`，或者 `bounds` 退化到 0。
    ///
    /// ⚠️ **不看 `alpha`**：`hideSpotifyCover` 会把**已经被我们藏起来的那张**写成 `alpha = 0`，
    ///    而下一拍 `measure()` 还得能再认出它来（隐藏名册在 `hiddenCovers` 里）。
    ///    这里只判"几何上被折没了"，那是「一屏」留下的唯一痕迹。
    ///
    /// 走查有界（32 跳，本仓库纪律），到 `root` 为止。
    private static func hasCollapsedAncestor(_ view: UIView, root: UIView) -> Bool {
        var node: UIView? = view
        var hops = 0
        while let current = node, hops < 32 {
            if current !== root {
                if current.isHidden { return true }
                if current.bounds.height < 1 || current.bounds.width < 1 { return true }
            }
            if current === root { break }
            node = current.superview
            hops += 1
        }
        return false
    }

    /// ★ **被我们自己藏起来的那张也算合格** —— 这是上面那条判据能活过第二拍的**前置条件**。
    ///
    /// `ensureCover` 在展开的那一刻就把 Spotify 那张主封面的 `alpha` 写成 0
    /// （`hideSpotifyCover`，同图所以看不出"换"），而 **`layoutAndMount` 每一拍都要重跑**
    /// ⇒ 下一拍 `visibleCover` 必须还能再认出它来。不认它的话：
    /// 严格那一趟一张都挑不到 → 退回旧判据 → 又去挑那张**卡的**封面 → `lift` 又变正数
    /// ⇒ **展开撑不过半秒**。（独立只读复核点出来的，本轮修法的前置条件。）
    private static func isHiddenByUs(_ view: UIView) -> Bool {
        // ★ 2026-10-12：问**静态名册**（`hiddenCovers`），不再问页面 ——
        //   `lastPage` 是 weak，页面一没这里就会答"不是我们藏的"，于是展开撑不过半秒；
        //   名册本身也不该依赖"哪一页"（见名册那段的两条理由）。
        hiddenCovers.contains(view)
    }

    /// 挑中的封面**换了就报一行**（上限 `chosenCoverLogLimit` 行）。
    ///
    /// 为什么不是"整个会话只报一次"：`visibleCover` 有两个调用时机 ——
    /// 页面开着时 `rememberArtworkIfNeeded` 顺手认一次、点的那一刻 `measure()` 再量一次。
    /// **这两次挑中的可能不是同一个**，而"挑错了"正是日志 50/51 的病根 ⇒
    /// 必须看得见"换了"。有限次，不会刷屏。
    private static weak var lastLoggedCover: UIView?
    private static var chosenCoverLogs = 0
    private static let chosenCoverLogLimit = 12

    private static func noteChosenCover(_ view: UIView, tier: String) {
        guard lastLoggedCover !== view else { return }
        lastLoggedCover = view
        guard chosenCoverLogs < chosenCoverLogLimit else { return }
        chosenCoverLogs += 1
        // ⚠️ 不要写 `rect.map(frameText)`：那是把一个 `@MainActor` 静态方法当函数值传，
        //    本仓库的编译器版本只保证"最多一个警告"，没必要冒这个险（独立复核指出）。
        let where_: String
        if let page = lastPage {
            where_ = frameText(view.convert(view.bounds, to: page))
        } else {
            where_ = "?"
        }
        writeDebugLog(
            "[\(logTag)] artwork picked \(NSStringFromClass(type(of: view)))"
                + " \(Int(view.bounds.width))×\(Int(view.bounds.height))"
                + " at \(where_)"
                + " (tier=\(tier))"
        )
    }

    /// 底部那一坨的顶边（页面坐标系）。
    ///
    /// ★ 2026-10-06：**先认"从 `page` 直接量"**（`convert` 出来就是页面坐标，最准），
    /// 找不到才退回老那套"列表 + `layer.position`"的算法。
    ///
    /// ⚠️ 这不是"修 bug"，是**加固** —— 老算法在日志 49 是有效的
    /// （`stage` 的底边 558 正好等于那一坨的顶边）。它的问题只在**找不到时的退路**：
    /// `page.bounds.height - 240` 是个硬编码猜值（日志 50 里是 656），而那一坨的顶边是
    /// `558` ⇒ 猜值比真值**低约 97pt**，歌词区会一路画到标题行 / 进度条 / 控件上。
    /// 两个消费者（`toggleFrame` / 底部音量条）都是用 `page` 那一跳才稳的，这里跟它们对齐。
    private static func bottomStackTop(in list: UIView, page: UIView) -> CGFloat? {        if let stack = findByIdentifier(bottomStackIdentifier, in: page) {
            let top = stack.convert(stack.bounds, to: page).minY
            if top > 0, top < page.bounds.height { return top }
        }
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

    // MARK: - 两个新锚点（2026-10-11：照片 67 → 68 的几何对齐）

    /// 导航条的下沿（pt，页面坐标系）。
    ///
    /// 判据是 **id**：`now-playing-minimize-button`（真机每一份 `[NPVTree]` 里都有
    /// `Tertiary@0,0,48,48,id=now-playing-minimize-button`）——
    /// 不按类名（`Tertiary` 全页好几颗）、不按几何猜。
    private static func navBarBottom(in page: UIView) -> CGFloat? {
        guard let button = findByIdentifier(minimizeButtonIdentifier, in: page) else { return nil }
        let frame = untransformed(button, in: page)
        guard frame.maxY > 0, frame.maxY < page.bounds.height / 2 else { return nil }
        return frame.maxY
    }

    /// 进度条单元的顶边（pt，页面坐标系）。
    ///
    /// 判据同样是 **id**：`Components.UI.ProgressBarUnitNowPlaying`
    /// （真机树里 `AutoLayoutStackView@0,0,358,41,id=…`）。
    /// 先在这一页的列表里找，再在整页找 —— 它在不在列表子树里，不同构建不一样
    /// （`bottomStackTop` 的注释里记过同一类问题）。
    private static func progressUnitTop(in list: UIView, page: UIView) -> CGFloat? {
        for root in [list, page] {
            guard let unit = findByIdentifier(progressUnitIdentifier, in: root) else { continue }
            let frame = untransformed(unit, in: page)
            guard frame.minY > 0, frame.minY < page.bounds.height else { continue }
            return frame.minY
        }
        return nil
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
    // MARK: - 收起态的大封面尺寸（用户 2026-10-04：「把现在的大封面做小，不需要那么大」）

    /// 收起态那张大封面的目标宽度（pt）—— **kumone 照片 41 逐像素量出来的 242pt**
    /// （原图 591×1280px：x 122…467、y 291…639 ⇒ ×0.7005 = 242.1pt 见方，水平居中、顶边 ≈204pt）。
    /// 我们原来是 **366pt**（Spotify 的 `24,146,366,366`），比它大 51%。
    ///
    /// 为什么只动 `transform`：收起态那张是 **Spotify 自己的**（我们那份只在展开时存在），
    /// 所以尺寸只能这么收 —— 仓库规矩 14：改别人的视图**只做 transform / 透明度**，
    /// 动完要能**完全还原**（原值记在 `scaledCoverBase`，离开页面 / 关开关时写回）。
    ///
    /// 附带三件事：
    ///   ① `measure()` 用的是 `convert`（**含 transform**）⇒ `geometry.cover` 自动变成 242pt，
    ///      `thumbTransform` 的缩放比与动画起点跟着对（缩略图仍是 64pt，因为它按宽度比算）；
    ///   ② 封面顶边落到 ≈208pt ⇒ 收起态标题行（98…149）离它有 59pt
    ///      —— 用户报的「大封面压住歌手名字下半截」一并消失（`closedTitleCoverGap` 只是兜底）；
    ///   ③ **展开 / 收起两个状态都摆**：换歌会换一个新的封面对象（`-5000 → -5001`）。
    private static let restingCoverSide: CGFloat = 242

    /// 我们缩过的那几张封面（**弱引用**：视图被回收就自动出册）+ 各自**自己的**原 transform。
    ///
    /// 为什么是"复数"：真机日志 57 里**同一页会挑出不同的封面候选**（见 `applyCoverRestingScale`），
    /// 只盯一个对象会让被换下去的那张弹回 366pt。
    private static let scaledCovers = NSHashTable<UIView>.weakObjects()
    private static var scaledCoverBase: [ObjectIdentifier: CGAffineTransform] = [:]

    /// 每拍把当前那张主封面**缩到 `restingCoverSide`**（见上面那段）。
    ///
    /// ⚠️ 只在真的不一样时才写：`CoverArtTiltView` 那条链上本来就有别人的 transform
    ///    （倾斜），每拍无条件重写会把它们打断 —— 与 `applyCoverState` 旁边那条教训同源。
    private static func applyCoverRestingScale(in page: UIView) {
        guard restingCoverSide > 1,
              let list = findByIdentifier(listIdentifier, in: page),
              let cover = visibleCover(in: list, page: page) else { return }

        // ★ 2026-10-12（独立复核）：**只缩"播放器自己那一张"。**
        //   `visibleCover` 的兜底那两趟能挑到**卡片**的封面（它自己的注释里写着
        //   "卡片自己的封面不在 `SPTNowPlayingView` 里"）—— 把卡片那张缩了就成了新的 bug。
        //   挑不到主封面就**什么都不做**（宁可这一拍还是 366pt，也不许缩错对象）。
        if let owner = findByIdentifier(nowPlayingViewIdentifier, in: page),
           !cover.isDescendant(of: owner) {
            return
        }

        // ★ 2026-10-12：**按对象记账，而且记的不止一个。**
        //
        // 为什么不是"上一个 / 这一个"两个变量：真机日志 57 里**挑中的封面会换**
        // （同一页里一会儿 `-369264,147,366,366`、一会儿 `24,147,366,366`）。
        // 只盯一个对象的话，"这一拍挑中另一个"就会把上一个**还原成 366pt**
        // —— 而屏幕上正显示的可能正是它 ⇒ 用户会看到封面在大小之间来回跳。
        // 现在：凡是被我们缩过的都记在册（`NSHashTable` 弱引用，视图没了自动出册），
        // 每拍把它们都摆到目标尺寸；离开页面 / 关开关时**逐个**还回各自的原值。
        if scaledCoverBase.count > 2 {
            // 出册的条目要清掉：`ObjectIdentifier` 是地址，视图释放后地址可能被新视图复用。
            let live = Set(scaledCovers.allObjects.map { ObjectIdentifier($0) })
            scaledCoverBase = scaledCoverBase.filter { live.contains($0.key) }
        }

        let key = ObjectIdentifier(cover)
        if scaledCoverBase[key] == nil {
            // **第一次**接管这一张：把它自己的 transform 记下来（还原用的就是它，不假设是恒等）。
            scaledCoverBase[key] = cover.transform
        }
        scaledCovers.add(cover)
        let base = scaledCoverBase[key] ?? .identity

        let natural = cover.bounds.width
        guard natural > 1 else { return }
        let scale = min(1, restingCoverSide / natural)
        // 先让它自己那一套（多半是恒等）作用完，再叠我们的等比缩放 —— 两者都关于锚点（默认中心）。
        let wanted = base.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        if cover.transform != wanted { cover.transform = wanted }
    }

    /// 把封面还回**它自己的** `transform`（关开关 / 离开页面 / 页面收尾 —— 不是"收起歌词"）。
    ///
    /// ⚠️ 收起歌词时**不许**调它：那时我们要的正是"缩小的封面"。
    private static func restoreCoverScale() {
        for cover in scaledCovers.allObjects {
            guard let base = scaledCoverBase[ObjectIdentifier(cover)] else { continue }
            if cover.transform != base { cover.transform = base }
        }
        scaledCovers.removeAllObjects()
        scaledCoverBase.removeAll()
    }

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
              let source = visibleCover(in: list, page: page) else { return nil }
        // ★ **先吃缓存**（页面开着的时候就已经认下来的那张），再退回"现在去抓树"。
        //   后者在真机树里经常还没就绪（`UIImageView(alpha=0.00)`），那正是"点了没反应"的来源。
        guard let image = rememberArtworkIfNeeded(in: page)
                ?? firstImage(in: source)
                ?? anyCoverImage(in: list) else {
            noteSkip("no image inside that cover view (\(NSStringFromClass(type(of: source))))")
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
        hideSpotifyCover(source)
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

    /// 被我们按下 `alpha` 的**别人那些视图**（`Encore.ImageView` 壳 + 真正画图的那一层）—— 弱引用名册。
    ///
    /// ★ 2026-10-12（独立复核点出来的两个死角都在这一段）：
    ///
    ///   ① 原来这份名单挂在**页面对象**上（`objc_setAssociatedObject(page, …)`），而还原那段是
    ///      `guard let page = lastPage else { return }` —— `lastPage` 是 **weak**：页面先被释放
    ///      （或已经换成新的一页）时，还原**整段跑不到**；而封面的视图住在**会被复用的 cell** 里
    ///      ⇒ 复用到下一页时它还是 `alpha = 0` ⇒ **永久空白封面**（本仓库最不能接受的那种失败）。
    ///      名册改成**静态**之后，"藏"与"还原"也不再依赖页面身份。
    ///   ② 原来还原写死 `alpha = 1`：可壳原本可能是 0、或是 0.5（日志 54 里就有 `alpha=0.50`
    ///      的重复件）⇒ 我们等于**把别人的值永久改坏**。现在**逐视图记下原值**、按原值写回。
    private static let hiddenCovers = NSHashTable<UIView>.weakObjects()
    private static var hiddenCoverAlphas: [ObjectIdentifier: CGFloat] = [:]

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
        // ★ 2026-10-04：缓存里那张**也要够大**才算数 —— 旧版本可能已经把占位图按这一首的 id
        //   存进来了（真机日志 `remembered this track's artwork 4×4 (cache 1/8)`）。
        //   直接丢条目、让这一拍重新去树里认；不丢的话用户升级之后**这一首还是**那块灰方块。
        if let cached = artworkCache[trackId] {
            if isUsableArtwork(cached) { return cached }
            artworkCache.removeValue(forKey: trackId)
            artworkCacheOrder.removeAll { $0 == trackId }
            if !unusableArtworkReported {
                unusableArtworkReported = true
                writeDebugLog(
                    "[\(logTag)] dropped a cached artwork that is too small to be a cover — "
                        + "\(Int(cached.size.width))×\(Int(cached.size.height))"
                )
            }
        }

        // ★ 2026-10-07（日志 52 的现场）：**换歌那一拍先不信视图树。**
        //
        // `currentTrackId()` 是**立刻**变的，而 Spotify 的封面要**晚一点**才换过来。
        // 日志 52 里这两行是**同一秒**：
        // ```
        // 07:00:46  [NPVLyrics] remembered this track's artwork 366×366 (cache 2/8)
        // 07:00:46  [PLAYER] track changed — pos=0.0s dur=168.0s
        // ```
        // ⇒ **上一首的图被当成新那一首的图存进了缓存**，而 `ensureCover` 优先吃缓存
        // ⇒ 于是"封面显示上一首歌的歌曲"，而且**这一首会一直错下去**。
        //
        // 所以：曲目 id 刚变的那一拍**只记 id、不认图**，下一拍（≤0.5s）再认 ——
        // 那时图也换过来了。这一拍 `ensureCover` 会退回 `firstImage(in: source)`，
        // 也就是**当前树里真实那张**，不会比原来差。
        if lastArtworkTrackId != trackId {
            // ★ 2026-10-09：把**上一首**那张图记下来 —— 下一次真的去抓树时要用它判"树换过来了没有"。
            previousArtworkImage = artworkCache[lastArtworkTrackId]
            staleArtworkTrackId = ""
            artworkTrackChangedAt = CFAbsoluteTimeGetCurrent()
            lastArtworkTrackId = trackId
            writeDebugLog(
                "[\(logTag)] track just changed — not caching the artwork this tick"
                    + " (the view tree still shows the previous cover)"
            )
            return nil
        }

        guard let list = findByIdentifier(listIdentifier, in: page),
              let source = visibleCover(in: list, page: page),
              let image = firstImage(in: source) ?? anyCoverImage(in: list) else { return nil }

        // ★ 2026-10-09（照片 61）：**"下一拍树就换过来了"这个假设不成立。**
        //
        // 日志 53 的换歌现场（同一秒）：
        // ```
        // 08:08:35  [NPVLyrics] artwork picked … ImageView 366×366 at 24,163,366,366
        // 08:08:35  [PLAYER] track changed — pos=0.3s dur=225.0s
        // 08:08:36  [NPVLyrics] remembered this track's artwork 366×366 (cache 2/8)   ← 抓到的还是旧那张
        // ```
        // 于是**上一首的图被写进新曲目的缓存**，而 `ensureCover` 优先吃缓存 ⇒ 缩略图一直显示上一首
        // （照片 61 的缩略图就是上一首那张橙色封面，标题却已经是新歌）。
        //
        // 判据：抓到的图**和上一首缓存里那张是同一个对象** ⇒ 树还没换过来 ⇒ 这一拍不写缓存。
        // 这一拍 `ensureCover` 会退回 `firstImage(in: source)`（同一张，画面对齐）；
        // 树真的换过来之后，对象不同 ⇒ 正常写缓存。
        //
        // ⚠️ **只在换歌那一小段窗口里判**（独立复核指出的死角）：同一个对象也可能是
        //    Spotify 自己的图缓存把**同一张专辑**的图复用了（连听两首同专辑），
        //    那时这条判据会**永久**不让缓存写进去 —— 画面不会错（兜底拿的是同一张真图），
        //    但"点开之前就先认下这张图"这个收益没了。所以给它一个 1.5s 的窗口：
        //    够覆盖"树晚一拍到一秒"（日志 53 是 ≤1s），之后照常缓存。
        if let previous = previousArtworkImage,
           image === previous,
           CFAbsoluteTimeGetCurrent() - artworkTrackChangedAt < staleArtworkWindow {
            if staleArtworkTrackId != trackId {
                staleArtworkTrackId = trackId
                writeDebugLog(
                    "[\(logTag)] the tree still shows the previous cover — not caching it for this track"
                        + " (falling back to the live image, will retry next tick)"
                )
            }
            return nil
        }

        // ★ 2026-10-04：**够大才配进缓存**（占位图一旦进去就是"永久的错封面"，见 `firstImage`）。
        guard isUsableArtwork(image) else {
            noteUnusableArtwork(image, from: source)
            return nil
        }

        artworkCache[trackId] = image
        artworkCacheOrder.append(trackId)
        while artworkCacheOrder.count > artworkCacheLimit {
            artworkCache.removeValue(forKey: artworkCacheOrder.removeFirst())
        }
        writeDebugLog(
            "[\(logTag)] remembered this track's artwork \(Int(image.size.width))×\(Int(image.size.height))"
                + " (cache \(artworkCacheOrder.count)/\(artworkCacheLimit))"
        )
        return image
    }

    /// 上一次认图时的曲目 id。用来识别"刚换歌那一拍"（见 `rememberArtworkIfNeeded`）。
    private static var lastArtworkTrackId = ""

    /// 「曲目刚变」那一刻，**上一首**缓存里那张图（见 `rememberArtworkIfNeeded` 的换歌判据）。
    private static var previousArtworkImage: UIImage?

    /// 已经为哪一首报过"树里还是上一首的图"（只报一次，别每拍刷屏）。
    private static var staleArtworkTrackId = ""

    /// 这一次"曲目刚变"发生的时刻 —— 那条"图还是上一首的"判据只在这个窗口里生效
    /// （见 `rememberArtworkIfNeeded`：同专辑连播时图可能真的是同一个对象，不能永久拦）。
    private static var artworkTrackChangedAt: CFAbsoluteTime = 0
    private static let staleArtworkWindow: CFAbsoluteTime = 1.5

    /// ⚠️ 收的是**已经认准的那一个**（由 `visibleCover` 挑出来），不再自己按 id 找一遍 ——
    /// 上一版这里又 `findByIdentifier` 了一次，于是"挑封面"与"藏封面"用的是两个不同的视图。
    private static func hideSpotifyCover(_ source: UIView) {
        hideCoverView(source)
        // 它下面那层真正画图的 `UIImageView` 也一起（`Encore.ImageView` 只是壳）。
        for sub in source.subviews where sub.alpha > 0.01 && sub.bounds.width >= 200 {
            hideCoverView(sub)
        }
    }

    /// 按下某个视图的 `alpha`，并**只在第一次**记下它自己的原值（还原时按原值写回，见名册那段）。
    private static func hideCoverView(_ view: UIView) {
        let key = ObjectIdentifier(view)
        if hiddenCoverAlphas[key] == nil { hiddenCoverAlphas[key] = view.alpha }
        hiddenCovers.add(view)
        view.alpha = 0
    }

    /// 把被我们按下去的视图**按各自的原值**还回去。**不依赖页面**（见名册那段：页面可能已经没了）。
    private static func restoreSpotifyCover() {
        for view in hiddenCovers.allObjects {
            guard let original = hiddenCoverAlphas[ObjectIdentifier(view)] else { continue }
            if view.alpha != original { view.alpha = original }
        }
        hiddenCovers.removeAllObjects()
        hiddenCoverAlphas.removeAll()
    }

    /// 在壳里找真正的 `UIImageView`（`Encore.ImageView` 自己不画图）。
    ///
    /// ★★ 2026-10-04（用户：「歌曲封面有时候会加载失败」）：**图也要看尺寸。**
    ///
    /// 现场（同一份真机日志）：`remembered this track's artwork 4×4 (cache 1/8)` ——
    /// 这一版以前**只认"有没有 `image`"**，而那个壳里除了真正画图的 `UIImageView`，
    /// 还挂着一个 `PlaceholderView`（它的占位图就是 4×4）。4×4 被当成封面缓存下来之后
    /// `ensureCover` **每一拍都优先吃缓存** ⇒ 缩略图永远是那块灰方块（照片 76 的左上角就是它），
    /// 而且**这一首永久错下去**（缓存按曲目 id 存，只在 LRU 到 8 张时才被挤掉）。
    ///
    /// 所以这里改成"**够大才算**"：太小的**跳过、继续往下走**（不是直接返回 nil ——
    /// 真图可能挂在这个小图的兄弟节点上）。
    private static func firstImage(in view: UIView) -> UIImage? {
        if let imageView = view as? UIImageView, let image = imageView.image {
            if isUsableArtwork(image) { return image }
            noteUnusableArtwork(image, from: view)
        }
        for sub in view.subviews {
            if let image = firstImage(in: sub) { return image }
        }
        return nil
    }

    /// 封面图的最小边长。真机那份日志里的 `4×4` 就是占位图；而正片封面在真机树里是
    /// 366×366 的壳 + 至少 300pt 以上的图 —— 128 这条线把占位图挡在外面，又给"小图放大"
    /// 留足余量（宁可放过一张小图，也不许把占位图当封面）。
    private static let minimumArtworkSide: CGFloat = 128

    /// 这张图够格当封面吗（见 `minimumArtworkSide`）。
    private static func isUsableArtwork(_ image: UIImage) -> Bool {
        image.size.width >= minimumArtworkSide && image.size.height >= minimumArtworkSide
    }

    /// 报一次"这张图太小、我跳过了"（只报一次，别每拍刷屏）。
    /// 下一份日志靠它把 `PlaceholderView` 这个来源钉死。
    private static var unusableArtworkReported = false

    private static func noteUnusableArtwork(_ image: UIImage, from view: UIView) {
        guard !unusableArtworkReported else { return }
        unusableArtworkReported = true
        let className = NSStringFromClass(type(of: view))
        writeDebugLog(
            "[\(logTag)] skipped an artwork that is too small to be a cover — "
                + "\(Int(image.size.width))×\(Int(image.size.height)) inside \(className)"
        )
    }

    /// 兜底：在整条列表子树里找**任意一张够大、看得见、真带图的** `UIImageView`。
    /// 判据与 `visibleCover` 同一个量级（≥200pt），走查有界（本仓库纪律）。
    ///
    /// ⚠️ 2026-10-07：**同样要跳过"被「一屏」折掉的卡"里的图**，而且**同样是两趟**
    /// （严格找不到就退回旧判据）—— 这一层只负责"好歹给张图"，不许因为新判据而
    /// 从"有图但可能是卡的"变成"一张都没有"（那会让展开直接失败）。
    private static func anyCoverImage(in list: UIView) -> UIImage? {
        if let strict = firstCoverImage(in: list, skippingCollapsedAncestors: true) { return strict }
        return firstCoverImage(in: list, skippingCollapsedAncestors: false)
    }

    private static func firstCoverImage(
        in list: UIView,
        skippingCollapsedAncestors: Bool
    ) -> UIImage? {
        var visited = 0
        var queue: [UIView] = [list]

        while !queue.isEmpty, visited < maxNodes {
            let view = queue.removeFirst()
            visited += 1

            if let imageView = view as? UIImageView,
               let image = imageView.image,
               isUsableArtwork(image),
               imageView.bounds.width >= 200,
               !imageView.isHidden,
               imageView.alpha > 0.01,
               !(skippingCollapsedAncestors && hasCollapsedAncestor(imageView, root: list)) {
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
        let title = geometry.titleElement
        let slide = title.map { _ in
            CGAffineTransform(translationX: geometry.shift.rounded(), y: 0)
        }
        moveTitleRow(row: row, rise: rise, element: title, slide: slide)

        if let title {
            lastTitleElement = title
            // 长标题向右会撞到"加号"：**用 mask 渐隐**，不改宽度（Spotify 的 marquee 会把宽度写回）。
            applyTitleMask(to: title, page: page)
        }
    }

    /// 标题行的两段位移（上移 + 右移）**只在这一处写**，而且**只在目标真的变了**时才放动画。
    ///
    /// ★ 2026-10-11（用户提的：「能不能给歌曲/歌手移动到右边的时候，加个动画」）。
    ///
    /// 为什么必须"变了才动"：本仓库的老教训（`applyCoverState` 旁边那条）—— 这一条链的节拍是
    /// 0.3s、动画是 0.45s，**每拍无条件 `UIView.animate` 就等于每拍重开一次**，画面上是"永远在动"。
    /// 目标 == 现值时直接不进这个分支，动画才播得完。
    ///
    /// 为什么第一程**不**加动画：那一程这一行还是 Spotify 的原生位置（`transform == .identity`）——
    /// 进页面时它会从屏幕中间"跳"到左上角，滑过去反而更怪。只有"已经在我们的某个位置上"
    /// （展开 ⇄ 收起）才滑。
    private static func moveTitleRow(
        row: UIView,
        rise: CGAffineTransform,
        element: UIView?,
        slide: CGAffineTransform?
    ) {
        let rowNeedsMove = row.transform != rise
        var elementNeedsMove = false
        if let element, let slide { elementNeedsMove = element.transform != slide }
        guard rowNeedsMove || elementNeedsMove else { return }

        let change = {
            if rowNeedsMove { row.transform = rise }
            if let element, let slide, elementNeedsMove { element.transform = slide }
        }
        // pw 那一套：0.45s + 临界阻尼（`usingSpringWithDamping 1`）+ 允许用户交互 + 从当前状态开始
        // （最后一条是"连点两次不跳"的关键）；开了「减弱动态效果」就不动。
        guard !UIAccessibility.isReduceMotionEnabled, row.transform != .identity else {
            UIView.performWithoutAnimation(change)
            return
        }
        UIView.animate(
            withDuration: moveDuration,
            delay: 0,
            usingSpringWithDamping: 1,
            initialSpringVelocity: 0,
            options: [.allowUserInteraction, .beginFromCurrentState],
            animations: change,
            // ⚠️ `completion` 显式写 `nil`：UIKit 那个 Swift 签名虽然给了默认值，
            //    但这个仓库的编译器版本只保证"最多一个警告"，不冒这个险（同 `applyCoverState`）。
            completion: nil
        )
    }

    /// 渐隐宽度 = 标题可用宽度（到右边那排控件为止 / 到页面右沿为止）—— 量不到就整行不遮。
    private static func applyTitleMask(to title: UIView, page: UIView) {
        let bounds = title.bounds
        guard bounds.width > 1, bounds.height > 1 else { return }

        // ★ 2026-10-04：**坐标口径修好**（独立只读复核与 `HANDOFF_2` §6.4⑤ 都点过这一处）。
        //
        // `trailingControlX` 量的是**页面坐标**，而 `bounds` 与 `mask.frame` 是**元素自己的坐标**；
        // 原来把页面坐标直接当元素宽度用，而元素自己已经右移了 `shift`（现在 ≈74pt）
        // ⇒ 该渐隐的位置**整整差一个 shift**。更糟的是"右边没有兄弟控件"那一支：
        // `room = bounds.width` ⇒ `width == bounds.width` ⇒ 上面那条 `guard` 直接把 mask 清掉
        // ⇒ **一行 mask 都不贴**（真机上多半走的正是这一支，因为标题与歌手是上下两行、不是左右）。
        //
        // 现在：① 两条路都换算到元素自己的坐标系；② 再兜一条"页面右沿 − 8"——
        // 于是长标题**一定**会在屏幕边上渐隐，不再依赖"右边恰好有别的控件"这个前提。
        // ⚠️ ★ 2026-10-12：这里**不能用 `untransformed`**。
        //
        // `untransformed` 会把元素**自己的** `tx` 减掉（它是给 `measure()` 算"位移前的起点"用的），
        // 而 mask 挂在**这个元素的 layer** 上 ⇒ mask 的 x=0 对的就是元素**当前（位移后）**的左边。
        // 用 `untransformed` 算出来的可用宽度会**多出整整一个 `shift`**（≈74pt），
        // 于是 `width == bounds.width`、上面那条 `guard` 直接把 mask 删掉
        // ⇒ 长标题尾巴**永远不会渐隐**（这正是用户报的第 1 条：晃动区一直顶到屏幕右边）。
        // 现在用 `convert`（**含 transform**）= 元素此刻在页面上的真实左边。
        let titleLeft = title.convert(title.bounds, to: page).minX
        let pageLimit = (page.bounds.maxX - 8) - titleLeft
        let limitRoom = trailingControlX(in: title, page: page)
            .map { $0 - titleLeft - titleGap }
        let room = min(min(limitRoom ?? pageLimit, pageLimit), bounds.width)
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

    // MARK: - 控件条：分享键搬进来 / 关歌词时标题行去左上角（2026-10-11 第二轮）

    /// 把 Spotify 自己的**分享键**搬进"控件条"（进度条上方那一条空带 —— 绿色 ✓ 本来就在那儿）。
    ///
    /// ## 用户 2026-10-11 的第二版方案（照片 71/72/73）
    /// 那一条放 **[分享 58] [我们的歌词键 215] [绿色 ✓ 371（不动）]**，于是底部那两排
    /// 一颗都不用改；**收藏键不搬**（用户原话：「那个绿色勾就让它呆在那里」）。
    /// 开头那段常量注释里有原话与逐条坐标。
    ///
    /// ## ⚠️ 这是**视觉**搬运：搬过去之后**点不到**（用户已知并选了这一档）
    /// UIKit 的 hit-test 在祖先那一层就问 `point(inside:)`：分享键被抬到 626pt 之后，已经在它
    /// **父视图（footer 那一行，≈792…836）的边界之外** ⇒ 触摸到不了它，要分享得走右上角
    /// `⋯` 菜单里的 Share。`bandNote` 会把"到底是不是点不到、被谁挡住"写进日志。
    ///
    /// ## 两个状态都摆，和 `isOpen` 无关
    /// 这一条在**开着**和**关着**歌词时都是空的（关着时标题/歌手已被
    /// `applyClosedTitleTransform` 挪去左上角）⇒ 每拍都摆。
    ///
    /// ## 为什么位移只写 `transform`
    /// 位置由父视图的 Auto Layout 决定，改 `frame` 会被下一拍写回（本仓库老教训 ——
    /// 见 `applyTitleTransform` 那句"改约束会被 stack view 布局写回"）。只写平移分量，
    /// `a,b,c,d` 原样保留；每拍用 `untransformed` 重算平移量，父视图重排也能跟上。
    @discardableResult
    private static func applyControlBand(in page: UIView) -> Bool {
        guard let button = visibleShareButton(in: page) else {
            if !didLogBandShareMissing {
                didLogBandShareMissing = true
                writeDebugLog(
                    "[\(logTag)] no visible share button in this page yet — "
                        + "leaving it in the footer row"
                )
            }
            return false
        }

        // 换了一颗（换歌会重建这一排）⇒ 先把上一颗还回去，免得两处位移叠在同一颗上。
        if bandShareButton !== button {
            clearControlBand()
            bandShareButton = button
            bandShareOriginalTransform = button.transform
        }

        let current = untransformed(button, in: page)
        // ★ 2026-10-11（照片 75）：和**下面那颗 shuffle 同一条竖线**（量不到才用常量）。
        let columnX = transportColumnX(shuffleButtonIdentifier, in: page) ?? shareButtonCenterX
        let target = CGPoint(x: columnX, y: controlBandMidY)
        let dx = (target.x - current.midX).rounded()
        let dy = (target.y - current.midY).rounded()
        let landed = CGRect(
            x: (target.x - current.width / 2).rounded(),
            y: (target.y - current.height / 2).rounded(),
            width: current.width,
            height: current.height
        )

        let existing = button.transform
        let moved = CGAffineTransform(
            a: existing.a, b: existing.b, c: existing.c, d: existing.d,
            tx: dx, ty: dy
        )
        if button.transform != moved { button.transform = moved }

        // ★ 2026-10-11（用户报的「分享按键…用不了」）：它自己点不到 ⇒ **替它收点击**。
        ensureShareRelay(in: page, frame: landed)

        if !didLogBandShare {
            didLogBandShare = true
            writeDebugLog(
                "[\(logTag)] share button moved into the control band — "
                    + "\(Int(current.width))×\(Int(current.height)) from \(frameText(current))"
                    + " to \(frameText(landed))" + bandNote(for: button, landing: landed, page: page)
                    + " (a transparent relay covers that spot and forwards taps)"
            )
        }
        return true
    }

    /// 分享键的**替身热区**：一颗透明的 `UIControl`，点它 = 替用户按那颗真按钮。
    ///
    /// 为什么非它不可（日志 56 逐字）：
    /// `share button moved … to 36,604,44,44 (visual only: _TtGC13Element_UIKit11ElementView… does not
    /// contain the landing spot, so taps stay dead)` —— 搬过去之后它在**祖先的边界之外**，
    /// hit-test 在那一层就断了（`transform` 只改绘制与坐标换算，改不了父视图的命中范围）。
    /// 要根治只能"把视图搬进另一个父视图"，那会把 Spotify 的约束体系弄坏 —— 不做。
    ///
    /// 为什么这次可以用 `sendActions`（本仓库 2026-10-10 刚把"替用户按胶囊"整块删掉）：
    /// 那一次删的理由是**切换类**动作（按两次回到原状 + 会落盘用户偏好）；分享是"打开一个面板"，
    /// 幂等、没有状态，转发它是安全的。
    private static func ensureShareRelay(in page: UIView, frame: CGRect) {
        let relay: UIControl
        if let existing = bandShareRelay, existing.superview === page {
            relay = existing
        } else {
            let fresh = UIControl(frame: frame)
            // ⚠️ 别用 `alpha = 0`：`hitTest` 会把 alpha ≤ 0.01 的视图当成不存在 —— 那就白做了。
            fresh.backgroundColor = .clear
            fresh.accessibilityIdentifier = "eevee-npv-share-relay"
            fresh.isAccessibilityElement = false
            fresh.addTarget(
                NowPlayingShareRelayTarget.shared,
                action: #selector(NowPlayingShareRelayTarget.tapped),
                for: .touchUpInside
            )
            page.addSubview(fresh)
            bandShareRelay = fresh
            relay = fresh
        }
        if relay.frame != frame { relay.frame = frame }
        // ⚠️ 必须压在**歌词容器之上**（容器铺满歌词区，只在控件条那一条放行；就算放行了，
        //    也还是这颗热区先收到触摸 —— 它是页面最前面的一个子视图）。
        page.bringSubviewToFront(relay)
    }

    /// 关着歌词时：把**标题行**搬到左上角（照片 73 的 kumone 位）—— 给控件条腾地方。
    ///
    /// ## 为什么必须搬（照片 72 那个"会挡住"）
    /// 控件条的**第 ① 处**（分享键 58pt）正好压在**原生歌名/歌手**上：照片 72 里歌名在 618、
    /// 歌手在 640，而分享键要去 626。用户给的解法就是照片 73：
    /// **不展开歌词**时歌名/歌手贴左上角；**展开歌词以后**封面占左上角、歌名/歌手往右让位
    /// （后者正是现在的做法，见 `applyTitleTransform`）。
    ///
    /// ## 落点
    /// `navBarBottom + closedTitleTopInset` ⇒ 照片 72 上是 **98**（行高 46 ⇒ 98…144），
    /// 而**原生大封面顶边 = 145** —— 正好卡在导航条与封面之间，一行都不压。
    /// **x 不动**：照片 72 的原生歌名本来就在 34pt（和 kumone 照片 73 的 34 一样），
    /// 只有 y 要抬（618 → 98，约 −520pt）。
    ///
    /// 返回"这一拍有没有找到标题行"。
    @discardableResult
    private static func applyClosedTitleTransform(in page: UIView) -> Bool {
        let list = findByIdentifier(listIdentifier, in: page)
        let label = (list.flatMap { findByIdentifier(titleLabelIdentifier, in: $0) })
            ?? findByIdentifier(titleLabelIdentifier, in: page)
        guard let element = label?.superview, let row = element.superview,
              let navBottom = navBarBottom(in: page) else {
            // 找不到就**什么都不做** —— 宁可保持 Spotify 原样，也不要瞎移一行。
            if !didLogClosedTitleMissing {
                didLogClosedTitleMissing = true
                writeDebugLog(
                    "[\(logTag)] cannot find the title row — leaving it where Spotify put it"
                )
            }
            return false
        }

        // 上一程"展开时"的那两段位移**不在这里手撤** —— 交给 `moveTitleRow` 一起动画：
        // 行往上滑回左上角的同时，字往左滑回原位（分开写会先"跳"一下）。
        let current = untransformed(row, in: page)
        guard current.height > 1 else { return false }

        // ★ 2026-10-04（用户：「大封面有时候会把歌手的名字的下半部分挡住」）：
        //   原来这里**只看导航条**，从不问"封面顶边在哪"。真机日志 57 逐字：
        //   行 `28,98,308,51`（下沿 **149**）vs 封面 `24,146,366,366`（顶边 **146**）
        //   ⇒ **压 3pt**，而 51pt 高的行里第二行就是歌手 ⇒ 用户看到的正是"歌手名字的下半截"。
        //   现在：量得到封面就夹一道"行底 ≤ 封面顶 − 6"；量不到就照旧（宁可保持原样，别瞎移）。
        var top = navBottom + closedTitleTopInset
        if let list = findByIdentifier(listIdentifier, in: page),
           let cover = visibleCover(in: list, page: page) {
            let coverTop = untransformed(cover, in: page).minY
            let limit = coverTop - closedTitleCoverGap - current.height
            if top > limit { top = limit }
        }

        let dy = (top - current.minY).rounded()
        moveTitleRow(
            row: row,
            rise: CGAffineTransform(translationX: 0, y: dy),
            element: element,
            slide: .identity
        )
        closedTitleRow = row
        closedTitleElement = element

        // 一次一页只报一行：下一份日志靠它判"关着态到底摆上了没有"。
        if !didLogClosedTitle {
            didLogClosedTitle = true
            let landed = CGRect(
                x: current.minX,
                y: navBottom + closedTitleTopInset,
                width: current.width,
                height: current.height
            )
            writeDebugLog(
                "[\(logTag)] title row moved to the top left for the closed state — "
                    + "\(frameText(current)) to \(frameText(landed))"
            )
        }
        return true
    }

    /// 把分享键还回原处（关开关 / 离开页面）。**只撤我们写的那段平移**：
    /// 接管前它自己的 `transform` 原样写回（不假设它一定是 identity）。
    private static func clearControlBand() {
        if let button = bandShareButton {
            let original = bandShareOriginalTransform ?? .identity
            if button.transform != original { button.transform = original }
        }
        bandShareButton = nil
        bandShareOriginalTransform = nil
        didLogBandShare = false
        didLogBandShareMissing = false
        // 替身热区也要一起拿走（它挂在页面上，不拿走会一直吃那一块的触摸）。
        bandShareRelay?.removeFromSuperview()
        bandShareRelay = nil
    }

    /// 热区被点了 ⇒ 把这一下**转给那颗真的分享键**。
    ///
    /// ⚠️ `bandShareButton` 的声明类型是 `UIView?`（我们只当它是"页里那个视图"），
    /// 而 `sendActions(for:)` 是 **`UIControl`** 的方法 ⇒ 这里必须 `as? UIControl`。
    /// 这一条 2026-10-11 让 CI 红过一次（`value of type 'UIView' has no member 'sendActions'`
    /// + `cannot infer contextual base in reference to member 'touchUpInside'`，
    /// 后一条是前一条的连锁）—— 自检 `swift_member_check.py` 的规则 ④ 就是为它加的。
    fileprivate static func relayShareTap() {
        guard let view = bandShareButton else { return }
        let name = NSStringFromClass(type(of: view))

        guard let control = view as? UIControl else {
            // 不是 `UIControl` ⇒ 这颗键不是靠 target/action 响应的，转发不了。
            // 留一行日志：下一轮就能分清"转发发生了但对方不是 UIControl"和"热区没收到触摸"。
            writeDebugLog(
                "[\(logTag)] the share button (\(name)) is not a UIControl — cannot forward the tap"
            )
            return
        }
        writeDebugLog("[\(logTag)] relaying a tap to the share button (\(name))")
        control.sendActions(for: .touchUpInside)
    }

    /// 把「歌词提供商」写到**歌手那一行的右边**：`歌手（提供商）`。
    ///
    /// ## 用户 2026-10-11 的想法（原话）
    /// > 就是在歌手的右边，写上歌词提供商。即 **歌手名字（歌词提供商）** 这种。而这两行是等高的。
    /// > 这个就不需要写 eveespotify 的水印了
    ///
    /// ## 为什么用"复查"而不是只写一次
    /// 这一行是 **Spotify 自己的标签**（`now-playing-subtitle-label`），它的 binder 会在绑定/
    /// 换歌时把文本写回 ⇒ 只写一次就是"过一会儿又变回去"。本仓库对"改原生标签"的既有手法
    /// 就是**常驻复查节拍**（见 `LibraryAppearance` 那段：写一次、每拍比一次、被写回时留一行日志）。
    /// 我们这条 0.3s 的节拍现成，直接蹭。
    ///
    /// ⚠️ **展开与收起都贴**（用户 2026-10-04 选的那一档：「两个状态都显示」）；
    /// 只有**离开页面 / 关开关**才由 `restoreArtistLine` 精确摘掉
    /// （记住贴上去的那一段，不靠猜括号；见 `settleAfterClosing`）。
    ///
    /// ⚠️ 两行的高度**不动**：标题与歌手各是 Spotify 自己的字号（真机树 24 / 22pt），
    /// 我们只往歌手那行**追加文本**，不换行、不改字体 —— 用户要的"两行等高"就是"别把第二行撑高"。
    private static func applyProviderToArtistLine(in page: UIView) {
        guard let label = artistLabel(in: page) else { return }
        guard let suffix = providerSuffix() else { return }

        let current = effectiveLabelText(label)
        guard !current.isEmpty else { return }

        // ★ 2026-10-12（独立复核点出来的死角）：**提供商换了名字**（同一首歌重新取词 /
        //   回落到另一个源）时，`hasSuffix(suffix)` 只挡得住"当前这一段"，
        //   于是会贴成 `歌手（NetEase）（Genius）`，而 `lastArtistSuffix` 只记得最新那一段
        //   ⇒ `restoreArtistLine` 只摘一段，**上一段永远留在 Spotify 的标签上**。
        //   所以贴之前先把**我们上一次贴的那一段**摘掉（记住的那一段，不靠猜括号）。
        var base = current
        if let previous = lastArtistSuffix, previous != suffix, base.hasSuffix(previous) {
            base = String(base.dropLast(previous.count))
        }
        guard !base.isEmpty, !base.hasSuffix(suffix) else { return }

        // 走到这里有两种情况：
        //   · 第一次贴（文本就是 Spotify 给的纯歌手名）；
        //   · binder 把文本写回成纯歌手名 ⇒ 再贴一次。
        lastArtistSuffix = suffix
        setLabelText(base + suffix, on: label)

        // ★ 2026-10-04：这条日志原来**一个进程只打一次**，于是"换歌之后有没有重新贴上"
        //   在日志里完全看不出来（用户这次报的就是"没有展示"，而我们手里没有一行能判它的证据）。
        //   改成"每换一首歌允许再报一次"。
        let trackId = currentTrackId() ?? ""
        if !didLogArtistProvider || loggedArtistProviderTrack != trackId {
            didLogArtistProvider = true
            loggedArtistProviderTrack = trackId
            writeDebugLog(
                "[\(logTag)] lyrics provider written next to the artist — \"\(current)\" + \"\(suffix)\""
            )
        } else if !didLogArtistReset, current == lastArtistBase {
            // 同一行、同一个歌手名，却又走到这里 ⇒ 是 binder 写回，不是换歌。
            didLogArtistReset = true
            writeDebugLog(
                "[\(logTag)] ⚠️ the artist line was written back by the binder -"
                    + " the 0.3s reconcile will keep putting the provider back"
            )
        }
        lastArtistBase = current
    }

    /// 上一次贴提供商时是哪一首（"每换一首歌允许再报一次"用，见 `applyProviderToArtistLine`）。
    private static var loggedArtistProviderTrack = ""

    /// 把歌手那一行还原成纯歌手名（**离开页面 / 关开关** —— 不再跟着"收起歌词"走）。
    private static func restoreArtistLine(in page: UIView) {
        guard let suffix = lastArtistSuffix, let label = artistLabel(in: page) else { return }
        let current = effectiveLabelText(label)
        guard current.hasSuffix(suffix) else {
            lastArtistSuffix = nil
            return
        }
        setLabelText(String(current.dropLast(suffix.count)), on: label)
        lastArtistSuffix = nil
    }

    /// 上一次贴之前那一行的原文（用来分辨"换歌"与"被 binder 写回"，只给日志用）。
    private static var lastArtistBase = ""

    /// 歌手那一行到底是哪一个 `UILabel`。判据**从硬到软**三条：
    ///
    ///   ① **id**：`now-playing-subtitle-label`（9.1.76 那份树里是它；9.1.88 上这份日志证明**已经不在**）；
    ///   ② ★ 2026-10-12（日志 58）：**按文本认** —— 页面里那个写着**当前歌手名**的标签。
    ///      歌手名从曲目元数据取（口径与 `LyricsWordByWord` 的壳、`AppleMusicLyricsOverlay` 的页头一致）。
    ///      这是**确定性**判据，不是位置猜；
    ///   ③ 位置兜底：标题那一行里、标题**正下方**、且与标题左边缘对齐的标签。
    ///
    /// ## 为什么必须重做（日志 58 逐字）
    ///
    /// ```
    /// [NPVLyrics] the artist line was found by position, not by id — class UILabel
    /// [NPVLyrics] lyrics provider written next to the artist — "直播" + "（NetEase）"
    /// ```
    ///
    /// ⇒ 旧的"位置兜底"挑中了一个 **`text = "直播"` 的徽章**：提供商被贴到 LIVE 徽章上，
    /// 用户看到的仍然是"提供商没写在歌手后面"（而且我们还改坏了别人的一个标签）。
    ///
    /// ## 另一半（同样致命）
    ///
    /// 三条判据都改用 `effectiveLabelText`：Spotify 的标签**未必把文字放在 `text` 里**
    /// （`attributedText` 是常态）—— 只认 `text` 会把真正的歌手行**整行跳过**，
    /// 于是兜底才轮得到那个徽章。这正是"直播"能中选的原因。
    private static func artistLabel(in page: UIView) -> UILabel? {
        let list = findByIdentifier(listIdentifier, in: page)
        let byId = (list.flatMap { findByIdentifier(subtitleLabelIdentifier, in: $0) })
            ?? findByIdentifier(subtitleLabelIdentifier, in: page)
        if let label = byId as? UILabel, !effectiveLabelText(label).isEmpty { return label }

        let titleLabel = (list.flatMap { findByIdentifier(titleLabelIdentifier, in: $0) })
            ?? findByIdentifier(titleLabelIdentifier, in: page)
        let titleFrame = titleLabel.map { untransformed($0, in: page) }
        let candidates = textLabels(in: page)

        // ② 按歌手名认（包含即可：Spotify 可能写成 "A, B" 而我们拿到的是主艺人）。
        let artist = currentArtistName()
        if !artist.isEmpty {
            let matched = candidates.filter { candidate in
                guard candidate.label !== titleLabel else { return false }
                let text = effectiveLabelText(candidate.label)
                return text.range(of: artist, options: .caseInsensitive) != nil
            }
            if let best = nearestBelow(matched, to: titleFrame) {
                if !didLogArtistLabelByText {
                    didLogArtistLabelByText = true
                    writeDebugLog(
                        "[\(logTag)] the artist line was found by its text — class "
                            + "\(NSStringFromClass(type(of: best)))"
                    )
                }
                return best
            }
        }

        // ③ 位置兜底：标题**正下方** + 左边缘对齐（比旧判据严一档：旧判据只要求"水平有重叠"，
        //    徽章也能满足）。三条都要过 `effectiveLabelText`。
        if let titleFrame {
            let positional = candidates.filter { candidate in
                guard candidate.label !== titleLabel else { return false }
                return candidate.frame.minY >= titleFrame.maxY - 2
                    && abs(candidate.frame.minX - titleFrame.minX) <= 12
            }
            if let best = nearestBelow(positional, to: titleFrame) {
                if !didLogArtistLabelFallback {
                    didLogArtistLabelFallback = true
                    writeDebugLog(
                        "[\(logTag)] the artist line was found by position, not by id — class "
                            + "\(NSStringFromClass(type(of: best)))"
                    )
                }
                return best
            }
        }

        // ④ 三条都不中：把**候选原样打进日志**（只打一次）。
        //    上一轮就是因为只有一句"找不到"，下一轮仍然只能猜 —— 这次让日志自己说出页面里有什么。
        if !didLogArtistLabelMissing {
            didLogArtistLabelMissing = true
            let dump = candidates.prefix(8).map { candidate -> String in
                let text = effectiveLabelText(candidate.label)
                let shown = text.count > 24 ? String(text.prefix(24)) + "..." : text
                let className = NSStringFromClass(type(of: candidate.label))
                return "\(className) [\(shown)] \(frameText(candidate.frame))"
            }.joined(separator: " | ")
            writeDebugLog("[\(logTag)] cannot find the artist line — candidates: \(dump)")
        }
        return nil
    }

    private static var didLogArtistLabelMissing = false
    private static var didLogArtistLabelFallback = false
    private static var didLogArtistLabelByText = false

    /// 标签的**有效文本**：`text` 为空就看 `attributedText`。
    ///
    /// ★ 日志 58 的教训（用户：「歌词提供商还是没在歌手后面」）：Spotify 那一行未必用 `text`
    ///   写入 —— 旧判据只认 `text`，于是**真正的歌手行被整行跳过**，位置兜底才挑中了
    ///   一个 `text = "直播"` 的徽章。凡是要读标签文字的地方都走这一个口径。
    private static func effectiveLabelText(_ label: UILabel) -> String {
        let plain = label.text ?? ""
        if !plain.isEmpty { return plain }
        return label.attributedText?.string ?? ""
    }

    /// 当前这首的**歌手名**（页面上的歌手那一行就该写着它）。
    ///
    /// 口径与仓库另外两处一致（`LyricsWordByWord` 的壳 `:897`、`AppleMusicLyricsOverlay` 的页头 `:671`）：
    /// 9.1.x 上要 `artistName()`，老版本只有 `artistTitle()`（见 `SPTPlayerTrack+Extension` 的说明）。
    private static func currentArtistName() -> String {
        let track = statefulPlayer?.currentTrack() ?? nowPlayingScrollViewController?.loadedTrack
        let name = EeveeSpotify.hookTarget == .lastAvailableiOS14
            ? track?.artistTitle()
            : track?.artistName()
        return (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 标题那一行里所有"**有文字**的 `UILabel`"（含标题自己），带它们在页面坐标里的 frame。
    ///
    /// 起点**逐级放宽**：标题元素 → 标题行 → 整页；哪一级找到就不往下找（越近的越可能是它）。
    /// 走查有界（每级 64 个节点）。**只看有效文本非空的**（见 `effectiveLabelText`）。
    private static func textLabels(in page: UIView) -> [(label: UILabel, frame: CGRect)] {
        let list = findByIdentifier(listIdentifier, in: page)
        let titleLabel = (list.flatMap { findByIdentifier(titleLabelIdentifier, in: $0) })
            ?? findByIdentifier(titleLabelIdentifier, in: page)

        var roots: [UIView] = []
        if let element = titleLabel?.superview { roots.append(element) }
        if let row = titleLabel?.superview?.superview { roots.append(row) }
        roots.append(page)

        var found: [(label: UILabel, frame: CGRect)] = []
        for root in roots {
            var visited = 0
            var queue: [UIView] = [root]
            while !queue.isEmpty, visited < 64 {
                let view = queue.removeFirst()
                visited += 1
                queue.append(contentsOf: view.subviews)
                guard !view.isHidden, view.alpha > 0.01, view.bounds.height > 1 else { continue }
                guard let label = view as? UILabel else { continue }
                guard !effectiveLabelText(label).isEmpty else { continue }
                if found.contains(where: { $0.label === label }) { continue }
                found.append((label, untransformed(view, in: page)))
            }
            if !found.isEmpty { break }
        }
        return found
    }

    /// 在候选里挑"**在标题下方、离标题最近**"的那个；没有标题 frame 就取第一个。
    private static func nearestBelow(
        _ candidates: [(label: UILabel, frame: CGRect)],
        to titleFrame: CGRect?
    ) -> UILabel? {
        guard let titleFrame else { return candidates.first?.label }
        let below = candidates.filter { $0.frame.minY >= titleFrame.maxY - 2 }
        return below.min { $0.frame.minY < $1.frame.minY }?.label ?? candidates.first?.label
    }

    /// `"歌手（提供商）"` 里那一段后缀；提供商为空 ⇒ `nil`（那就什么都不写，保持 Spotify 原样）。
    private static func providerSuffix() -> String? {
        let provider = currentLyricsProvider.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !provider.isEmpty else { return nil }
        return "（\(provider)）"
    }

    /// 改 Spotify 标签的文本时**保住它自己的字体/颜色**：有 `attributedText` 就在它上面改，
    /// 没有才退回 `text`（直接写 `text` 会把 Spotify 设的属性字符串整段丢掉）。
    private static func setLabelText(_ text: String, on label: UILabel) {
        if let attributed = label.attributedText, attributed.length > 0 {
            let mutable = NSMutableAttributedString(attributedString: attributed)
            mutable.replaceCharacters(
                in: NSRange(location: 0, length: mutable.length),
                with: text
            )
            label.attributedText = mutable
        } else {
            label.text = text
        }
    }

    /// 把我们写给标题行 / 标题元素的那两段位移撤掉（关开关 / 离开页面）。
    private static func clearClosedTitleTransform() {
        if let row = closedTitleRow, row.transform != .identity { row.transform = .identity }
        if let element = closedTitleElement, element.transform != .identity {
            element.transform = .identity
        }
        closedTitleRow = nil
        closedTitleElement = nil
        didLogClosedTitleMissing = false
        didLogClosedTitle = false
    }

    /// 页里**看得见、而且在屏上**的那一份分享键。
    ///
    /// ⚠️ 不能用 `findByIdentifier`：它返回 BFS 里**第一份**，而页里有**两份**分享键
    /// （日志 54 逐字：`12.EncoreButton@0,0,44,44,alpha=0.50,id=ShareButtonNowPlayingView`
    /// 与 `12.EncoreButton@0,0,44,44,id=ShareButtonNowPlayingView`）
    /// ⇒ 位移会写在一份看不见（或不在屏上）的按钮上，屏幕上一点变化都没有，
    /// 而日志还会说"成了"（规矩 1/11 的老坑）。
    ///
    /// 走查**起点从小到大**（同 `progressUnitTop` 的思路；整页 BFS 会被列表里那些格子吃掉预算）：
    ///   ① `npv.bottomStackView`（分享键的家 —— 底部那一坨的 footer 行）；
    ///   ② `SPTNowPlayingView`（播放器自己那一份，几百个节点）；
    ///   ③ `page` 兜底。
    private static func visibleShareButton(in page: UIView) -> UIView? {
        if let cached = bandShareButton,
           cached.window != nil,
           !cached.isHidden,
           cached.alpha > 0.01,
           cached.isDescendant(of: page) {
            return cached
        }

        var roots: [UIView] = []
        if let stack = findByIdentifier(bottomStackIdentifier, in: page) { roots.append(stack) }
        if let player = findByIdentifier(nowPlayingViewIdentifier, in: page) { roots.append(player) }
        roots.append(page)

        for root in roots {
            if let found = firstVisibleShareButton(in: root, page: page) { return found }
        }
        return nil
    }

    /// 一趟有界 BFS：按 **id + 看得见 + 在屏上** 挑分享键（判据风格与 `firstVisibleCover` 一致）。
    private static func firstVisibleShareButton(in root: UIView, page: UIView) -> UIView? {
        var visited = 0
        var queue: [UIView] = [root]

        while !queue.isEmpty, visited < maxNodes {
            let view = queue.removeFirst()
            visited += 1

            if view.accessibilityIdentifier == shareButtonIdentifier,
               !view.isHidden,
               view.alpha > 0.01,
               view.window != nil,
               view.bounds.width >= 1,
               view.bounds.height >= 1,
               isOnScreen(view, in: page) {
                return view
            }
            // hidden 的子树不往下走。
            if view.isHidden { continue }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// 这一份是不是**真的在屏上**。照片 71 里那颗分享键在 815pt 那一排；
    /// "另外那一份"（`alpha=0.50`）通常在别的卡里 / 被折起来了 ⇒ 用它把那一份筛掉。
    private static func isOnScreen(_ view: UIView, in page: UIView) -> Bool {
        let frame = untransformed(view, in: page)
        return frame.width >= 1
            && frame.height >= 1
            && frame.midY > 0
            && frame.midY < page.bounds.height
            && frame.intersects(page.bounds)
    }

    /// 搬进控件条之后的一行注脚：**会不会被裁** / **点不点得到**（只报，**不自动改**）。
    ///
    /// 三条判据都从"落点还在不在祖先的框里"推出来，正好回答下一份日志最想知道的三个问题：
    ///   · 有祖先 `clipsToBounds` 且框装不下落点 ⇒ 屏幕上可能**缺一块**（不自动清：清掉别人的
    ///     裁剪可能把别的被裁内容一起放出来，那是更大的破坏）；
    ///   · ★ **我们自己那个歌词容器**在它前面（`bringSubviewToFront`，而且铺满歌词区）⇒
    ///     触摸会被我们先吃掉 —— 这一条比父视图的边界更容易被忘掉；
    ///   · 有祖先（**没开裁剪也一样**）框装不下落点 ⇒ hit-test 在那一层就断了。
    private static func bandNote(for view: UIView, landing: CGRect, page: UIView) -> String {
        var node = view.superview
        var hops = 0
        var clipper: String?
        var blocker: String?

        while let current = node, hops < 32 {
            if current.bounds.width > 1, current.bounds.height > 1,
               !untransformed(current, in: page).contains(landing) {
                if blocker == nil { blocker = NSStringFromClass(type(of: current)) }
                if current.clipsToBounds, clipper == nil {
                    clipper = NSStringFromClass(type(of: current))
                }
            }
            if current === page { break }
            node = current.superview
            hops += 1
        }

        if let clipper {
            return " — WARNING: \(clipper) clips to bounds and does not contain the landing spot,"
                + " so it may be cut off"
        }
        if let container = lastContainer, container.window != nil,
           container.convert(container.bounds, to: page).contains(landing) {
            return " (visual only: our own lyrics container is in front of it, so taps stay dead)"
        }
        if let blocker {
            return " (visual only: \(blocker) does not contain the landing spot, so taps stay dead)"
        }
        return " (inside every ancestor — it should still take taps)"
    }

    // MARK: - 歌词键（2026-10-11 第二轮：搬进**控件条**）

    /// 那枚键的落点。
    ///
    /// ★★ 2026-10-11 第二轮（照片 71）：**首选控件条**那一格（与绿色 ✓ / 分享键同一条线），
    /// 也就是 `toggleCenterX` × `controlBandMidY`。用户圈的第 ② 处就是它。
    /// 控件条**量不出来**（没有进度条锚点 / 页面太矮 / 该位置已经被导航条吃掉）时才退回
    /// 下面那套老的三级判据 —— 宁可回到旧行为，也不要摆一个压在进度条或歌词上的键。
    private static func toggleFrame(in page: UIView) -> CGRect? {
        // ★ 2026-10-11（照片 75）：和**下面那颗播放/暂停键同一条竖线**（量不到才用常量）。
        let centerX = transportColumnX(playButtonIdentifier, in: page) ?? toggleCenterX
        if let band = controlBandFrame(in: page, side: toggleSide, centerX: centerX) {
            return band
        }
        return fallbackToggleFrame(in: page)
    }

    /// 控件条上的一格（给定中心 x，y 恒为 `controlBandMidY`）。
    ///
    /// 两条健全性检查（任一不过就返回 `nil`，交给 `fallbackToggleFrame`）：
    ///   · 这一格必须在**导航条下沿之下**（否则会压在那三个导航控件上）；
    ///   · 必须在**进度条顶边之上**（否则会压住进度条的拖动）。
    private static func controlBandFrame(
        in page: UIView,
        side: CGFloat,
        centerX: CGFloat
    ) -> CGRect? {
        guard page.bounds.height >= livingHeight else { return nil }

        if let nav = navBarBottom(in: page), controlBandMidY - side / 2 <= nav { return nil }
        if let list = findByIdentifier(listIdentifier, in: page),
           let progressTop = progressUnitTop(in: list, page: page),
           controlBandMidY + side / 2 >= progressTop {
            return nil
        }
        return CGRect(
            x: (centerX - side / 2).rounded(),
            y: (controlBandMidY - side / 2).rounded(),
            width: side,
            height: side
        )
    }

    /// 老的三级判据（2026-10-03 起用的）。**只在控件条量不出来时兜底**。
    ///
    /// * **①**：`npv.bottomStackView` 的**最后一行**（footer）的 frame、水平居中。
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
    private static func fallbackToggleFrame(in page: UIView) -> CGRect? {
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
        // ★ 2026-10-12：总开关关着就**一枚键都不许摆** —— 用户报的"歌词按钮点不动"
        //   就是"键摆出来了、点下去 `canShow` 直接 false"造成的。调用点（`apply` / `reconcile`）
        //   本来都判过了，这里再判一次是**兜底**：将来多一条调用路径，也不会再造出那枚死键。
        guard isEnabled else {
            removeToggle()
            return
        }
        guard let wanted = toggleFrame(in: page) else {
            noteSkip("cannot find the play button, so there is nowhere to put the lyrics button")
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
        let words = hasAnythingToDrawFast() ? "this track has lyrics" : "no lyrics for this track — greyed out"
        writeDebugLog(
            "[\(logTag)] lyrics button in place \(frameText(wanted)) (visible round button; tap to expand/collapse; \(words))"
        )
    }

    /// 那枚键长什么样：**永远是那个歌词图标**；这一首没词就变灰（**但仍然可点** —— 点了会说明原因）。
    ///
    /// ★ 2026-10-11（用户提的）：展开时**不再**换成 `chevron.down`。
    /// 用户原话：「现在点击歌词按钮之后会显示一个向下的箭头，能不能给这个箭头删了，
    /// 然后就只有原本的歌词长相」+「**它原本就是歌词图标，就无论怎么点，它看起来都是那个歌词图标**」。
    /// （收起仍然靠点这一颗 —— 图标不变，位置也不变。）
    private static func applyToggleAppearance(to zone: UIControl) {
        let symbol = "quote.bubble.fill"

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
                let candidates = ["quote.bubble.fill", "quote.bubble", "text.alignleft"]
                let image = candidates
                    .compactMap { UIImage(systemName: $0, withConfiguration: configuration) }
                    .first
                glyph.image = image?.withRenderingMode(.alwaysTemplate)
            }
        }

        // ★ 2026-10-11：判据从 `hasLyricsAvailable()`（只认"有时间轴的词级/行级"）换成热路径版的
        //   `hasAnythingToDrawFast()` —— 否则"没有时间轴但能静态列出全文"那一档会被错误地变灰。
        zone.alpha = hasAnythingToDrawFast() ? 1 : toggleDisabledAlpha
    }

    /// 把那枚键拿走（关开关 / 离开页面）。
    private static func removeToggle() {
        guard let zone = lastToggleZone else { return }
        zone.removeFromSuperview()
        lastToggleZone = nil
    }

    // MARK: - ★ 2026-10-04：封面与歌词键之间的**一行居中歌词**（用户建议的第二条）

    /// 用户原话：
    /// > 把现在的大封面做小，不需要那么大（图片 41 的大小差不多）。然后，在**封面和歌词按钮中间**
    /// > 做一行居中的歌词（**类似于 Spotify 的单行歌词，但这行歌词现在是我们自己做**）
    ///
    /// ## 落点
    /// **封面底边与控件条上沿的中点**（用户从照片里挑的那一档：封面 242pt 之后底 ≈450、
    /// 控件条上沿 604 ⇒ 中点 ≈527，与他看着照片要的 525 一致）。宽度与歌词块同宽
    /// （两侧各 `stageSideInset`）。所以这一行**自己会跟着封面走**：封面没缩成（兜底那一路）时，
    /// 它就自动往下落到 512 与 604 的中点 —— 不会压到封面上。
    ///
    /// ## 判据**一处都不新写**
    ///   · 行模型：`currentLines()`（就是展开时那份，含罗马化缓存）—— 这里再按
    ///     「歌词版本 + 曲目 id」缓存一层，因为这条节拍每 0.3s 就问它一次；
    ///   · "唱到哪一行"：`LyricPlaybackTimeline.position(at:in:)` —— 本仓库**唯一**的判定入口
    ///     （`AppleMusicLyricsPage` 用的也是它）。**不许**在这里再写一份 `time <= playback`：
    ///     「同一个判据抄两份、只修一份」在 `seekToTappedLyricLine` 上刚踩过（HANDOFF_2 §4.9）；
    ///   · 播放位置：`WordByWordPositionResolver.shared.currentPositionSeconds()`（逐词那层在用）；
    ///   · 节拍：蹭 `reconcile` 那条 0.3s。**不抢**共享 CADisplayLink —— 它只有一个 handler 槽，
    ///     逐词那一层占着（见 `usePerFrameClockIfAvailable` 那段注释）。
    ///
    /// ## 什么时候**不**显示
    /// 开关关 / 歌词展开着（整页歌词都在，再来一行就是重复）/ 页面要走 / 还没词 /
    /// **一行带时间轴的都没有**（那就没有"当前行"这回事 —— 静态歌词那一档不适用）。
    /// ⚠️ `weak`（独立复核）：页面归它所有；万一有哪条路没走到 `removeSingleLyric`，
    ///   也不该由这个静态变量**钉住上一页的标签**。
    private static weak var singleLyric: UILabel?
    private static var singleLyricShownText = ""
    private static var singleLyricLines: [LyricLine] = []
    private static var singleLyricCacheKey = ""
    private static var didLogSingleLyric = false

    /// 这一行**现在该写哪一句**（`nil` = 现在不该有它）。
    private static func singleLyricTextNow() -> String? {
        guard UserDefaults.nowPlayingSingleLyric else { return nil }

        // ⚠️ 行模型可能还是**上一首**的：切歌**不一定**伴随歌词请求（客户端缓存命中 / 离线歌词时
        //    没有 `color-lyrics` 请求，`resetWordByWordLyrics` 就不会跑）。
        //    两层早就有这条判据（`LyricsWordByWordOverlayView.belongsToAnotherTrack` /
        //    `WordByWordHost.lineModelIsForeign`，口径见 `currentLyricsDtoTrackId` 的说明）；
        //    这里用**同一个**口径：宁可这一行暂时空着，也绝不显示上一首的歌词。
        let model = currentLyricsDtoTrackId
        let live = currentTrackId() ?? ""
        if !model.isEmpty, !live.isEmpty, model != live { return nil }

        let key = "\(currentLyricsVersion)#\(live)"
        if key != singleLyricCacheKey {
            singleLyricCacheKey = key
            // ⚠️ `currentLines()` 会把**没有时间轴的行整首滤掉**（`LyricLinesAdapter` 里的 filter）
            //    ⇒ 没有时间轴的歌这里自然是空的，一句都不画（正确：那种歌没有"当前行"）。
            singleLyricLines = currentLines() ?? []
        }
        guard !singleLyricLines.isEmpty else { return nil }

        // ⚠️ 位置是**可选的**（`currentPositionSeconds() -> Double?`：拿不到播放器时是 nil）
        //    ⇒ 拿不到就**这一拍不画**，不许拿 0 当"唱到开头"（那会让封面下面先闪一句第一行）。
        guard let playback = WordByWordPositionResolver.shared.currentPositionSeconds() else {
            return nil
        }
        let position = LyricPlaybackTimeline.position(at: playback, in: singleLyricLines)
        guard let highlighted = position.highlightedLyricID,
              let line = singleLyricLines.first(where: { $0.id == highlighted }) else {
            return nil
        }
        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// 每拍摆一次。**关闭 / 展开 / 离页**都会把它收起来（`alpha = 0`，对象留着给下一拍用）。
    private static func applySingleLyric(in page: UIView) {
        guard isEnabled, !isOpen, page.window != nil, let text = singleLyricTextNow() else {
            hideSingleLyric()
            return
        }
        let label = ensureSingleLyricLabel(in: page)
        layoutSingleLyric(label, in: page)
        showSingleLyric(text, on: label)
    }

    private static func ensureSingleLyricLabel(in page: UIView) -> UILabel {
        if let existing = singleLyric {
            if existing.superview !== page {
                existing.removeFromSuperview()
                page.addSubview(existing)
            }
            page.bringSubviewToFront(existing)
            return existing
        }

        let label = UILabel()
        label.accessibilityIdentifier = "eevee-npv-single-lyric"
        label.textAlignment = .center
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        // ⚠️ **不吃触摸**：它落在封面与控件条之间那条空带上，那一带下面是别人的手势区。
        label.isUserInteractionEnabled = false
        // 字号取 `.player` 档的主歌词字号（22pt）—— 与展开时那一页同一个量级，
        // 展开/收起时不会有"字忽然变大变小"的感觉。
        label.font = UIFont.systemFont(ofSize: 22, weight: .semibold)
        label.textColor = UIColor.white.withAlphaComponent(0.96)
        // 底下是我们的取色渐变，深浅都可能 ⇒ 与标题行同样的可读性手法：一点阴影。
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 0.35
        label.layer.shadowRadius = 8
        label.layer.shadowOffset = CGSize(width: 0, height: 1)
        label.alpha = 0
        page.addSubview(label)
        page.bringSubviewToFront(label)
        singleLyric = label

        if !didLogSingleLyric {
            didLogSingleLyric = true
            writeDebugLog(
                "[\(logTag)] the one-line lyric between the cover and the lyrics button is up"
                    + " (22pt, centred between the cover's bottom and \(Int(controlBandMidY - controlBandHalfHeight)))"
            )
        }
        return label
    }

    /// 摆哪一行：**封面底边与控件条上沿的中点**（见上面那段）。
    private static func layoutSingleLyric(_ label: UILabel, in page: UIView) {
        let bandTop = controlBandMidY - controlBandHalfHeight
        let coverBottom = visibleCoverBottom(in: page) ?? page.bounds.midY
        let height: CGFloat = 30
        // ⚠️ 夹一道上限（独立复核）：`visibleCoverBottom` 拿不到主封面时会退回**卡片**那张的底边
        //    （≈878）⇒ 中点会落到进度条上。宁可让它贴着控件条上沿，也不要压住进度条。
        let centerY = min((coverBottom + bandTop) / 2, bandTop - height / 2)
        let frame = CGRect(
            x: stageSideInset,
            y: (centerY - height / 2).rounded(),
            width: max(60, page.bounds.width - stageSideInset * 2),
            height: height
        )
        if label.frame != frame { label.frame = frame }
    }

    /// 封面（**缩放之后**那一帧）的底边。量不到 ⇒ `nil`（调用方退回页面中线，宁可摆低一点也不摆错）。
    private static func visibleCoverBottom(in page: UIView) -> CGFloat? {
        guard let list = findByIdentifier(listIdentifier, in: page),
              let cover = visibleCover(in: list, page: page) else { return nil }
        return untransformed(cover, in: page).maxY
    }

    private static func hideSingleLyric() {
        guard let label = singleLyric, label.alpha > 0.01 else { return }
        label.alpha = 0
        singleLyricShownText = ""
    }

    /// 换句时**交叉淡入**（0.18s）；开「减弱动态效果」就直接换字。
    private static func showSingleLyric(_ text: String, on label: UILabel) {
        if label.alpha < 0.99 {
            label.text = text
            singleLyricShownText = text
            UIView.animate(
                withDuration: 0.18,
                animations: { label.alpha = 1 },
                completion: nil
            )
            return
        }
        guard singleLyricShownText != text else { return }
        singleLyricShownText = text
        guard !UIAccessibility.isReduceMotionEnabled else {
            label.text = text
            return
        }
        UIView.transition(
            with: label,
            duration: 0.18,
            options: [.transitionCrossDissolve, .allowUserInteraction],
            animations: { label.text = text },
            completion: nil
        )
    }

    /// 拿走（关开关 / 页面收尾）。缓存也一起清：下一首 / 下一次进来重新算。
    private static func removeSingleLyric() {
        singleLyric?.removeFromSuperview()
        singleLyric = nil
        singleLyricShownText = ""
        singleLyricCacheKey = ""
        singleLyricLines = []
    }

    // MARK: - ★ 2026-10-12：被我们移走的标题行**还能点**（点歌名 / 歌手跳专辑 / 歌手页）

    /// 触摸替身（来龙去脉见 `NowPlayingTitleRelayView` 的说明）。
    private static weak var titleRelay: NowPlayingTitleRelayView?
    private static var titleRelayForwards = 0

    /// 每拍把替身对准"当前那一行"。
    ///
    /// **两个状态都要摆**：展开时那一行在缩略图右边（`lastUnit`），收起时在左上角
    /// （`closedTitleRow`）—— 两处都是被 `transform` 移出自己 cell 的，所以两处都点不到。
    /// 一行都没有（量不到标题行）就把替身收掉：宁可没有替身，也不要一个乱转发触摸的层。
    private static func applyTitleRelay(in page: UIView) {
        guard let row = lastUnit ?? closedTitleRow, row.window != nil else {
            removeTitleRelay()
            return
        }

        let relay: NowPlayingTitleRelayView
        if let existing = titleRelay, existing.superview === page {
            relay = existing
        } else {
            relay = NowPlayingTitleRelayView(frame: page.bounds)
            relay.backgroundColor = .clear
            relay.isUserInteractionEnabled = true
            relay.accessibilityIdentifier = "eevee-npv-title-relay"
            relay.isAccessibilityElement = false
            relay.onForward = { noteTitleRelayForward() }
            page.addSubview(relay)
            titleRelay = relay
        }
        relay.row = row
        if relay.frame != page.bounds { relay.frame = page.bounds }
        page.bringSubviewToFront(relay)
    }

    /// 真的转发了一次触摸 ⇒ 记一行（**有上限**：这是每点一次都会走的路，不许刷屏）。
    ///
    /// 为什么要这行日志：用户 2026-10-12 报的"点歌名/歌手不能跳转"在**上一份日志里
    /// 一条痕迹都没有**（我们根本没参与那次触摸）。有了它，下一份日志能直接回答
    /// "替身接到触摸了吗、转进去了吗"。
    private static func noteTitleRelayForward() {
        guard titleRelayForwards < 5 else { return }
        titleRelayForwards += 1
        writeDebugLog(
            "[\(logTag)] forwarded a tap into the moved title row — forward #\(titleRelayForwards)"
                + " (it should open the album / artist page)"
        )
    }

    private static func removeTitleRelay() {
        titleRelay?.removeFromSuperview()
        titleRelay = nil
    }

    // MARK: - 我们自己的容器

    private static func ensureContainer(in page: UIView, frame: CGRect) -> UIView {
        if let existing = objc_getAssociatedObject(page, &containerKey) as? UIView {
            if existing.superview !== page { page.addSubview(existing) }
            if existing.frame != frame { existing.frame = frame }
            // 歌词要能点（点行跳转），但**容器之外不吃触摸**；容器本身只占歌词区。
            existing.isUserInteractionEnabled = true
            applyContainerPassThrough(to: existing, frame: frame)
            page.bringSubviewToFront(existing)
            lastContainer = existing
            return existing
        }

        let container = NowPlayingLyricsContainerView(frame: frame)
        container.backgroundColor = .clear
        container.clipsToBounds = true
        container.accessibilityIdentifier = "eevee-npv-lyrics-container"
        container.isAccessibilityElement = false
        applyContainerPassThrough(to: container, frame: frame)
        page.addSubview(container)
        page.bringSubviewToFront(container)
        objc_setAssociatedObject(page, &containerKey, container, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        lastContainer = container
        return container
    }

    // MARK: - 歌词区底沿的署名（Spicy Lyrics 条款 §6）

    /// 署名那一行的高度 / 距控制条上沿的距离 / 与歌词之间留的空隙。
    ///
    /// ★ 2026-10-13（用户）：「把滚动歌词的下部分抬高，确保歌词不会穿过这个上传者什么的」
    ///   —— 这三个数**同时**决定"歌词区底部要抬高多少"（见 `stageBottomReserve`）：
    ///   歌词（连同它自己的底部渐隐带）必须止步在署名**上方** `creditGapAboveLyrics` 处。
    private static let creditHeight: CGFloat = 14
    private static let creditBottomInset: CGFloat = 3
    private static let creditGapAboveLyrics: CGFloat = 8

    /// 署名那一行的**顶边**（页面坐标系）。
    private static var creditTop: CGFloat {
        controlBandMidY - controlBandHalfHeight - creditBottomInset - creditHeight
    }

    /// 歌词区底部要为署名让出的高度。stage 本来就比署名低时返回 0 —— **绝不为负**，
    /// 否则容器会被算成负高（小屏 + 大字号时真的可能量到）。
    private static func stageBottomReserve(for stage: CGRect) -> CGFloat {
        max(0, stage.maxY - (creditTop - creditGapAboveLyrics))
    }

    /// 歌词区**底沿**那条小字署名：`上传者 X · 制作者 Y`（没有社区署名时是彩蛋
    /// `Thx,Spicy Lyrics!`），**可点**。
    ///
    /// ★ 2026-10-13（用户拍板「方案 1」）：**不再重复提供商** —— 提供商在歌手那一行，
    /// 这一行只承担条款里"可链接的上传者/制作者"那半。拼接规则见
    /// `currentLyricsPlateCreditText()`。
    ///
    /// ## 为什么要有它（用户 2026-10-13 拍板「放 ①」）
    ///
    /// Spicy Lyrics 的服务条款把 `/docs/attribution` 定为**条款的一部分**（§6）：
    /// *"Always name the provider… When `source` is `spicy_lyrics`, credit **and link** the
    /// uploader, and the maker… Attribution goes wherever the lyrics are."*
    ///
    /// 于是我们分三处摆：
    ///   · **歌手那一行**只放**短名**（`providerSuffix()` → `歌手（Spicy Lyrics）`）——
    ///     那里塞不下"制作者 / 上传者"，长了会把歌手名挤掉；
    ///   · **注入 payload 的 `providedBy`** 放**完整纯文本**（Spotify 原生歌词页/卡片底部那一行，
    ///     点不动，但位置够）；
    ///   · **这里**放**可点的那一份** —— 条款要的"link"落在这。
    ///
    /// ## 位置的两条硬约束
    ///
    /// 1. **必须在控制条上沿之上**（`controlBandMidY − controlBandHalfHeight` ≈ 604）。
    ///    那一条（604…648）是 Spotify 自己的键（收藏 / 分享……），我们的容器在那一带
    ///    是**放行触摸**的（`applyContainerPassThrough`）；署名若压上去，它会实心吃掉那些键的点击。
    ///    所以贴着 604 往上摆 —— 正好落在歌词区自己的底部渐隐带里（"底沿"就是那里）。
    /// 2. **跟着歌词一起出现/收起**：只在展开态的 `layoutAndMount` 里摆，收起与离页由
    ///    `removeCreditLabel()` 摘掉。没有歌词时署名文本为空 ⇒ 它也不会空挂一条。
    private static func ensureCreditLabel(in page: UIView, lyricsFrame: CGRect) {
        // 文本由 `currentLyricsPlateCreditText()` 拼（**这一行专用**：只写"上传者/制作者"，
        // 提供商留给歌手那一行；没有社区署名时走那句彩蛋 `Thx,Spicy Lyrics!`，别的源留空
        // ⇒ 这一条整行不出现）。
        // 自绘歌词页页脚用的是 `currentLyricsCreditText()`（**带**提供商，那一页没有歌手行）。
        let credit = currentLyricsPlateCreditText()
        guard !credit.isEmpty else {
            removeCreditLabel()
            return
        }

        let label: UILabel
        if let existing = objc_getAssociatedObject(page, &creditLabelKey) as? UILabel {
            label = existing
            if label.superview !== page { page.addSubview(label) }
        } else {
            let fresh = UILabel()
            fresh.font = .systemFont(ofSize: 11, weight: .regular)
            fresh.textColor = .secondaryLabel
            fresh.numberOfLines = 1
            fresh.lineBreakMode = .byTruncatingMiddle
            fresh.adjustsFontSizeToFitWidth = true
            fresh.minimumScaleFactor = 0.8
            fresh.isUserInteractionEnabled = true
            fresh.accessibilityIdentifier = "eevee-npv-lyrics-credit"
            fresh.addGestureRecognizer(
                UITapGestureRecognizer(
                    target: NowPlayingLyricsCreditTarget.shared,
                    action: #selector(NowPlayingLyricsCreditTarget.tapped)
                )
            )
            page.addSubview(fresh)
            objc_setAssociatedObject(page, &creditLabelKey, fresh, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            lastCreditLabel = fresh
            label = fresh
        }
        lastCreditLabel = label

        if label.text != credit { label.text = credit }
        // 无障碍：有链接就按"链接"播报（与可点这件事保持一致）。
        label.isAccessibilityElement = true
        label.accessibilityLabel = credit
        label.accessibilityTraits = creditLinks().isEmpty ? .staticText : .link

        let height = Self.creditHeight
        let inset: CGFloat = 2
        let bottom = (controlBandMidY - controlBandHalfHeight) - Self.creditBottomInset
        let target = CGRect(
            x: lyricsFrame.minX + inset,
            y: (bottom - height).rounded(),
            width: max(0, lyricsFrame.width - inset * 2),
            height: height
        )
        if label.frame != target { label.frame = target }
        // 后写的赢：容器是在我们之前 `bringSubviewToFront` 的，署名要压在它上面才点得到。
        page.bringSubviewToFront(label)
    }

    private static func removeCreditLabel() {
        // ⚠️ 用记下来的那个 `label` 摘，**不查 `lastPage`** —— 离页时 `lastPage` 可能已经换了人，
        //   查它会留下一条挂在上一页上的孤儿署名。
        lastCreditLabel?.removeFromSuperview()
        if let label = lastCreditLabel, let page = label.superview {
            objc_setAssociatedObject(page, &creditLabelKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        lastCreditLabel = nil
    }

    /// 可点的链接（顺序 = 显示顺序）：提供者站点 + 每个带 `url` 的贡献者。
    ///
    /// 条款 §6 原话是 *"Use the `url` on each contributor as the link target"* ——
    /// 所以点开的是**他们自己的页面**，不是我们的。
    static func creditLinks() -> [(title: String, url: URL)] {
        var links: [(title: String, url: URL)] = []
        let provider = currentLyricsProvider.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = currentLyricsProviderURL, !provider.isEmpty {
            links.append((provider, url))
        }
        for contributor in currentLyricsContributors {
            guard let url = contributor.url else { continue }
            links.append((contributor.role.label + " " + contributor.name, url))
        }
        return links
    }

    /// 点那条署名：一个链接就直接开；多个弹一张 Action Sheet（每条链接一个按钮）。
    ///
    /// 为什么不是"整条文字里逐词命中"：那需要把标签拆成多段并做字符级命中测试，
    /// 而这行字只有一两段链接、点一下就能选 —— 不值得为它引一套富文本命中。
    static func openCreditLink(_ sender: UIView?) {
        let links = creditLinks()
        guard !links.isEmpty else {
            writeDebugLog("[\(logTag)] credit tapped but nothing is linkable")
            return
        }
        if links.count == 1 {
            open(links[0].url)
            return
        }

        guard let host = sender?.window?.rootViewController
            ?? lastPage?.window?.rootViewController
            ?? keyWindowRootViewController() else {
            open(links[0].url)
            return
        }
        var top = host
        while let presented = top.presentedViewController { top = presented }

        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .alert)
        for link in links {
            sheet.addAction(UIAlertAction(title: link.title, style: .default) { _ in
                NowPlayingLyricsPlate.open(link.url)
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel".uiKitLocalized, style: .cancel))
        top.present(sheet, animated: true)
    }

    /// 既没有 sender、也没有记住的听歌页时，退回**当前 key window** 的根控制器。
    ///
    /// 谁需要这条路：**自绘歌词页页脚的署名**（`AppleMusicLyricsPage.providerFooter`）。
    /// 那一页不是本类型记住的 `lastPage`，所以不补这一步的话，多条链接（提供商 + 两个社区
    /// 贡献者）会**只开出第一条** —— 条款 §6 要的"链接上传者/制作者"就落空了。
    private static func keyWindowRootViewController() -> UIViewController? {
        let windows = UIApplication.shared.windows
        return (windows.first(where: { $0.isKeyWindow }) ?? windows.first)?.rootViewController
    }

    private static func open(_ url: URL) {
        writeDebugLog("[\(logTag)] opening attribution link \(url.host ?? "?")")
        onMainThreadSync { UIApplication.shared.open(url) }
    }

    /// 把"控件条那一条要放行触摸"告诉容器（见 `NowPlayingLyricsContainerView`）。
    ///
    /// 放行的范围：从 `controlBandMidY − 22`（≈604）起**到底边**。
    /// 照片 71 + 日志 56 的实测：收藏键（＋/✓）在 604…648、我们搬过去的分享键同样在 604…648，
    /// 而歌词容器的底边是 641（`lyrics area 20,242,374,399`）⇒ 那一片必须让开。
    ///
    /// ★ 2026-10-13：容器底边现在被 `stageBottomReserve` 抬到 ≈579（署名顶边之上），
    /// **已经不再压住那一条**，所以这里的值通常是 0。留着它是因为这个函数还有别的调用点：
    /// 版式变了（进度条量不到、走了 `lyricsBottom` 那条退路）时容器仍可能伸进控制条。
    private static func applyContainerPassThrough(to container: UIView, frame: CGRect) {
        guard let plate = container as? NowPlayingLyricsContainerView else { return }
        plate.passThroughBottom = max(0, frame.maxY - (controlBandMidY - controlBandHalfHeight))
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
        // ★ 2026-10-12：**不再**看「更好的逐词歌词」—— 那两颗开关在这一层里的分工见
        //   `isEnabled` 上面那段：这一层画的就是那套渲染，"更好的"只管 Spotify 原生歌词页。
        //   （以前这里一 false，那枚键会被画成灰的，用户会以为"这首没词"。）
        return hasUsableWordLevelData(currentLyricsDto) || hasUsableLineLevelData(currentLyricsDto)
    }

    /// 这一首有没有能画的东西（行级即可 —— 与上一版放宽后的门禁一致）。
    ///
    /// ★ 2026-10-11：**再加一条"有事可说"的路** —— 用户要的是"键随时能按"：
    ///   没词可画时打开，就在歌词的位置写「未找到歌词」/「此歌曲为纯音乐。」/「正在查找歌词…」。
    ///   （以前这里直接 false ⇒ 键看得见、点下去什么都不会发生，用户报的就是这个。）
    private static func canShow(for page: UIView) -> Bool {
        if #available(iOS 26.0, *) {} else { return false }
        // ★★ 2026-10-12（用户：「那怎么办，自己画的这套视图塞不进去单纯的逐词吗」）：
        //   **这里不再要求「更好的逐词歌词」。** 这一层画的就是那套渲染（iOS 26 起），
        //   在这一层里**没有第二种渲染可选**，所以那颗开关不该在这里当闸门 ——
        //   它管的是 Spotify **原生歌词页**用哪套渲染（`AppleMusicLyricsOverlay` ↔ 旧
        //   `LyricsWordByWord`）。以前在这里 guard 的后果就是用户报的那条：
        //   只开「逐词歌词」时**键摆着、点下去这里 false ⇒ 点不动**（而"整层退出"又会让
        //   kumone 那套版式消失，同样不对）。
        // ★ 用户要求「键随意能按」⇒ 这里**永远为真**：有词就画词，没词就写一句说明
        //   （见 `noticeText()`），画不出来的异常也照样给一句话，绝不留下"点了没反应"的键。
        return true
    }

    /// 打开之后写在歌词**正中间**的那句话。`nil` = 有歌词可画（不写）。
    ///
    /// 四种"没词"必须分开说（这正是用户要的）：
    ///   · 源**明确**说是纯音乐 ⇒ 「此歌曲为纯音乐。」（`song_is_instrumental`，键早就有了）；
    ///   · ★ **有行、但一行时间都没有** ⇒ 「这首歌的歌词没有时间轴」（`lyrics_no_timeline`，本轮新增）；
    ///   · 查完了没有 ⇒ 「未找到歌词」（`ngzhwm_lyrics_unavailable`，键也早就有了）；
    ///   · 还在查 ⇒ 「正在查找歌词…」（`lyrics_looking_up`，上一轮新增的键）。
    /// ⚠️ "查无此歌"**不许**冒充纯音乐 —— 判据是 `LyricsDto.isInstrumental`（只有源明确判定时才置位）。
    /// ⚠️ ★ 2026-10-11（S1）：也**不许**把"这一首没有时间轴"说成"未找到歌词" —— 见下面第 ③ 段。
    private static func noticeText() -> String? {
        // ① 有行而且画得出来 ⇒ 正常画歌词。
        if currentLyricsDto?.lines.isEmpty == false, currentLines() != nil { return nil }
        // ② 源明确说了这是纯音乐。
        if currentLyricsDto?.isInstrumental == true { return "song_is_instrumental".localized }
        // ③ 有行、却画不出来。★ 先说清是**哪一档**"画不出来"，别一律报"没找到"。
        if let dto = currentLyricsDto, !dto.lines.isEmpty {
            // ★ 这一档是**误报**的源头（S1）：
            //   `LyricLinesAdapter.toAppleMusicLyricLines()` 第 21 行的 `.filter { $0.offsetMs != nil }`
            //   会把"一行时间都没有"的整首歌滤成空 ⇒ 我们这层没有行模型；
            //   而**注入给 Spotify 的那份 payload 是带这些行的**（Spotify 自己的歌词卡能列全文）
            //   ⇒ 用户看到的是"歌词明明有、我们却说未找到"。数据在，只是没有时间轴。
            //
            // ★★ 2026-10-11（用户追了一句「**歌词呢**」）：这一档**不再只写一句话** ——
            //   文本提得出来就 `nil`（去画静态歌词，见 `staticLines(from:)`）；
            //   只有**连文本都提不出来**（全是空行）才退回那句话。
            if !dto.lines.contains(where: { $0.offsetMs != nil }) {
                return currentUntimedLines() == nil ? "lyrics_no_timeline".localized : nil
            }
            // 有行、也有至少一行带时间，却还是画不出来 ⇒ 这是转换异常，按"没找到"说，**别做成死键**。
            return "ngzhwm_lyrics_unavailable".localized
        }
        // ④ 数据还没到：正在查 vs 查完了没有。
        switch currentLyricsLookupState {
        case .idle, .loading:
            // ★ 2026-10-12（用户点名要的**彩蛋**）：「正在查找歌词…」→「少女祈祷中…」。
            //   开关在**调试**页（「替换寻找歌词时的占位符」），**默认关**。
            //   全文只此一处写这句占位文本（`lyrics_looking_up` 的另一处只是注释）。
            return UserDefaults.lyricsSearchPlaceholderEasterEgg
                ? "lyrics_looking_up_easter_egg".localized
                : "lyrics_looking_up".localized
        case .failed, .found:
            return "ngzhwm_lyrics_unavailable".localized
        }
    }

    private static weak var lastNoticeLabel: UILabel?

    /// 摆 / 撤那句说明。`text == nil` ⇒ 撤掉（有歌词可画了）。
    private static func applyNoticeLabel(_ text: String?, in container: UIView) {
        guard let text else {
            lastNoticeLabel?.removeFromSuperview()
            lastNoticeLabel = nil
            return
        }

        let label: UILabel
        if let existing = lastNoticeLabel, existing.superview === container {
            label = existing
        } else {
            lastNoticeLabel?.removeFromSuperview()
            let fresh = UILabel()
            fresh.accessibilityIdentifier = "eevee-npv-lyrics-notice"
            fresh.textAlignment = .center
            fresh.numberOfLines = 0
            fresh.font = .systemFont(ofSize: 17, weight: .medium)
            fresh.textColor = UIColor.white.withAlphaComponent(0.55)
            // 我们自己的一句话，不该抢歌词行的点击（点行跳转仍在 SwiftUI 那一层）。
            fresh.isUserInteractionEnabled = false
            container.addSubview(fresh)
            lastNoticeLabel = fresh
            label = fresh
        }

        if label.text != text { label.text = text }

        // 居中：容器就是"歌词那一块"（日志 55 的 `20,261,374,323`），
        // 用 `sizeThatFits` 量出文字高度再把它摆在中间 —— 直接铺满会变成顶对齐。
        let maxWidth = max(container.bounds.width - 32, 40)
        let size = label.sizeThatFits(CGSize(width: maxWidth, height: .greatestFiniteMagnitude))
        let frame = CGRect(
            x: 16,
            y: ((container.bounds.height - size.height) / 2).rounded(),
            width: maxWidth,
            height: size.height
        )
        if label.frame != frame { label.frame = frame }
        container.bringSubviewToFront(label)
    }

    /// 把"没有时间轴的文本行"包成渲染层吃的 `LyricLine`（时间一律 0、无音节）。
    ///
    /// ★ 2026-10-11（用户：「这个没有时间轴的歌词的滚动，展示大小什么的**不是复用有时间轴的逻辑吗**」）——
    /// 复用就是对的做法：**同一套**渲染层 + `AppleMusicLyricsPage.isStatic` 接管三件事
    /// （不高亮、不跟随、点行不跳）。字号 / 行距 / 左右内边距 / 滚动容器 / 底部 120pt 留白
    /// （正好让最后一行躲开控件条）全部自动一致。
    ///
    /// ⚠️ `time: 0` 只是**占位**：`isStatic` 那一档不读它。
    ///
    /// ★★ 2026-10-11（用户：「把罗马字和歌词翻译接上去吧」）：这一档也**照样带译文与罗马字**，
    /// 都按**原数组下标**配对（所以入参带下标）；罗马字仍走仓库那条既有罗马化管线。
    private static func staticLines(from items: [(index: Int, text: String)]) -> [LyricLine] {
        let translationLines = currentLyricsDto?.translation?.lines ?? []
        // ⚠️ 走带缓存的 `romanizedContentsForDisplay()`（这个函数也在 0.3s 那条节拍上）。
        let romanizedContents = currentLyricsDto?.romanizedContentsForDisplay() ?? []

        return items.enumerated().map { order, item in
            let translation: String? = item.index < translationLines.count
                ? translationLines[item.index]
                : nil
            let trimmedText = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let romanized = item.index < romanizedContents.count
                ? romanizedContents[item.index].trimmingCharacters(in: .whitespacesAndNewlines)
                : ""

            return LyricLine(
                id: "eevee-static-\(order)",
                time: 0,
                duration: 0,
                timingKind: .lineSynchronized,
                text: item.text,
                syllables: [],
                // 与原文相同 ⇒ 不显示（同 `LyricLinesAdapter.romanization(original:romanized:)`）。
                romanization: (romanized.isEmpty || romanized == trimmedText) ? nil : romanized,
                translation: translation
            )
        }
    }

    private static func currentLines() -> [LyricLine]? {
        let lines = (currentLyricsDto?.toAppleMusicLyricLines()) ?? []
        return lines.isEmpty ? nil : lines
    }

    /// 这一首"**没有时间轴、但有行**"的歌词文本（`nil` = 这一档不适用）。
    ///
    /// ★ 2026-10-11（用户问的「**歌词呢**」）：加载到没有时间轴的歌词时，
    /// 以前只写一句「这首歌的歌词没有时间轴」—— 数据明明在（Spotify 自己那张卡列得出全文）。
    /// 现在把文本提出来**静态列出来**（见 `staticLines(from:)` + `isStatic`），这一档才算真的有内容。
    ///
    /// ⚠️ 只认"**一行时间都没有**"这一档；只要有一行带 `offsetMs`，就交给时间轴那条路
    /// （`LyricLinesAdapter` 会把带时间的挑出来渲染）。
    ///
    /// ★ 2026-10-11：返回的是 `(原数组下标, 文本)` —— 下标要**一直带着**，因为译文与罗马字
    /// 都按同一个下标配对（空行被滤掉之后下标会错位，这正是本函数不返回 `[String]` 的原因）。
    private static func currentUntimedLines() -> [(index: Int, text: String)]? {
        guard let dto = currentLyricsDto, !dto.lines.isEmpty else { return nil }
        guard !dto.lines.contains(where: { $0.offsetMs != nil }) else { return nil }
        let items = dto.lines.enumerated().compactMap { index, line -> (index: Int, text: String)? in
            let text = line.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : (index, text)
        }
        return items.isEmpty ? nil : items
    }

    /// 这一首**有没有东西可画**：画歌词 / 画静态歌词 / 写一句话 —— 三占其一。
    ///
    /// ⚠️ 它会建数组（`currentUntimedLines` / `noticeText`），**只能用在"点开的那几拍"**
    /// （重试窗口 ≤5 拍）；每 0.3s 的复查节拍上要用 `hasAnythingToDrawFast()`。
    private static func hasSomethingToShow() -> Bool {
        if hasLyricsAvailable() { return true }
        if currentUntimedLines() != nil { return true }
        return noticeText() != nil
    }

    /// 热路径版（**不建数组**，只读几个 bool / 计数）：有没有东西可画。
    ///
    /// ⚠️ 不能在这里调 `noticeText()` / `currentLines()` —— 那是每 0.3s 一次的节拍
    /// （`hasLyricsAvailable()` 上面那段注释记过同一件事）。
    private static func hasAnythingToDrawFast() -> Bool {
        if hasLyricsAvailable() { return true }
        if currentLyricsDto?.lines.isEmpty == false { return true }
        switch currentLyricsLookupState {
        case .idle, .loading: return true      // 还在查 ⇒ 键也该是亮的（点了会说明"正在查找"）
        case .failed, .found: return false
        }
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
        writeDebugLog("[\(logTag)] not expanding (\(reason))")
    }

    /// 「这一层为什么没参与」——一次一页只报一行。
    ///
    /// ★ 2026-10-12：这条现在只剩**一个**原因（「歌词进播放器」关了）。加它是因为
    /// "歌词键不见了"必须能从日志里读出来 —— 本仓库的老规矩：任何静默返回都要留话。
    private static var lastEnabledSkipReason = ""

    private static func noteDisabledReason() {
        let reason = "'Lyrics in the player' is off"
        guard lastEnabledSkipReason != reason else { return }
        lastEnabledSkipReason = reason
        writeDebugLog("[\(logTag)] our layer is not in play (\(reason))")
    }

    private static func frameText(_ frame: CGRect) -> String {
        "\(Int(frame.origin.x)),\(Int(frame.origin.y)),\(Int(frame.width)),\(Int(frame.height))"
    }

    /// 锚点那种"可能量不到"的数值：量不到就说 `not found`，**不编造**。
    private static func anchorText(_ value: CGFloat?) -> String {
        guard let value else { return "not found" }
        return "\(Int(value))"
    }

    /// 最近一次 `measure()` 量到的三个锚点（**只给日志用**，避免为了打印再走查一遍）。
    private static var lastAnchorText = ""

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

/// 被我们**移走**的标题行的触摸替身 —— 让"点歌名 / 歌手跳专辑 / 歌手页"这个原生功能活下来。
///
/// ## 为什么需要它（用户 2026-10-12 报的）
///
/// > spotify 点击歌手 / 歌曲名字那里是可以点击然后跳往专辑或者歌手主页的。但是现在没这个功能。
///
/// 我们把标题行用 `transform` 抬到了左上角（照片 72/73 的 kumone 位），但**行还在它原来的
/// cell 里** —— UIKit 的命中测试是从窗口往下走的：点落在 cell 的 frame **之外**时，
/// 那一整棵子树根本不会被问 ⇒ 抬上去的那一行**看着在、点不到**（这是"移动别人的子视图"
/// 的固有代价，pw 也踩过）。
///
/// ## 做法（照 pw `PlayerLyrics.x` 的 `hitTest:`）
///
/// pw 在同一处境下的解法是：在**自己**这一层重写 `hitTest:`，把点**换算**进那一行，
/// 问它要一个命中视图并返回（`PlayerLyrics.x:100-104`）。这里照做：
///   · 本层铺满页面，但 `point(inside:)` 只认**那一行当前的视觉 frame**；
///   · `hitTest` 里先问那一行；命中就把那个视图返回 ⇒ 触摸照常走到 Spotify 的控件
///     （它的祖先手势 / 选中机制也都还能收到这次触摸）。
/// 范围之外一律返回 nil，触摸穿透给下面原有的视图。
final class NowPlayingTitleRelayView: UIView {

    /// 被我们移走的那一行（弱引用：换歌 / 页面走了它自己就没了）。
    weak var row: UIView?

    /// 真的转发了一次触摸 ⇒ 叫一声（只给日志用，见 `noteTitleRelayForward`）。
    var onForward: (() -> Void)?

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01 else { return false }
        guard let row, row.window != nil else { return false }
        return row.convert(row.bounds, to: self).contains(point)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01 else { return nil }
        guard let row, row.window != nil else { return nil }
        guard row.convert(row.bounds, to: self).contains(point) else { return nil }
        // 把点换算进那一行自己的坐标系，问它（以及它的子视图）谁接到这一下。
        let hit = row.hitTest(row.convert(point, from: self), with: event)
        if hit != nil { onForward?() }
        return hit
    }
}

/// 歌词容器。
///
/// **唯一特殊之处**：控件条那一条（底部 ≈40pt）**放行触摸**。
///
/// 为什么需要它（用户 2026-10-11 报的「为什么分享按键和收藏按键用不了」）：
/// 这个容器铺满整个歌词区（日志 56：`lyrics area 20,242,374,399` ⇒ y 242…641）、
/// `isUserInteractionEnabled = true`（歌词行要靠它收点击去跳转）、而且被
/// `bringSubviewToFront` 顶到最上面 ⇒ **它把这一片的触摸全吃掉了** ——
/// 包括 Spotify 自己的收藏键（＋/绿色 ✓，就坐在 371,626）。
///
/// 只让**那一条**（那一段本来就被上下渐隐遮着，少一点行点击没关系），
/// 歌词正文那一片照旧吃触摸。
final class NowPlayingLyricsContainerView: UIView {

    /// 底部放行多少 pt（0 = 不放行）。
    var passThroughBottom: CGFloat = 0

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard super.point(inside: point, with: event) else { return false }
        guard passThroughBottom > 0 else { return true }
        return point.y < bounds.height - passThroughBottom
    }
}

/// 歌词键的手势目标（`UIControl` 的 target 必须是 ObjC 对象）。
final class NowPlayingLyricsToggleTarget: NSObject {

    static let shared = NowPlayingLyricsToggleTarget()

    @objc func tapped() {
        onMainThreadSync { NowPlayingLyricsPlate.toggle() }
    }
}

/// 分享键**替身热区**的点击目标（同上，target 必须是 ObjC 对象）。
final class NowPlayingShareRelayTarget: NSObject {

    static let shared = NowPlayingShareRelayTarget()

    @objc func tapped() {
        onMainThreadSync { NowPlayingLyricsPlate.relayShareTap() }
    }
}

/// 歌词区底沿那条**署名**的点击目标（同上，target 必须是 ObjC 对象）。
///
/// 不带参数：多带一个 `sender` 就要写成 `#selector(...tapped(_:))`，两处签名必须一起改，
/// 而这种"改了选择器忘了改注册"的错只会在运行时炸。署名那条链接取全局状态即可
/// （`currentLyricsProviderURL` / `currentLyricsContributors`），不需要从手势里拿。
final class NowPlayingLyricsCreditTarget: NSObject {

    static let shared = NowPlayingLyricsCreditTarget()

    @objc func tapped() {
        onMainThreadSync { NowPlayingLyricsPlate.openCreditLink(nil) }
    }
}
