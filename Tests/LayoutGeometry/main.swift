import CoreGraphics
import Foundation

// 「几何随屏幕尺寸自适应」的回归测试（Foundation + CoreGraphics，不需要 iOS SDK）。
//
// 跑法（需要 Swift 工具链）：
//   swiftc Tests/LayoutGeometry/main.swift \
//          Sources/EeveeSpotify/Appearance/LayoutGeometry.swift \
//          -o /tmp/layout-geometry-tests && /tmp/layout-geometry-tests
//
// 钉的是「换任何屏幕宽度都不越界、不错位」：
//   · 比例落在 clamp 区间里；
//   · 底排三颗中心严格递增，整颗字形都留在页面宽度内；
//   · frame 是正方形、以 midY 居中；
//   · 迷你条玻璃宽度不超过宿主、不小于 160；
//   · 标签栏只在紧凑宽度让高度，取整方式与旧实现一致（向上取整）。

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAIL: \(message)") }
}

private struct ScreenSize {
    let name: String
    let width: CGFloat
    let height: CGFloat
}

private let sizes: [ScreenSize] = [
    ScreenSize(name: "SE", width: 320, height: 568),
    ScreenSize(name: "mini", width: 375, height: 812),
    ScreenSize(name: "regular", width: 393, height: 852),
    ScreenSize(name: "Plus", width: 428, height: 926),
    ScreenSize(name: "Pro Max", width: 430, height: 932),
    ScreenSize(name: "iPad split", width: 507, height: 700),
    ScreenSize(name: "iPad full", width: 744, height: 1024),
]

private let glyphBox: CGFloat = 26
private let glyphMidY: CGFloat = 800
private let tolerance: CGFloat = 0.001

private func near(_ value: CGFloat, _ expected: CGFloat) -> Bool {
    abs(value - expected) <= tolerance
}

// ── 底排三颗
for size in sizes {
    let scale = LayoutGeometry.scale(forWidth: size.width)
    require(scale >= LayoutGeometry.minScale, "\(size.name): scale below clamp")
    require(scale <= LayoutGeometry.maxScale, "\(size.name): scale above clamp")

    let raw = size.width / LayoutGeometry.referenceWidth
    let expected = min(max(raw, LayoutGeometry.minScale), LayoutGeometry.maxScale)
    require(near(scale, expected), "\(size.name): scale \(scale) != \(expected)")

    let centres = LayoutGeometry.footerCentres(containerWidth: size.width)
    require(centres.count == 3, "\(size.name): expected three centres")
    require(centres[0] < centres[1] && centres[1] < centres[2], "\(size.name): centres not ascending")

    for centre in centres {
        require(centre - glyphBox / 2 >= 0, "\(size.name): glyph runs off the left edge")
        require(centre + glyphBox / 2 <= size.width + tolerance, "\(size.name): glyph runs off the right edge")
    }

    let frames = LayoutGeometry.footerFrames(
        containerWidth: size.width,
        midY: glyphMidY,
        box: glyphBox
    )
    require(frames.count == 3, "\(size.name): expected three frames")

    for frame in frames {
        require(near(frame.width, glyphBox) && near(frame.height, glyphBox), "\(size.name): frame not square")
        require(frame.minX >= 0, "\(size.name): frame starts before the page")
        require(frame.maxX <= size.width + tolerance, "\(size.name): frame ends past the page")
        require(near(frame.midY, glyphMidY.rounded()), "\(size.name): frame not centred on midY")
    }
}

// 同一页面宽度下，六组尺寸的间距都应该随宽度变化（不是写死坐标）。
let narrow = LayoutGeometry.footerCentres(containerWidth: 320)
let wide = LayoutGeometry.footerCentres(containerWidth: 430)
require(wide[0] > narrow[0] && wide[2] > narrow[2], "centres do not follow the page width")

// ── 迷你条玻璃宽度
require(near(LayoutGeometry.miniPlateWidth(hostWidth: 414, usableRatio: 1), 414), "mini plate not capped by host")
require(near(LayoutGeometry.miniPlateWidth(hostWidth: 414, usableRatio: 0), 160), "mini plate below minimum")
require(near(LayoutGeometry.miniPlateWidth(hostWidth: 320, usableRatio: 0.5), 160), "small host plate below minimum")
require(near(LayoutGeometry.miniPlateWidth(hostWidth: 414, usableRatio: 0.87), 360.18), "mini plate ratio mismatch")

// ── 标签栏让出的高度
require(near(LayoutGeometry.tabBarRoom(containerHeight: 83, stockRowHeight: 49, bottomInset: 34, compact: true), 0), "room on Face ID bar")
require(near(LayoutGeometry.tabBarRoom(containerHeight: 96.4, stockRowHeight: 49, bottomInset: 34, compact: true), 14), "room should round up")
require(near(LayoutGeometry.tabBarRoom(containerHeight: 96, stockRowHeight: 49, bottomInset: 34, compact: false), 0), "regular width should not make room")
require(near(LayoutGeometry.tabBarRoom(containerHeight: 20, stockRowHeight: 49, bottomInset: 34, compact: true), 0), "room should not go negative")

print("OK: \(sizes.count) screen sizes, footer / mini bar / tab bar geometry")
