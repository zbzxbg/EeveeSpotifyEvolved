// 横屏页那两行（歌名 / 艺人）的滚动时间表。
//
// 不是"一直向左滚"的跑马灯，而是**分段读**：
//   贴左端停一下 → 左移一段停一下 → … → 尾端贴右端停一下 → 一帧跳回开头 → 再走。
// 两端的字都完整露过，中间每段都停得下来 —— 名字再长也不用盯着它一直跑。
//
// 这里**只算数**（值 / keyTimes / 总时长），不碰 CoreAnimation：纯逻辑，所以能进
// `Tests/LandscapeMarqueeTimeline` 那条 CI 链。视图层（`LandscapePageMarqueeView`）
// 只把它翻成 `CAKeyframeAnimation`。
import CoreGraphics
import Foundation

struct LandscapeMarqueeTimeline {

    /// 时间表的形状旋钮。默认值就是横屏页用的那一套。
    struct Style {
        /// 一次左移走过多少视口宽（再夹到 [minTravel, maxTravel]）。
        var travelRatio: CGFloat = 0.55
        var minTravel: CGFloat = 56
        var maxTravel: CGFloat = 160
        /// 左移速度（pt / 秒）。
        var speed: CGFloat = 70
        /// 开头（贴左端）停多久。
        var startHold: TimeInterval = 1.5
        /// 中间每段停多久。
        var stopHold: TimeInterval = 0.9
        /// 尾端（贴右端）停多久。
        var endHold: TimeInterval = 1.7
        /// 跳回开头那一帧的时长。一帧 ⇒ 读起来是"跳回去"，不是"倒着滚回去"。
        var snap: TimeInterval = 1.0 / 60

        static let standard = Style()
    }

    /// `transform.translation.x` 的关键帧（0 与负值，单位 pt）。
    let values: [CGFloat]
    /// 与 `values` 一一对应：严格递增、首 0 尾 1。
    let keyTimes: [Double]
    /// 一轮（从贴左端到跳回开头）的时长。
    let duration: TimeInterval

    /// 溢出不够（放得下）时返回 nil —— 调用方保持静止。
    ///
    /// `overflow` = 文字宽 − 视口宽（> 0 才需要滚）；负值按"放得下"处理。
    static func timeline(
        overflow: CGFloat,
        viewportWidth: CGFloat,
        style: Style = .standard
    ) -> LandscapeMarqueeTimeline? {
        guard overflow > 0.5, viewportWidth > 1 else { return nil }

        let travel = min(max(viewportWidth * style.travelRatio, style.minTravel), style.maxTravel)
        // 向上取整：最后一段只走剩下的那一点，所以每段都不超过 `travel`。
        let steps = max(1, Int((overflow / travel).rounded(.up)))
        let stepDistance = overflow / CGFloat(steps)
        let speed = max(style.speed, 1)

        // 每一段都必须有时长，否则 keyTimes 会出现相同值（CoreAnimation 要求严格递增）。
        let startHold = max(style.startHold, 0.01)
        let stopHold = max(style.stopHold, 0.01)
        let endHold = max(style.endHold, 0.01)
        let snap = max(style.snap, 1.0 / 240)

        var values: [CGFloat] = [0]
        var times: [TimeInterval] = [0]
        var t: TimeInterval = 0

        // 贴左端停一下。
        t += startHold
        values.append(0)
        times.append(t)

        for step in 1...steps {
            t += max(TimeInterval(stepDistance / speed), 0.01)
            let x = -CGFloat(step) * stepDistance
            values.append(x)
            times.append(t)
            t += step == steps ? endHold : stopHold
            values.append(x)
            times.append(t)
        }

        // 回到开头：一帧，读起来就是"跳回去"。
        t += snap
        values.append(0)
        times.append(t)

        let duration = times[times.count - 1]
        guard duration > 0 else { return nil }
        let keyTimes = times.map { Double($0 / duration) }
        return LandscapeMarqueeTimeline(values: values, keyTimes: keyTimes, duration: duration)
    }
}
