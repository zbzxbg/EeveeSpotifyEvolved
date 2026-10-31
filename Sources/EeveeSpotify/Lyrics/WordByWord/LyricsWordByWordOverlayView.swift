// UIKit 叠加视图：逐行 UILabel + 当前词 NSAttributedString 高亮 + 自动滚动。
import Orion
import UIKit
import ObjectiveC
import SwiftUI

private final class LineLabel: UILabel {
    var lineIndex = -1
}

// 这里曾经有一个自绘的 UIKit 进度条 `WordByWordProgressBar`。
// 已删除：进度条现在与「更好的逐词歌词」共用**同一份** SwiftUI 实现
// （`AppleMusicLyricsProgressBar`，见 `AppleMusicLyricsPlaybackControl.swift`）——
// 两份实现必然会在尺寸、圆点大小、拖动手感上慢慢跑偏。

final class LyricsWordByWordOverlayView: UIView, UIScrollViewDelegate {

    private let scrollView = UIScrollView()
    private let stackView = UIStackView()
    private var lineLabels: [UILabel] = []
    private var displayTexts: [String] = []
    private var wordRanges: [[Range<String.Index>]] = []
    private var wordIndices: [[Int]] = []
    private var providerLabel: UILabel?
    /// 是否在底部显示「歌词提供者」（全屏显示，内嵌不显示）。
    var showsProviderFooter = false
    /// 是否显示行级译文（全屏显示；内嵌「预览歌词」不显示）。
    var showsTranslation = true
    /// 是否显示**全屏壳**：曲名 + 歌手、进度条 + 时间、三键、右上角收起键。
    ///
    /// 为什么必须有：这一层在全屏时用的是**不透明**底色（见 `configureBackdropIfNeeded`），
    /// 而它挂在 `vc.view` 的最前面 —— 原生那一页的标题栏、进度条、播放键、
    /// 右上角收起键全被压在下面。不出自己的壳，用户在全屏里就是
    /// "一个按键都没有"，而且是一屏没有任何元信息的纯歌词。
    ///
    /// ⚠️ 壳的内容**不是这里画的**：用的是与「更好的逐词歌词」**同一份** SwiftUI 组件
    /// （`LyricsShellViews.swift`）。自己再手写一套 UIKit 壳的结果，真机对比下来
    /// 处处对不上（标题偏高、三键太散、上下淡出难看）—— 是"直接照抄不好吗"。
    /// 这里只管：把它挂上、给它数据、按同样的常数给歌词让位。
    /// 歌词本身的高亮/闪烁与背景仍保持旧层原样。
    var showsPlaybackControls = false {
        didSet {
            guard showsPlaybackControls != oldValue else { return }
            applyControlsVisibility(showsPlaybackControls)
        }
    }
    /// 行级译文标签（每行原文下面一行小字），用于 rebuild 清理。
    private var translationLabels: [UILabel] = []

    // MARK: 全屏壳（与「更好的逐词歌词」共用同一份组件）
    //
    // 壳的宿主（顶部条 + 底部条两个 SwiftUI hosting controller）。
    private let shellHosts = LyricsShellHosts()
    /// 壳要的播放状态投影（当前时间 / 总时长 / 是否在播放）。
    ///
    /// 位置来源与歌词高亮**复用同一个** `WordByWordPositionResolver` ——
    /// 两处各读一次播放器很容易错拍（进度条和歌词差半秒那种）。
    private lazy var projection = AppleMusicLyricsPlaybackProjection {
        WordByWordPositionResolver.shared.currentPositionSeconds()
    }
    /// 换歌时要跟着变的壳文本。
    private var shellTitle: String = ""
    private var shellArtist: String = ""
    /// 壳当前是否已按"可见"布置过（避免每帧重设约束常量）。
    private var controlsApplied: Bool?
    private var stackBottomConstraint: NSLayoutConstraint?
    private var stackTopConstraint: NSLayoutConstraint?

    private var dto: LyricsDto?
    private var dtoVersion = -1
    private var activeLineIndex = -1
    private var activeWordIndex = -1
    /// 最近一次打过「逐字判定」账的歌词版本号。
    /// 判定只随数据变、不随时间变，所以按版本号去重，一首歌只打一行。
    private var judgedLyricsVersion = -1

    /// 行色随背景明暗切换，见 `resolveTextColors`。
    private var lineColor = UIColor.black
    private var activeLineColorValue = UIColor.white
    /// 行级译文字号（比歌词小）。
    private let translationFontSize: CGFloat = 16
    /// 行级译文颜色：与未唱歌词（其余行）一致。
    private var translationColor = UIColor.black
    /// 当前行内「未唱」词的透明度（已唱/正在唱为全白）。
    private let unsungWordOpacity: CGFloat = 0.45
    /// 背景色缓存：每次 rebuild（换歌/换数据）后按「定制」选项重新计算一次。
    private var resolvedBackgroundColor: UIColor?
    /// 模糊封面背景层（最底层）：封面拿不到 / 用户选了静态色时自动退回纯色。
    private let backdropView = LyricsBackdropView()
    /// 当前背景对应的「歌 + 设置」标识，变了才重新配置背景。
    private var resolvedBackdropKey: String?
    /// 顶部渐隐层（scrim）：背景色 → 透明，让上滚的歌词在顶部渐隐退出。
    private let topFadeView = UIView()
    private let topFadeLayer = CAGradientLayer()
    /// 底部渐隐层（scrim）：透明 → 背景色，让从底部进入的歌词渐隐进入。
    private let bottomFadeView = UIView()
    private let bottomFadeLayer = CAGradientLayer()

    /// 手动滚动时暂停自动跟随，直到该时间点
    private var autoScrollPauseUntil: Date = .distantPast
    /// 诊断：节流打印当前高亮状态
    private var lastDiagnosticLog: Date = .distantPast
    /// 当前行在视口中的目标位置（距顶部比例）：0.40 = 视口上方约 40% 处。
    private let activeLineViewportFraction: CGFloat = 0.40
    /// 自动滚动动画时长（秒），越小越「干脆」。
    private let scrollAnimationDuration: TimeInterval = 0.20
    /// 歌词行字号（对照 Spotify 原生歌词放大）。
    private let lyricsFontSize: CGFloat = 22
    /// 歌词行左右内边距（对照「歌词」标题的左缩进）；全屏歌词可单独调大。
    private var lyricsSideInset: CGFloat = 16
    /// 歌词块顶部留白（未滚动时第一行的起始高度）。
    private let lyricsTopPadding: CGFloat = 18
    // 左右/宽度约束的可更新引用（供 setSideInset 调整）
    private var stackLeadingConstraint: NSLayoutConstraint?
    private var stackTrailingConstraint: NSLayoutConstraint?
    private var stackWidthConstraint: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        // ⚠️ 自己的尺寸**始终**等于宿主的 bounds。
        //
        // `autoresizingMask` 只在"父视图 bounds 之后又变了"时按比例调整；而挂载那一刻
        // 宿主可能还没收敛到最终尺寸（真机实证：预览里的歌词被排成整页宽，
        // 右侧在卡片边缘被裁掉、滚动看着"跑偏"）。这里每个布局周期对齐一次。
        if let host = superview, bounds.size != host.bounds.size {
            frame = CGRect(origin: .zero, size: host.bounds.size)
        }

        // 上下淡出带（含"壳下面那两块铺底"）。
        //
        // 有壳时不再是"一小条淡出"就完事：
        // · 上：从屏幕顶到**标题栏下沿**整块铺底色，只在最下面 `fadeBottomBand`
        // 范围内做淡入 —— 这样淡入正好落在"歌手下方"，标题/歌手背后是干净的底色；
        // · 下：从**控件栏顶部**到底部整块铺底色，往上 `fadeBottomBand` 做淡出 ——
        // 进度条/时间/三键背后同样是干净的底色。
        //
        // 真机截图实证（修之前）：只铺一条 40pt 的淡出带，壳本身没有背景，
        // 于是歌词直接从标题、进度条和三键底下穿过去 —— 三键压在一行歌词上。
        // 安全区用 `resolvedSafeAreaInsets`（窗口的）：全屏页里我们挂在 `vc.view` 上，
        // 自己那份是 0，用它会得到"淡入贴屏幕最顶端、淡出压到进度条上"。
        updateFadeLayers()

        // 折行宽度**显式**告诉每个 label。
        //
        // 栈的宽度约束本来已经给了宽度，但 label 不设 `preferredMaxLayoutWidth` 时，
        // 在某些布局时序上（宿主刚挂上、宽度还没收敛）会先按**单行固有宽度**排一次，
        // 顺手把栈撑宽 —— 表现就是"歌词跑到卡片外面被裁掉、滚动看着跑偏"。
        let wrapWidth = currentWrapWidth
        if wrapWidth != lastWrapWidth {
            lastWrapWidth = wrapWidth
            for label in lineLabels { label.preferredMaxLayoutWidth = wrapWidth }
            for label in translationLabels { label.preferredMaxLayoutWidth = wrapWidth }
        }

        // 有壳时歌词的上下留白要跟着安全区 + 壳的高度走（旋转 / 换设备都要跟着变）。
        updateLyricsInsetsIfNeeded()

        // 几何诊断：歌词面板 + 淡出带的实际停靠点。
        //
        // ⚠️ 这一行是排查"淡入/淡出位置不对"的**唯一**依据 ——
        // 把上下淡出带、壳的实际占位、窗口安全区一次打全：
        // `fade=` 那两段是**绝对 y**，直接和截图里"歌手下方 / 进度条上沿"对得上。
        let fadeSummary = "top[\(Int(topFadeView.frame.minY))..\(Int(topFadeView.frame.maxY))]"
            + " bottom[\(Int(bottomFadeView.frame.minY))..\(Int(bottomFadeView.frame.maxY))]"
        if fadeSummary != lastLoggedFadeSummary {
            lastLoggedFadeSummary = fadeSummary
            writeDebugLog(
                "[WordByWord] legacy fades \(fadeSummary)"
                    + " insets=(\(Int(resolvedSafeAreaInsets.top)),\(Int(resolvedSafeAreaInsets.bottom)))"
                    + " shell=\(showsPlaybackControls) hidden=(\(topFadeView.isHidden),\(bottomFadeView.isHidden))"
            )
        }

        // 尺寸变化时打一条（排查"挂上了但大小/换行不对"用；不随每帧刷屏）。
        if bounds.size != lastLoggedSize {
            lastLoggedSize = bounds.size
            writeDebugLog(
                "[WordByWord] legacy overlay \(Int(bounds.width))x\(Int(bounds.height))"
                    + " stack=\(Int(stackView.bounds.width))"
                    + " label=\(Int(lineLabels.first?.bounds.width ?? 0))"
                    + " shell=\(showsPlaybackControls)"
            )
        }
    }

    /// 安全区：**优先用窗口的**。
    ///
    /// ⚠️ 真机实证：全屏页里我们挂在 `vc.view` 上，自己算出来的
    /// `safeAreaInsets` 是 **0**（这一页的安全区由更上层处理），于是
    /// "上淡出带"从屏幕最顶端开始、"下淡出带"压到进度条上 ——
    /// 就是"淡入不在歌手下方、淡出不在进度条上方"。
    /// 窗口的安全区一定拿得到，用它就和 SwiftUI 那边（新层）对齐了。
    private var resolvedSafeAreaInsets: UIEdgeInsets {
        if let insets = window?.safeAreaInsets, insets != .zero { return insets }
        return safeAreaInsets
    }

    /// 有壳时歌词的上下留白 = 安全区 + 壳高度 + 呼吸。
    ///
    /// 数值全部取自 `LyricsShellLayout`（与新层同一份），所以第一行落在
    /// "标题栏下沿 + 8"、最后一行停在"控件栏上沿 − 46"，两边一致。
    private func updateLyricsInsetsIfNeeded() {
        let insets = resolvedSafeAreaInsets
        let top: CGFloat
        let bottom: CGFloat
        if showsPlaybackControls {
            top = insets.top + LyricsShellLayout.headerHeight + LyricsShellLayout.contentTopInset
            bottom = -(insets.bottom + LyricsShellLayout.footerHeight + LyricsShellLayout.contentBottomInset)
        } else {
            top = lyricsTopPadding
            bottom = -60
        }
        if let constraint = stackTopConstraint, constraint.constant != top {
            constraint.constant = top
        }
        if let constraint = stackBottomConstraint, constraint.constant != bottom {
            constraint.constant = bottom
        }
    }

    /// 上一次设置过的折行宽度 / 上一次打过日志的尺寸（都是"变了才动"的缓存）。
    private var lastWrapWidth: CGFloat = -1
    private var lastLoggedSize: CGSize = .zero
    private var lastLoggedFadeSummary: String = ""

    /// 当前应当使用的折行宽度（= 我们宽度 − 左右边距）。
    private var currentWrapWidth: CGFloat {
        max(bounds.width - 2 * lyricsSideInset, 1)
    }

    /// 把两条渐隐带的图层对齐到各自的视图。
    ///
    /// ⚠️⚠️ **这两行是"上下淡入淡出根本不出现"的唯一原因，别再删掉。**
    ///
    /// `CAGradientLayer` 是**手动** `addSublayer` 上去的，不参与 Auto Layout，
    /// 新建时 `frame` 是 `.zero` —— 而下面 `updateFadeLayers` 从头到尾只改
    /// `topFadeView.frame` / `bottomFadeView.frame` 和渐变的 `colors`/`locations`，
    /// **从来没给过这两个图层尺寸**。一个 0x0 的渐变图层画不出任何像素，
    /// 于是那两条"铺底色 + 淡出"的带子等于不存在：
    /// · 全屏（有壳）：标题栏、进度条、时间、三键背后是干净的透明，
    /// 歌词直接从它们**底下穿过去** —— 真机截图里"歌曲名压在第一行歌词上"、
    /// "三键压在一行歌词上"就是这个；
    /// · 预览（无壳）：卡片上下两端没有渐隐，进出视口的行是硬切。
    ///
    /// 对照：`LyricsBackdropArtworkView` 那个同类渐变层是在 `layoutSubviews`
    /// 里 `gradientLayer.frame = bounds` 的，所以它的背景一直正常 ——
    /// 两处只有一处写了尺寸，这就是差别。
    ///
    /// 放在 `updateFadeLayers` 里（而不是 `layoutSubviews`）是因为两个视图的
    /// `frame` 就是在那里设的，尺寸与位置必须成对更新，否则会差一帧。
    private func syncFadeLayerFrames() {
        topFadeLayer.frame = topFadeView.bounds
        bottomFadeLayer.frame = bottomFadeView.bounds
    }

    /// 淡出带（scrim）的几何 + 颜色 + 渐变停靠点。
    ///
    /// ⚠️ 颜色与 `locations` 必须**成对、在同一处**设置：`CAGradientLayer` 要求两者
    /// 数量一致，一处只设 colors、另一处只设 locations 会画出花屏甚至直接崩。
    /// 所以这里统一算，`configureBackdropIfNeeded` 只负责把底色算出来。
    /// 尺寸交给上面的 `syncFadeLayerFrames`（`frame` 变了它必须跟着变）。
    private func updateFadeLayers() {
        let base = resolvedBackgroundColor ?? .black
        let clear = base.withAlphaComponent(0)

        guard showsPlaybackControls else {
            // 预览：卡片内部没有壳，上下各一小条渐隐就够了。
            let band: CGFloat = bounds.height < 420 ? 28 : 48
            let insets = safeAreaInsets
            topFadeView.frame = CGRect(x: 0, y: insets.top, width: bounds.width, height: band)
            topFadeLayer.colors = [base.cgColor, clear.cgColor]
            topFadeLayer.locations = [0, 1]
            bottomFadeView.frame = CGRect(
                x: 0,
                y: bounds.height - insets.bottom - band,
                width: bounds.width,
                height: band
            )
            bottomFadeLayer.colors = [clear.cgColor, base.cgColor]
            bottomFadeLayer.locations = [0, 1]
            syncFadeLayerFrames()
            return
        }

        let insets = resolvedSafeAreaInsets
        // 渐隐带的**过渡宽度**（不是整条带子的高度，见下面两段）。
        //
        // ⚠️ 这个值别改回 `contentTopInset`(8)：8pt 的过渡在 3x 屏上只有 24 个像素，
        // 观感是"一刀切"而不是淡入淡出 —— 真机反馈原话是"下方的淡出有点低"
        // （淡出挤在最后 8pt 里，看着就像贴在底部的一条硬边）。
        // 40 与「更好的逐词歌词」那条路的 `LyricsShellLayout.fadeBottomBand` 一致，
        // 两条路的淡出手感才对得上。
        let band = LyricsShellLayout.fadeBottomBand

        // ── 上：标题栏整块铺底色，在**紧贴第一行歌词**的上方 `band` 里做淡入
        //
        // 要的是"淡入淡出放在歌手名字下面、播放条上面，像卡拉OK那样"。
        // 歌词让位的起点 = `安全区 + 标题栏高(62) + 内容呼吸(8)`，也就是第一行歌词的 y：
        // · 0 … (headerBottom − band) 完全不透明 → 状态栏、歌名、歌手背后是干净底色，
        // 歌手名字**不会被渐变蹭到**（这一点很难返工，必须在第一次就做对）；
        // · (headerBottom − band) … headerBottom 逐渐变透明 → 歌词正好从"歌手下方"
        // 开始淡入，而不是凭空出现。
        //
        // ⚠️ `headerBottom` 不再夹一个 `min(..., 1)`：原来那写法在极短屏/异常状态下会让
        // `headerBottom < band`，`topStop` 被夹成 0，于是 locations 变成 [0,0,1]，
        // 最上面那一段从第一像素起就开始透明 —— 底色整块失效。
        let headerBottom = max(
            insets.top + LyricsShellLayout.headerHeight + LyricsShellLayout.contentTopInset,
            band + 1
        )
        topFadeView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: headerBottom)
        topFadeLayer.colors = [base.cgColor, base.cgColor, clear.cgColor]
        let topStop = min(max(Double(max(headerBottom - band, 0) / headerBottom), 0), 1)
        topFadeLayer.locations = [0, NSNumber(value: topStop), 1]

        // ── 下：从控件栏顶部**往上** `band` 做淡出，控件栏整块（进度条 + 时间 + 三键）铺底色 ──
        //
        // 停靠点用的是新层那套名义值 `height − (安全区 + 116)`：它正好落在**进度条上沿之上**
        // （控件实际内容在它下面约 16pt），所以"淡出停在进度条上方"。
        // 渐变向上铺满 `band`，于是淡出发生在"最后一行歌词下方到进度条之间"那段空白里，
        // 不会等到贴着屏幕底才开始 —— 这就是"淡出太低"的修法。
        let footerTop = min(
            bounds.height - (max(insets.bottom, 8) + LyricsShellLayout.footerHeight),
            bounds.height
        )
        let fadeStart = max(footerTop - band, 0)
        let span = max(bounds.height - fadeStart, 1)
        bottomFadeView.frame = CGRect(x: 0, y: fadeStart, width: bounds.width, height: span)
        bottomFadeLayer.colors = [clear.cgColor, base.cgColor, base.cgColor]
        let bottomStop = min(max(Double(band / span), 0), 1)
        bottomFadeLayer.locations = [0, NSNumber(value: bottomStop), 1]

        syncFadeLayerFrames()
    }

    /// 设置背景样式：全屏传 `.stage`（溢出铺满整屏、均匀暗化），
    /// 内嵌预览传 `.card`（只在卡片内、上下暗中间透）。
    func setBackdropStyle(_ style: LyricsBackdropView.Style) {
        backdropView.style = style
        // 样式变了要让 configureBackdropIfNeeded 重新算一次（它按 key 缓存）。
        resolvedBackdropKey = nil
    }

    /// 调整歌词行左右边距（全屏用到更大的左边距时调用）。
    func setSideInset(_ inset: CGFloat) {
        lyricsSideInset = inset
        stackLeadingConstraint?.constant = inset
        stackTrailingConstraint?.constant = -inset
        stackWidthConstraint?.constant = -(2 * inset)
    }

    private func setupView() {
        // 背景交给 backdropView（模糊封面），自身保持透明，否则会把它盖住。
        backgroundColor = .clear

        backdropView.frame = bounds
        backdropView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        topFadeLayer.startPoint = CGPoint(x: 0.5, y: 0)
        topFadeLayer.endPoint = CGPoint(x: 0.5, y: 1)
        topFadeView.layer.addSublayer(topFadeLayer)
        topFadeView.isUserInteractionEnabled = false
        topFadeView.isHidden = true

        bottomFadeLayer.startPoint = CGPoint(x: 0.5, y: 0)
        bottomFadeLayer.endPoint = CGPoint(x: 0.5, y: 1)
        bottomFadeView.layer.addSublayer(bottomFadeLayer)
        bottomFadeView.isUserInteractionEnabled = false
        bottomFadeView.isHidden = true

        scrollView.delegate = self
        scrollView.showsVerticalScrollIndicator = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .vertical
        stackView.alignment = .fill
        stackView.distribution = .fill
        stackView.spacing = 18
        stackView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scrollView)
        scrollView.addSubview(stackView)
        addSubview(topFadeView)
        addSubview(bottomFadeView)
        // 控制条与收起键**最后加**：它们要浮在渐隐层与歌词之上。
        setupPlaybackControls()

        let stackBottom = stackView.bottomAnchor.constraint(
            equalTo: scrollView.contentLayoutGuide.bottomAnchor,
            constant: -60
        )
        stackBottomConstraint = stackBottom
        let stackTop = stackView.topAnchor.constraint(
            equalTo: scrollView.contentLayoutGuide.topAnchor,
            constant: lyricsTopPadding
        )
        stackTopConstraint = stackTop

        NSLayoutConstraint.activate([
            // ⚠️ 滚动视图贴自己的四边，**不贴安全区**：安全区改由歌词的上下留白承担
            // （见 `updateLyricsInsetsIfNeeded`）。这样"第一行落在标题栏下沿"这件事
            // 只依赖一处计算，不会再出现"我们这层拿到的 safeAreaInsets 是 0"时整体上移。
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackTop,
            stackBottom,
        ])

        // 左右/宽度单独建，便于全屏时调整左边距。
        //
        // 某些时序下那条链会解出一个比我们宽得多的值（overlay=342 而 stack=486），
        // 歌词于是被排成 486pt 宽、在卡片右缘裁掉 —— 就是"预览歌词向左偏移"。
        // 锚到自己就只有一个来源：我们的宽度。
        let leading = stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: lyricsSideInset)
        let trailing = stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -lyricsSideInset)
        let width = stackView.widthAnchor.constraint(equalTo: widthAnchor, constant: -(2 * lyricsSideInset))
        NSLayoutConstraint.activate([leading, trailing, width])
        stackLeadingConstraint = leading
        stackTrailingConstraint = trailing
        stackWidthConstraint = width

        // 背景必须在最底层 —— 放在所有子视图添加完之后再插到 index 0，
        // 不依赖 addSubview 的调用顺序。
        insertSubview(backdropView, at: 0)

        applyControlsVisibility(showsPlaybackControls)
    }

    // MARK: 全屏壳（与「更好的逐词歌词」共用同一份组件）
    //
    // 把壳挂上（只挂一次；显隐与内容由 `applyControlsVisibility` /
    // `refreshShellMetadata` 管）。
    //
    // 壳的每个部件都来自 `LyricsShellViews.swift` —— 与新层是**同一份代码**。
    // （自己再手写一套 UIKit 壳的结果，真机对比处处对不上：标题偏高、三键太散、
    // 上下淡出难看；而且那个自绘收起键的标签正好是 "close"，
    // 被 `dismissFullscreen` 当成原生控件点了回来 —— 无限递归直接爆栈崩掉。）
    private func setupPlaybackControls() {
        shellHosts.attach(
            to: self,
            projection: projection,
            primaryColor: .white,
            onSeek: { time in
                // 点行跳转**只有一份实现**（见 `AppleMusicLyricsOverlay.swift` 开头的
                // `seekToTappedLyricLine`：`rounded` + 5ms，缺一个就会"点这一行、跳到上一行"）。
                seekToTappedLyricLine(time)
            },
            onClose: {
                WordByWordPlaybackControl.dismissFullscreen()
            }
        )
        shellHosts.setHidden(true)
    }

    /// 如果自己不在宿主的最前面就抬一次（已经是最前时什么都不做）。
    ///
    /// 每帧都会被调用，所以不能真的每次都重排 subviews —— 那会让 UIKit 每帧都做一次
    /// 数组搬移与图层重排。
    private func ensureFrontmost() {
        guard let host = superview else { return }
        if host.subviews.last !== self {
            host.bringSubviewToFront(self)
        }
        // 壳的两个宿主也要一直压在最上面（原生内容重排 subviews 时会挤上来）。
        shellHosts.bringToFront()
    }

    /// 显示 / 隐藏整套壳，并让歌词上下留出同样的空。
    ///
    /// ⚠️ 带缓存：`setCurrentTime` 每帧都会调到这里，而改 `constant` 会让 UIKit
    /// 重新跑一轮布局 —— 每帧重设一次等于每帧无谓地失效一次布局。
    private func applyControlsVisibility(_ visible: Bool) {
        guard controlsApplied != visible else { return }
        controlsApplied = visible
        shellHosts.setHidden(!visible)
        // 歌词的上下留白由 `updateLyricsInsetsIfNeeded` 统一算（安全区 + 壳高度），
        // 否则第一行会钻到标题栏底下、最后几行会被进度条压住。
        updateLyricsInsetsIfNeeded()
        setNeedsLayout()
    }

    /// 每帧把播放状态喂给壳。
    ///
    /// 进度条的百分比、两个时间、播放/暂停图标**全在那份投影里算** ——
    /// 与新层走的是同一个 `AppleMusicLyricsPlaybackProjection`，所以两边的
    /// 手感/数值天然一致，不会各算各的。
    private func updateShellPlayback() {
        guard showsPlaybackControls else { return }
        projection.refresh()
    }

    /// 换歌时刷新壳上的曲名 / 歌手。
    ///
    /// 从 `SPTPlayerTrack` 取（与新层一致）：歌词里没有歌手名，
    /// 而曲名在歌词数据里可能是别的语言写法。
    private func refreshShellMetadata() {
        let track = statefulPlayer?.currentTrack() ?? nowPlayingScrollViewController?.loadedTrack
        shellTitle = track?.trackTitle() ?? ""
        shellArtist = (EeveeSpotify.hookTarget == .lastAvailableiOS14
            ? track?.artistTitle()
            : track?.artistName()) ?? ""
        shellHosts.update(title: shellTitle, artist: shellArtist)
        writeDebugLog("[Shell] legacy metadata \"\(shellTitle)\" — \"\(shellArtist)\"")
    }

    /// 打完一行几何诊断：**"歌词看起来偏不偏"全在这几个数里**。
    ///
    /// 面板宽度、它在窗口里的位置、滚动视图宽度、栈宽、第一行 label 的宽度 ——
    /// 之前"预览歌词偏左/被裁"这类问题只能靠猜，有了这一行一眼就能定位。
    /// 每次 rebuild（换歌 / 换数据）打一条，不随每帧刷屏。
    private func logLegacyGeometry() {
        guard !lineLabels.isEmpty else { return }
        let inWindow = convert(bounds, to: nil)
        let insets = showsPlaybackControls ? resolvedSafeAreaInsets : safeAreaInsets
        writeDebugLog(
            "[WordByWord] legacy geometry overlay=\(Int(bounds.width))x\(Int(bounds.height))"
                + " at(\(Int(inWindow.minX)),\(Int(inWindow.minY)))"
                + " scroll=\(Int(scrollView.frame.width))"
                + " content=\(Int(scrollView.contentSize.width))"
                + " stack=\(Int(stackView.frame.width))"
                + " label=\(Int(lineLabels[0].frame.width))"
                + " wrap=\(Int(currentWrapWidth))"
                + " sideInset=\(Int(lyricsSideInset))"
                + " insets=(\(Int(insets.top)),\(Int(insets.bottom)))"
                + " shell=\(showsPlaybackControls)"
        )
    }

    /// 「这一首为什么走逐字档 / 交还原生」的**按版本去重**调用点。
    ///
    /// 文案由文件级的 `wordLevelJudgeLine(dto:version:)` 拼（见那个函数的说明）——
    /// 提成文件级之后，`WordByWordHost.attach` 被拒那条路也能打同一行，
    /// 而那正是"没挂上"时最需要的一行。
    ///
    /// ⚠️起没有逐词数据的歌**不会挂我们这层**，所以这条去重路径只在
    /// "挂了层"的歌上跑；"没挂"那边由 `attach` 的拒绝路径负责，两处口径一致。
    ///
    /// 每次换歌/换数据打一行（由 `setCurrentTime` 里版本变化处调用），
    /// 不是每帧：判定只随数据变。
    private func logWordLevelJudgeOnce() {
        guard judgedLyricsVersion != currentLyricsVersion else { return }
        judgedLyricsVersion = currentLyricsVersion

        if let line = wordLevelJudgeLine(dto: currentLyricsDto, version: currentLyricsVersion) {
            writeDebugLog(line)
        }
    }

    // MARK: 行模型归属
    //
    // 当前**实时**播放的曲目 id。
    //
    // 与壳上的曲名同一个来源（`refreshShellMetadata` 也是从这里读的），
    // 所以"壳显示的歌"和"这个判据认为的歌"永远是同一首。
    private var liveTrackIdentifier: String {
        statefulPlayer?.currentTrack()?.trackIdentifier ?? ""
    }

    /// `currentLyricsDto` 是不是**别的**曲目的（切歌但没来歌词请求时会发生）。
    ///
    /// 两层的口径必须一致：AM 层是 `AppleMusicLyricsOverlayHost.hasForeignLineModel`，
    /// 旧层就是这里。详见文件顶部 `currentLyricsDtoTrackId` 的说明。
    private var belongsToAnotherTrack: Bool {
        let model = currentLyricsDtoTrackId
        let live = liveTrackIdentifier
        guard !model.isEmpty, !live.isEmpty else { return false }
        return model != live
    }

    /// 上一次为"模型属于别的曲目"打过日志的那首曲目 id —— 同一首只打一行，
    /// 这个判据是每帧跑的，不记就会把日志刷爆。
    private var loggedForeignModelTrackId: String?

    /// 整层交还 Spotify 原生：清底、藏歌词与淡出带、触摸穿透、自绘控制条一起收。
    ///
    /// 抽出来是因为现在有**三处**判据要走它（没有逐词数据 / 模型属于别的曲目 /
    /// 图层关闭）。以前是逐处手写一遍，漏一处就是"层撤了但底色还在"那种不一致。
    private func handBackToNative() {
        backgroundColor = .clear
        backdropView.isHidden = true
        stackView.isHidden = true
        topFadeView.isHidden = true
        bottomFadeView.isHidden = true
        isUserInteractionEnabled = false   // 回退原生时让触摸穿透，别挡住原生歌词滚动
        // 整层都交还给原生时，自绘控制条也必须一起交还 ——
        // 否则会留下两颗悬浮的按钮压在 Spotify 原生界面上。
        applyControlsVisibility(false)
    }

    /// 每帧由时钟调用：惰性取 dto、词级高亮、自动滚动。
    func setCurrentTime(_ ms: Double) {
        updateShellPlayback()
        // 原生内容（卡片里的歌词视图 / Element 各层）会在重排 subviews 时把我们挤下去，
        // 那一下 "bringSubviewToFront" 就白做了 —— 表现是"预览里的逐词层时不时被盖住"。
        // 每帧补一次；已经是最前时只花一次指针比较。
        ensureFrontmost()

        if dtoVersion != currentLyricsVersion {
            dto = currentLyricsDto
            dtoVersion = currentLyricsVersion
            rebuild()
            // 换歌/换数据后打一次"逐字判定"的账 —— 见 `logWordLevelJudgeOnce`。
            // 放在这里而不是每帧：判定结果只随数据变，不随时间变。
            logWordLevelJudgeOnce()
        }

        // 背景（模糊封面 + 暗化）与文字色必须先于下面的 guard 配置好：
        // 文字色取决于背景明暗，而 rebuild 已经按旧色建过标签了。
        configureBackdropIfNeeded()

        // ── 行模型是不是**这一首**的？（与 AM 层 `hasForeignLineModel` 同一判据）
        //
        // 切歌**不一定**伴随歌词请求：客户端命中自己的歌词存储 / 离线歌词时没有
        // `color-lyrics` 请求，`resetWordByWordLyrics` 就不会跑，`currentLyricsDto`
        // 还是上一首的 —— 而壳上的曲名是每帧从播放器实时读的。真机现场：
        // `[Shell] legacy metadata "Planetarium"` 配 `word-level judge: 31/33`（那是上
        // 一首 Rokudenashi 的 33 行模型，而 Planetarium 自己的 dto 只有 23 行、无逐词）。
        //
        // 处置：整层交还。宁可只显示"这首歌的原生歌词"（哪怕那是官方 PetitLyrics），
        // 也绝不能显示上一首的歌词 —— 后者会让人以为"歌词源串了"。
        if belongsToAnotherTrack {
            let live = liveTrackIdentifier
            if loggedForeignModelTrackId != live {
                loggedForeignModelTrackId = live
                writeDebugLog(
                    "[WordByWord] line model belongs to another track"
                        + " (model=\(currentLyricsDtoTrackId), live=\(live))"
                        + " — handing back to Spotify's own lyrics"
                )
            }
            handBackToNative()
            return
        }

        // 撤层的条件必须与 `attach` 的挂载判据**完全一致**：只有拿到逐词数据的歌才由我们渲染。
        //
        // ⚠️ 这条从 `hasUsableLineLevelData` 收回到 `hasUsableWordLevelData`：
        // "只有逐行"的歌现在整首交还 Spotify 原生那页/那张卡（产品规则写在 `attach`
        // 里那道 guard 的注释里）。这里如果还按行级放行，就会出现"attach 已经不挂了、
        // 但早先挂上去的旧层还在自己画"的不一致状态 —— 层不会自己消失。
        // 真正该撤的还是那三种：无逐词数据 / 静态歌词 / 还没拿到 dto。
        guard let dto, hasUsableWordLevelData(dto) else {
            handBackToNative()
            return
        }

        stackView.isHidden = false
        isUserInteractionEnabled = true
        applyControlsVisibility(showsPlaybackControls)
        updateFadeVisibility()

        var bestLine = -1
        var bestWord = -1
        for (i, line) in dto.lines.enumerated() {
            guard let offset = line.offsetMs, Double(offset) <= ms else { continue }
            bestLine = i
            if let words = line.words {
                for j in words.indices where Double(words[j].startMs) <= ms {
                    bestWord = j
                }
            }
        }

        // 诊断：节流打印当前高亮状态（每 1s 一次），用于对比数据时间轴与实际渲染
        if Date().timeIntervalSince(lastDiagnosticLog) > 1.0 {
            lastDiagnosticLog = Date()
            var wordInfo = "no-line"
            if bestLine >= 0, bestLine < dto.lines.count {
                if let words = dto.lines[bestLine].words, !words.isEmpty {
                    if bestWord >= 0, bestWord < words.count {
                        wordInfo = "w\(bestWord)=\"\(words[bestWord].text)\"@\(words[bestWord].startMs)ms"
                    } else {
                        wordInfo = "w=none-yet"
                    }
                } else {
                    wordInfo = "words=nil"
                }
            }
            writeDebugLog("[WordByWord] t=\(Int(ms))ms line=\(bestLine) \(wordInfo)")
        }

        if bestLine == activeLineIndex && bestWord == activeWordIndex { return }

        let lineChanged = bestLine != activeLineIndex

        if lineChanged {
            let oldIndex = activeLineIndex
            activeLineIndex = bestLine

            if bestLine == oldIndex + 1 {
                // 正常前进：只更新旧/新两行，crossfade 平滑黑白切换，消除闪烁
                if oldIndex >= 0, oldIndex < lineLabels.count {
                    crossfade(lineLabels[oldIndex]) { self.applyPlain(to: oldIndex) }
                }
            } else {
                // 跳转/回退：整列表重涂 —— 已唱过/当前行白、未到行黑
                repaintAllLines(upTo: bestLine)
            }

            // 只在行切换时滚动；词切换不重复滚动，避免动画被反复打断产生卡顿
            if bestLine >= 0 {
                scrollToLine(bestLine)
            } else {
                // 回到歌曲开头（当前时间早于第一行）时滚回顶部
                scrollToTop()
            }
        }

        activeWordIndex = bestWord
        if bestLine >= 0 {
            if lineChanged {
                crossfade(lineLabels[bestLine]) { self.applyHighlight(to: bestLine, wordIndex: bestWord) }
            } else {
                applyHighlight(to: bestLine, wordIndex: bestWord)
            }
        }
    }

    private func rebuild() {
        for label in lineLabels { label.removeFromSuperview() }
        lineLabels = []
        for label in translationLabels { label.removeFromSuperview() }
        translationLabels = []
        providerLabel?.removeFromSuperview()
        providerLabel = nil
        displayTexts = []
        wordRanges = []
        wordIndices = []
        activeLineIndex = -1
        activeWordIndex = -1
        resolvedBackgroundColor = nil
        // 换歌/换数据后强制重算背景（即使两首歌底色恰好相同也要换封面）。
        resolvedBackdropKey = nil
        // 壳上的曲名 / 歌手 / 总时长也跟着换（换歌时唯一可靠的地方就是这里）。
        refreshShellMetadata()
        // 文字色不在这里定：setCurrentTime 紧接着就会调用
        // configureBackdropIfNeeded，由它按背景明暗统一决定并在需要时重涂。
        // 这里先回到改动前的默认值，保证纯色兜底时建出来的标签就是对的。

        guard let dto else { return }

        for (index, line) in dto.lines.enumerated() {
            let (text, ranges, indices) = buildDisplayText(for: line)
            let label = LineLabel()
            label.lineIndex = index
            label.numberOfLines = 0
            // `.natural`（**不是** `.left`）：按**内容**决定贴哪一边 ——
            // 阿拉伯语 / 希伯来语歌词因此靠右，中英文不受影响（`.natural` = `.left`）。
            // 见 `String+ScriptDirection.swift` 顶部那段（报的"贴左不贴右"）。
            label.textAlignment = .natural
            label.font = .systemFont(ofSize: lyricsFontSize, weight: .semibold)
            // 折行宽度**建的时候**就给死：别等下一轮布局（`layoutSubviews` 里那次）
            // 才设，否则第一帧会按单行固有宽度排、把栈撑宽 —— 真机上就是
            // "预览歌词向左偏移 / 右边被卡片裁掉"。
            label.preferredMaxLayoutWidth = currentWrapWidth
            label.text = text
            label.textColor = lineColor
            label.isUserInteractionEnabled = true
            label.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleLineTap(_:))))

            // 每行用竖排 stack 包住：原文行 + 可选译文行
            let lineStack = UIStackView()
            lineStack.axis = .vertical
            lineStack.spacing = 4
            lineStack.addArrangedSubview(label)

            // ⚠️ 这里必须**再查一次**「不展示网易云歌词翻译」开关。
            //
            // 光靠仓库层（`NeteaseLyricsRepository` 里 `isNeteaseHideTranslationEnabled`
            // 时把 `translation` 置 nil）是不够的：开关是**运行时可变**的，
            // 而 dto 可能是在开关还关着的时候取到的（换歌缓存、切歌时序、改设置不改歌），
            // 那种情况下仓库层不会重跑，`dto.translation` 里仍然带着译文 ——
            // 于是"开关明明开着，界面上还是显示翻译"。
            // 显示层按开关自己再挡一道，两个条件都用 `&&` 而不是抄成一行，
            // 是为了让"到底哪一条挡住的"在读代码时一眼可见。
            let translationAllowed =
                showsTranslation && !NgzhwmSettingsViewModel.isNeteaseHideTranslationEnabled

            if translationAllowed, let translation = dto.translation, index < translation.lines.count {
                let t = translation.lines[index]
                if !t.isEmpty {
                    let translationLabel = UILabel()
                    translationLabel.numberOfLines = 0
                    // 同上：按内容解析。译文通常跟界面语言走（中文 → 仍贴左），
                    // 但阿拉伯语译文会自动贴右 —— 两种情况都对。
                    translationLabel.textAlignment = .natural
                    translationLabel.font = .systemFont(ofSize: translationFontSize, weight: .regular)
                    translationLabel.preferredMaxLayoutWidth = currentWrapWidth
                    translationLabel.textColor = translationColor
                    translationLabel.text = t
                    translationLabel.isUserInteractionEnabled = false
                    lineStack.addArrangedSubview(translationLabel)
                    translationLabels.append(translationLabel)
                }
            }

            stackView.addArrangedSubview(lineStack)
            lineLabels.append(label)
            displayTexts.append(text)
            wordRanges.append(ranges)
            wordIndices.append(indices)
        }

        // 底部：歌词提供者（仅全屏显示；原生歌词表格 footer 里的信息，overlay 覆盖后补出来）
        if showsProviderFooter, !currentLyricsProvider.isEmpty {
            let footer = UILabel()
            footer.numberOfLines = 0
            // 同上：这条是**我们自己的本地化文案**（"歌词来源：…"），按内容解析时
            // 仍然跟着界面语言走 —— 写死 `.left` 只会在阿拉伯语界面上出错。
            footer.textAlignment = .natural
            footer.font = .systemFont(ofSize: 14, weight: .regular)
            footer.textColor = lineColor
            footer.text = "word_by_word_lyrics_provider".localizeWithFormat(currentLyricsProvider)
            stackView.addArrangedSubview(footer)
            providerLabel = footer
        }

        // 标签建完了：这一步之后几何才有意义（见那一行日志的说明）。
        setNeedsLayout()
        layoutIfNeeded()
        logLegacyGeometry()
    }

    /// 由词文本拼出行显示文本，并记录每个词在文本中的范围（空格 token 保留，空文本词跳过）。
    private func buildDisplayText(for line: LyricsLineDto) -> (String, [Range<String.Index>], [Int]) {
        guard let words = line.words, !words.isEmpty else { return (line.content, [], []) }

        var text = ""
        var ranges: [Range<String.Index>] = []
        var indices: [Int] = []
        for (index, word) in words.enumerated() {
            guard !word.text.isEmpty else { continue }
            let start = text.endIndex
            text += word.text
            ranges.append(start..<text.endIndex)
            indices.append(index)
        }
        guard !text.isEmpty else { return (line.content, [], []) }
        return (text, ranges, indices)
    }

    /// 行切换时整列表重涂：已唱过/当前行白、未到行黑（Spotify 原生样式）。
    private func repaintAllLines(upTo activeIndex: Int) {
        for (index, label) in lineLabels.enumerated() {
            label.attributedText = nil
            label.text = displayTexts[index]
            label.textColor = index <= activeIndex ? activeLineColorValue : lineColor
        }
    }

    /// 把某一行重置为纯白（已唱状态）。
    private func applyPlain(to lineIndex: Int) {
        guard lineIndex >= 0, lineIndex < lineLabels.count else { return }
        let label = lineLabels[lineIndex]
        label.attributedText = nil
        label.text = displayTexts[lineIndex]
        label.textColor = activeLineColorValue
    }

    /// 用 crossfade 平滑某个 label 的外观切换（消除行切换时的整行闪烁）。
    private func crossfade(_ label: UILabel, _ update: @escaping () -> Void) {
        UIView.transition(with: label, duration: 0.15, options: [.transitionCrossDissolve], animations: update)
    }

    /// 当前行内部按「已唱/正在唱/未唱」上色（Apple Music 式行内点亮）：
    /// 已唱全白（普通）、正在唱全白加粗、未唱降透明度。
    private func applyHighlight(to lineIndex: Int, wordIndex: Int) {
        guard lineIndex >= 0, lineIndex < lineLabels.count else { return }
        let label = lineLabels[lineIndex]
        let text = displayTexts[lineIndex]

        let regularFont = UIFont.systemFont(ofSize: lyricsFontSize, weight: .semibold)

        // 整行默认全白（没有词级数据的行也保持全白）
        let highlighted = NSMutableAttributedString(string: text, attributes: [
            .foregroundColor: activeLineColorValue,
            .font: regularFont,
        ])

        let ranges = wordRanges[lineIndex]
        let indices = wordIndices[lineIndex]
        let activePos = wordIndex >= 0 ? indices.firstIndex(of: wordIndex) : nil

        for (pos, _) in indices.enumerated() {
            guard pos < ranges.count else { continue }
            let nsRange = NSRange(ranges[pos], in: text)

            let isSung = activePos.map { pos < $0 } ?? false
            if pos == activePos {
                // 正在唱：全白 + 描边"加粗"（负 strokeWidth 叠在填充上，不改变字形宽度，
                // 避免日文逐字加粗导致换行重排的闪烁）
                highlighted.addAttributes([
                    .strokeWidth: -2.0,
                    .strokeColor: activeLineColorValue,
                ], range: nsRange)
            } else if activePos != nil, !isSung {
                // 未唱：仅当已有正在唱的词时才降透明度；
                // 一行还没唱到第一个词时整行保持全白，避免「整行突然变灰」的闪烁
                highlighted.addAttributes([
                    .foregroundColor: activeLineColorValue.withAlphaComponent(unsungWordOpacity),
                ], range: nsRange)
            }
            // 已唱（pos < activePos）：保持整行默认的全白
        }

        label.attributedText = highlighted
    }

    // MARK: 背景：模糊封面
    //
    // 是否使用「模糊封面 + 暗化渐变」背景。三条否决：
    // - 定制里选了静态色 → 静态色优先，不做封面背景；
    // - 用户选了显示原生颜色 → 保持 Spotify 原始观感，不做封面背景；
    // - 开关本身关掉 → 退回改动前的纯色底。
    private var backdropEnabled: Bool {
        guard NgzhwmSettingsViewModel.isLyricsBlurredBackdropEnabled else { return false }
        let settings = UserDefaults.lyricsColors
        if settings.useStaticColor, !settings.staticColor.isEmpty { return false }
        if settings.displayOriginalColors { return false }
        return true
    }

    /// 背景配置的缓存标识：换歌、改设置、或底色来源变化都会让它变化。
    /// 返回 nil 表示当前应使用纯色底。
    ///
    /// 把 `currentLyricsBackgroundColorARGB` 也编进去是必要的：CustomLyrics
    /// 是在歌词注入**之后**才写回这个值，只按歌名做 key 会一直用首次算出的底色。
    private func backdropKey() -> String? {
        guard backdropEnabled else { return nil }
        let track = statefulPlayer?.currentTrack() ?? nowPlayingScrollViewController?.loadedTrack
        let trackKey = track?.trackIdentifier ?? "unknown"
        return "\(trackKey)|\(NgzhwmSettingsViewModel.isLyricsBackdropMaterialEnabled)|\(currentLyricsBackgroundColorARGB)"
    }

    /// 按当前背景明暗决定文字色。
    ///
    /// `isDarkSurface` 为 nil 表示「当前是纯色兜底底」，此时沿用改动前的黑底约定；
    /// 非 nil 时表示模糊封面层正在生效（该层必然是深色，因为有暗化渐变），
    /// 而原来的行色是按 Spotify 浅色底定的黑字 —— 不切换未唱行与译文会直接看不见。
    ///
    /// ⚠️ 这里显式传参而不是读 `backdropView.isHidden`：后者会残留上一次的底色判断，
    /// 在「切歌后先走纯色、再切到模糊封面」这种过渡帧上会做出错误结论。
    ///
    /// 返回 true 表示文字色发生了变化（调用方据此决定要不要重涂标签）。
    @discardableResult
    private func resolveTextColors(isDarkSurface: Bool?) -> Bool {
        // 已唱/正在唱始终是最亮的一层，两种底色下都是白色。
        let newLineColor: UIColor
        let newTranslationColor: UIColor
        if let isDarkSurface {
            // 深底：未唱用白（靠 unsungWordOpacity 压暗，与已唱区分），译文白但略淡。
            // 浅底：维持改动前的黑字。
            newLineColor = isDarkSurface ? .white : .black
            newTranslationColor = isDarkSurface ? UIColor.white.withAlphaComponent(0.75) : .black
        } else {
            newLineColor = .black
            newTranslationColor = .black
        }

        let changed = newLineColor != lineColor || newTranslationColor != translationColor
        lineColor = newLineColor
        translationColor = newTranslationColor
        activeLineColorValue = .white
        return changed
    }

    /// 按需（重）配置背景：纯色底或模糊封面层，并同步文字色。
    ///
    /// 每帧调用，但只在「首次 / 换歌 / 改设置 / 底色来源变化」时真正干活。
    private func configureBackdropIfNeeded() {
        // ── 非卡拉 OK 状态：**整块透明，把屏幕交还给 Spotify 原生界面**
        //
        // 什么时候走到这里：逐词歌词开关关掉、或这一首歌**没有可用的逐词数据**。
        // 此时这一层不该画任何东西 —— 连背景也不该画。
        // （判据是**逐词**：只有逐行的歌现在整首交还 Spotify 原生，
        // 见 `attach` 里那道 guard 的产品规则注释。）
        //
        // ⚠️ 这里以前会铺一块**不透明的底色**（`backgroundColor = targetBackground`）。
        // 那一块把 Spotify 原生那一页整个盖住了：标题栏、进度条、播放键全部被压掉，
        // 屏幕上只剩我们的歌词和一块专辑色 —— 也就是"关掉更好的逐词歌词之后
        // 界面全没了"的真正原因。
        //
        // 而这一层本来的设计意图就是"渲染不了就交还"（见下面 `setCurrentTime` 里
        // 那个 guard 的注释）。不透明底色把这个退路堵死了。现在补回来。
        // ⚠️ 判据与 `setCurrentTime` 必须一致，否则会出现"层被撤掉了但底色还在"
        // 或者反过来"层还在但底色没了"——两者是同一层的一体两面。
        guard NgzhwmSettingsViewModel.isWordByWordLyricsEnabled,
              hasUsableWordLevelData(currentLyricsDto) else {
            backgroundColor = .clear
            backdropView.isHidden = true
            // 同 `setCurrentTime`：整层交还原生时控制条也要一起交还。
            applyControlsVisibility(false)
            return
        }

        // resolvedBackgroundColor 是缓存，定制里的颜色时它不会变，
        // 所以不能沿用旧的 `backgroundColor != targetBackground` 判断，
        // 要把影响外观的几项一起编进 key。
        let key = backdropKey()
        let changed = resolvedBackgroundColor == nil || resolvedBackdropKey != key
        let targetBackground = changed ? wordByWordSolidBackgroundColor() : (resolvedBackgroundColor ?? .black)

        if changed {
            resolvedBackgroundColor = targetBackground
            resolvedBackdropKey = key
        }

        // 纯色底（用户选了静态色 / 显示原生色 / 开关关闭）：整块退回改动前的行为。
        guard key != nil else {
            if changed {
                backdropView.isHidden = true
                backgroundColor = targetBackground
                // 渐隐层的颜色/停靠点由 `updateFadeLayers` 统一设置
                // （颜色与 locations 必须成对，见那里）—— 这里只让它重算一次。
                setNeedsLayout()
            }
            // 纯色兜底：沿用改动前的黑字约定（传 nil）。
            if resolveTextColors(isDarkSurface: nil) {
                repaintAllLines(upTo: activeLineIndex)
            }
            return
        }

        // 文字色跟着背景明暗走 —— 模糊封面层必然是深色底，而默认行色是黑字。
        // 每帧都能安全调用：resolveTextColors 是恒等操作，除非颜色真的要变。
        if changed {
            backdropView.isHidden = false
            backdropView.configure(
                baseColor: targetBackground,
                showsArtwork: true,
                material: NgzhwmSettingsViewModel.isLyricsBackdropMaterialEnabled
            )
            // 渐隐层同样交给 `updateFadeLayers`（底色变了要重算一次）。
            setNeedsLayout()
            // 自身保持透明，否则会把 backdropView 盖住。
            backgroundColor = .clear
        }

        if resolveTextColors(isDarkSurface: backdropView.baseColorBrightness < 0.55) {
            repaintAllLines(upTo: activeLineIndex)
        }
    }

    // MARK: 背景取色（跟随「定制」选项）
    //
    // 取色逻辑已抽成文件级 `wordByWordSolidBackgroundColor`：
    // 旧 UIKit 层（iOS 26 以下）与"只开逐词歌词"那条路的纯色背景共用同一份，
    // 两处各写一遍必然慢慢跑偏（这个文件里已经吃过好几次这种亏）。
    //
    // MARK: 手动滚动打断自动跟随

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        autoScrollPauseUntil = Date().addingTimeInterval(3)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // 歌词滚到顶部/底部时对应渐隐层才隐藏（保证首尾行不被遮挡）
        updateFadeVisibility()
    }

    /// 顶部/底部渐隐层的显隐。
    ///
    /// ⚠️ 有壳时**永远显示**：这两条现在不是"首尾行的装饰"，而是歌词与壳之间的过渡，
    /// 同时也是壳的底色（见 `updateFadeLayers`）。一藏起来，标题栏和控件栏就会直接
    /// 压在清晰的歌词上 —— 真机截图实证：三键压在一行歌词上、歌曲名和第一行重叠。
    ///
    /// 预览（无壳）保持原来的行为：歌词在顶部/底部时隐藏，保证首尾行不被遮挡。
    private func updateFadeVisibility() {
        guard !showsPlaybackControls else {
            topFadeView.isHidden = stackView.isHidden
            bottomFadeView.isHidden = stackView.isHidden
            return
        }

        let atTop = scrollView.contentOffset.y <= 1
        let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        let atBottom = scrollView.contentOffset.y >= maxY - 1
        topFadeView.isHidden = stackView.isHidden || atTop
        bottomFadeView.isHidden = stackView.isHidden || atBottom
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        autoScrollPauseUntil = Date().addingTimeInterval(2)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        autoScrollPauseUntil = Date().addingTimeInterval(2)
    }

    private func scrollToLine(_ lineIndex: Int) {
        // 手动滚动暂停期内不自动拉回
        guard Date() >= autoScrollPauseUntil else { return }
        guard lineIndex >= 0, lineIndex < lineLabels.count else { return }
        // 强制刷新布局：初次挂载/rebuild 后 contentSize 与各行 frame 尚未更新，
        // 不刷新会按旧 contentSize 算出错误 target，导致全屏打开时不滚到当前行。
        scrollView.layoutIfNeeded()
        let label = lineLabels[lineIndex]
        let rect = label.convert(label.bounds, to: scrollView)
        // 当前行定位到视口上方约 1/3 处，而不是 scrollRectToVisible 那样贴到最底部。
        let targetY = rect.minY - scrollView.bounds.height * activeLineViewportFraction
        let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        let target = CGPoint(x: 0, y: min(max(0, targetY), maxY))
        // 自定义更短的动画时长，让自动滚动更干脆（贴近 Spotify 手感）
        UIView.animate(
            withDuration: scrollAnimationDuration,
            delay: 0,
            options: [.curveEaseOut],
            animations: { [weak self] in
                self?.scrollView.setContentOffset(target, animated: false)
            }
        )
    }

    /// 滚回歌词顶部（含安全区内边距修正）。
    private func scrollToTop() {
        scrollView.setContentOffset(
            CGPoint(x: 0, y: -scrollView.adjustedContentInset.top),
            animated: true
        )
    }

    @objc private func handleLineTap(_ recognizer: UITapGestureRecognizer) {
        guard let label = recognizer.view as? LineLabel,
              let dto = dto, label.lineIndex >= 0, label.lineIndex < dto.lines.count,
              let offset = dto.lines[label.lineIndex].offsetMs else { return }
        // 这一条（旧 UIKit overlay 的点行）以前是**直接 seek 到 offsetMs** ——
        // 少了那 5ms，和"歌词进播放器"那一档犯的是同一个错（点这一行、跳到上一行）。
        // 统一走 `seekToTappedLyricLine`（定义在 `AppleMusicLyricsOverlay.swift` 开头）。
        seekToTappedLyricLine(TimeInterval(offset) / 1000)
    }
}
