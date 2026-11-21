import AVFoundation
import CoreGraphics
import CoreImage
import CoreText
import Foundation
import UIKit

/// 把一行歌词画成一段可以直接交给锁屏的 H.264 短片。
///
/// 为什么是"每行一段视频"而不是叠一层 UILabel：锁屏的全屏封面区只吃
/// `MPMediaItemAnimatedArtwork`（一段本地文件），没有任何可以挂子视图的时机 ——
/// 系统在锁屏画它自己那份播放器。所以歌词只能**画进画面本身**。
///
/// 一段片子默认只有一帧：这一行会一直显示到下一条（由调度器在换行时换文件）。
/// 逐字那一档是例外 —— 每个词开始编一帧（`LockScreenKaraoke`），编完停在最后一帧。
/// 单帧编码在手机上只要几十毫秒；多帧多花的那点时间由后台队列吃掉。
enum LyricClipRenderer {

    struct Failure: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// 锁屏那一格只有这么大，再高只是多占缓存与解码。
    /// 两条边都取 16 的倍数：H.264 编码器对奇数/非对齐尺寸会直接拒绝或补边。
    static func clipSize(for aspect: LockScreenArtwork.Aspect) -> CGSize {
        let wanted = aspect.renderSize
        let width = max(16, (wanted.width / 16).rounded() * 16)
        let height = max(16, (wanted.height / 16).rounded() * 16)
        return CGSize(width: width, height: height)
    }

    // MARK: - 对外

    /// 预览图与首帧是同一张：系统在视频还没到手时先显示它，慢一拍就会先闪静态封面，
    /// 等久了甚至不再来要视频。
    static func stillImage(
        cover: CGImage?,
        line: String?,
        next: String?,
        translation: String?,
        romanization: String? = nil,
        isDuet: Bool = false,
        flipped: Bool = false,
        nextFlipped: Bool = false,
        revealedCharacters: Int? = nil,
        companion: String? = nil,
        companionRevealedCharacters: Int? = nil,
        companionFlipped: Bool = false,
        credit: String,
        size: CGSize
    ) throws -> CGImage {
        let backdrop = try backdrop(cover: cover, size: size)
        return try compose(
            backdrop: backdrop,
            line: line,
            next: next,
            translation: translation,
            romanization: romanization,
            isDuet: isDuet,
            flipped: flipped,
            nextFlipped: nextFlipped,
            revealedCharacters: revealedCharacters,
            companion: companion,
            companionRevealedCharacters: companionRevealedCharacters,
            companionFlipped: companionFlipped,
            credit: credit,
            size: size
        )
    }

    /// 写一段短片。`seconds` 是这段片子的名义时长：系统用它算循环点，
    /// 真正换不换行由调度器决定，所以这里给足"到下一行"的时间就行。
    ///
    /// `karaoke` 非空时编**多帧**：每个词开始的那一刻一帧（已唱词亮、未唱词压暗），
    /// 编完最后一帧就停在那里等下一行；空则退回单帧（整行一次点亮）。
    ///
    /// `companionKaraoke` 非空时是**对唱叠句**：当前句和同一时刻还在唱的另一位歌手那句
    /// 同时画进每一帧，两张帧表按时间并起来（`LockScreenKaraoke.combinedFrames`）。
    static func write(
        cover: CGImage?,
        line: String?,
        next: String?,
        translation: String?,
        romanization: String? = nil,
        isDuet: Bool = false,
        flipped: Bool = false,
        nextFlipped: Bool = false,
        karaoke: [LockScreenKaraokeFrame] = [],
        companion: String? = nil,
        companionKaraoke: [LockScreenKaraokeFrame] = [],
        companionFlipped: Bool = false,
        credit: String,
        size: CGSize,
        seconds: Double,
        to destination: URL
    ) async throws {
        // 编码会阻塞（等 `isReadyForMoreMediaData`、等 `finishWriting`），
        // 放到自己的串行队列，别占着 Swift 并发的协作线程。
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            encodeQueue.async {
                do {
                    let backdrop = try backdrop(cover: cover, size: size)
                    let pair = pairFrames(
                        line: karaoke,
                        companion: companionKaraoke,
                        companionText: companion
                    )
                    if let pair, pair.count >= 2 {
                        var frames: [(at: Int, image: CGImage)] = []
                        frames.reserveCapacity(pair.count)
                        for frame in pair {
                            let image = try compose(
                                backdrop: backdrop,
                                line: line,
                                next: next,
                                translation: translation,
                                romanization: romanization,
                                isDuet: isDuet,
                                flipped: flipped,
                                nextFlipped: nextFlipped,
                                revealedCharacters: frame.lineCharacters,
                                companion: companion,
                                companionRevealedCharacters: frame.companionCharacters,
                                companionFlipped: companionFlipped,
                                credit: credit,
                                size: size
                            )
                            frames.append((frame.offsetMs, image))
                        }
                        try writeFrames(frames, size: size, seconds: seconds, to: destination)
                    } else if karaoke.count >= 2 {
                        var frames: [(at: Int, image: CGImage)] = []
                        frames.reserveCapacity(karaoke.count)
                        for frame in karaoke {
                            let image = try compose(
                                backdrop: backdrop,
                                line: line,
                                next: next,
                                translation: translation,
                                romanization: romanization,
                                isDuet: isDuet,
                                flipped: flipped,
                                nextFlipped: nextFlipped,
                                revealedCharacters: frame.revealedCharacters,
                                companion: companion,
                                companionRevealedCharacters: nil,
                                companionFlipped: companionFlipped,
                                credit: credit,
                                size: size
                            )
                            frames.append((frame.offsetMs, image))
                        }
                        try writeFrames(frames, size: size, seconds: seconds, to: destination)
                    } else {
                        let image = try compose(
                            backdrop: backdrop,
                            line: line,
                            next: next,
                            translation: translation,
                            romanization: romanization,
                            isDuet: isDuet,
                            flipped: flipped,
                            nextFlipped: nextFlipped,
                            revealedCharacters: karaoke.first?.revealedCharacters,
                            companion: companion,
                            companionRevealedCharacters: nil,
                            companionFlipped: companionFlipped,
                            credit: credit,
                            size: size
                        )
                        try writeFrames([(0, image)], size: size, seconds: seconds, to: destination)
                    }
                    continuation.resume()
                } catch let error {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// 对唱叠句的合并帧表：两边都得有真正的逐词帧表，`companion` 也得有文本。
    private static func pairFrames(
        line: [LockScreenKaraokeFrame],
        companion: [LockScreenKaraokeFrame],
        companionText: String?
    ) -> [LockScreenKaraokePairFrame]? {
        guard let text = companionText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return LockScreenKaraoke.combinedFrames(line: line, companion: companion)
    }

    private static let encodeQueue = DispatchQueue(
        label: "com.eevee.lockscreen.lyricclip",
        qos: .utility
    )

    // MARK: - 背景

    /// 模糊封面铺底 + 一层压暗。模糊在**缩小后的小图上**做（160px 宽），再放大铺满：
    /// 整幅原图做高斯模糊在手机上一次要十几秒，而模糊本身又把细节抹掉了，
    /// 先缩后糊在观感上没有区别。
    private static func backdrop(cover: CGImage?, size: CGSize) throws -> CGImage {
        let width = Int(size.width)
        let height = Int(size.height)
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue
              ) else {
            throw Failure(reason: "could not open a bitmap context")
        }

        let full = CGRect(origin: .zero, size: size)
        if let cover, let blurred = blurred(cover) {
            drawFilling(blurred, in: full, context: context)
        } else {
            context.setFillColor(CGColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1))
            context.fill(full)
        }

        // 白字要压在任意亮度的封面上都读得出来，底必须压暗。
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.45))
        context.fill(full)

        guard let backdrop = context.makeImage() else {
            throw Failure(reason: "could not compose the backdrop")
        }
        return backdrop
    }

    private static func blurred(_ source: CGImage) -> CGImage? {
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

    /// 与 `FillArtworkRenderer` 同一套取色/缩放：软件渲染在后台任务里会拖慢整机，
    /// 这里沿用仓库里已经在用的默认 CIContext。
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

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

    // MARK: - 文字

    /// 「歌词 → 文字」那一档字号倍率。锁屏与 App 内共用同一个设置。
    ///
    /// 乘在**自适应起点**上：字号变大之后 `fittedFontSize` 仍会按画面高度往下收，
    /// 所以放大只体现在"放得下时更大"，不会把一行顶出锁屏。
    private static var textScale: CGFloat {
        CGFloat(NgzhwmSettingsViewModel.lyricsTextScale)
    }

    /// 行距倍率。锁屏里唯一的"行距"是当前行与下一行之间那道空隙（`gap`）。
    private static var spacingScale: CGFloat {
        CGFloat(NgzhwmSettingsViewModel.lyricsLineSpacingScale)
    }

    /// 在当前行下面再画一行压暗的"下一行"，这是锁屏歌词最有用的那点上下文：
    /// 只看一句不知道唱到哪，看到下一句就知道还有多久换行。
    ///
    /// `companion` 非空时换成**对唱叠句**画法：当前句和另一位歌手那句同时画、各自逐词亮，
    /// 不再画"下一行"（那一格让给另一位歌手）。
    private static func compose(
        backdrop: CGImage,
        line: String?,
        next: String?,
        translation: String?,
        romanization: String?,
        isDuet: Bool,
        flipped: Bool,
        nextFlipped: Bool,
        revealedCharacters: Int?,
        companion: String?,
        companionRevealedCharacters: Int?,
        companionFlipped: Bool,
        credit: String,
        size: CGSize
    ) throws -> CGImage {
        let width = Int(size.width)
        let height = Int(size.height)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw Failure(reason: "could not open a bitmap context")
        }

        // 这张合成图有两个去处：系统要预览时当静帧交出去，要视频时按原样编码。两处必须
        // 同一朝向，所以背景和文字都画在同一个（未翻转的）坐标系里。
        context.interpolationQuality = .high
        context.draw(backdrop, in: CGRect(origin: .zero, size: size))

        drawLyricText(
            line: line,
            next: next,
            translation: translation,
            romanization: romanization,
            isDuet: isDuet,
            flipped: flipped,
            nextFlipped: nextFlipped,
            revealedCharacters: revealedCharacters,
            companion: companion,
            companionRevealedCharacters: companionRevealedCharacters,
            companionFlipped: companionFlipped,
            credit: credit,
            size: size,
            context: context
        )

        guard let composed = context.makeImage() else {
            throw Failure(reason: "could not compose the frame")
        }
        return composed
    }

    private static func drawLyricText(
        line: String?,
        next: String?,
        translation: String?,
        romanization: String?,
        isDuet: Bool,
        flipped: Bool,
        nextFlipped: Bool,
        revealedCharacters: Int?,
        companion: String?,
        companionRevealedCharacters: Int?,
        companionFlipped: Bool,
        credit: String,
        size: CGSize,
        context: CGContext
    ) {
        let columnWidth = size.width * 0.8
        let columnX = (size.width - columnWidth) / 2
        // 文字块的中心略低于几何中心：锁屏上方是状态栏与时间，视觉重心偏下更稳。
        let centerY = size.height * 0.5

        let current = (line ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let following = (next ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        guard !current.isEmpty || !following.isEmpty else { return }
        // 歌词来源的署名：锁屏是唯一看不到页内署名的展示面，不能只显示别人的词。
        defer {
            drawCredit(credit, size: size, columnWidth: columnWidth, columnX: columnX, context: context)
        }

        // 对唱：两位歌手各贴自己那一侧（第一位左、第二位右）。单嗓歌保持居中 ——
        // 锁屏上居中才是常态，只有"换人唱"这件事值得动对齐。
        let currentAlignment: CTTextAlignment = isDuet ? (flipped ? .right : .left) : .center
        let nextAlignment: CTTextAlignment = isDuet ? (nextFlipped ? .right : .left) : .center

        // 对唱叠句：同一时刻两位歌手都在唱。两句都画出来（各自逐词亮），
        // "下一行"那一格让给它 —— 否则后开始的那句一接管，先开始的那句就从画面上消失。
        let companionText = (companion ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !companionText.isEmpty, isDuet, !current.isEmpty {
            drawDuetPair(
                current: current,
                companion: companionText,
                translation: translation ?? "",
                currentAlignment: currentAlignment,
                companionAlignment: companionFlipped ? .right : .left,
                currentRevealed: revealedCharacters,
                companionRevealed: companionRevealedCharacters,
                size: size,
                columnWidth: columnWidth,
                columnX: columnX,
                centerY: centerY,
                context: context
            )
            return
        }

        // 没在唱（间奏/换行间隙）时只把下一行压暗放在中间，不留下上一句的残影。
        guard !current.isEmpty else {
            let fontSize = fittedFontSize(
                for: following,
                size: size,
                columnWidth: columnWidth,
                start: size.width * 0.062 * textScale,
                maxHeight: size.height * 0.4
            )
            let height = textHeight(for: following, fontSize: fontSize, columnWidth: columnWidth)
            draw(
                following,
                fontSize: fontSize,
                alpha: 0.5,
                rect: CGRect(
                    x: columnX,
                    y: centerY - height / 2,
                    width: columnWidth,
                    height: height
                ),
                alignment: nextAlignment,
                context: context
            )
            return
        }

        let fontSize = fittedFontSize(
            for: current,
            size: size,
            columnWidth: columnWidth,
            start: size.width * 0.075 * textScale,
            maxHeight: size.height * 0.42
        )
        let currentHeight = textHeight(for: current, fontSize: fontSize, columnWidth: columnWidth)

        var nextFontSize: CGFloat = 0
        var nextHeight: CGFloat = 0
        if !following.isEmpty {
            nextFontSize = max(14, fontSize * 0.68)
            nextHeight = textHeight(for: following, fontSize: nextFontSize, columnWidth: columnWidth)
            // 下一行只是提示，不许把当前行挤出画面。
            let budget = size.height * 0.22
            if nextHeight > budget {
                nextFontSize *= budget / nextHeight
                nextHeight = budget
            }
        }

        // 译文：压在正文下面一小行。上限 14% 画面高 —— 它只是辅助，
        // 再加上"下一行"提示，三者一起仍要给锁屏上方的时间/日期留出余量。
        let translationText = (translation ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var translationFontSize: CGFloat = 0
        var translationHeight: CGFloat = 0
        if !translationText.isEmpty {
            translationFontSize = max(12, fontSize * 0.52)
            translationHeight = textHeight(
                for: translationText,
                fontSize: translationFontSize,
                columnWidth: columnWidth
            )
            let budget = size.height * 0.14
            if translationHeight > budget {
                translationFontSize *= budget / translationHeight
                translationHeight = budget
            }
        }
        let translationGap = translationText.isEmpty ? 0 : fontSize * 0.22 * spacingScale

        // 罗马字：画在正文**上方**一小行（与歌词页同一个位置约定）。
        // 只是辅助信息，同样给个高度上限，不让它把正文挤小。
        let romanizationText = (romanization ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var romanizationFontSize: CGFloat = 0
        var romanizationHeight: CGFloat = 0
        if !romanizationText.isEmpty {
            romanizationFontSize = max(11, fontSize * 0.48)
            romanizationHeight = textHeight(
                for: romanizationText,
                fontSize: romanizationFontSize,
                columnWidth: columnWidth
            )
            let budget = size.height * 0.12
            if romanizationHeight > budget {
                romanizationFontSize *= budget / romanizationHeight
                romanizationHeight = budget
            }
        }
        let romanizationGap = romanizationText.isEmpty ? 0 : fontSize * 0.18 * spacingScale

        let nextGap = following.isEmpty ? 0 : fontSize * 0.55 * spacingScale
        let total = romanizationHeight + romanizationGap
            + currentHeight + translationGap + translationHeight + nextGap + nextHeight
        let top = centerY + total / 2

        if !romanizationText.isEmpty {
            draw(
                romanizationText,
                fontSize: romanizationFontSize,
                alpha: 0.62,
                rect: CGRect(
                    x: columnX,
                    y: top - romanizationHeight,
                    width: columnWidth,
                    height: romanizationHeight
                ),
                alignment: currentAlignment,
                context: context
            )
        }

        let currentTop = top - romanizationHeight - romanizationGap
        let currentRect = CGRect(
            x: columnX,
            y: currentTop - currentHeight,
            width: columnWidth,
            height: currentHeight
        )
        if let revealedCharacters {
            // 逐字那一帧：已唱到的那一段亮白，后面的压暗。折行/对齐不变，
            // 所以字幕块的高度与单帧那份完全一样，行不会跳。
            drawRevealed(
                current,
                revealedCharacters: revealedCharacters,
                fontSize: fontSize,
                rect: currentRect,
                alignment: currentAlignment,
                context: context
            )
        } else {
            draw(
                current,
                fontSize: fontSize,
                alpha: 1,
                rect: currentRect,
                alignment: currentAlignment,
                context: context
            )
        }

        let translationTop = currentTop - currentHeight - translationGap - translationHeight
        if !translationText.isEmpty {
            draw(
                translationText,
                fontSize: translationFontSize,
                alpha: 0.78,
                rect: CGRect(
                    x: columnX,
                    y: translationTop,
                    width: columnWidth,
                    height: translationHeight
                ),
                alignment: currentAlignment,
                context: context
            )
        }

        guard !following.isEmpty else { return }
        draw(
            following,
            fontSize: nextFontSize,
            alpha: 0.42,
            rect: CGRect(
                x: columnX,
                y: translationTop - nextGap - nextHeight,
                width: columnWidth,
                height: nextHeight
            ),
            alignment: nextAlignment,
            context: context
        )
    }

    /// 对唱叠句那一档：同一时刻还在唱的另一句（先开口的）在上、当前句在下。
    ///
    /// 上下顺序按**开口先后**（另一位总是先开始，见 controller 的 `companionLine`）：
    /// 这样一句唱完、下一句开始时，先开口那句不会在上下之间跳，只有新的那句在下方出现/消失。
    /// 两句各自按自己的边对齐、各自逐词亮；这一档不画罗马字（四行会挤，而且它是辅助信息），
    /// 译文只画当前句的。总和超过画面 90% 时整体按比例缩一次。
    private static func drawDuetPair(
        current: String,
        companion: String,
        translation: String,
        currentAlignment: CTTextAlignment,
        companionAlignment: CTTextAlignment,
        currentRevealed: Int?,
        companionRevealed: Int?,
        size: CGSize,
        columnWidth: CGFloat,
        columnX: CGFloat,
        centerY: CGFloat,
        context: CGContext
    ) {
        let translationText = translation.trimmingCharacters(in: .whitespacesAndNewlines)

        var currentFontSize = fittedFontSize(
            for: current,
            size: size,
            columnWidth: columnWidth,
            start: size.width * 0.075 * textScale,
            maxHeight: size.height * 0.32
        )
        var companionFontSize = fittedFontSize(
            for: companion,
            size: size,
            columnWidth: columnWidth,
            start: currentFontSize,
            maxHeight: size.height * 0.30
        )
        var translationFontSize: CGFloat = 0
        if !translationText.isEmpty {
            translationFontSize = max(12, currentFontSize * 0.5)
        }

        struct Metrics {
            let current: CGFloat
            let companion: CGFloat
            let translation: CGFloat
            let currentGap: CGFloat
            let translationGap: CGFloat
            let total: CGFloat
        }

        func metrics() -> Metrics {
            let currentHeight = textHeight(
                for: current,
                fontSize: currentFontSize,
                columnWidth: columnWidth
            )
            let companionHeight = textHeight(
                for: companion,
                fontSize: companionFontSize,
                columnWidth: columnWidth
            )
            let translationHeight = translationText.isEmpty
                ? 0
                : textHeight(
                    for: translationText,
                    fontSize: translationFontSize,
                    columnWidth: columnWidth
                )
            let currentGap = currentFontSize * 0.16 * spacingScale
            let translationGap = translationText.isEmpty
                ? 0
                : currentFontSize * 0.22 * spacingScale
            let total = companionHeight + currentGap + currentHeight
                + translationGap + translationHeight
            return Metrics(
                current: currentHeight,
                companion: companionHeight,
                translation: translationHeight,
                currentGap: currentGap,
                translationGap: translationGap,
                total: total
            )
        }

        var m = metrics()
        let limit = size.height * 0.9
        if m.total > limit, m.total > 0 {
            let factor = limit / m.total
            currentFontSize *= factor
            companionFontSize *= factor
            translationFontSize *= factor
            m = metrics()
        }
        guard m.total > 0 else { return }

        var cursor = centerY + m.total / 2

        // 先开口的那句（`companion`）在上。
        let companionRect = CGRect(
            x: columnX,
            y: cursor - m.companion,
            width: columnWidth,
            height: m.companion
        )
        if let companionRevealed {
            drawRevealed(
                companion,
                revealedCharacters: companionRevealed,
                fontSize: companionFontSize,
                rect: companionRect,
                alignment: companionAlignment,
                context: context
            )
        } else {
            draw(
                companion,
                fontSize: companionFontSize,
                alpha: 1,
                rect: companionRect,
                alignment: companionAlignment,
                context: context
            )
        }
        cursor -= m.companion + m.currentGap

        // 当前句在下。
        let currentRect = CGRect(
            x: columnX,
            y: cursor - m.current,
            width: columnWidth,
            height: m.current
        )
        if let currentRevealed {
            drawRevealed(
                current,
                revealedCharacters: currentRevealed,
                fontSize: currentFontSize,
                rect: currentRect,
                alignment: currentAlignment,
                context: context
            )
        } else {
            draw(
                current,
                fontSize: currentFontSize,
                alpha: 1,
                rect: currentRect,
                alignment: currentAlignment,
                context: context
            )
        }
        cursor -= m.current + m.translationGap

        if m.translation > 0 {
            draw(
                translationText,
                fontSize: translationFontSize,
                alpha: 0.78,
                rect: CGRect(
                    x: columnX,
                    y: cursor - m.translation,
                    width: columnWidth,
                    height: m.translation
                ),
                alignment: currentAlignment,
                context: context
            )
        }
    }

    /// 底沿一行小字：歌词来源。锁屏是唯一没有页内署名的地方，这一行保证"谁的词"始终可见。
    private static func drawCredit(
        _ credit: String,
        size: CGSize,
        columnWidth: CGFloat,
        columnX: CGFloat,
        context: CGContext
    ) {
        let text = credit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let fontSize = max(9, size.width * 0.032)
        let height = textHeight(for: text, fontSize: fontSize, columnWidth: columnWidth)
        draw(
            text,
            fontSize: fontSize,
            alpha: 0.38,
            rect: CGRect(
                x: columnX,
                y: size.height * 0.07,
                width: columnWidth,
                height: height
            ),
            context: context
        )
    }

    /// 一屏放不下的长句：先按标准字号量，超出预算就按 4% 一档缩，缩到 55% 还放不下
    /// 就让它溢出（截断歌词比溢出更糟 —— 用户没办法知道少了什么）。
    private static func fittedFontSize(
        for text: String,
        size: CGSize,
        columnWidth: CGFloat,
        start: CGFloat,
        maxHeight: CGFloat
    ) -> CGFloat {
        var fontSize = max(16, min(start, 64))
        let floor = fontSize * 0.55
        while fontSize > floor {
            let height = textHeight(for: text, fontSize: fontSize, columnWidth: columnWidth)
            if height <= maxHeight { return fontSize }
            fontSize *= 0.96
        }
        return fontSize
    }

    private static func textHeight(
        for text: String,
        fontSize: CGFloat,
        columnWidth: CGFloat
    ) -> CGFloat {
        let framesetter = framesetter(for: text, fontSize: fontSize, alpha: 1)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: 0),
            nil,
            CGSize(width: columnWidth, height: .greatestFiniteMagnitude),
            nil
        )
        return ceil(suggested.height)
    }

    private static func draw(
        _ text: String,
        fontSize: CGFloat,
        alpha: CGFloat,
        rect: CGRect,
        alignment: CTTextAlignment = .center,
        context: CGContext
    ) {
        guard rect.height > 0 else { return }
        let framesetter = framesetter(
            for: text,
            fontSize: fontSize,
            alpha: alpha,
            alignment: alignment
        )

        context.saveGState()
        // 白字压在模糊封面上容易糊，加一点阴影把字从底里拉出来。
        context.setShadow(
            offset: CGSize(width: 0, height: -1),
            blur: fontSize * 0.12,
            color: UIColor(white: 0, alpha: 0.55).cgColor
        )
        let path = CGPath(rect: rect, transform: nil)
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: 0),
            path,
            nil
        )
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    /// 逐字那一帧：前 `revealedCharacters` 个字符亮白，其余压暗。
    ///
    /// 不用"裁一块渐变盖上去"：锁屏这块画布是多行折行的文本，按 x 裁剪会把整行
    /// 一起点亮（折行后同一行 y 上有好几个词）。按**字符区间**上色才是逐词的语义。
    private static func drawRevealed(
        _ text: String,
        revealedCharacters: Int,
        fontSize: CGFloat,
        rect: CGRect,
        alignment: CTTextAlignment,
        context: CGContext
    ) {
        guard rect.height > 0 else { return }
        let framesetter = revealedFramesetter(
            for: text,
            fontSize: fontSize,
            revealedCharacters: revealedCharacters,
            alignment: alignment
        )

        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -1),
            blur: fontSize * 0.12,
            color: UIColor(white: 0, alpha: 0.55).cgColor
        )
        let path = CGPath(rect: rect, transform: nil)
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: 0),
            path,
            nil
        )
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    /// 已唱到 / 还没唱到两种颜色：两段 `NSAttributedString`（CoreText 只认 CF 那套属性名）。
    ///
    /// 区间用 UTF-16 长度（CoreText 的 range 口径），`revealedCharacters` 是 Character 数 ——
    /// emoji / 组合字下两者不等，所以先截前缀再取 `NSString.length`。
    private static func revealedFramesetter(
        for text: String,
        fontSize: CGFloat,
        revealedCharacters: Int,
        alignment: CTTextAlignment
    ) -> CTFramesetter {
        let font = coreTextFont(fontSize)
        var alignment = alignment
        let paragraph: CTParagraphStyle = withUnsafePointer(to: &alignment) { pointer in
            var setting = CTParagraphStyleSetting(
                spec: .alignment,
                valueSize: MemoryLayout<CTTextAlignment>.size,
                value: UnsafeRawPointer(pointer)
            )
            return CTParagraphStyleCreate(&setting, 1)
        }

        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [
                NSAttributedString.Key(rawValue: kCTFontAttributeName as String): font,
                NSAttributedString.Key(rawValue: kCTForegroundColorAttributeName as String):
                    UIColor.white.withAlphaComponent(unsungAlpha).cgColor,
                NSAttributedString.Key(rawValue: kCTParagraphStyleAttributeName as String): paragraph,
            ]
        )

        let clamped = max(0, min(revealedCharacters, text.count))
        if clamped > 0 {
            let prefix = String(text.prefix(clamped)) as NSString
            if prefix.length > 0 {
                attributed.addAttribute(
                    NSAttributedString.Key(rawValue: kCTForegroundColorAttributeName as String),
                    value: UIColor.white.cgColor,
                    range: NSRange(location: 0, length: prefix.length)
                )
            }
        }

        return CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
    }

    /// 还没唱到的那一段的不透明度：比"下一行提示"（0.42）亮一点，
    /// 整体行仍读得出来，但一眼能看出"这句还没唱"。
    private static let unsungAlpha: CGFloat = 0.38


    /// CoreText 要的是 `CTFont`，而 `UIFont.systemFont(...).fontName` 给出来的是**私有名**
    /// （`.SFUI-Semibold` 这种）—— `CTFontCreateWithName` 解析不了这种名字，会**静默**退到
    /// Times New Roman（拉丁）和明朝体（CJK），于是锁屏上的字既不是系统字体、也不是应用里
    /// 看到的那一套。只能从 UI 字体类型枚举要，那条路一定拿得到真正的 SF。
    private static func coreTextFont(_ size: CGFloat) -> CTFont {
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil)
            ?? CTFontCreateWithName("HelveticaNeue-Medium" as CFString, size, nil)
        logFontOnce(font)
        return font
    }

    private static var loggedFont = false

    private static func logFontOnce(_ font: CTFont) {
        guard !loggedFont else { return }
        loggedFont = true
        let name = CTFontCopyPostScriptName(font) as String
        writeDebugLog("[\(LockScreenLyrics.logTag)] clip font — \(name)")
    }

    private static func framesetter(
        for text: String,
        fontSize: CGFloat,
        alpha: CGFloat,
        alignment: CTTextAlignment = .center
    ) -> CTFramesetter {
        let font = coreTextFont(fontSize)
        // 只有对齐方式需要非默认值：换行用默认的按词换行，行距交给系统。
        var alignment = alignment
        let paragraph: CTParagraphStyle = withUnsafePointer(to: &alignment) { pointer in
            var setting = CTParagraphStyleSetting(
                spec: .alignment,
                valueSize: MemoryLayout<CTTextAlignment>.size,
                value: UnsafeRawPointer(pointer)
            )
            return CTParagraphStyleCreate(&setting, 1)
        }

        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(rawValue: kCTFontAttributeName as String): font,
            NSAttributedString.Key(rawValue: kCTForegroundColorAttributeName as String):
                UIColor.white.withAlphaComponent(alpha).cgColor,
            NSAttributedString.Key(rawValue: kCTParagraphStyleAttributeName as String): paragraph,
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        return CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
    }

    // MARK: - 编码

    /// 一段 H.264。`frames` 是「毫秒偏移 + 画面」：单帧就是 `[(0, image)]`，
    /// 逐字则是每个词一帧。最后一个 sample 之后的画面由 `endSession` 的时长兜住 ——
    /// 编完最后一帧就停在那一帧，等调度器换行来换片段。
    private static func writeFrames(
        _ frames: [(at: Int, image: CGImage)],
        size: CGSize,
        seconds: Double,
        to destination: URL
    ) throws {
        guard !frames.isEmpty else {
            throw Failure(reason: "no frames to encode")
        }
        let width = Int(size.width)
        let height = Int(size.height)
        // 先写同目录下的临时 `.mp4` 再改名：`.mp4.partial` 这种后缀有可能被
        // AVFoundation 按扩展名校验挡下来（那样每段都静默失败，只剩预览图）。
        let folder = destination.deletingLastPathComponent()
        let partial = folder.appendingPathComponent("writing-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: partial)
        try? FileManager.default.removeItem(at: destination)

        guard let writer = try? AVAssetWriter(outputURL: partial, fileType: .mp4) else {
            throw Failure(reason: "could not create the writer")
        }
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 2_000_000,
                    AVVideoMaxKeyFrameIntervalKey: 15,
                ],
            ]
        )
        input.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            ]
        )

        guard writer.canAdd(input) else {
            throw Failure(reason: "the writer refused the video input")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw Failure(reason: writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)

        do {
            for (index, frame) in frames.enumerated() {
                while !input.isReadyForMoreMediaData {
                    Thread.sleep(forTimeInterval: 0.002)
                    guard writer.status == .writing else {
                        throw Failure(reason: writer.error?.localizedDescription ?? "writing stopped")
                    }
                }

                guard let pool = adaptor.pixelBufferPool else {
                    throw Failure(reason: "no pixel buffer pool")
                }
                var buffer: CVPixelBuffer?
                let created = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
                guard created == kCVReturnSuccess, let buffer else {
                    throw Failure(reason: "could not make a pixel buffer")
                }
                try draw(frame.image, into: buffer, size: size)
                // 时间戳必须严格递增：同一毫秒的两帧会被 writer 拒掉。
                let previous = index > 0 ? frames[index - 1].at : -1
                let offset = max(frame.at, previous + 1)
                let time = CMTime(value: Int64(max(0, offset)), timescale: 1000)
                guard adaptor.append(buffer, withPresentationTime: time) else {
                    throw Failure(reason: "the writer rejected frame \(index) of \(frames.count)")
                }
            }

            input.markAsFinished()
            let lastSeconds = Double(frames[frames.count - 1].at) / 1000
            writer.endSession(
                atSourceTime: CMTime(
                    seconds: max(seconds, lastSeconds + 1),
                    preferredTimescale: 600
                )
            )
            let done = DispatchSemaphore(value: 0)
            writer.finishWriting { done.signal() }
            done.wait()
            guard writer.status == .completed else {
                throw Failure(reason: writer.error?.localizedDescription ?? "finishWriting failed")
            }
        } catch let error {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: partial)
            throw error
        }

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
    }

    private static func draw(_ image: CGImage, into buffer: CVPixelBuffer, size: CGSize) throws {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(
                  data: base,
                  width: Int(size.width),
                  height: Int(size.height),
                  bitsPerComponent: 8,
                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue
              ) else {
            throw Failure(reason: "could not draw into the pixel buffer")
        }

        // 不翻 Y：这桶像素的第 0 行就是画面顶行，和位图上下文一致。再翻一次会让视频
        // 相对预览静帧上下镜像 —— 同一行歌词，预览是正的、视频是反的。
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
    }
}
