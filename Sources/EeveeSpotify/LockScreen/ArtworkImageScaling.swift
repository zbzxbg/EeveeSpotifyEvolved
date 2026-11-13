import CoreGraphics
import UIKit

/// 把一张图按"填满目标矩形再裁掉多余"缩放，用来给系统交预览图。
///
/// 系统按**像素**验收：1:1 的键收方图、3:4 的键收竖图，比例差得多就退回静态封面。
/// 所以这里不保留留白，宁可裁掉两边。源图通常只有 640px，放大到请求尺寸不会更清楚，
/// 但系统要的就是这个尺寸，照做即可。
enum ArtworkImageScaling {

    /// 预览图再大也看不出来；这条上限只是防系统某个尺寸（平板 / 外接屏）把内存拉满。
    private static let maximumSide: CGFloat = 1600

    static func fill(_ image: UIImage, to size: CGSize) -> UIImage {
        let target = capped(size)
        guard target.width >= 1, target.height >= 1,
              image.size.width >= 1, image.size.height >= 1 else {
            return image
        }
        guard abs(image.size.width - target.width) >= 0.5
            || abs(image.size.height - target.height) >= 0.5 else {
            return image
        }

        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.image { _ in
            let scale = max(target.width / image.size.width, target.height / image.size.height)
            let drawn = CGSize(
                width: image.size.width * scale,
                height: image.size.height * scale
            )
            image.draw(
                in: CGRect(
                    x: (target.width - drawn.width) / 2,
                    y: (target.height - drawn.height) / 2,
                    width: drawn.width,
                    height: drawn.height
                )
            )
        }
    }

    private static func capped(_ size: CGSize) -> CGSize {
        guard size.width >= 1, size.height >= 1 else { return size }
        let longest = max(size.width, size.height)
        guard longest > maximumSide else {
            return CGSize(width: round(size.width), height: round(size.height))
        }
        let scale = maximumSide / longest
        return CGSize(width: round(size.width * scale), height: round(size.height * scale))
    }
}
