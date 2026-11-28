import CoreGraphics
import Foundation

/// 纯几何：**输入容器尺寸，输出 frame** —— 不读屏幕、不碰 UIKit。
///
/// 为什么单独拎出来：
/// · 真机只有一两台，靠"在我手机上看着对"验不出 320pt 的 SE、430pt 的 Pro Max、
///   iPad 分屏这些尺寸；
/// · 这些函数没有副作用，`Tests/LayoutGeometry` 可以把它们直接编进 macOS 测试，
///   在 CI 里跑一组尺寸，不用 iOS SDK、也不用真机。
///
/// 414 在这里只是**参考宽度**（底排三颗字形是按 414pt 宽的页面量的），不是坐标：
/// 位置一律由它按比例换算，再夹到合理区间。
enum LayoutGeometry {

    /// 底排三颗字形的参考宽度。
    static let referenceWidth: CGFloat = 414

    /// 参考宽度上三颗字形的中心 x（歌词 / 隔空播放 / 队列）。
    static let footerReferenceCentres: [CGFloat] = [86, 207, 328]

    /// 比例的下限 / 上限。
    ///
    /// 下限 0.8：SE（320pt）上原比例 0.77 会把三颗挤到一起；
    /// 上限 1.25：iPad 全屏 / 分屏时页面远比 414 宽，而 iPhone 那条底排本来不出现在那里，
    /// 夹住只是保证"万一画了也不会被推出屏幕"。
    static let minScale: CGFloat = 0.8
    static let maxScale: CGFloat = 1.25

    /// 参考宽度 → 本页的实际比例。
    static func scale(forWidth width: CGFloat) -> CGFloat {
        guard width > 0 else { return 1 }
        return min(max(width / referenceWidth, minScale), maxScale)
    }

    /// 底排三颗的中心 x（未取整；取整交给 `footerFrames`）。
    static func footerCentres(containerWidth: CGFloat) -> [CGFloat] {
        let value = scale(forWidth: containerWidth)
        return footerReferenceCentres.map { $0 * value }
    }

    /// 底排三颗字形的 frame：以 `midY` 为中线、`box` 见方。
    static func footerFrames(
        containerWidth: CGFloat,
        originX: CGFloat = 0,
        midY: CGFloat,
        box: CGFloat
    ) -> [CGRect] {
        footerCentres(containerWidth: containerWidth).map { centre in
            CGRect(
                x: (originX + centre - box / 2).rounded(),
                y: (midY - box / 2).rounded(),
                width: box,
                height: box
            )
        }
    }

    /// 迷你条玻璃板的宽度：不超过宿主，也不小于 160。
    ///
    /// `usableRatio` 是"标签栏胶囊宽 ÷ 栏宽"；拿不到时调用方传兜底比例。
    static func miniPlateWidth(hostWidth: CGFloat, usableRatio: CGFloat) -> CGFloat {
        min(hostWidth, max(160, hostWidth * usableRatio))
    }

    /// 玻璃标签栏要比 Spotify 自己那一行多让出来的高度。
    ///
    /// 只有紧凑宽度（iPhone）才需要让：Spotify 的常规宽度栏是固定 76pt、不吃 inset。
    static func tabBarRoom(
        containerHeight: CGFloat,
        stockRowHeight: CGFloat,
        bottomInset: CGFloat,
        compact: Bool
    ) -> CGFloat {
        guard compact else { return 0 }
        return max(0, (containerHeight - stockRowHeight - bottomInset).rounded(.up))
    }

    // MARK: - 横屏两栏（听歌页）
    //
    // 横屏听歌页按两栏排：左栏 = 封面 + 歌名/艺人 + 进度 + 传输，右栏 = 整页歌词。
    // 这里只算框；把 Spotify 自己那几行收进左栏是 `NowPlayingIOS27` 的事。
    //
    // 所有尺寸都由页面尺寸推出来（不是 414×896 的写死坐标）：iPhone 各代的横屏
    // 是 667…932 宽、375…430 高，iPad 分屏也会走到同一段。

    /// 左栏占可用宽度的比例（pw 的横屏播放页 ≈ 0.40）。
    ///
    /// 0.34 是让左栏窄一点、右栏宽一点；同时保证那一坨（歌名 / 进度 / 传输）横着放得下 ——
    /// 它自己那一行是原生视图，宽度不够就会被挤扁。
    static let landscapeColumnRatio: CGFloat = 0.34
    static let landscapeColumnMinWidth: CGFloat = 260
    static let landscapeColumnMaxWidth: CGFloat = 380
    /// 封面边长：不超过栏宽，也不超过「可用高 − 那一坨 − 空隙」（再封一个上限）。
    ///
    /// 有 `stackHeight` 时**由高度预算决定**。以前还按栏宽的 0.62 另外封一刀，
    /// 那一刀在 414 高的页面上把封面压到一百出头，而同一栏的进度条有 260 多 —— 两者差出一倍。
    static let landscapeCoverHeightRatio: CGFloat = 0.45
    static let landscapeCoverMaxSide: CGFloat = 200
    /// 两栏之间的空隙。
    static let landscapeColumnGap: CGFloat = 24
    /// 封面与它下面那一坨之间的空隙（`placeLandscapeStack` 用的也是这个值）。
    static let landscapeCoverStackGap: CGFloat = 14
    /// 封面的最小边长。再小就只剩一颗邮票，不如让那一坨挤一挤。
    static let landscapeMinCoverSide: CGFloat = 72

    /// 横屏两栏的三个框（页面坐标）。
    struct LandscapeColumns: Equatable {
        /// 左栏：封面、标题、进度、传输都落在这一列里。
        var column: CGRect
        /// 封面方块：与左栏的上沿、左线对齐。
        var cover: CGRect
        /// 右栏：歌词铺满。
        var lyrics: CGRect
    }

    /// 两栏几何。
    ///
    /// `stackHeight` = 左栏里**封面下面那一坨**（歌名 / 进度 / 传输）的高度。
    /// 封面吃的是「可用高 − 那一坨 − 空隙」，所以把工具行从那一坨里撤出去，封面就长一截。
    ///
    /// 量不到 `stackHeight` 时（第一拍）退回按可用高的比例估一个，别把封面卡成一颗邮票。
    ///
    /// `lyricsMaxWidth` > 0 时给右栏封一个宽度上限：横屏页面很宽（896…932），
    /// 歌词一行铺到 480pt 会顶到右上角那颗 ⋯（它就在导航条最右边，点不到也是因为它
    /// 落在歌词容器的命中范围里）。
    static func landscapeColumns(
        size: CGSize,
        leftInset: CGFloat,
        topInset: CGFloat,
        bottomInset: CGFloat,
        rightInset: CGFloat,
        stackHeight: CGFloat = 0,
        lyricsMaxWidth: CGFloat = 0
    ) -> LandscapeColumns {
        let width = max(0, size.width)
        let height = max(0, size.height)
        let usableWidth = max(0, width - leftInset - rightInset)
        let usableHeight = max(0, height - topInset - bottomInset)

        let columnWidth = min(
            max(usableWidth * landscapeColumnRatio, landscapeColumnMinWidth),
            min(landscapeColumnMaxWidth, usableWidth)
        )
        let column = CGRect(
            x: leftInset,
            y: topInset,
            width: columnWidth,
            height: usableHeight
        )

        var coverSide = stackHeight > 0
            ? min(columnWidth, usableHeight - stackHeight - landscapeCoverStackGap)
            : min(columnWidth, usableHeight * landscapeCoverHeightRatio)
        coverSide = max(landscapeMinCoverSide, min(coverSide, landscapeCoverMaxSide))
        let cover = CGRect(x: leftInset, y: topInset, width: coverSide, height: coverSide)

        let lyricsX = leftInset + columnWidth + landscapeColumnGap
        var lyricsWidth = max(0, width - rightInset - lyricsX)
        if lyricsMaxWidth > 0 { lyricsWidth = min(lyricsWidth, lyricsMaxWidth) }
        let lyrics = CGRect(
            x: lyricsX,
            y: topInset,
            width: lyricsWidth,
            height: usableHeight
        )
        return LandscapeColumns(column: column, cover: cover, lyrics: lyrics)
    }

    // MARK: - 封面圆角
    //
    // 按**边长**取，不写死：竖屏歌词那张 64pt 缩略图有自己的 8pt（12.5% 的比例，
    // 那一档看着正圆），而横屏左栏的封面是一百多 pt 的方块 —— 同一个 8pt 只占 6%，
    // 看上去像根本没切过角。

    /// 封面圆角：边长的 6%，夹在 10…16，取到 0.5pt 的整数倍。
    ///
    /// 6% 这个比例是照横屏播放页上那种"看得出是圆角、但不像卡片"的量感定的
    /// （≈180pt 的封面配 ≈11pt 的角）。取整到 0.5pt 是让 2x / 3x 屏的边缘都落在整像素上。
    static func artworkCornerRadius(side: CGFloat) -> CGFloat {
        guard side > 1 else { return 0 }
        let wanted = min(16, max(10, side * 0.06))
        return (wanted * 2).rounded() / 2
    }
}
