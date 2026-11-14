import CoreGraphics
import Foundation
import UIKit

/// 歌词分享卡片的绘制层：一张 9:16 竖图。
///
/// 版式照 Spotify 自己那张「歌词分享卡」来：**封面取色铺满整张**、顶部一行小封面 + 曲名/歌手、
/// 中间大字歌词、底沿一行小字署名。这样分享出去和用户在这个 App 里见过的卡片是同一个观感，
/// 而我们的版本能存相册、能选词、带罗马音和译文。
///
/// 为什么不复用锁屏那份 `LyricClipRenderer`：那边的版式是系统预览键倒逼出来的
/// （3:4 / 1:1、当前行 + 压暗的下一行 + 底沿署名），而分享卡是 9:16 + 顶部信息行，
/// 两套版式塞进同一个函数里，任何一边调间距都会牵到另一边。
enum LyricShareCardRenderer {

    struct Content {
        let title: String
        let artist: String
        let lyric: String
        var romanization: String?
        var translation: String?
        let credit: String
        var cover: UIImage?
        /// Spotify 随 track metadata 下发的封面取色（`extracted_color`，6 位 RGB 或 8 位 ARGB）。
        /// 没有时退回封面平均色。
        var backgroundColorHex: String?
    }

    /// 9:16 —— 相册与主流社交 App 的预览都按这个比例完整显示。
    static let cardSize = CGSize(width: 1080, height: 1920)

    static func image(for content: Content) -> UIImage {
        let background = resolvedBackground(content)
        let ink = inkColor(on: background)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: cardSize, format: format).image { context in
            drawBackground(background, in: context.cgContext)
            drawHeader(content, ink: ink, in: context.cgContext)
            drawLyricBlock(content, ink: ink, in: context.cgContext)
            drawFooter(content, ink: ink, in: context.cgContext)
        }
    }

    // MARK: - 底色

    /// 取色顺序：metadata 里的 `extracted_color`（与播放页取色底同一个值）→ 封面平均色 →
    /// 中性暗底。中间那两条都拿不到时也不能留白，白字压白底直接看不见。
    private static func resolvedBackground(_ content: Content) -> UIColor {
        if let color = color(fromHex: content.backgroundColorHex) {
            return balanced(color)
        }
        if let cover = content.cover, let average = averageColor(of: cover) {
            return balanced(average)
        }
        return UIColor(white: 0.10, alpha: 1)
    }

    /// 把"太亮 / 太中间调"的封面色调到能压字的那一档：
    ///
    /// · 很亮（白封面）→ 压到 0.9 的亮度，用黑字；
    /// · 很暗 → 保持，用白字；
    /// · 中间调（灰、饱和中等）→ 压到 0.40 并保留色相，改用白字 ——
    ///   中间调上黑字和白字都糊，这是唯一稳的一档。
    private static func balanced(_ color: UIColor) -> UIColor {
        let luminance = relativeLuminance(of: color)
        if luminance >= 0.72 {
            return brightnessCapped(color, at: 0.9)
        }
        if luminance < 0.30 {
            return color
        }
        return brightnessCapped(color, at: 0.40)
    }

    /// 压亮度、保留色相：白封面回来的近白色要压成"深一点的同色"，字才读得清。
    private static func brightnessCapped(_ color: UIColor, at ceiling: CGFloat) -> UIColor {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else {
            return color
        }
        guard brightness > ceiling else { return color }
        return UIColor(hue: hue, saturation: saturation, brightness: ceiling, alpha: alpha)
    }

    private static func inkColor(on background: UIColor) -> UIColor {
        relativeLuminance(of: background) >= 0.55
            ? UIColor(white: 0.06, alpha: 1)
            : UIColor(white: 1, alpha: 1)
    }

    private static func relativeLuminance(of color: UIColor) -> CGFloat {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return 0
        }
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    /// 解析 `#RRGGBB` / `RRGGBB` / `AARRGGBB`。仓库里那份同名工具是文件私有的，这里不跨文件借。
    private static func color(fromHex raw: String?) -> UIColor? {
        guard var hex = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !hex.isEmpty else {
            return nil
        }
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6 || hex.count == 8, let value = UInt64(hex, radix: 16) else {
            return nil
        }
        let red, green, blue: CGFloat
        if hex.count == 8 {
            red = CGFloat((value >> 16) & 0xFF) / 255
            green = CGFloat((value >> 8) & 0xFF) / 255
            blue = CGFloat(value & 0xFF) / 255
        } else {
            red = CGFloat((value >> 16) & 0xFF) / 255
            green = CGFloat((value >> 8) & 0xFF) / 255
            blue = CGFloat(value & 0xFF) / 255
        }
        return UIColor(red: red, green: green, blue: blue, alpha: 1)
    }

    private static func averageColor(of image: UIImage) -> UIColor? {
        guard let source = image.cgImage else { return nil }
        var pixel: [UInt8] = [0, 0, 0, 0]
        let space = CGColorSpaceCreateDeviceRGB()
        let drawn = pixel.withUnsafeMutableBufferPointer { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .medium
            context.draw(source, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn else { return nil }
        return UIColor(
            red: CGFloat(pixel[0]) / 255,
            green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255,
            alpha: 1
        )
    }

    private static func drawBackground(_ color: UIColor, in context: CGContext) {
        let full = CGRect(origin: .zero, size: cardSize)
        context.setFillColor(color.cgColor)
        context.fill(full)

        // 上下各一层极轻的明暗：纯平色在聊天列表里看着像一块贴纸，压一点更接近原生那张卡。
        let colors = [
            UIColor(white: 1, alpha: 0.05).cgColor,
            UIColor(white: 1, alpha: 0).cgColor,
            UIColor(white: 0, alpha: 0.10).cgColor
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

    // MARK: - 版式常量

    private static let margin: CGFloat = 88
    private static let coverSide: CGFloat = 112
    private static let coverTop: CGFloat = 128
    private static let headerGap: CGFloat = 28
    private static let titleSize: CGFloat = 46
    private static let artistSize: CGFloat = 36
    private static let romanizationSize: CGFloat = 36
    private static let translationSize: CGFloat = 42
    private static let creditSize: CGFloat = 26
    private static let blockGap: CGFloat = 26
    private static let lineSpacingRatio: CGFloat = 0.18

    private static var columnWidth: CGFloat {
        cardSize.width - margin * 2
    }

    // MARK: - 顶部（小封面 + 曲名 / 歌手）

    private static func drawHeader(_ content: Content, ink: UIColor, in context: CGContext) {
        var textX = margin
        if let cover = content.cover {
            let rect = CGRect(x: margin, y: coverTop, width: coverSide, height: coverSide)
            UIGraphicsPushContext(context)
            UIBezierPath(roundedRect: rect, cornerRadius: 12).addClip()
            let scale = max(rect.width / cover.size.width, rect.height / cover.size.height)
            let drawn = CGSize(
                width: cover.size.width * scale,
                height: cover.size.height * scale
            )
            cover.draw(
                in: CGRect(
                    x: rect.midX - drawn.width / 2,
                    y: rect.midY - drawn.height / 2,
                    width: drawn.width,
                    height: drawn.height
                )
            )
            UIGraphicsPopContext()
            textX = rect.maxX + headerGap
        }

        let textWidth = cardSize.width - margin - textX
        let titleHeight = height(of: content.title, fontSize: titleSize, weight: .semibold, width: textWidth)
        let artistHeight = height(of: content.artist, fontSize: artistSize, weight: .regular, width: textWidth)
        let total = titleHeight + 6 + artistHeight
        let top = coverTop + max((coverSide - total) / 2, 0)

        if !content.title.isEmpty {
            draw(
                content.title,
                fontSize: titleSize,
                weight: .semibold,
                color: ink,
                alignment: .left,
                in: CGRect(x: textX, y: top, width: textWidth, height: titleHeight),
                context: context
            )
        }
        if !content.artist.isEmpty {
            draw(
                content.artist,
                fontSize: artistSize,
                weight: .regular,
                color: ink.withAlphaComponent(0.66),
                alignment: .left,
                in: CGRect(
                    x: textX,
                    y: top + titleHeight + 6,
                    width: textWidth,
                    height: artistHeight
                ),
                context: context
            )
        }
    }

    // MARK: - 歌词

    private static func drawLyricBlock(_ content: Content, ink: UIColor, in context: CGContext) {
        let romanization = (content.romanization ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let translation = (content.translation ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        let blockTop = coverTop + coverSide + 84
        let blockBottom = cardSize.height - 190

        let romanizationHeight = height(
            of: romanization,
            fontSize: romanizationSize,
            weight: .regular,
            width: columnWidth
        )
        let translationHeight = height(
            of: translation,
            fontSize: translationSize,
            weight: .regular,
            width: columnWidth
        )
        let fixed = romanizationHeight + translationHeight
            + (romanization.isEmpty ? 0 : blockGap)
            + (translation.isEmpty ? 0 : blockGap)

        // 主歌词：从 96pt 起按 6% 一档缩，缩到 56pt 为止。
        // 再放不下就让它溢出 —— 截断歌词比溢出更糟，用户无法知道少了什么。
        var lyricSize: CGFloat = 96
        var lyricHeight = height(
            of: content.lyric,
            fontSize: lyricSize,
            weight: .semibold,
            width: columnWidth
        )
        let available = max(blockBottom - blockTop - fixed, 240)
        while lyricHeight > available, lyricSize > 56 {
            lyricSize *= 0.94
            lyricHeight = height(
                of: content.lyric,
                fontSize: lyricSize,
                weight: .semibold,
                width: columnWidth
            )
        }

        let total = fixed + lyricHeight
        var y = blockTop + max((blockBottom - blockTop - total) * 0.42, 0)

        if !romanization.isEmpty {
            draw(
                romanization,
                fontSize: romanizationSize,
                weight: .regular,
                color: ink.withAlphaComponent(0.62),
                alignment: .left,
                in: CGRect(x: margin, y: y, width: columnWidth, height: romanizationHeight),
                context: context
            )
            y += romanizationHeight + blockGap
        }
        draw(
            content.lyric,
            fontSize: lyricSize,
            weight: .semibold,
            color: ink,
            alignment: .left,
            in: CGRect(x: margin, y: y, width: columnWidth, height: lyricHeight),
            context: context
        )
        y += lyricHeight
        if !translation.isEmpty {
            y += blockGap
            draw(
                translation,
                fontSize: translationSize,
                weight: .regular,
                color: ink.withAlphaComponent(0.74),
                alignment: .left,
                in: CGRect(x: margin, y: y, width: columnWidth, height: translationHeight),
                context: context
            )
        }
    }

    // MARK: - 底沿署名

    private static func drawFooter(_ content: Content, ink: UIColor, in context: CGContext) {
        let credit = content.credit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !credit.isEmpty else { return }
        let creditHeight = height(
            of: credit,
            fontSize: creditSize,
            weight: .regular,
            width: columnWidth
        )
        draw(
            credit,
            fontSize: creditSize,
            weight: .regular,
            color: ink.withAlphaComponent(0.48),
            alignment: .left,
            in: CGRect(
                x: margin,
                y: cardSize.height - 120 - creditHeight,
                width: columnWidth,
                height: creditHeight
            ),
            context: context
        )
    }

    // MARK: - 文字工具（左对齐，与原生那张卡一致）

    private static func height(
        of text: String,
        fontSize: CGFloat,
        weight: UIFont.Weight,
        width: CGFloat
    ) -> CGFloat {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        let bounds = attributed(trimmed, fontSize: fontSize, weight: weight, color: .black)
            .boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            )
        return ceil(bounds.height)
    }

    private static func draw(
        _ text: String,
        fontSize: CGFloat,
        weight: UIFont.Weight,
        color: UIColor,
        alignment: NSTextAlignment,
        in rect: CGRect,
        context: CGContext
    ) {
        guard rect.height > 0 else { return }
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        attributed(
            text,
            fontSize: fontSize,
            weight: weight,
            color: color,
            alignment: alignment
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
        color: UIColor,
        alignment: NSTextAlignment = .left
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineSpacing = fontSize * lineSpacingRatio
        paragraph.lineBreakMode = .byWordWrapping

        return NSAttributedString(
            string: text,
            attributes: [
                .font: UIFont.systemFont(ofSize: fontSize, weight: weight),
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]
        )
    }
}
