import CoreGraphics
import Foundation

// MARK: - 间奏（三个呼吸点）的纯逻辑
//
// 为什么要有这个测试：间奏这条链有三层，其中两层**没有任何 UI 依赖**：
//   · `LyricInterludeTimeline`              —— 哪两句之间算间奏、这一拍该显示什么；
//   · `AppleMusicInterludeDotsPresentation` —— 这一拍三个点各多亮、整排缩放/淡出。
// 第三层（`AppleMusicInterludeRow`）要 SwiftUI，进不来 —— 而前两层恰恰是"算错了也看不出来"
// 的那种代码：阈值差 0.2s、比较方向写反、曲线取错，真机上只表现为"点早亮了一下 / 根本没出现"。
//
// 还有一层意思：本仓库本机没有 Swift 工具链（只有 Windows + iPhone），这两个新文件在
// 打包之前**没有任何东西编译过它们**。这一步至少让 `swiftc` 真的过一遍它们 + 依赖的模型，
// 顺便把数字钉死在 MeloX 的口径上（`MeloX/Core/Lyrics/LyricInterludeTimeline.swift`）。
//
// 跑法（CI 里就是这条）：
//   swiftc Sources/EeveeSpotify/Lyrics/AppleMusic/LyricModels.swift \
//          Sources/EeveeSpotify/Lyrics/AppleMusic/LyricInterlude.swift \
//          Sources/EeveeSpotify/Lyrics/AppleMusic/LyricInterludeTimeline.swift \
//          Sources/EeveeSpotify/Lyrics/AppleMusic/LyricVocalDurationEstimator.swift \
//          Sources/EeveeSpotify/Lyrics/AppleMusic/AppleMusicInterludeMotionProfile.swift \
//          Sources/EeveeSpotify/Lyrics/AppleMusic/AppleMusicInterludeDotsPresentation.swift \
//          Tests/LyricInterludeTimeline/main.swift -o lyric-interlude-tests

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fatalError("FAIL: \(message)")
    }
}

private func requireClose(
    _ value: TimeInterval,
    _ expected: TimeInterval,
    _ message: String,
    tolerance: TimeInterval = 0.000_001
) {
    guard abs(value - expected) <= tolerance else {
        fatalError("FAIL: \(message) — got \(value), expected \(expected)")
    }
}

/// 造歌词行，`duration` 按 `LyricLinesAdapter.toAppleMusicLyricLines()` 的规则补：
/// 下一行起点 − 本行起点，末行用估算器。**必须**照那条规则造 ——
/// 它决定了 `.lineSynchronized` 行的 `contentEndTime` 上限，也就是"人声尾巴会不会
/// 把整段间隙吃掉"。手写一个固定的 duration 会让 fixture 与真机的形状对不上。
private func adapterLines(
    _ entries: [(time: TimeInterval, text: String)]
) -> [LyricLine] {
    entries.enumerated().map { index, entry in
        let duration: TimeInterval
        if index + 1 < entries.count {
            duration = max(entries[index + 1].time - entry.time, 0)
        } else {
            duration = LyricVocalDurationEstimator.estimatedDuration(for: entry.text)
        }
        return LyricLine(
            id: "line:\(index)",
            time: entry.time,
            duration: duration,
            timingKind: .lineSynchronized,
            text: entry.text
        )
    }
}

private func presentation(
    at playbackTime: TimeInterval,
    in interlude: LyricInterlude,
    reducesMotion: Bool = false
) -> AppleMusicInterludeDotsPresentation {
    AppleMusicInterludeDotsPresentation.make(
        playbackTime: playbackTime,
        interlude: interlude,
        reducesMotion: reducesMotion
    )
}

// MARK: - 1. 参数与阈值

requireClose(
    LyricInterludeTimeline.minimumAnimatedGapDuration,
    2.8,
    "minimumAnimatedGapDuration = fillLeadInDuration(1) + cueOutLeadTime(1.8)"
)
requireClose(
    AppleMusicInterludeMotionProfile.iOS26_6.visualExitDuration,
    1.5,
    "visualExitDuration = max(cuePeak+cueFade, cuePeak+cueTerminalScale)"
)

// MARK: - 2. 一段真实的 12 秒空档

// 8 行每 3 秒，然后 21s → 36s 空出 12 秒（真间奏），再跟 3 行。
let times: [TimeInterval] = [0, 3, 6, 9, 12, 15, 18, 21, 36, 39, 42]
let song = adapterLines(
    times.enumerated().map { (time: $0.element, text: "line number \($0.offset) here") }
)

let detected = LyricInterludeTimeline.interludes(
    in: song,
    detectionPolicy: .automatic(minimumInferredGapDuration: 4)
)
require(detected.count == 1, "the 12s hole is the only interlude, got \(detected.count)")

let interlude = detected[0]
require(interlude.precedingLyricID == "line:7", "the interlude follows line 7")
require(interlude.followingLyricID == "line:8", "the interlude precedes line 8")
require(interlude.displayBeforeLyricID == "line:8", "the resident row sits above line 8")
require(interlude.timingSource == .lineSynchronized, "LRC-only source")
require(!interlude.isPrelude, "this one is between two lines, not a prelude")
// line 7 从 21s 唱到 36s（duration 15），"line number 7 here" 15 字 → 估 4.8s
requireClose(interlude.startTime, 21 + 4.8, "the interlude starts where the vocal tail ends")
requireClose(interlude.countdownEndTime, 36, "the interlude ends where the next line starts")
requireClose(interlude.gapDuration, 10.2, "gap = next start − estimated vocal tail")

// 紧挨着的 3 秒行**一个候选都不该多出来**：它们的 duration 就是"到下一行"，
// 估出来的人声时长被它夹住之后间隙正好是 0。这条同时钉住"别把每一次换气都当间奏"。
require(
    LyricInterludeTimeline.candidates(in: song).count == 1,
    "only one candidate: the tight 3s lines have no gap to speak of"
)

// MARK: - 3. policy：作者时间轴那一档不许认推断出来的间隙

require(
    LyricInterludeTimeline.interludes(in: song, detectionPolicy: .preciseTiming).isEmpty,
    ".preciseTiming must ignore gaps inferred from line-synchronized lyrics"
)

// 3 秒间隙：清得过被夹过的下界（max(2, 2.8) = 2.8），清不过 3.5 的阈值。
let tight = adapterLines([(time: 0, text: "aa"), (time: 5, text: "bb")])
require(LyricInterludeTimeline.candidates(in: tight).count == 1, "the 5s spacing is one gap")
requireClose(
    LyricInterludeTimeline.candidates(in: tight)[0].gapDuration,
    3,
    "gap = 5 − estimated(2) for a two-character line"
)
require(
    !LyricInterludeTimeline.interludes(
        in: tight,
        detectionPolicy: .automatic(minimumInferredGapDuration: 2)
    ).isEmpty,
    "a 3s gap clears the clamped minimum (2.8s)"
)
require(
    LyricInterludeTimeline.interludes(
        in: tight,
        detectionPolicy: .automatic(minimumInferredGapDuration: 3.5)
    ).isEmpty,
    "a 3s gap must not clear a 3.5s threshold"
)

// MARK: - 4. 前奏

let late = adapterLines([(time: 5, text: "starts late"), (time: 20, text: "second")])
let lateCandidates = LyricInterludeTimeline.candidates(in: late)
require(lateCandidates.count == 2, "prelude + the 20s hole, got \(lateCandidates.count)")
require(lateCandidates[0].isPrelude, "the first candidate is the prelude")
require(lateCandidates[0].precedingLyricID == nil, "a prelude has nothing before it")
requireClose(lateCandidates[0].startTime, 0, "the prelude starts at 0")
requireClose(lateCandidates[0].countdownEndTime, 5, "the prelude ends at the first line")
require(
    LyricInterludeTimeline.interludes(
        in: late,
        detectionPolicy: .automatic(minimumInferredGapDuration: 4)
    ).count == 2,
    "both the prelude and the hole are long enough"
)

require(
    LyricInterludeTimeline.candidates(
        in: adapterLines([(time: 0, text: "a"), (time: 3, text: "b")])
    ).allSatisfy { !$0.isPrelude },
    "no prelude when the song starts singing at 0"
)

// MARK: - 5. 作者时间轴：音节结束时间比 duration 长时以它为准

let preciseFirst = LyricLine(
    id: "precise:0",
    time: 10,
    duration: 2,
    timingKind: .precise,
    text: "precise",
    syllables: [
        LyricSyllable(text: "pre", startTime: 10, endTime: 11),
        LyricSyllable(text: "cise", startTime: 11, endTime: 12.5),
    ]
)
let preciseSecond = LyricLine(
    id: "precise:1",
    time: 20,
    duration: 2,
    timingKind: .precise,
    text: "next"
)
let preciseCandidates = LyricInterludeTimeline.candidates(in: [preciseFirst, preciseSecond])
require(preciseCandidates.count == 2, "prelude + the authored gap")
require(preciseCandidates[0].timingSource == .precise, "authored timing stays authored")
requireClose(preciseCandidates[0].countdownEndTime, 10, "the prelude ends at the first lyric")
requireClose(
    preciseCandidates[1].startTime,
    12.5,
    "the last syllable ends later than duration(2), so it wins"
)
requireClose(preciseCandidates[1].gapDuration, 7.5, "20 − 12.5")
require(
    LyricInterludeTimeline.interludes(
        in: [preciseFirst, preciseSecond],
        detectionPolicy: .preciseTiming
    ).count == 2,
    "authored gaps count even under .preciseTiming"
)

// MARK: - 6. 这一拍该显示什么：三个阶段必须无缝衔接

let motion = AppleMusicInterludeMotionProfile.iOS26_6.timing(for: interlude)
requireClose(motion.cueOutTime, 36 - 1.8, "cue-out leads the next lyric by 1.8s")
requireClose(
    motion.visualEndTime,
    36 - 1.8 + 1.5,
    "the dots are visually gone 1.5s after cue-out"
)
requireClose(motion.fillStartTime, 25.8 + 1, "fill starts 1s after the interlude begins")

let before = LyricInterludeTimeline.position(at: interlude.startTime - 0.01, in: detected)
require(before.visibleInterludeID == nil, "nothing is visible before the gap starts")
requireClose(
    before.nextTransitionTime ?? -1,
    interlude.startTime,
    "the caller gets woken at the gap start"
)

let head = LyricInterludeTimeline.position(at: interlude.startTime, in: detected)
require(head.visibleInterludeID == interlude.id, "the row owns the slot")
require(head.focusedInterludeID == interlude.id, "and the focus, while the dots are up")
require(head.promotedLyricID == nil, "nothing is promoted yet")

let tail = LyricInterludeTimeline.position(at: motion.visualEndTime, in: detected)
require(tail.visibleInterludeID == interlude.id, "the resident row survives the cue-out")
require(tail.focusedInterludeID == nil, "the dots are empty, so focus leaves")
require(
    tail.promotedLyricID == interlude.followingLyricID,
    "the next line is promoted before it starts"
)
require(
    LyricInterludeTimeline.position(at: interlude.countdownEndTime, in: detected)
        .visibleInterludeID == nil,
    "the slot is released exactly when the next line starts"
)

// 视图靠 `visibleInterludeID` 决定要不要占那条 40pt 的驻留行 ——
// 中间断一拍就是"下面所有歌词往上跳一截"，所以整段必须连续成立。
var probe = interlude.startTime
while probe < interlude.countdownEndTime {
    require(
        LyricInterludeTimeline.position(at: probe, in: detected).visibleInterludeID
            == interlude.id,
        "the resident row was lost at \(probe)s"
    )
    probe += 0.05
}

// MARK: - 7. 三个点：范围、顺序、退出、减弱动态效果

let hidden = presentation(at: interlude.startTime - 0.5, in: interlude)
require(hidden.opacity == 0, "nothing shows outside the gap")
require(hidden.dotOpacities.allSatisfy { $0 == 0 }, "no stray dot outside the gap")

var peakScale: CGFloat = 0
var firstFull: TimeInterval?
var secondFull: TimeInterval?
var thirdFull: TimeInterval?
probe = interlude.startTime - 0.5
while probe < interlude.countdownEndTime + 0.5 {
    let shown = presentation(at: probe, in: interlude)
    require(
        shown.dotOpacities.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 },
        "dot opacity out of range at \(probe)s: \(shown.dotOpacities)"
    )
    require(
        shown.scale.isFinite && shown.scale >= 0.19 && shown.scale <= 1.21,
        "scale out of range at \(probe)s: \(shown.scale)"
    )
    require(
        shown.opacity.isFinite && shown.opacity >= 0 && shown.opacity <= 1,
        "opacity out of range at \(probe)s: \(shown.opacity)"
    )
    if probe < motion.startTime || probe >= motion.visualEndTime {
        require(
            shown.opacity == 0 && shown.dotOpacities.allSatisfy { $0 == 0 },
            "outside the visual window nothing may show at \(probe)s"
        )
    }
    peakScale = max(peakScale, shown.scale)
    if firstFull == nil, shown.dotOpacities[0] > 0.99 { firstFull = probe }
    if secondFull == nil, shown.dotOpacities[1] > 0.99 { secondFull = probe }
    if thirdFull == nil, shown.dotOpacities[2] > 0.99 { thirdFull = probe }
    probe += 0.005
}

require(peakScale >= 1.19, "the cue peak must reach cuePeakScale(1.2), got \(peakScale)")
require(firstFull != nil && secondFull != nil && thirdFull != nil, "every dot lights up")
require(
    firstFull! < secondFull! && secondFull! < thirdFull!,
    "the dots must light up in order: \(firstFull!), \(secondFull!), \(thirdFull!)"
)
require(
    firstFull! > interlude.startTime + 0.5,
    "the fill waits out fillLeadInDuration(1s); lit at \(firstFull!)"
)

for reduceProbe in [
    interlude.startTime,
    interlude.startTime + 1.5,
    motion.cueOutTime,
    motion.cueOutTime + 0.5,
] {
    require(
        presentation(at: reduceProbe, in: interlude, reducesMotion: true).scale == 1,
        "reduce-motion must not scale (at \(reduceProbe)s)"
    )
}

// MARK: - 8. 退化的输入不许崩、也不许凭空造间奏

require(
    LyricInterludeTimeline.interludes(
        in: [],
        detectionPolicy: .automatic(minimumInferredGapDuration: 4)
    ).isEmpty,
    "no lyrics, no interludes"
)
require(
    LyricInterludeTimeline.candidates(in: adapterLines([(time: 0, text: "only")])).isEmpty,
    "a single line at 0 has no gap to fill"
)
require(
    LyricInterludeTimeline.position(at: .nan, in: detected).visibleInterludeID == nil,
    "a NaN playback time must not resolve to an interlude"
)
require(
    presentation(at: .infinity, in: interlude).opacity == 0,
    "an infinite playback time must not show the dots"
)

print("OK — interlude timeline + dots presentation: all invariants hold")
print(
    "  detected gap \(interlude.startTime)s → \(interlude.countdownEndTime)s "
        + "(gap \(interlude.gapDuration)s)"
)
print(
    "  visual window \(motion.startTime)s → \(motion.visualEndTime)s "
        + "(cue-out \(motion.cueOutTime)s)"
)
