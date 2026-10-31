// 歌词叠加视图本体。从 `AppleMusicLyricsOverlay.swift` 原样拆出。
import SwiftUI
import UIKit

// ⚠️ `@available(iOS 26.0, *)` 必须留着：这个视图用的是 iOS 26 才有的
// `attributedTextFormattingDefinition` 那条自定义 TextAttribute 路径
// （见 `LyricAttributedText.swift`）。2026-10-17 的拆分漏了它，CI 直接报 availability。
@available(iOS 26.0, *)
struct AppleMusicLyricsOverlayView: View {

    /// 行模型。换歌时由外部替换。
    ///
    /// ⚠️ 是 `var` 而不是 `let`：切歌时 `update()` 走的是"就地更新、不重建 hosting
    /// controller"那条路（为了保住滚动位置），而那条路以前**没有任何地方写回行模型** ——
    /// 结果就是"壳上的曲名/歌手换了，歌词还是上一首的"。
    var lines: [LyricLine]
    /// 背景样式（`.stage` 全屏 / `.card` 预览）。
    ///
    /// ⚠️ 是 `var` 而不是 `let`：全屏 ↔ 预览切换、以及"实心档"变化时，
    /// 都由宿主就地写入，不重建 hosting controller —— 否则整页 SwiftUI 状态
    /// （滚动位置）会被丢掉。背景因此不能像以前那样在构造时固化成 `AnyView`。
    var backdropStyle: LyricsBackdropView.Style
    /// 背景是否走"实心"档（全屏）。
    var solidBackdrop: Bool
    /// 是否显示底部「歌词提供者」。
    ///
    /// ⚠️ 故意是 `var` 而不是 `let`：全屏 ↔ 预览切换时只改这个值 + `sideInset`，
    /// 由 SwiftUI 就地更新布局，**不重建 hosting controller**。
    /// 之前是 `let` + 在 host 里重建 rootView，代价是整页状态（滚动位置）被丢掉，
    /// 于是切屏后歌词回到顶部、不再居中于当前行。
    var showsProviderFooter: Bool
    /// 左右内边距。同样是 `var`，理由见上。
    var sideInset: CGFloat
    /// 预览卡片顶部标题栏的高度（卡片高度 − 歌词视图高度，实测 39pt）。
    ///
    /// 只有预览用：这段高度本来是 Spotify 的标题栏（`歌词` + 分享 + 展开），
    /// 现在由我们自己画（`previewHeader`），所以歌词内容要让出同样多的高度，
    /// 否则会被顶进我们画的标题栏里。
    var previewHeaderInset: CGFloat = 0

    /// 预览那一行「歌词 · 分享 · 全屏」**要不要自己画**。
    ///
    /// 默认 `true`（卡片内嵌那一档要它：Spotify 那块 39pt 的面板是父视图自己刷的色，
    /// 子视图盖不住，标题栏只能我们自己出）。
    ///
    /// ★ 2026-10-09：**"歌词进播放器"这一档要 `false`。**
    /// 用户照片 60 报"「歌词 · 分享 · 打开全屏歌词」这几个按钮还在"，而那一行**是我们自己画的**：
    /// 实测几何对得上 —— 容器 20,210,374,378、内边距 14、两个 40×32 的按钮 ⇒ 分享键中心
    /// 319pt、全屏键中心 364pt，照片里量的正是 319 / 364。原生那一行（`lyrics-share-button`
    /// 那三颗）在**列表里那张被折成 0 高的卡**上（日志 53 的 `2.CollectionViewCell@20,838,374,0`），
    /// 根本不在屏上 —— 所以藏原生入口永远是白费力气（见 `NowPlayingLyricsPlate` 里那段）。
    var showsPreviewHeader: Bool = true

    /// 点行跳转。
    let onSeek: ((TimeInterval) -> Void)?
    /// 曲名 / 歌手 —— 自绘壳的标题栏用。
    ///
    /// 不再依赖原生那一页的标题视图（我们连它长什么样都读不到），直接取
    /// `SPTPlayerTrack`。
    ///
    /// ⚠️ 必须是 `var`：`update()` 在宿主没变时会**就地更新**宿主上的属性
    /// （这样才不会重建 hosting controller、丢掉滚动位置）。换歌时标题要跟着变，
    /// 声明成 `let` 就会在那一行报"对不可变属性赋值"。
    var trackTitle: String
    var trackArtist: String

    /// 背景是否**透明**（不画模糊封面、不铺暗化）。
    ///
    /// 为什么需要（2026-10-05 真机日志 47）：这一层原本只有两种用法 —— 全屏页与**卡片内嵌**，
    /// 两者都需要"自己把底下的原生内容盖掉"（`isBackdropOpaque = true`）。
    /// 但"歌词进播放器"把它摆在了**取色底之上**，那块 414×240 的模糊封面就成了
    /// 用户看到的"糊在屏幕上的一层"（日志 47 的树：
    /// `_UIHostingView<AppleMusicLyricsOverlayView>@0,0,414,240` 里挂着
    /// `UIKitPlatformViewHost<…LyricsBackdropRepresentable>`）。
    /// 播放器那一档要的是"只有歌词"，所以给它一个显式的透明开关。
    var transparentBackdrop: Bool = false

    @ObservedObject var clock: AppleMusicLyricsClock
    /// 播放状态投影（当前时间 / 总时长 / 是否在播放），自绘壳的进度条与播放键用它。
    @ObservedObject var projection: AppleMusicLyricsPlaybackProjection

    /// ★ 2026-10-11：**静态档**（"这一首没有时间轴"）—— 透传给 `AppleMusicLyricsPage`，
    /// 语义与理由写在那边的 `isStatic` 上（不高亮、不跟随、点行不跳）。
    ///
    /// ⚠️ 放在属性表**最后**：逐成员初始化器是位置敏感的，放最后就不会动到既有调用点。
    var isStatic: Bool = false

    /// 主歌词下面的**副唱/背景人声**那一小行要不要画。
    ///
    /// ★★ 2026-10-17（用户：「**歌词进播放器**的时候，也**没有额外的歌词结构**啊，
    ///    不是代码已经写了么」）：以前它被绑在 `showsProviderFooter` 上（`body` 里
    ///    `showsBackgroundVocals: showsProviderFooter`），而"歌词进播放器"那一档
    ///    **必须** `showsProviderFooter: false`（那一档不画署名页脚，见 `NowPlayingLyricsHost`）
    ///    ⇒ 于是**整条链路都在、数据也在，就是永远不画**。
    ///    署名页脚是"元信息"，副唱是**歌词内容**，两件事不该共用一个开关。
    ///
    /// ⚠️ 同样放在属性表最后（逐成员初始化器位置敏感，见 `isStatic` 那段）。
    var showsBackgroundVocals: Bool = true

    private static var profile: AppleMusicLyricsMotionProfile { .iOS26_6 }

    /// 预览标题栏那一行的自然高度（15pt 文字 / 32pt 按钮，取按钮高度）。
    /// 用途见 `headerTopInset`：把自绘标题行竖直居中在卡片标题栏那块高度里。
    private static let previewHeaderRowHeight: CGFloat = 32

    /// 全屏（有壳）时才显示自绘标题栏与播放控制；内嵌预览那一小块不显示。
    private var showsShell: Bool { showsProviderFooter }

    /// ★ 2026-10-11：**译文要不要画** —— 尊重"歌词页面"里的那套选择（用户要求）。
    ///
    /// 两个条件：
    ///   · 这一首**有译文行**（`lines` 里至少一行带非空 `translation`）；
    ///   · 用户没关掉「隐藏译文」（`NgzhwmSettingsViewModel.isNeteaseHideTranslationEnabled`，
    ///     默认随设备语言：中文设备默认**显示**、其它默认隐藏 —— 那是仓库既有口径，
    ///     旧 overlay 也是照它判的：`LyricsWordByWord.x.swift` 里
    ///     `showsTranslation && !isNeteaseHideTranslationEnabled`）。
    ///
    /// ⚠️ 算在这里、而不是当参数从外面传：`body` 每一帧都会被时间轴重新求值，
    /// 于是"在设置里一改、回到播放器立刻生效"，不用等下一次取词。
    private var showsTranslationNow: Bool {
        let hasTranslation = lines.contains { line in
            guard let translation = line.translation else { return false }
            return !translation.isEmpty
        }
        // ★★ 2026-10-31（歌词系统翻译）：**我们自己翻出来的译文**不受下面那条历史口径约束 ——
        //   那条「隐藏译文」是当年给 NetEase 的按钮写的，默认值还跟设备语言走
        //   （非中文设备默认隐藏）。用户既然专门打开了「在本机翻译歌词」，
        //   就该看见结果，否则开关开了却什么都没有。
        if UserDefaults.lyricsAutoTranslate { return hasTranslation }
        guard !NgzhwmSettingsViewModel.isNeteaseHideTranslationEnabled else { return false }
        return hasTranslation
    }

    /// 主色：**白色**。
    ///
    /// 与改动前一致（`AppleMusicLyricsPage` 的 `primaryColor` 参数此前没被传过，
    /// 用的就是它的默认值 `.white`）。背景是"模糊封面 + 黑色暗化"，白字是唯一
    /// 在各封面上都稳的选择；歌词、页脚、自绘壳全部共用它，换色时不会漏。
    private let primaryColor: Color = .white

    var body: some View {
        ZStack {
            if transparentBackdrop {
                // 只有歌词：背景完全让给别人（播放器那一档铺的是整页取色底）。
                Color.clear
            } else {
                AppleMusicLyricsBackdrop.makeBackground(
                    style: backdropStyle,
                    solid: solidBackdrop
                )
            }

            if lines.isEmpty {
                // 没有可用行时保持完全透明：让下面的 Spotify 原生歌词透出来，
                // 这比显示一块空背景更不易被误认为「歌词加载失败」。
                Color.clear
            } else {
                AppleMusicLyricsPage(
                    lines: lines,
                    playbackTime: clock.playbackTime,
                    background: AnyView(Color.clear),
                    onClose: nil,
                    onSeek: onSeek,
                    contentInsets: EdgeInsets(
                        // ⚠️ 预览的底边距必须给够，否则"当前行居中"根本不会发生。
                        //
                        // 机制：ScrollView 只在**内容比视口高**时才能滚；中心对齐靠的是
                        // 滚动偏移。卡片只有 320pt，歌词常常只有三四行（百余点），
                        // 内容比视口矮 → 没有可滚范围 → `scrollTo(anchor: .center)`
                        // 无从生效 → 内容只能贴顶，下面留一片空。
                        // 真机表现就是"歌词那几个框太靠上 + 下面很空"。
                        //
                        // 120 这个值是按最坏情况倒推的：单行歌词也要让内容高过视口，
                        // 这样任何一首歌的当前行都能居中。
                        // ⚠️ 关掉预览标题栏那一档（"歌词进播放器"）给 **24pt**：
                        //    没有标题栏之后内容直接顶到容器上沿，而**无壳兜底那条淡出**
                        //    （`legacyFadeStops` 的 `fadeTopRatio = 0.08`，容器 378pt ⇒ 约 30pt）
                        //    会把第一行压暗。原来有标题栏时内容从 45pt 开始、正好在淡出带之下 ——
                        //    这里留 24pt（加上 `scrollInsets` 里那次同样的加法 ⇒ 实际 48pt）保持同样的"干净起点"。
                        top: showsProviderFooter ? 8 : (showsPreviewHeader ? 6 : 24),
                        leading: sideInset,
                        // ★ 2026-10-11：**底边距也要分档** —— 三档共用 120 就是用户报的那条。
                        //
                        // 用户原话：「当歌词已经划到最后一行时，此歌词行不会停留在歌词视图的底部，
                        // 而是可以划动到歌词视图的中间行」。
                        //
                        // 算术（`scrollInsets` 把这个值**加了两次**，见 `AppleMusicLyricsPage`
                        // 的 `footerContent == nil` 那一条）：播放器这一档改动前拿到的是
                        // 120 × 2 = **240pt**，而它的歌词容器只有 399pt
                        // （`lyrics area 20,242,374,399`）⇒ 滚到底时最后一行下方空 240pt，
                        // 那**比容器中线（399/2 ≈ 200）还多** ⇒ 最后一行底边落在容器 y = 399 − 240
                        // = **159**，在中线以上。这就是"最后一行能划到中间去"。
                        //
                        // 这一档取 **24**（与上面 `top:` 同一个数，无壳这一档对称为 24 / 24）：
                        //   · 滚到底 ⇒ 最后一行下方 2 × 24 = **48pt**；
                        //   · 容器下沿 641（它锚在进度条上：`stageBottom = progressTop − 19`，
                        //     所以顶边往上移不改这条算术），控件条占 604…648
                        //     （`controlBandMidY 626 ± 22`，容器在 604 以下放行触摸）
                        //     ⇒ 最后一行落在 641 − 48 = **593**，离控件条上沿还有 11pt；
                        //   · 48pt 相对 399～441pt 的容器是"贴底"，不再够得着中线。
                        //
                        // ⚠️ 预览那一档的 **120 一个字都不改**：卡片只有 320pt、歌词常常只有三四行，
                        //    那 120 是**为了让内容比视口高**（否则 `scrollTo(anchor: .center)`
                        //    无从生效、当前行居不了中）—— 理由见上面 `top:` 那段；全屏的 46 同样不动。
                        bottom: showsProviderFooter ? 46 : (showsPreviewHeader ? 120 : 24),
                        trailing: sideInset
                    ),
                    // 分档按「是不是全屏」决定：
                    // showsProviderFooter 只在全屏页为 true（内嵌预览不显示提供者），
                    // 所以直接拿它当尺度判据，不必再往下传一个额外参数。
                    // ★ 2026-10-11：再加一档 `.player` —— 关掉预览标题栏的那一档
                    //   （"歌词进播放器"）容器是**中段一整块**，用 `.preview` 太挤（照片 67）。
                    typography: showsProviderFooter
                        ? .fullscreen
                        : (showsPreviewHeader ? .preview : .player),
                    // ★★ 2026-10-17（用户：「歌词进播放器的时候也没有额外的歌词结构」）：
                    //    这一行原来写的是 `showsProviderFooter` —— 而"歌词进播放器"那一档
                    //    **必须** `showsProviderFooter: false` ⇒ 副唱永远不画（链路与数据都在）。
                    //    现在由显式参数 `showsBackgroundVocals` 决定（默认 true）；
                    //    调用方想按"是否全屏"收窄就自己传（见 `AppleMusicLyricsOverlay` 那一处）。
                    showsBackgroundVocals: showsBackgroundVocals,
                    // ★ 2026-10-11（用户）：译文接上 —— 判据见 `showsTranslationNow`
                    //   （有译文 + 用户没关掉「隐藏译文」）。译文由渲染层画在**主歌词下方**。
                    showsTranslation: showsTranslationNow,
                    // 歌词提供者页脚：全屏显示，预览不显示（卡片太小）。
                    //
                    // 从全局读而不是做参数，是为了**避免一个能预报的 bug**：
                    // `update()` 在「布局参数没变」时会提前 return，不重建 rootView，
                    // 所以任何存在 view 里、由 host 推入的值在换歌时都会变成陈旧的。
                    // `currentLyricsProvider` 是全局，按需读取天然最新。
                    provider: currentLyricsProvider,
                    // ★ 2026-10-13：完整署名（provider + Spicy Lyrics 社区同步的 uploader/maker）
                    //   也一起推给页脚 —— 条款 §6 要求这些人出现在**歌词所在的那一屏**上。
                    //   与 `provider` 同样从全局按需读（理由见上面那段）。
                    providerCredit: currentLyricsCreditText(),
                    showsProviderFooter: showsProviderFooter,
                    primaryColor: primaryColor,
                    // ⚠️ 两个分支要**各自**包成 AnyView，不能写成
                    // `AnyView(cond ? a : b)`：`a`/`b` 虽然都是 `some View`，
                    // 但是两个不同的具体类型，三元表达式本身没法统一它们
                    // （`AnyView` 是在外面套的，救不了里面）。
                    // ★ 2026-10-09：预览标题栏可以被**关掉**（"歌词进播放器"那一档要关，
                    //    见 `showsPreviewHeader`）；关掉时传 `nil` —— 这一页自己的排版
                    //    会从 `safeArea.top + headerHeight` 那一档退回 `contentInsets.top`
                    //    （`AppleMusicLyricsPage` 里 `headerContent == nil` 那一条；
                    //    注意它在 `scrollInsets` 里会被加两次 ⇒ 实际让出 2×`contentInsets.top`）。
                    headerContent: showsProviderFooter
                        ? AnyView(shellHeader)
                        : (showsPreviewHeader ? AnyView(previewHeader) : Optional<AnyView>.none),
                    footerContent: showsShell ? AnyView(shellFooter) : nil,
                    closeContent: showsShell ? AnyView(shellClose) : nil,
                    // 全屏：曲名 + 歌手两行（62）；预览：一行「歌词」+ 两个按钮（39，
                    // 由宿主按"卡片高度 − 歌词视图高度"实测传入）。
                    //
                    // 预览的兜底值刻意是 39 而不是 62：量不到卡片容器时（退化挂到歌词
                    // 视图上）用全屏那两行的高度会让标题栏占掉卡片 1/5 的高度，
                    // 把歌词整体往下推一截；预览标题栏本来就只有一行。
                    headerHeight: showsProviderFooter
                        ? 62
                        : (showsPreviewHeader ? (previewHeaderInset > 0 ? previewHeaderInset : 39) : 0),
                    // ⚠️ 预览必须传 0：卡片里 `safeArea.top == 0`，再用全屏那套 -30
                    // 会把整条标题栏推到卡片外面 —— 表现就是"预览一个按钮都没有"。
                    //
                    // 但预览也不能死贴卡片顶：卡片那块标题栏高度（`previewHeaderInset`，
                    // 实测 64）比我们这一行（≈32）高，Spotify 原来那一行是**竖直居中**的
                    // （卡片上留 16pt，行本身 48）。这里补上同样的居中偏移，
                    // 自绘的「歌词」才会落在原生那一行的位置上。
                    headerTopInset: showsProviderFooter
                        ? -30
                        : max((previewHeaderInset - Self.previewHeaderRowHeight) / 2, 0),
                    // 预览不参与"划动收起壳"：那张小卡片上收起壳只会剩一片空白。
                    hidesShellOnScroll: showsProviderFooter,
                    // 预览：底部淡出按**离底部的固定距离**压住，不再吃比例。
                    //
                    // 卡片只有 320pt，按比例算（0.86）会得到 45pt 的大淡出带；
                    // 而底边距是 120pt（为了让内容可滚、当前行能居中），
                    // 那片空白本来就不该参与淡出 —— 所以起点要落在最后一个可见行附近。
                    // ⚠️ 关掉预览标题栏的那一档（"歌词进播放器"）**必须传 1.0**：
                    //    `headerContent == nil` 会让 `AppleMusicLyricsPage` 退回 `legacyFadeStops`
                    //    （整屏比例口径），而 0.62 会给这一块**加一条本来没有的底部淡出带**
                    //    （照片 60 里最下面那几行是清楚的）。原来有标题栏时走的是"按壳占位算"
                    //    那条路、底部本来全不透明 ⇒ `1.0` 才是**保持原样**。
                    fadeBottomOpaqueRatio: showsProviderFooter
                        ? 0.86
                        : (showsPreviewHeader ? 0.62 : 1.0),
                    // ⚠️ 预览必须传 0：它**没有控件栏**，而淡出遮罩是按
                    // `高度 − footerHeight` 算起点的。写死 116 会让 320pt 高的卡片
                    // 从 y≈204 就开始淡出 —— 这才是"下淡出太高"的真正原因
                    // （注意 `fadeBottomOpaqueRatio` 在预览里其实走不到，
                    // 因为预览也有 headerContent，用的是按壳占位算的 `fadeMaskStops`）。
                    footerHeight: showsProviderFooter ? 116 : 0,
                    // 预览的"底部淡出带"= 0：卡片底部 120pt 是**为了让内容可滚
                    // 而留的空白**（当前行才能居中），在那片空白上淡出等于白淡，
                    // 还会顺手把最后一行也压暗。让歌词一直清晰到卡片下缘即可。
                    fadeBottomBand: showsProviderFooter ? 40 : 0,
                    // ★ 2026-10-11：把"静态档"透传下去（见 `AppleMusicLyricsPage.isStatic`）。
                    isStatic: isStatic
                )
            }
        }
    }

    // MARK: 自绘壳

    /// 预览卡片顶部那一行：`歌词` + 分享 + 展开。
    ///
    /// 为什么预览也要自己画：卡片面板是 Spotify 的 Element 框架刷的专辑纯色，
    /// 而我们的层是它的子视图 —— **子视图盖不住父视图自己的背景**，
    /// 所以那一行 39pt 永远是粉的（试过五种改法都无效）。
    /// 现在换个思路：把我们的层挂到**卡片容器**上（而不是歌词视图），
    /// 整张卡片都由我们画，"壳"就不存在了。
    ///
    /// 两个按钮的动作转发给原生控件（见 `WordByWordPlaybackControl` 里那两个方法）。
    private var previewHeader: some View {
        HStack(spacing: 0) {
            Text("lyrics".localized)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(primaryColor)
                .lineLimit(1)

            Spacer(minLength: 8)

            Button {
                WordByWordPlaybackControl.shareLyrics()
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(primaryColor.opacity(0.92))
                    .frame(width: 40, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                WordByWordPlaybackControl.expandToFullscreenLyrics()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(primaryColor.opacity(0.92))
                    .frame(width: 40, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 顶部：曲名 + 歌手（居中，与 Spotify 原生一致）。
    ///
    /// 内容本身在 `LyricsShellChrome` 里 —— 旧渲染层（不开「更好的逐词歌词」时那条）
    /// 用的是**同一份代码**，见 `LyricsShellViews.swift` 的文件头说明。
    private var shellHeader: some View {
        LyricsShellChrome.header(
            title: trackTitle,
            artist: trackArtist,
            primaryColor: primaryColor
        )
    }

    /// 底部：进度条 + 时间 + 播放控制。
    private var shellFooter: some View {
        LyricsShellChrome.footer(
            projection: projection,
            primaryColor: primaryColor,
            onSeek: { onSeek?($0) }
        )
    }

    /// 右上角：关闭全屏页（原生那个 chevron 被我们的背景盖住了，所以自己画一个）。
    private var shellClose: some View {
        LyricsShellChrome.close(primaryColor: primaryColor) {
            WordByWordPlaybackControl.dismissFullscreen()
        }
    }
}
