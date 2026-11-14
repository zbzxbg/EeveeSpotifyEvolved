import CoreGraphics
import CoreImage
import Foundation
import UIKit

/// 歌词分享卡片的绘制层：一张 9:16 竖图。
///
/// 三套模板（见 `LyricShareCardTemplate`）共用同一份"背景 + 文字"工具：
/// · `native`   —— 照 Spotify 那张卡的结构：取色底 + 顶部小封面/曲名 + 大字歌词；
/// · `polaroid` —— 白框拍立得：照片窗口放封面，下方留白写歌词与曲名/歌手；
/// · `minimal`  —— 纯色/纯黑底，只留歌词与一行署名。
///
/// 拍立得比例用经典值 3.5 : 4.25（约 1:1.21）：照片窗口是正方形，左右上边长边约 6.2%，
/// 底部留白约占 19% —— 比真实相纸的 16% 略多一点，因为我们要在留白里塞下一句歌词。
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
        var template: LyricShareCardTemplate = .native
        var background: LyricShareCardBackground = .cover
        var ink: LyricShareCardInk = .auto
    }

    /// 9:16 —— 相册与主流社交 App 的预览都按这个比例完整显示。
    static let cardSize = CGSize(width: 1080, height: 1920)

    static func image(for content: Content) -> UIImage {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: cardSize, format: format).image { context in
            let cg = context.cgContext
            let ink = drawBackdrop(content, in: cg)
            switch content.template {
            case .native:
                drawNative(content, ink: ink, in: cg)
            case .polaroid:
                drawPolaroid(content, ink: ink, in: cg)
            case .minimal:
                drawMinimal(content, ink: ink, in: cg)
            }
        }
    }

    // MARK: - 背景

    /// 画底、并返回文字该用的颜色。
    private static func drawBackdrop(_ content: Content, in context: CGContext) -> UIColor {
        let full = CGRect(origin: .zero, size: cardSize)
        switch content.background {
        case .cover:
            let color = resolvedCoverColor(content)
            context.setFillColor(color.cgColor)
            context.fill(full)
            drawSheen(in: context, full: full)
            return inkColor(content.ink, on: color)
        case .blurredCover:
            context.setFillColor(UIColor(white: 0.06, alpha: 1).cgColor)
            context.fill(full)
            if let cover = content.cover, let blurred = blurredCover(cover) {
                UIGraphicsPushContext(context)
                let scale = max(
                    full.width / blurred.size.width,
                    full.height / blurred.size.height
                )
                let drawn = CGSize(
                    width: blurred.size.width * scale,
                    height: blurred.size.height * scale
                )
                blurred.draw(
                    in: CGRect(
                        x: full.midX - drawn.width / 2,
                        y: full.midY - drawn.height / 2,
                        width: drawn.width,
                        height: drawn.height
                    )
                )
                UIGraphicsPopContext()
            }
            context.setFillColor(UIColor(white: 0, alpha: 0.45).cgColor)
            context.fill(full)
            return content.ink == .black
                ? UIColor(white: 0.06, alpha: 1)
                : UIColor(white: 1, alpha: 1)
        case .black:
            context.setFillColor(UIColor(white: 0.03, alpha: 1).cgColor)
            context.fill(full)
            return content.ink == .black
                ? UIColor(white: 0.06, alpha: 1)
                : UIColor(white: 1, alpha: 1)
        }
    }

    /// 取色顺序：metadata 里的 `extracted_color` → 封面平均色 → 中性暗底。
    private static func resolvedCoverColor(_ content: Content) -> UIColor {
        if let color = color(fromHex: content.backgroundColorHex) {
            return balanced(color)
        }
        if let cover = content.cover, let average = averageColor(of: cover) {
            return balanced(average)
        }
        return UIColor(white: 0.10, alpha: 1)
    }

    /// 把"太亮 / 太中间调"的封面色调到能压字的那一档。
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

    private static func inkColor(_ choice: LyricShareCardInk, on background: UIColor) -> UIColor {
        switch choice {
        case .black:
            return UIColor(white: 0.06, alpha: 1)
        case .white:
            return UIColor(white: 1, alpha: 1)
        case .auto:
            return relativeLuminance(of: background) >= 0.55
                ? UIColor(white: 0.06, alpha: 1)
                : UIColor(white: 1, alpha: 1)
        }
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

    /// 上下各一层极轻的明暗：纯平色在聊天列表里看着像一块贴纸，压一点更接近原生那张卡。
    private static func drawSheen(in context: CGContext, full: CGRect) {
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
            start: CGPoint(x: full.midX, y: full.minY),
            end: CGPoint(x: full.midX, y: full.maxY),
            options: []
        )
    }

    /// 模糊封面：先缩到 160px 宽再高斯模糊，整幅原图在手机上糊会拖慢整机。
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private static func blurredCover(_ cover: UIImage) -> UIImage? {
        guard let source = cover.cgImage, source.width > 0 else { return nil }
        let smallWidth: CGFloat = 160
        let scale = smallWidth / CGFloat(source.width)
        let input = CIImage(cgImage: source).transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)
        )
        let blurred = input
            .clampedToExtent()
            .applyingGaussianBlur(sigma: smallWidth * 0.06)
            .cropped(to: input.extent)
        guard let cgImage = ciContext.createCGImage(blurred, from: input.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
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

    // MARK: - 模板：原生卡

    private static func drawNative(_ content: Content, ink: UIColor, in context: CGContext) {
        drawHeader(content, ink: ink, in: context)
        drawLyricBlock(content, ink: ink, in: context)
        drawCredit(content.credit, ink: ink, y: cardSize.height - 120, in: context)
    }

    private static func drawHeader(_ content: Content, ink: UIColor, in context: CGContext) {
        var textX = margin
        if let cover = content.cover {
            let rect = CGRect(x: margin, y: coverTop, width: coverSide, height: coverSide)
            drawCover(cover, in: rect, cornerRadius: 12, context: context)
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

        // 主歌词：从 96pt 起按 6% 一档缩，缩到 52pt 为止。
        // 再放不下就让它溢出 —— 截断歌词比溢出更糟，用户无法知道少了什么。
        var lyricSize: CGFloat = 96
        var lyricHeight = height(
            of: content.lyric,
            fontSize: lyricSize,
            weight: .semibold,
            width: columnWidth
        )
        let available = max(blockBottom - blockTop - fixed, 240)
        while lyricHeight > available, lyricSize > 52 {
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

    // MARK: - 模板：拍立得

    private static func drawPolaroid(_ content: Content, ink: UIColor, in context: CGContext) {
        // 经典比例 3.5 : 4.25；照片窗口是正方形，所以先定宽再倒推高。
        let cardWidth = cardSize.width * 0.80
        let inset = cardWidth * 0.062
        let photoSide = cardWidth - inset * 2
        let cardHeight = (photoSide + inset) / 0.81
        let cardRect = CGRect(
            x: (cardSize.width - cardWidth) / 2,
            y: (cardSize.height - cardHeight) / 2 - 30,
            width: cardWidth,
            height: cardHeight
        )

        // 略微歪一点、带投影，才有"一张相纸放桌上"的感觉。
        context.saveGState()
        context.translateBy(x: cardRect.midX, y: cardRect.midY)
        context.rotate(by: -2 * .pi / 180)
        context.translateBy(x: -cardRect.midX, y: -cardRect.midY)

        context.setShadow(
            offset: CGSize(width: 0, height: 22),
            blur: 54,
            color: UIColor(white: 0, alpha: 0.34).cgColor
        )
        let cardPath = UIBezierPath(roundedRect: cardRect, cornerRadius: 10)
        context.addPath(cardPath.cgPath)
        context.setFillColor(UIColor(red: 0.984, green: 0.976, blue: 0.957, alpha: 1).cgColor)
        context.fillPath()
        context.setShadow(offset: .zero, blur: 0, color: nil)

        let photoRect = CGRect(
            x: cardRect.minX + inset,
            y: cardRect.minY + inset,
            width: photoSide,
            height: photoSide
        )
        if let cover = content.cover {
            drawCover(cover, in: photoRect, cornerRadius: 2, context: context)
        } else {
            let colors = [
                UIColor(white: 0.28, alpha: 1).cgColor,
                UIColor(white: 0.16, alpha: 1).cgColor
            ] as CFArray
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors,
                locations: [0, 1]
            ) {
                context.saveGState()
                context.addRect(photoRect)
                context.clip()
                context.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: photoRect.midX, y: photoRect.minY),
                    end: CGPoint(x: photoRect.midX, y: photoRect.maxY),
                    options: []
                )
                context.restoreGState()
            }
        }

        // 相纸上的字是深色：白框上不能用背景那套 ink。
        let paperInk = UIColor(white: 0.10, alpha: 1)
        let paperSecondary = UIColor(white: 0.32, alpha: 1)
        let textWidth = photoSide
        let textX = photoRect.minX
        var textY = photoRect.maxY + 20

        let lyricSize: CGFloat = 34
        let lyricHeight = min(
            height(of: content.lyric, fontSize: lyricSize, weight: .regular, width: textWidth),
            88
        )
        draw(
            content.lyric,
            fontSize: lyricSize,
            weight: .regular,
            color: paperInk,
            alignment: .left,
            in: CGRect(x: textX, y: textY, width: textWidth, height: lyricHeight),
            context: context
        )
        textY += lyricHeight + 6

        let titleHeight = height(of: content.title, fontSize: 30, weight: .semibold, width: textWidth)
        if !content.title.isEmpty {
            draw(
                content.title,
                fontSize: 30,
                weight: .semibold,
                color: paperInk,
                alignment: .left,
                in: CGRect(x: textX, y: textY, width: textWidth, height: titleHeight),
                context: context
            )
            textY += titleHeight + 2
        }
        let artistHeight = height(of: content.artist, fontSize: 26, weight: .regular, width: textWidth)
        if !content.artist.isEmpty {
            draw(
                content.artist,
                fontSize: 26,
                weight: .regular,
                color: paperSecondary,
                alignment: .left,
                in: CGRect(x: textX, y: textY, width: textWidth, height: artistHeight),
                context: context
            )
        }

        context.restoreGState()

        // 相纸外面的署名（跟着背景选颜色）。
        drawCredit(
            content.credit,
            ink: ink,
            y: cardRect.maxY + 64,
            in: context
        )
    }

    // MARK: - 模板：极简

    private static func drawMinimal(_ content: Content, ink: UIColor, in context: CGContext) {
        let top = cardSize.height * 0.30
        let bottom = cardSize.height * 0.70
        let lyricWidth = cardSize.width * 0.84
        var lyricSize: CGFloat = 88
        var lyricHeight = height(
            of: content.lyric,
            fontSize: lyricSize,
            weight: .semibold,
            width: lyricWidth
        )
        let available = bottom - top
        while lyricHeight > available, lyricSize > 52 {
            lyricSize *= 0.94
            lyricHeight = height(
                of: content.lyric,
                fontSize: lyricSize,
                weight: .semibold,
                width: lyricWidth
            )
        }

        draw(
            content.lyric,
            fontSize: lyricSize,
            weight: .semibold,
            color: ink,
            alignment: .center,
            in: CGRect(
                x: (cardSize.width - lyricWidth) / 2,
                y: top + max((available - lyricHeight) / 2, 0),
                width: lyricWidth,
                height: lyricHeight
            ),
            context: context
        )

        var footerY = cardSize.height * 0.80
        let titleHeight = height(of: content.title, fontSize: 34, weight: .semibold, width: columnWidth)
        if !content.title.isEmpty {
            draw(
                content.title,
                fontSize: 34,
                weight: .semibold,
                color: ink.withAlphaComponent(0.92),
                alignment: .center,
                in: CGRect(x: margin, y: footerY, width: columnWidth, height: titleHeight),
                context: context
            )
            footerY += titleHeight + 4
        }
        let artistHeight = height(of: content.artist, fontSize: 30, weight: .regular, width: columnWidth)
        if !content.artist.isEmpty {
            draw(
                content.artist,
                fontSize: 30,
                weight: .regular,
                color: ink.withAlphaComponent(0.62),
                alignment: .center,
                in: CGRect(x: margin, y: footerY, width: columnWidth, height: artistHeight),
                context: context
            )
        }

        drawCredit(content.credit, ink: ink, y: cardSize.height - 130, in: context)
    }

    // MARK: - 公共部件

    private static func drawCover(
        _ cover: UIImage,
        in rect: CGRect,
        cornerRadius: CGFloat,
        context: CGContext
    ) {
        guard cover.size.width >= 1, cover.size.height >= 1 else { return }
        UIGraphicsPushContext(context)
        UIBezierPath(roundedRect: rect, cornerRadius: cornerRadius).addClip()
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
    }

    private static func drawCredit(
        _ credit: String,
        ink: UIColor,
        y: CGFloat,
        in context: CGContext
    ) {
        let text = credit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let creditHeight = height(
            of: text,
            fontSize: creditSize,
            weight: .regular,
            width: columnWidth
        )
        draw(
            text,
            fontSize: creditSize,
            weight: .regular,
            color: ink.withAlphaComponent(0.48),
            alignment: .left,
            in: CGRect(x: margin, y: y, width: columnWidth, height: creditHeight),
            context: context
        )
    }

    // MARK: - 文字工具

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
