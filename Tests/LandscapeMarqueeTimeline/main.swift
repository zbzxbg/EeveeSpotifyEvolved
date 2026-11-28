import CoreGraphics
import Foundation

// 横屏页歌名 / 艺人"分段停"滚动时间表的回归测试（纯 Foundation + CoreGraphics，不需要设备）。
//
// 跑法（需要 Swift 工具链；本仓库本机没有，所以由 CI 跑）：
//   swiftc Sources/EeveeSpotify/Appearance/LandscapeMarqueeTimeline.swift \
//          Tests/LandscapeMarqueeTimeline/main.swift \
//          -o /tmp/landscape-marquee-tests && /tmp/landscape-marquee-tests
//
// 钉的是形状，不是观感：
//   · 放得下 ⇒ 不给时间表（静止）；
//   · 贴左端先停 → 每段左移后停 → 尾端贴右端（完整溢出量）再停 → 一帧回 0；
//   · keyTimes 严格递增、首 0 尾 1，与 values 一样长；
//   · 每段位移不超过配置上限，最后一段只走剩下的；
//   · 视口越宽，同样的溢出需要的段数越少。

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAIL: \(message)") }
}

private func near(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 0.01) -> Bool {
    abs(a - b) <= tolerance
}

private func nearTime(_ a: TimeInterval, _ b: TimeInterval, _ tolerance: TimeInterval = 0.02) -> Bool {
    abs(a - b) <= tolerance
}

private let style = LandscapeMarqueeTimeline.Style.standard

/// 时间表里"停了几段"：开头那一对 + 每段一对 + 最后跳回 0 的那一个。
private func stopCount(_ timeline: LandscapeMarqueeTimeline) -> Int {
    (timeline.values.count - 3) / 2
}

private func time(_ timeline: LandscapeMarqueeTimeline, at index: Int) -> TimeInterval {
    timeline.keyTimes[index] * timeline.duration
}

// MARK: - 放得下就静止

require(
    LandscapeMarqueeTimeline.timeline(overflow: 0, viewportWidth: 197) == nil,
    "no overflow must not produce a timeline"
)
require(
    LandscapeMarqueeTimeline.timeline(overflow: -40, viewportWidth: 197) == nil,
    "negative overflow must not produce a timeline"
)
require(
    LandscapeMarqueeTimeline.timeline(overflow: 120, viewportWidth: 0) == nil,
    "a zero-width viewport must not produce a timeline"
)

// MARK: - 短名字：一段就够

let short = LandscapeMarqueeTimeline.timeline(overflow: 83, viewportWidth: 197)
require(short != nil, "a title wider than the viewport must scroll")
if let timeline = short {
    require(stopCount(timeline) == 1, "83pt of overflow fits in a single step")
    require(timeline.values.count == 5, "one step is start-pair + step-pair + snap")
    require(near(timeline.values[0], 0), "the cycle starts at the left edge")
    require(near(timeline.values[1], 0), "the start hold stays at the left edge")
    require(near(timeline.values[2], -83), "the step lands on the full overflow")
    require(near(timeline.values[3], -83), "the end hold keeps the tail at the right edge")
    require(near(timeline.values[4], 0), "the snap returns to the start")

    // 开头停 `startHold`，走一段 `overflow / speed`，尾端停 `endHold`，最后一帧跳回。
    require(nearTime(time(timeline, at: 1), style.startHold), "the start hold is the configured one")
    require(
        nearTime(time(timeline, at: 2) - time(timeline, at: 1), 83 / style.speed),
        "the first step takes distance / speed"
    )
    require(
        nearTime(time(timeline, at: 3) - time(timeline, at: 2), style.endHold),
        "the last stop is the end hold"
    )
    require(
        time(timeline, at: 4) - time(timeline, at: 3) <= style.snap + 0.001,
        "the return to the start is a single frame"
    )
    require(
        nearTime(
            timeline.duration,
            style.startHold + 83 / style.speed + style.endHold + style.snap
        ),
        "the cycle length is the sum of its legs"
    )
}

// MARK: - 长名字：分几段，每段都停

let long = LandscapeMarqueeTimeline.timeline(overflow: 403, viewportWidth: 197)
require(long != nil, "a long title must scroll")
if let timeline = long {
    // 197 * 0.55 = 108.35 ⇒ ceil(403 / 108.35) = 4 段，每段 100.75。
    require(stopCount(timeline) == 4, "403pt of overflow needs four steps")
    require(timeline.values.count == 11, "four steps are start-pair + four step-pairs + snap")
    let stepDistance = CGFloat(403) / 4
    for step in 1...4 {
        let travelIndex = 2 * step
        require(
            near(timeline.values[travelIndex], -stepDistance * CGFloat(step)),
            "step \(step) lands on its stop"
        )
        require(
            near(timeline.values[travelIndex + 1], timeline.values[travelIndex]),
            "step \(step) holds its stop"
        )
    }
    require(
        near(timeline.values[timeline.values.count - 2], -403),
        "the last stop puts the tail flush with the right edge"
    )
    require(near(timeline.values[timeline.values.count - 1], 0), "the cycle ends back at the start")

    // 中间停 `stopHold`，只有最后一段停 `endHold`。
    for step in 1...3 {
        let holdIndex = 2 * step + 1
        require(
            nearTime(time(timeline, at: holdIndex) - time(timeline, at: holdIndex - 1), style.stopHold),
            "stop \(step) is the intermediate hold"
        )
    }
    require(
        nearTime(
            time(timeline, at: 9) - time(timeline, at: 8),
            style.endHold
        ),
        "the last stop is the end hold"
    )
    require(
        time(timeline, at: 10) - time(timeline, at: 9) <= style.snap + 0.001,
        "the return to the start is a single frame"
    )
}

// MARK: - 不变量：任何一组输入都对

let inputs: [(overflow: CGFloat, viewport: CGFloat)] = [
    (12, 197), (83, 197), (403, 197), (900, 197), (1600, 340), (4000, 340),
]
for input in inputs {
    guard let timeline = LandscapeMarqueeTimeline.timeline(
        overflow: input.overflow,
        viewportWidth: input.viewport
    ) else {
        fatalError("FAIL: \(input.overflow)/\(input.viewport) should scroll")
    }
    require(
        timeline.values.count == timeline.keyTimes.count,
        "\(input): values and keyTimes must pair up"
    )
    require(
        timeline.keyTimes[0] == 0,
        "\(input): keyTimes must start at 0"
    )
    require(
        timeline.keyTimes[timeline.keyTimes.count - 1] == 1,
        "\(input): keyTimes must end at 1"
    )
    var previous = -Double.infinity
    for keyTime in timeline.keyTimes {
        require(keyTime > previous, "\(input): keyTimes must strictly increase (\(keyTime))")
        require(keyTime >= 0 && keyTime <= 1, "\(input): keyTime out of range (\(keyTime))")
        previous = keyTime
    }
    for value in timeline.values {
        require(
            value <= 0.001 && value >= -input.overflow - 0.001,
            "\(input): translation \(value) left the [−overflow, 0] band"
        )
    }
    require(
        near(timeline.values.min() ?? 0, -input.overflow),
        "\(input): one stop must show the whole tail"
    )
    require(timeline.duration > 0, "\(input): a cycle must take time")

    // 除了最后那一帧，位移只能往左走（不会来回抖）。
    for index in 1..<(timeline.values.count - 1) {
        require(
            timeline.values[index] <= timeline.values[index - 1] + 0.001,
            "\(input): the track moved backwards at keyframe \(index)"
        )
    }

    // 每段位移不超过一次左移的上限。
    let travel = min(max(input.viewport * style.travelRatio, style.minTravel), style.maxTravel)
    let steps = stopCount(timeline)
    require(
        input.overflow / CGFloat(steps) <= travel + 0.001,
        "\(input): a step moved farther than the configured travel"
    )
}

// MARK: - 视口越宽，段数越少（同样的溢出）

if let narrow = LandscapeMarqueeTimeline.timeline(overflow: 400, viewportWidth: 100),
   let wide = LandscapeMarqueeTimeline.timeline(overflow: 400, viewportWidth: 400) {
    require(
        stopCount(narrow) > stopCount(wide),
        "a wide viewport must need fewer stops (narrow \(stopCount(narrow)), wide \(stopCount(wide)))"
    )
    require(
        near(narrow.values[narrow.values.count - 2], -400),
        "the narrow cycle still ends flush with the right edge"
    )
}

// MARK: - 旋钮真的接进时间表

var custom = LandscapeMarqueeTimeline.Style.standard
custom.startHold = 0.4
custom.stopHold = 0.25
custom.endHold = 0.3
custom.snap = 0.02
custom.travelRatio = 0.9
custom.minTravel = 200
custom.maxTravel = 300
if let timeline = LandscapeMarqueeTimeline.timeline(
    overflow: 450,
    viewportWidth: 340,
    style: custom
) {
    require(timeline.values.count == 7, "a custom 300pt travel needs two steps for 450pt")
    require(nearTime(time(timeline, at: 1), 0.4), "the custom start hold is honoured")
    require(nearTime(time(timeline, at: 3) - time(timeline, at: 2), 0.25), "the custom stop hold is honoured")
    require(nearTime(time(timeline, at: 5) - time(timeline, at: 4), 0.3), "the custom end hold is honoured")
}

// 速度为 0 / 负数被夹住，不能算出无限长的一轮。
var zeroSpeed = LandscapeMarqueeTimeline.Style.standard
zeroSpeed.speed = 0
require(
    LandscapeMarqueeTimeline.timeline(overflow: 100, viewportWidth: 197, style: zeroSpeed) != nil,
    "a zero speed must be clamped, not crash"
)

print("landscape marquee timeline: all assertions passed")
