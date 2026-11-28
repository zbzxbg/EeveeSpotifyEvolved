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

// ── 底排三颗在横屏左栏里（位置相对左栏，再整体挪过去）
for size in sizes {
    let columnX: CGFloat = 28
    let columnWidth: CGFloat = 302
    let frames = LayoutGeometry.footerFrames(
        containerWidth: columnWidth,
        originX: columnX,
        midY: glyphMidY,
        box: glyphBox
    )
    require(frames.count == 3, "\(size.name): lateral footer needs three frames")
    for frame in frames {
        require(frame.minX >= columnX - tolerance, "\(size.name): lateral glyph before the column")
        require(frame.maxX <= columnX + columnWidth + tolerance, "\(size.name): lateral glyph past the column")
    }
    // 不给 originX 时行为与旧实现逐字一致。
    let legacy = LayoutGeometry.footerFrames(containerWidth: columnWidth, midY: glyphMidY, box: glyphBox)
    require(near(legacy[0].minX, (LayoutGeometry.footerCentres(containerWidth: columnWidth)[0] - glyphBox / 2).rounded()),
            "\(size.name): default origin changed the legacy frame")
}

// ── 横屏两栏：封面 / 控件在左栏，歌词在右栏，谁都不出页面
private struct LandscapeSize {
    let name: String
    let width: CGFloat
    let height: CGFloat
}

private let landscapeSizes: [LandscapeSize] = [
    LandscapeSize(name: "iPhone 8", width: 667, height: 375),
    LandscapeSize(name: "iPhone mini", width: 812, height: 375),
    LandscapeSize(name: "iPhone regular", width: 852, height: 393),
    LandscapeSize(name: "iPhone Pro Max", width: 932, height: 430),
    LandscapeSize(name: "iPhone XR", width: 896, height: 414),
]

for size in landscapeSizes {
    let leftInset: CGFloat = 28
    let topInset: CGFloat = 16
    let bottomInset: CGFloat = 18
    let rightInset: CGFloat = 28
    // 414×896 的页面转成横屏后 `npv.bottomStackView` 的高度：歌名 56 + 进度 41
    // + 传输 64 + 工具行 44，再加三处间距 = 245。
    let stackHeight: CGFloat = 245
    let layout = LayoutGeometry.landscapeColumns(
        size: CGSize(width: size.width, height: size.height),
        leftInset: leftInset,
        topInset: topInset,
        bottomInset: bottomInset,
        rightInset: rightInset,
        stackHeight: stackHeight,
        lyricsMaxWidth: 440
    )

    require(layout.column.minX >= leftInset - tolerance, "\(size.name): column before the left inset")
    require(layout.column.maxX <= size.width - rightInset + tolerance, "\(size.name): column past the right inset")
    require(layout.column.width >= LayoutGeometry.landscapeColumnMinWidth - tolerance,
            "\(size.name): column narrower than the minimum")
    require(layout.column.height > 0, "\(size.name): column has no height")

    require(layout.cover.minX >= layout.column.minX - tolerance, "\(size.name): cover before the column")
    require(layout.cover.maxX <= layout.column.maxX + tolerance, "\(size.name): cover wider than the column")
    require(layout.cover.maxY <= layout.column.maxY + tolerance, "\(size.name): cover taller than the column")
    require(near(layout.cover.width, layout.cover.height), "\(size.name): cover is not a square")

    require(layout.lyrics.minX >= layout.column.maxX + LayoutGeometry.landscapeColumnGap - tolerance,
            "\(size.name): lyrics overlap the column")
    require(layout.lyrics.maxX <= size.width - rightInset + tolerance, "\(size.name): lyrics past the right inset")
    require(layout.lyrics.width > layout.cover.width, "\(size.name): lyrics column narrower than the cover")
    require(layout.lyrics.width <= 440 + tolerance, "\(size.name): lyrics column wider than the cap")
    require(layout.lyrics.height > 0, "\(size.name): lyrics has no height")

    // 封面 + 空隙 + 那一坨（歌名 / 进度 / 传输 / 工具行）必须整块放得下 ——
    // 放不下的话 `placeLandscapeStack` 会把整坨顶回去，歌名就压在封面上。
    let stackTop = layout.cover.maxY + LayoutGeometry.landscapeCoverStackGap
    require(stackTop + stackHeight <= topInset + layout.column.height + tolerance,
            "\(size.name): the control stack does not fit under the cover")
    // 封面也不能被压成一颗邮票。
    require(layout.cover.width >= LayoutGeometry.landscapeMinCoverSide - tolerance,
            "\(size.name): cover smaller than the minimum")
    require(layout.cover.height <= (layout.column.height) * 0.5 + tolerance,
            "\(size.name): cover eats the control rows")
}

print("OK: \(sizes.count) screen sizes, footer / mini bar / tab bar geometry")
print("OK: \(landscapeSizes.count) landscape sizes, two-column geometry")

// ── 封面圆角：跟边长走，夹在 10…16，取到 0.5pt
require(near(LayoutGeometry.artworkCornerRadius(side: 0), 0), "a zero side has no corner")
require(near(LayoutGeometry.artworkCornerRadius(side: 64), 10), "a thumbnail-sized side hits the floor")
require(near(LayoutGeometry.artworkCornerRadius(side: 127), 10), "127pt hits the 10pt floor")
require(near(LayoutGeometry.artworkCornerRadius(side: 179), 10.5), "179pt is 6% of its side")
require(near(LayoutGeometry.artworkCornerRadius(side: 262), 15.5), "262pt is 6% of its side")
require(near(LayoutGeometry.artworkCornerRadius(side: 400), 16), "a huge side hits the 16pt cap")
var previousRadius: CGFloat = 0
for side in [32, 40, 64, 100, 127, 150, 179, 200, 262, 300, 400] {
    let radius = LayoutGeometry.artworkCornerRadius(side: CGFloat(side))
    require(radius >= previousRadius, "corner radius is not monotonic at \(side)pt")
    require(near(radius * 2, (radius * 2).rounded()), "corner radius is not a multiple of 0.5 at \(side)pt")
    previousRadius = radius
}
print("OK: cover corner radius follows the side")

