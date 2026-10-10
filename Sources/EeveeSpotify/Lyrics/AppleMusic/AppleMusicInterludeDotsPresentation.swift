import CoreGraphics
import Foundation

// 移植自 MeloX `MeloX/Core/Lyrics/AppleMusicInterludeDotsPresentation.swift`（GPL-3.0）。
//
// 这里就是用户说的「三个呼吸点」的**全部动画数学**：给定播放时间，算出
//   · 三个点各自的不透明度（`dotOpacities`）—— 依次点亮，前面点亮的点回落到
//     `inactiveDotOpacity`；
//   · 整排的缩放（`scale`）—— 平时按 `breathHalfCycleDuration` 一呼一吸，
//     cue-out 时先冲一下峰值再塌缩；
//   · 整排的不透明度（`opacity`）—— 退出阶段淡出。
//
// 纯函数、无 UI 依赖：视图只负责把这三个数画出来（见 `AppleMusicInterludeRow`）。
// 时钟由调用方给（本项目 = `AppleMusicLyricsPage` 宿主里那条 CADisplayLink）。
//
// ⚠️ 与 MeloX 的差别只有措辞级：注释改中文、`switch` 与 `guard` 的写法对齐本仓库的
//    `AppleMusicInterludeMotionProfile`。曲线、事件顺序、阈值一律照抄 —— 这排点的观感
//    就是靠这些数字还原 Apple Music 的，改一个数都要先在真机上看过。

struct AppleMusicInterludeDotsPresentation: Equatable, Sendable {
    let dotOpacities: [Double]
    let scale: CGFloat
    let opacity: Double

    static func make(
        playbackTime: TimeInterval,
        interlude: LyricInterlude,
        reducesMotion: Bool,
        profile: AppleMusicInterludeMotionProfile = .iOS26_6
    ) -> AppleMusicInterludeDotsPresentation {
        let timing = profile.timing(for: interlude)
        // 这一拍不属于这个间奏（还没到，或已经退出完了）⇒ 整排藏起来。
        guard playbackTime.isFinite,
              playbackTime >= timing.startTime,
              playbackTime < timing.visualEndTime else {
            return hidden(profile: profile)
        }

        // 「减弱动态效果」：不呼吸、不冲峰，只按阶段一个个点亮，然后整排消失。
        if reducesMotion {
            return reducedMotionPresentation(
                at: playbackTime,
                timing: timing,
                profile: profile
            )
        }

        let dotOpacities = (0..<profile.dotCount).map { dotIndex in
            fillOpacity(
                at: playbackTime,
                dotIndex: dotIndex,
                timing: timing,
                profile: profile
            )
        }

        // 淡出从"冲峰结束"那一刻才开始：先享受完那一下，再整排走。
        let exitStartTime = timing.cueOutTime + profile.cuePeakDuration
        let opacity: Double
        if playbackTime < exitStartTime {
            opacity = 1
        } else {
            opacity = ScalarTransition(
                startTime: exitStartTime,
                duration: profile.cueFadeDuration,
                fromValue: 1,
                toValue: 0,
                curve: .easeIn
            ).value(at: playbackTime)
        }

        return AppleMusicInterludeDotsPresentation(
            dotOpacities: dotOpacities,
            scale: cueScale(
                at: playbackTime,
                timing: timing,
                profile: profile
            ),
            opacity: opacity
        )
    }

    private static func hidden(
        profile: AppleMusicInterludeMotionProfile
    ) -> AppleMusicInterludeDotsPresentation {
        AppleMusicInterludeDotsPresentation(
            dotOpacities: Array(repeating: 0, count: profile.dotCount),
            scale: 1,
            opacity: 0
        )
    }

    /// 减弱动态效果那一档：不做缩放（`scale` 恒 1），只按填充阶段给亮/暗两档。
    private static func reducedMotionPresentation(
        at playbackTime: TimeInterval,
        timing: AppleMusicInterludeMotionTiming,
        profile: AppleMusicInterludeMotionProfile
    ) -> AppleMusicInterludeDotsPresentation {
        let exitStartTime = timing.cueOutTime + profile.cuePeakDuration
        guard playbackTime < exitStartTime else {
            return hidden(profile: profile)
        }

        let completedDotCount: Int
        if playbackTime < timing.fillStartTime {
            completedDotCount = 0
        } else if timing.fillStageInterval > 0 {
            completedDotCount = min(
                Int(
                    floor(
                        (playbackTime - timing.fillStartTime)
                            / timing.fillStageInterval
                    )
                ) + 1,
                profile.dotCount
            )
        } else {
            completedDotCount = profile.dotCount
        }

        let dotOpacities = (0..<profile.dotCount).map { index -> Double in
            if completedDotCount == 0 {
                return 0
            }
            return index < completedDotCount
                ? 1
                : profile.inactiveDotOpacity
        }

        return AppleMusicInterludeDotsPresentation(
            dotOpacities: dotOpacities,
            scale: 1,
            opacity: 1
        )
    }

    /// 第 `dotIndex` 个点此刻多亮。
    ///
    /// 每个点都排了 `dotCount` 个事件（"点到第几个"各一次），事件的起点按
    /// `fillStageInterval` 依次推后、再各自错开 `fillStagger` —— 这就是"一个接一个亮起来"
    /// 的全部来源。目标值分两种：还没轮到自己点亮 → `inactiveDotOpacity`（暗着等），
    /// 已经轮到 → 1。先点亮的点随后会被下一个事件带回暗档。
    private static func fillOpacity(
        at playbackTime: TimeInterval,
        dotIndex: Int,
        timing: AppleMusicInterludeMotionTiming,
        profile: AppleMusicInterludeMotionProfile
    ) -> Double {
        let events = (1...profile.dotCount).map { completedCount in
            ScalarTransitionEvent(
                startTime: timing.fillStartTime
                    + Double(completedCount - 1) * timing.fillStageInterval
                    + Double(dotIndex) * profile.fillStagger,
                duration: profile.fillAnimationDuration,
                targetValue: dotIndex < completedCount
                    ? 1
                    : profile.inactiveDotOpacity,
                curve: .linear
            )
        }
        return ScalarTransitionEvent.value(
            at: playbackTime,
            initialValue: 0,
            events: events
        )
    }

    /// 整排的缩放：cue-out 之前是"呼吸"，之后是"冲峰 → 塌缩"。
    private static func cueScale(
        at playbackTime: TimeInterval,
        timing: AppleMusicInterludeMotionTiming,
        profile: AppleMusicInterludeMotionProfile
    ) -> CGFloat {
        // ⚠️ 冲峰的起点必须**接上**呼吸的当前值，否则那一下会看到跳变。
        let scaleAtCueOut = breathScale(
            at: timing.cueOutTime,
            timing: timing,
            profile: profile
        )
        guard playbackTime >= timing.cueOutTime else {
            return breathScale(
                at: playbackTime,
                timing: timing,
                profile: profile
            )
        }

        let peakTransition = ScalarTransition(
            startTime: timing.cueOutTime,
            duration: profile.cuePeakDuration,
            fromValue: Double(scaleAtCueOut),
            toValue: Double(profile.cuePeakScale),
            curve: .cuePeak
        )
        let terminalStartTime = timing.cueOutTime + profile.cuePeakDuration
        guard playbackTime >= terminalStartTime else {
            return CGFloat(peakTransition.value(at: playbackTime))
        }
        return CGFloat(
            ScalarTransition(
                startTime: terminalStartTime,
                duration: profile.cueTerminalScaleDuration,
                fromValue: Double(profile.cuePeakScale),
                toValue: Double(profile.cueTerminalScale),
                curve: .easeIn
            ).value(at: playbackTime)
        )
    }

    /// 呼吸：`breathHalfCycleDuration` 半个周期，偶数相位放大（`breathUpperScale`）、
    /// 奇数相位缩回（`breathLowerScale`），每个相位都留 `breathAnimationInset` 给缓动。
    private static func breathScale(
        at playbackTime: TimeInterval,
        timing: AppleMusicInterludeMotionTiming,
        profile: AppleMusicInterludeMotionProfile
    ) -> CGFloat {
        guard timing.breathHalfCycleDuration > 0 else { return 1 }

        let phaseCount = max(
            Int(
                ceil(
                    (timing.cueOutTime - timing.startTime)
                        / timing.breathHalfCycleDuration
                )
            ),
            1
        )
        let animationDuration = max(
            timing.breathHalfCycleDuration - profile.breathAnimationInset,
            0
        )
        let events = (0..<phaseCount).map { phase in
            ScalarTransitionEvent(
                startTime: timing.startTime
                    + Double(phase) * timing.breathHalfCycleDuration
                    + profile.breathDelay,
                duration: animationDuration,
                targetValue: Double(
                    phase.isMultiple(of: 2)
                        ? profile.breathUpperScale
                        : profile.breathLowerScale
                ),
                curve: .easeOut
            )
        }
        return CGFloat(
            ScalarTransitionEvent.value(
                at: min(playbackTime, timing.cueOutTime),
                initialValue: 1,
                events: events
            )
        )
    }
}

/// 一条"从当前值过渡到目标值"的事件。多条串起来按时间顺序求值，
/// 后来的那条以前一条在它起点处的**结果**为起点 —— 所以不会跳变。
private struct ScalarTransitionEvent {
    let startTime: TimeInterval
    let duration: TimeInterval
    let targetValue: Double
    let curve: AppleMusicInterludeTimingCurve

    static func value(
        at playbackTime: TimeInterval,
        initialValue: Double,
        events: [ScalarTransitionEvent]
    ) -> Double {
        var activeTransition: ScalarTransition?
        for event in events {
            guard playbackTime >= event.startTime else {
                return activeTransition?.value(at: playbackTime)
                    ?? initialValue
            }
            let fromValue = activeTransition?.value(at: event.startTime)
                ?? initialValue
            activeTransition = ScalarTransition(
                startTime: event.startTime,
                duration: event.duration,
                fromValue: fromValue,
                toValue: event.targetValue,
                curve: event.curve
            )
        }
        return activeTransition?.value(at: playbackTime) ?? initialValue
    }
}

/// 一条按曲线推进的标量过渡。`duration <= 0` 直接给终值（退化成阶跃）。
private struct ScalarTransition {
    let startTime: TimeInterval
    let duration: TimeInterval
    let fromValue: Double
    let toValue: Double
    let curve: AppleMusicInterludeTimingCurve

    func value(at playbackTime: TimeInterval) -> Double {
        guard duration > 0 else { return toValue }
        let progress = min(
            max((playbackTime - startTime) / duration, 0),
            1
        )
        let curvedProgress = curve.value(at: progress)
        return fromValue + (toValue - fromValue) * curvedProgress
    }
}

/// Apple Music 那四条曲线的等价物（`uiView` 的默认缓动 + 那一下冲峰的过冲感）。
private enum AppleMusicInterludeTimingCurve {
    case linear
    case easeIn
    case easeOut
    case cuePeak

    func value(at progress: Double) -> Double {
        switch self {
        case .linear:
            return progress
        case .easeIn:
            return CubicBezier(
                firstControlPoint: (0.42, 0),
                secondControlPoint: (1, 1)
            ).value(at: progress)
        case .easeOut:
            return CubicBezier(
                firstControlPoint: (0, 0),
                secondControlPoint: (0.58, 1)
            ).value(at: progress)
        case .cuePeak:
            return CubicBezier(
                firstControlPoint: (0.25, 0.1),
                secondControlPoint: (0.25, 1)
            ).value(at: progress)
        }
    }
}

/// 三次贝塞尔求值：先按 x 反解参数（牛顿迭代 + 二分兜底），再取 y。
private struct CubicBezier {
    let firstControlPoint: (x: Double, y: Double)
    let secondControlPoint: (x: Double, y: Double)

    func value(at progress: Double) -> Double {
        let progress = min(max(progress, 0), 1)
        guard progress > 0, progress < 1 else { return progress }

        var parameter = progress
        for _ in 0..<8 {
            let difference = component(
                at: parameter,
                first: firstControlPoint.x,
                second: secondControlPoint.x
            ) - progress
            let derivative = componentDerivative(
                at: parameter,
                first: firstControlPoint.x,
                second: secondControlPoint.x
            )
            guard abs(derivative) > 0.000_001 else { break }
            let candidate = parameter - difference / derivative
            guard candidate >= 0, candidate <= 1 else { break }
            parameter = candidate
        }

        var lowerBound = 0.0
        var upperBound = 1.0
        for _ in 0..<20 {
            let x = component(
                at: parameter,
                first: firstControlPoint.x,
                second: secondControlPoint.x
            )
            if abs(x - progress) < 0.000_001 {
                break
            }
            if x < progress {
                lowerBound = parameter
            } else {
                upperBound = parameter
            }
            parameter = (lowerBound + upperBound) * 0.5
        }

        return component(
            at: parameter,
            first: firstControlPoint.y,
            second: secondControlPoint.y
        )
    }

    private func component(
        at parameter: Double,
        first: Double,
        second: Double
    ) -> Double {
        let inverse = 1 - parameter
        return 3 * inverse * inverse * parameter * first
            + 3 * inverse * parameter * parameter * second
            + parameter * parameter * parameter
    }

    private func componentDerivative(
        at parameter: Double,
        first: Double,
        second: Double
    ) -> Double {
        let inverse = 1 - parameter
        return 3 * inverse * inverse * first
            + 6 * inverse * parameter * (second - first)
            + 3 * parameter * parameter * (1 - second)
    }
}
