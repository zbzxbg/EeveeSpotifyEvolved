import CoreGraphics
import CoreImage
import Foundation
import UIKit

/// 歌词分享卡片的绘制层：一张 9:16 竖图。
///
/// 为什么不复用锁屏那份 `LyricClipRenderer`：那边的版式是系统预览键倒逼出来的
/// （3:4 / 1:1、当前行 + 压暗的下一行 + 底沿署名），而分享卡要的是
/// 罗马字 / 当前行 / 译文三行结构 + 曲名歌手。两套版式放在同一个函数里，
/// 任何一边调间距都会牵到另一边，所以文字排版各写一份。
///
/// 背景的模糊做法沿用锁屏那条已经验证过的结论：**先缩到 160px 宽再高斯模糊**。
/// 整幅原图在手机上做高斯模糊要十几秒，而模糊本身已经把细节抹掉，先缩后糊看不出差别。
enum LyricShareCardRenderer {

    struct Content {
        let title: String
        let artist: String
        let lyric: String
        var romanization: String?
        var translation: String?
        let credit: String
        var cover: UIImage?
    }

    /// 9:16 —— 相册与主流社交 App 的预览都按这个比例完整显示，和锁屏那套竖图观感一致。
    static let cardSize = CGSize(width: 1080, height: 1920)

    static func image(for content: Content) -> UIImage {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: cardSize, format: format).image { context in
            drawBackdrop(cover: content.cover, in: context.cgContext)
            drawScrim(in: context.cgContext)
            drawLyricBlock(content, in: context.cgContext)
            drawFooter(content, in: context.cgContext)
        }
    }

    // MARK: - 背景

    private static func drawBackdrop(cover: UIImage?, in context: CGContext) {
        let full = CGRect(origin: .zero, size: cardSize)
        if let cover, let blurred = blurred(cover) {
            drawFilling(blurred, in: full, context: context)
        } else {
            // 取不到封面时给一块中性暗底：白字仍然读得出来，也不会像加载失败。
            context.setFillColor(CGColor(red: 0.10, green: 0.10, blue: 0.11, alpha: 1))
            context.fill(full)
        }
    }

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private static func blurred(_ cover: UIImage) -> CGImage? {
        guard let source = cover.cgImage, source.width > 0 else { return nil }
        let smallWidth: CGFloat = 160
        let scale = smallWidth / CGFloat(source.width)
        let input = CIImage(cgImage: source).transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)
        )
        let blurred = input
            .clampedToExtent()
            .applyingGaussianBlur(sigma: smallWidth * 0.05)
            .cropped(to: input.extent)
        return ciContext.createCGImage(blurred, from: input.extent)
    }

    private static func drawFilling(_ image: CGImage, in rect: CGRect, context: CGContext) {
        let imageWidth = CGFloat(image.width)
        let imageHeight = CGFloat(image.height)
        guard imageWidth > 0, imageHeight > 0 else { return }
        let scale = max(rect.width / imageWidth, rect.height / imageHeight)
        let drawn = CGSize(width: imageWidth * scale, height: imageHeight * scale)
        let destination = CGRect(
            x: rect.midX - drawn.width / 2,
            y: rect.midY - drawn.height / 2,
            width: drawn.width,
            height: drawn.height
        )
        context.interpolationQuality = .high
        context.draw(image, in: destination)
    }

    /// 上下渐变压暗。白字要压在任意亮度的封面上都读得出来，
    /// 而分享图常常被缩到聊天窗口那样的小尺寸，底不够暗时字会糊成一片。
    private static func drawScrim(in context: CGContext) {
        let colors = [
            UIColor(white: 0, alpha: 0.28).cgColor,
            UIColor(white: 0, alpha: 0.46).cgColor,
            UIColor(white: 0, alpha: 0.72).cgColor
        ] as CFArray
        let locations: [CGFloat] = [0, 0.55, 1]
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors,
            locations: locations
        ) else { return }
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: cardSize.width / 2, y: 0),
            end: CGPoint(x: cardSize.width / 2, y: cardSize.height),
            options: []
        )
    }

    // MARK: - 歌词区

    private static let margin: CGFloat = 96
    private static let romanizationSize: CGFloat = 36
    private static let translationSize: CGFloat = 44
    private static let blockGap: CGFloat = 40
    private static let lineSpacingRatio: CGFloat = 0.24

    private static func drawLyricBlock(_ content: Content, in context: CGContext) {
        let column = columnWidth
        let romanization = (content.romanization ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let translation = (content.translation ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        let blockTop = cardSize.height * 0.28
        let blockBottom = cardSize.height - 430

        let romanizationHeight = height(
            of: romanization,
            fontSize: romanizationSize,
            weight: .regular,
            column: column
        )
        let translationHeight = height(
            of: translation,
            fontSize: translationSize,
            weight: .regular,
            column: column
        )
        let fixed = romanizationHeight + translationHeight
            + (romanization.isEmpty ? 0 : blockGap)
            + (translation.isEmpty ? 0 : blockGap)

        // 主歌词：从 84pt 起按 6% 一档缩，缩到 46pt 为止。
        // 再放不下就让它溢出 —— 截断歌词比溢出更糟，用户无法知道少了什么。
        var lyricSize: CGFloat = 84
        var lyricHeight = height(
            of: content.lyric,
            fontSize: lyricSize,
            weight: .semibold,
            column: column
        )
        let available = max(blockBottom - blockTop - fixed, 200)
        while lyricHeight > available, lyricSize > 46 {
            lyricSize *= 0.94
            lyricHeight = height(
                of: content.lyric,
                fontSize: lyricSize,
                weight: .semibold,
                column: column
            )
        }

        let total = fixed + lyricHeight
        var y = blockTop + max((blockBottom - blockTop - total) / 2, 0)

        if !romanization.isEmpty {
            draw(
                romanization,
                fontSize: romanizationSize,
                weight: .regular,
                alpha: 0.72,
                in: CGRect(x: margin, y: y, width: column, height: romanizationHeight),
                context: context
            )
            y += romanizationHeight + blockGap
        }
        draw(
            content.lyric,
            fontSize: lyricSize,
            weight: .semibold,
            alpha: 1,
            in: CGRect(x: margin, y: y, width: column, height: lyricHeight),
            context: context
        )
        y += lyricHeight
        if !translation.isEmpty {
            y += blockGap
            draw(
                translation,
                fontSize: translationSize,
                weight: .regular,
                alpha: 0.82,
                in: CGRect(x: margin, y: y, width: column, height: translationHeight),
                context: context
            )
        }
    }

    // MARK: - 页脚（曲名 / 歌手 / 署名）

    private static func drawFooter(_ content: Content, in context: CGContext) {
        let column = columnWidth
        let entries: [(text: String, size: CGFloat, weight: UIFont.Weight, alpha: CGFloat)] = [
            (content.title, 46, .semibold, 1),
            (content.artist, 38, .regular, 0.82),
            (content.credit, 28, .regular, 0.55)
        ]
        let visible = entries.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !visible.isEmpty else { return }

        let heights = visible.map {
            height(of: $0.text, fontSize: $0.size, weight: $0.weight, column: column)
        }
        let gap: CGFloat = 12
        let total = heights.reduce(0, +) + gap * CGFloat(max(visible.count - 1, 0))
        var y = cardSize.height - 120 - total

        for (index, entry) in visible.enumerated() {
            draw(
                entry.text,
                fontSize: entry.size,
                weight: entry.weight,
                alpha: entry.alpha,
                in: CGRect(x: margin, y: y, width: column, height: heights[index]),
                context: context
            )
            y += heights[index] + gap
        }
    }

    // MARK: - 文字工具

    private static var columnWidth: CGFloat {
        cardSize.width - margin * 2
    }

    private static func height(
        of text: String,
        fontSize: CGFloat,
        weight: UIFont.Weight,
        column: CGFloat
    ) -> CGFloat {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        let bounds = attributed(
            trimmed,
            fontSize: fontSize,
            weight: weight,
            alpha: 1
        ).boundingRect(
            with: CGSize(width: column, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        return ceil(bounds.height)
    }

    private static func draw(
        _ text: String,
        fontSize: CGFloat,
        weight: UIFont.Weight,
        alpha: CGFloat,
        in rect: CGRect,
        context: CGContext
    ) {
        guard rect.height > 0 else { return }
        // `NSAttributedString.draw` 画到"当前"上下文上，而这里拿到的是显式传入的那一个；
        // 压进去再弹出来，调用点就不依赖自己正处在渲染块里。
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        attributed(
            text,
            fontSize: fontSize,
            weight: weight,
            alpha: alpha
        ).draw(
            with: rect,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
    }

    private static func attributed(
        _ text: String,
        fontSize: CGFloat,
        weight: UIFont.Weight,
        alpha: CGFloat
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = fontSize * lineSpacingRatio
        paragraph.lineBreakMode = .byWordWrapping

        // 白字压在模糊封面上容易和底糊在一起，加一点阴影把字拉出来。
        let shadow = NSShadow()
        shadow.shadowColor = UIColor(white: 0, alpha: 0.45)
        shadow.shadowOffset = CGSize(width: 0, height: 2)
        shadow.shadowBlurRadius = 12

        return NSAttributedString(
            string: text,
            attributes: [
                .font: UIFont.systemFont(ofSize: fontSize, weight: weight),
                .foregroundColor: UIColor(white: 1, alpha: alpha),
                .paragraphStyle: paragraph,
                .shadow: shadow
            ]
        )
    }
}
