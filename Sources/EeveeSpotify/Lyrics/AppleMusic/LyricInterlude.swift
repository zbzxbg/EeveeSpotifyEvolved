import Foundation

// 移植自 MeloX `MeloX/Core/Lyrics/LyricInterludeTimeline.swift` 的模型部分（GPL-3.0）。
//
// 这个文件**只有模型与呈现位置结构**（谁是谁、这一拍该显示什么）。检测与定位的算法在
// 隔壁 `LyricInterludeTimeline.swift`；渲染在 `AppleMusicInterludeRow.swift`。

enum LyricInterludeTimingSource: Hashable, Sendable {
    /// YRC 提供了作者标注的行/音节结束时间。
    case precise

    /// LRC 只有行起始时间，人声尾部是估算的。
    case lineSynchronized
}

enum LyricInterludeDetectionPolicy: Hashable, Sendable {
    /// 对齐 Apple Music 的作者时间轴路径，忽略推断出来的 LRC 间隙。
    case preciseTiming

    /// 把推断静音时长达到阈值的 LRC 间隙也算进来。
    case automatic(minimumInferredGapDuration: TimeInterval)

    /// 页面用的口径：15 秒。
    ///
    /// 这条数字来自 Musixmatch 对间奏标记（`♪`）的规则 —— 连续 15 秒以上没有可同步的
    /// 歌词才算一段间奏。更短的阈值（MeloX 的默认值是 4.0s）会把"两句之间换一口气"
    /// 也画成呼吸点：那是一条 40pt 的驻留行，在歌词里看起来就是凭空多出的空行。
    ///
    /// ⚠️ MXM 那条规则还有个结构前提（"只在分节之间"），我们只有时间轴，没有分节信息，
    /// 所以这里是纯时间判据：只要人声尾巴到下一句之间空了 15 秒以上就画。
    static let standard = LyricInterludeDetectionPolicy.automatic(
        minimumInferredGapDuration: 15
    )
}

struct LyricInterlude: Identifiable, Hashable {
    let startTime: TimeInterval
    let countdownEndTime: TimeInterval
    let precedingLyricID: LyricLine.ID?
    let followingLyricID: LyricLine.ID
    let displayBeforeLyricID: LyricLine.ID
    let timingSource: LyricInterludeTimingSource

    var id: String {
        "lyric-interlude-\(startTime)-\(displayBeforeLyricID)-\(followingLyricID)"
    }

    var isPrelude: Bool {
        precedingLyricID == nil
    }

    /// 圆点在下一句歌词开始前就进入退出动画。
    var cueOutTime: TimeInterval {
        max(
            startTime,
            countdownEndTime
                - AppleMusicInterludeMotionProfile.iOS26_6.cueOutLeadTime
        )
    }

    var gapDuration: TimeInterval {
        max(countdownEndTime - startTime, 0)
    }
}

struct LyricInterludePlaybackPosition: Equatable {
    /// 常驻的 40pt 行拥有指示器生命周期；在歌词边界附近它可能已经视觉清空。
    let visibleInterludeID: LyricInterlude.ID?

    /// 在 cue-out 动画视觉完成前，槽位保持焦点。
    let focusedInterludeID: LyricInterlude.ID?

    /// 圆点消失之后、歌词作者标注的开始时间之前被提升的那一行。
    let promotedLyricID: LyricLine.ID?

    let nextTransitionTime: TimeInterval?
}
