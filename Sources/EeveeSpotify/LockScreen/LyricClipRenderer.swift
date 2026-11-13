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
/// 一段片子只有一帧：这一行会一直显示到下一条（由调度器在换行时换文件），
/// 所以不需要逐帧动画。单帧编码在手机上只要几十毫秒，一行一段也不至于让
/// 锁屏黑一下。
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
        size: CGSize
    ) throws -> CGImage {
        let backdrop = try backdrop(cover: cover, size: size)
        return try compose(backdrop: backdrop, line: line, next: next, size: size)
    }

    /// 写一段单帧短片。`seconds` 是这段片子的名义时长：系统用它算循环点，
    /// 真正换不换行由调度器决定，所以这里给足"到下一行"的时间就行。
    static func write(
        cover: CGImage?,
        line: String?,
        next: String?,
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
                    let image = try compose(backdrop: backdrop, line: line, next: next, size: size)
                    try writeSingleFrame(image, size: size, seconds: seconds, to: destination)
                    continuation.resume()
                } catch let error {
                    continuation.resume(throwing: error)
                }
            }
        }
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

    /// 在当前行下面再画一行压暗的"下一行"，这是锁屏歌词最有用的那点上下文：
    /// 只看一句不知道唱到哪，看到下一句就知道还有多久换行。
    private static func compose(
        backdrop: CGImage,
        line: String?,
        next: String?,
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

        // 背景图是从另一个位图上下文里出来的，画进这个上下文要自己翻一次 Y；
        // 文字走 CoreText，在未翻转的坐标里画才是正的，所以只翻图片那一段。
        context.saveGState()
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(backdrop, in: CGRect(origin: .zero, size: size))
        context.restoreGState()

        drawLyricText(line: line, next: next, size: size, context: context)

        guard let composed = context.makeImage() else {
            throw Failure(reason: "could not compose the frame")
        }
        return composed
    }

    private static func drawLyricText(
        line: String?,
        next: String?,
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

        // 没在唱（间奏/换行间隙）时只把下一行压暗放在中间，不留下上一句的残影。
        guard !current.isEmpty else {
            let fontSize = fittedFontSize(
                for: following,
                size: size,
                columnWidth: columnWidth,
                start: size.width * 0.062,
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
                context: context
            )
            return
        }

        let fontSize = fittedFontSize(
            for: current,
            size: size,
            columnWidth: columnWidth,
            start: size.width * 0.075,
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

        let gap = following.isEmpty ? 0 : fontSize * 0.55
        let total = currentHeight + gap + nextHeight
        let top = centerY + total / 2

        draw(
            current,
            fontSize: fontSize,
            alpha: 1,
            rect: CGRect(
                x: columnX,
                y: top - currentHeight,
                width: columnWidth,
                height: currentHeight
            ),
            context: context
        )

        guard !following.isEmpty else { return }
        draw(
            following,
            fontSize: nextFontSize,
            alpha: 0.42,
            rect: CGRect(
                x: columnX,
                y: top - currentHeight - gap - nextHeight,
                width: columnWidth,
                height: nextHeight
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
        context: CGContext
    ) {
        guard rect.height > 0 else { return }
        let framesetter = framesetter(for: text, fontSize: fontSize, alpha: alpha)

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

    private static func framesetter(
        for text: String,
        fontSize: CGFloat,
        alpha: CGFloat
    ) -> CTFramesetter {
        let font = CTFontCreateWithName(
            UIFont.systemFont(ofSize: fontSize, weight: .semibold).fontName as CFString,
            fontSize,
            nil
        )
        // 只有对齐方式需要非默认值：换行用默认的按词换行，行距交给系统。
        var alignment: CTTextAlignment = .center
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

    /// 单帧 H.264。`AVAssetWriter` 的最后一个 sample 时长由 `endSession` 决定，
    /// 所以"一帧 + 指定时长"就是一段定长短片，不需要真的编 N 帧。
    private static func writeSingleFrame(
        _ image: CGImage,
        size: CGSize,
        seconds: Double,
        to destination: URL
    ) throws {
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
            try draw(image, into: buffer, size: size)
            guard adaptor.append(buffer, withPresentationTime: .zero) else {
                throw Failure(reason: "the writer rejected the frame")
            }

            input.markAsFinished()
            writer.endSession(atSourceTime: CMTime(seconds: max(seconds, 1), preferredTimescale: 600))
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

        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
    }
}
