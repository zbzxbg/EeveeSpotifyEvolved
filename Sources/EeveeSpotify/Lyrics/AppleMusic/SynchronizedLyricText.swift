import SwiftUI

// 改写自 MeloX `MeloX/Features/Player/Lyrics/Shared/SynchronizedLyricText.swift`（GPL-3.0）。
//
// ★ 与 MeloX 原版的差异（有意为之，非疏漏）★
//   1. 去掉设置体系耦合：MeloX 的每个视觉参数都能被用户在设置里改，并在
//      「Apple Music 预设」与「MeloX 自有预设」之间分叉。本项目只需要
//      Apple Music 那套，所以直接固定用 `AppleMusicLyricsMotionProfile.iOS26.6`，
//      不再传 `settings`。
//   2. 去掉对唱翻转 / 背景人声 / ruby 音译的独立分量，保留**接入点**（`isFlipped`），
//      等数据层能提供 agent 信息时再补——避免现在搬入一堆恒不成立的死分支。
//   3. 保留原版的分层结构：未唱副本（可模糊）+ 已唱副本（渐变前沿裁剪 + 光晕），
//      以及 `timingEffectsStrength` 驱动的焦点强度衰减。
//
// 这个视图本身不持有时钟：`playbackTime` 由外部每帧传入（本项目走 CADisplayLink）。

@available(iOS 26.0, *)
struct SynchronizedLyricText: View {

    // MARK: 输入

    /// 这一行的逐字时间轴（来自 `LyricLine.syllables`）。
    let syllables: [LyricSyllable]
    /// 整行文本（用于没有逐字时间轴时的降级显示）。
    let text: String
    /// 当前播放时间（秒）。由外部每帧喂入。
    let playbackTime: TimeInterval
    /// 是否为当前焦点行。
    let isFocused: Bool
    /// 焦点强度 0~1：驱动「未唱字」的透明度与模糊过渡。
    let focusStrength: Double
    /// 行译文（可选），显示在原文下方。
    let translation: String?
    /// 罗马字 / 音译（可选），显示在原文**上方**。
    ///
    /// ★ 2026-10-11（用户）：「罗马字在歌词上方，翻译在下方」。数据来自 `LyricLine.romanization`
    /// （`LyricLinesAdapter` 用仓库既有的罗马化管线填的：整首语言判定 + 逐语言开关，
    /// 且**与原文相同的行为 nil** ⇒ 那种行不会白占一行高度）。
    ///
    /// ⚠️ 这个属性是**必须**存在的：`body` 里那句 `if let romanization`（Swift 5.7 的简写绑定）
    /// 只在**当前作用域里已有同名可选值**时才成立。2026-10-11 CI 就是这么红的 ——
    /// `error: cannot find 'romanization' in scope`（当时我在 `body` 里写了这一行、
    /// 却没有把它加成视图的入参）。自检规则 ⑤ 现在会提前抓这一形态。
    let romanization: String?
    /// 副唱/背景人声（可选），按位置画在主歌上方或下方。
    let backgroundVocal: LyricBackgroundVocal?
    /// 文本最大宽度（决定折行）。
    let constrainedWidth: CGFloat?
    /// 对齐方式。
    let alignment: SynchronizedLyricTextAlignment
    /// 排版分档（字号 / 译文号 / 行距）。
    let typography: LyricsTypographyScale
    /// 字重。
    let fontWeight: LyricsFontWeight
    /// 主色。
    let primaryColor: Color
    /// 是否应用时间轴特效（未聚焦的行传 false，直接静态绘制，省掉每帧开销）。
    let appliesTimingEffects: Bool
    /// 是否显示副唱（背景人声）。
    ///
    /// 内嵌「预览歌词」传 false：预览只有约 200pt 高、主字号 19pt，
    /// 副唱按 0.63 系数缩到约 12pt 基本看不清，还白占一行高度。
    /// 只让全屏页承担这个信息层级。
    let showsBackgroundVocals: Bool
    /// 是否显示行译文。
    ///
    /// Apple Music 歌词层一律传 false —— 那是"Apple Music 成功返回歌词"
    /// 的条件之一（见 `printShowsTranslation` 的说明），译文不参与展示。
    let showsTranslation: Bool

    init(
        syllables: [LyricSyllable],
        text: String,
        playbackTime: TimeInterval,
        isFocused: Bool,
        focusStrength: Double,
        translation: String? = nil,
        romanization: String? = nil,
        backgroundVocal: LyricBackgroundVocal? = nil,
        constrainedWidth: CGFloat?,
        alignment: SynchronizedLyricTextAlignment = .leading,
        typography: LyricsTypographyScale = .fullscreen,
        fontWeight: LyricsFontWeight = .semibold,
        primaryColor: Color = .white,
        appliesTimingEffects: Bool = true,
        showsBackgroundVocals: Bool = true,
        showsTranslation: Bool = true
    ) {
        self.syllables = syllables
        self.text = text
        self.playbackTime = playbackTime
        self.isFocused = isFocused
        self.focusStrength = focusStrength
        self.translation = translation
        self.romanization = romanization
        self.backgroundVocal = backgroundVocal
        self.constrainedWidth = constrainedWidth
        self.alignment = alignment
        self.typography = typography
        self.fontWeight = fontWeight
        self.primaryColor = primaryColor
        self.appliesTimingEffects = appliesTimingEffects
        self.showsBackgroundVocals = showsBackgroundVocals
        self.showsTranslation = showsTranslation
    }

    // MARK: 常量（来自 Apple Music 26.6 profile）

    private static var profile: AppleMusicLyricsMotionProfile {
        .iOS26_6
    }
    private static var supplemental: AppleMusicLyricsSupplementalTextProfile {
        .iOS26_6
    }

    /// 复用别名，读起来短一些。
    private var fontSize: CGFloat { typography.primaryFontSize }

    // MARK: Body

    var body: some View {
        VStack(
            alignment: alignment.stackAlignment,
            spacing: 0
        ) {
            // ★★ 2026-10-11（用户）：「**罗马字在歌词上方**」（翻译在下方 —— 那一行本来就在下面）。
            //
            // 排版是我定的（用户把大小交给我）：
            //   · 字号 = `supplementalFontSize × 0.85` —— 译文 17pt 时它是 ≈14.5pt：
            //     罗马字是"读音提示"，比译文再小一档，不该和正文抢注意力；
            //   · 与主歌词的间距用 Apple Music 自己的 `transliterationSpacing = 5`
            //     （`AppleMusicLyricsSupplementalTextProfile` 里那个常量本来就写着"音译"）；
            //   · 颜色/焦点跟随与译文同一条公式，再淡一档。
            if let romanization, !romanization.isEmpty {
                romanizationText(romanization)
            }

            // 副唱画在主歌的**上方或下方**，取决于它在 TTML 里的位置；
            // 它是独立的一小行，而不是拼进主歌文本（那样会把"同时演唱"
            // 退化成"先唱完主歌再唱副唱"）。预览模式下整块不显示。
            if showsBackgroundVocals,
               let backgroundVocal,
               backgroundVocal.position == .beforePrimary {
                backgroundVocalRow(backgroundVocal)
            }

            lyricText

            if showsBackgroundVocals,
               let backgroundVocal,
               backgroundVocal.position == .afterPrimary {
                backgroundVocalRow(backgroundVocal)
            }

            if showsTranslation, let translation, !translation.isEmpty {
                translationText(translation)
            }
        }
        .frame(
            maxWidth: .infinity,
            alignment: alignment.frameAlignment
        )
    }

    // MARK: 副唱（背景人声）

    /// 副唱行：同一个渲染器、更小的字号、更弱的视觉权重。
    ///
    /// 参数取自 Apple Music 26.6（`AppleMusicLyricsMotionProfile`）：
    /// 字号 ×0.63、非播放行再 ×0.9、与主歌的间距 15pt。
    /// 时间轴是它**自己的**（与主词重叠），所以填充动画也是独立走的。
    @ViewBuilder
    private func backgroundVocalRow(
        _ backgroundVocal: LyricBackgroundVocal
    ) -> some View {
        let scale = CGFloat(Self.profile.backgroundVocalsDeselectedScale)
        SynchronizedLyricText(
            syllables: backgroundVocal.syllables,
            text: backgroundVocal.text,
            playbackTime: playbackTime,
            isFocused: false,
            focusStrength: focusStrength,
            translation: backgroundVocal.translation,
            constrainedWidth: constrainedWidth,
            alignment: alignment,
            typography: typography.scaled(
                primaryBy: Self.profile.backgroundVocalsFontCoefficient,
                supplementalBy: Self.profile.translationBackgroundVocalsFontCoefficient
            ),
            fontWeight: fontWeight,
            primaryColor: primaryColor,
            appliesTimingEffects: appliesTimingEffects
        )
        .scaleEffect(scale, anchor: alignment == .trailing ? .trailing : .leading)
        .padding(
            backgroundVocal.position == .beforePrimary ? .bottom : .top,
            CGFloat(Self.profile.backgroundVocalsTopSpacing)
        )
    }

    // MARK: 主歌词

    @ViewBuilder
    private var lyricText: some View {
        let font = Font.system(size: fontSize, weight: fontWeight.swiftUIWeight)
        let textValue = resolvedText

        textValue
            .font(font)
            .foregroundStyle(primaryColor)
            .multilineTextAlignment(alignment.textAlignment)
            // ★ 2026-10-12（用户：「主语言换行的中间空隙有点大了」）：
            //   这里以前吃的是 `typography.lineSpacing` —— 那是**块间距**（`.player` 档 26pt，
            //   kumone 的 `LazyVStack(spacing: 26)` 那条）。一行自己折成两行时也吃 26
            //   ⇒ 折行看着像"空了一整句"。改用**折行专用**的紧行距（见 `wrappedLineSpacing`）。
            .lineSpacing(typography.wrappedLineSpacing)
            // ⚠️ 顺序要紧：先注册属性作用域，再挂渲染器。
            // 少了 `lyricTextAttributes()`，渲染器在 run 上取不到逐字时间轴，
            // 表现为文字正常但完全不亮（且不报错）。
            .lyricTextAttributes()
            .textRenderer(
                LyricGlowTextRenderer(
                    playbackTime: playbackTime,
                    style: rendererStyle,
                    layoutConfiguration: .init(
                        width: constrainedWidth,
                        centersLines: alignment == .center
                    ),
                    appliesTimingEffects: appliesTimingEffects,
                    timingEffectsStrength: focusStrength
                )
            )
            .transaction { transaction in
                // 每帧都在换 playbackTime，隐式动画会把它插值成拖影。
                transaction.animation = nil
            }
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 有逐字时间轴走逐字构建；否则退回普通文本。
    private var resolvedText: Text {
        guard !syllables.isEmpty else {
            return TimedLyricTextBuilder.text(
                from: text,
                constrainedWidth: constrainedWidth,
                fontSize: fontSize,
                fontWeight: fontWeight
            )
        }
        return TimedLyricTextBuilder.text(
            from: syllables,
            constrainedWidth: constrainedWidth,
            fontSize: fontSize,
            fontWeight: fontWeight
        )
    }

    private var rendererStyle: LyricGlowTextRenderer.Style {
        let profile = Self.profile
        return LyricGlowTextRenderer.Style(
            glowRadius: CGFloat(profile.glowRadius),
            glowOpacity: 0.4,
            glowsLongSyllablesOnly: false,
            longSyllableDetectionMode: .character,
            longSyllableDurationThreshold: 0.55,
            unplayedOpacity: profile.selectedUpcomingTextOpacity,
            focusOpacityEndpoints: LyricFocusOpacityEndpoints(
                deselected: profile.deselectedTextOpacity,
                selected: profile.selectedTextOpacity,
                selectedUpcoming: profile.selectedUpcomingTextOpacity
            ),
            // 预设路径下「未唱字」的模糊由外层整行 blur 负责，字形层不再叠一层。
            maximumUnplayedBlurRadius: 0,
            playedRise: CGFloat(profile.syllableLift),
            maximumLongSyllableScale: CGFloat(profile.emphasisScaleRange.upperBound),
            longSyllableExpansionPadding: 0,
            highlightGradientWidth: 1,
            lineProgressionGradientFeather: CGFloat(profile.lineProgressionGradientFeather),
            highlightGradientReduction: 0,
            lineFinishProgressAnimationDuration: profile.lineFinishProgressAnimationDuration,
            liftMode: .character
        )
    }

    // MARK: 罗马字（主歌词**上方**那一行）

    /// 罗马字/音译行。数值的选择与理由见 `body` 里那段注释。
    private func romanizationText(_ romanization: String) -> some View {
        Text(romanization)
            .font(
                .system(
                    size: typography.supplementalFontSize * 0.85,
                    weight: .regular
                )
            )
            .foregroundStyle(
                primaryColor.opacity(
                    // 与译文同一条"跟随焦点"的公式，但整体再淡一档（它是读音提示）。
                    (
                        Self.profile.deselectedTextOpacity
                            + (Self.profile.selectedTextOpacity
                                - Self.profile.deselectedTextOpacity)
                                * clamped(focusStrength)
                    ) * 0.85
                )
            )
            .multilineTextAlignment(alignment.textAlignment)
            .padding(.bottom, AppleMusicLyricsSupplementalTextProfile.iOS26_6.transliterationSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .frame(
                maxWidth: .infinity,
                alignment: alignment.frameAlignment
            )
    }

    // MARK: 译文

    private func translationText(_ translation: String) -> some View {
        Text(translation)
            .font(
                .system(
                    // 用分档里显式给出的译文字号，而不是按主字号比例算 ——
                    // 原 overlay 就是 22 主 / 16 译文（约 0.73），不是 0.62。
                    size: typography.supplementalFontSize,
                    weight: .regular
                )
            )
            .foregroundStyle(
                primaryColor.opacity(
                    // 译文跟随整行焦点，而不是逐字时间轴。
                    Self.profile.deselectedTextOpacity
                        + (Self.profile.selectedTextOpacity
                            - Self.profile.deselectedTextOpacity)
                            * clamped(focusStrength)
                )
            )
            .multilineTextAlignment(alignment.textAlignment)
            .padding(.top, typography.supplementalSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .frame(
                maxWidth: .infinity,
                alignment: alignment.frameAlignment
            )
    }

    private func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

// MARK: - 对齐

@available(iOS 26.0, *)
enum SynchronizedLyricTextAlignment: Equatable {
    case leading
    case center
    /// 对唱时另一侧歌手的行（Apple Music 会把它推到另一端）。
    case trailing

    var frameAlignment: Alignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    var stackAlignment: HorizontalAlignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    var textAlignment: TextAlignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    /// 对唱翻转的行用 trailing，其余保持 leading。
    static func resolved(isFlipped: Bool) -> SynchronizedLyricTextAlignment {
        isFlipped ? .trailing : .leading
    }
}
