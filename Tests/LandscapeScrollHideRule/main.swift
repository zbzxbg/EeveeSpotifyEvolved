import CoreGraphics
import Foundation

// 横屏歌词页"划动时收控件"的判据（纯 Foundation + CoreGraphics，不需要设备）。
//
// 跑法（需要 Swift 工具链；本仓库本机没有，所以由 CI 跑）：
//   swiftc Sources/EeveeSpotify/Appearance/LandscapeScrollHideRule.swift \
//          Tests/LandscapeScrollHideRule/main.swift \
//          -o /tmp/landscape-scroll-hide-tests && /tmp/landscape-scroll-hide-tests
//
// 两档歌词的判据不一样：
//   · 逐词 / 逐行（有时间轴）：歌词每帧自己在滚 ⇒ 只能看手势。划出阈值就收，
//     **不能**看 `contentOffset`（它一直在变，点一下也会"变了"）；
//   · 纯文本（没有时间轴）：内容可能短到放得下 ⇒ 还要"手势期间内容真的挪过"，
//     否则按一下也收，就变成"没划动也消失"。

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAIL: \(message)") }
}

private let drag = LandscapeScrollHideRule.dragThreshold
private let scroll = LandscapeScrollHideRule.contentScrollThreshold

// MARK: - 逐词 / 逐行：看手势，不看偏移

require(
    LandscapeScrollHideRule.shouldHide(isStatic: false, dragDistance: drag, contentOffsetDelta: 0),
    "timed lyrics must hide once the finger really drags"
)
require(
    LandscapeScrollHideRule.shouldHide(isStatic: false, dragDistance: -drag, contentOffsetDelta: 0),
    "an upward drag counts the same as a downward one"
)
require(
    !LandscapeScrollHideRule.shouldHide(isStatic: false, dragDistance: drag - 0.1, contentOffsetDelta: 0),
    "a tap-sized move must not hide the column"
)
require(
    !LandscapeScrollHideRule.shouldHide(isStatic: false, dragDistance: 0, contentOffsetDelta: 400),
    "the offset alone must never hide the column (timed lyrics scroll by themselves)"
)

// MARK: - 纯文本：必须"内容真的滚了"

require(
    !LandscapeScrollHideRule.shouldHide(isStatic: true, dragDistance: 30, contentOffsetDelta: 0),
    "plain lyrics must not hide when nothing scrolled (the text fits)"
)
require(
    !LandscapeScrollHideRule.shouldHide(isStatic: true, dragDistance: -30, contentOffsetDelta: 0),
    "plain lyrics still fit when dragging the other way"
)
require(
    LandscapeScrollHideRule.shouldHide(isStatic: true, dragDistance: 12, contentOffsetDelta: scroll),
    "plain lyrics hide once the text really moved"
)
require(
    LandscapeScrollHideRule.shouldHide(isStatic: true, dragDistance: 12, contentOffsetDelta: -scroll),
    "an upward scroll of the text counts the same"
)
require(
    !LandscapeScrollHideRule.shouldHide(isStatic: true, dragDistance: 12, contentOffsetDelta: scroll - 0.5),
    "less than the content threshold is not a scroll"
)
require(
    !LandscapeScrollHideRule.shouldHide(isStatic: true, dragDistance: drag - 0.1, contentOffsetDelta: 80),
    "a moving text under a finger that did not drag is not a hide trigger"
)

// MARK: - 阈值本身不能退化

require(drag >= 4, "the drag threshold must be big enough to ignore taps (\(drag)pt)")
require(scroll > 0 && scroll < drag, "the content threshold must be a small real movement")
require(
    LandscapeScrollHideRule.shouldHide(isStatic: false, dragDistance: drag * 100, contentOffsetDelta: 0),
    "a long drag always hides"
)

print("landscape scroll hide rule: all assertions passed")
