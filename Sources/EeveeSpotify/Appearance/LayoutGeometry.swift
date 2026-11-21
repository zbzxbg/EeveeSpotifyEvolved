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
    static func footerFrames(containerWidth: CGFloat, midY: CGFloat, box: CGFloat) -> [CGRect] {
        footerCentres(containerWidth: containerWidth).map { centre in
            CGRect(
                x: (centre - box / 2).rounded(),
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
}
