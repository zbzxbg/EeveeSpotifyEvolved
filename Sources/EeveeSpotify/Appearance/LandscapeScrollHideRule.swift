// 横屏歌词页：手指划歌词时，左列（歌名 / 艺人 / 控件带）什么时候收起来。
//
// 判据只用手势，不看 `contentOffset` 的绝对值 —— 逐词 / 逐行那两档每帧都在自动滚，
// 按偏移判会永远收着。但**纯文本**那一档不自动滚，手指按上去也会开一条 pan：
// 只有"内容真的滚动了"才算划动，否则（比如整段词放得下、根本没得滚）按一下也收，
// 就变成"没划动也消失"。
//
// 收 / 放的动作在 `NowPlayingIOS27+LandscapePage.swift`；这里只是那条判据，
// 纯逻辑，能进 `Tests/LandscapeScrollHideRule` 那条 CI 链。
import CoreGraphics
import Foundation

enum LandscapeScrollHideRule {

    /// 手指纵向划出这么多（pt）才算"真的在划"，不看手势开始那一刻。
    static let dragThreshold: CGFloat = 8

    /// 纯文本歌词：内容至少挪了这么多（pt）才收。
    static let contentScrollThreshold: CGFloat = 2

    /// - Parameters:
    ///   - isStatic: 这一档歌词没有时间轴（纯文本，如 Genius / 无时间戳的词）。
    ///   - dragDistance: 手指的累计纵向位移（pt，正负都算）。
    ///   - contentOffsetDelta: 手势开始到现在，歌词容器实际滚动的纵向距离（pt）。
    static func shouldHide(
        isStatic: Bool,
        dragDistance: CGFloat,
        contentOffsetDelta: CGFloat
    ) -> Bool {
        guard abs(dragDistance) >= dragThreshold else { return false }
        guard isStatic else { return true }
        return abs(contentOffsetDelta) >= contentScrollThreshold
    }
}
