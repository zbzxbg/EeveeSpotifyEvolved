import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import UIKit

/// 本地 Fill：两条网络源都没有时，用专辑封面渲一段 4 秒、24 fps 的循环短片。
///
/// 画面是"模糊封面铺底 + 封面居中"（方版铺满、竖版居中）再叠一个来回缩放。缩放用余弦，
/// 首帧和末帧都回到 1.0，循环时不会跳。
///
/// 幅度是 7%：锁屏上这条片子被放大到整屏，3–4% 的缩放看上去就是"画面在呼吸"、读不出是
/// 在动；再大就开始像镜头推拉过头。
///
/// 为什么不用 `AVAssetExportSession` 拼：这里没有源视频，要自己出帧，所以走
/// `AVAssetWriter` + `AVAssetWriterInputPixelBufferAdaptor`。整段只写一次、落在缓存里，
/// 不参与播放路径，也不会在锁屏刷新时重渲染。
enum FillArtworkRenderer {

    struct Failure: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    private static let seconds = 4
    private static let framesPerSecond: Int32 = 24
    private static let zoom: CGFloat = 0.07

    static func render(
        cover: UIImage,
        aspect: LockScreenArtwork.Aspect,
        to destination: URL
    ) async throws {
        // 编码是同步阻塞的（等 `isReadyForMoreMediaData`、等 `finishWriting`）。放到自己的
        // 串行队列，别占着 Swift 并发的协作线程。
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            encodeQueue.async {
                do {
                    try renderSync(cover: cover, aspect: aspect, to: destination)
                    continuation.resume()
                } catch let error {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static let encodeQueue = DispatchQueue(
        label: "com.eevee.lockscreen.fill",
        qos: .utility
    )

    private static func renderSync(
        cover: UIImage,
        aspect: LockScreenArtwork.Aspect,
        to destination: URL
    ) throws {
        guard let source = bitmap(cover) else {
            throw Failure(reason: "the cover has no bitmap")
        }

        let size = aspect.renderSize
        let composed = try compose(source, size: size, aspect: aspect)
        try write(composed, size: size, to: destination)
    }

    /// `MPMediaItemArtwork` 给回来的图偶尔不是 CGImage 背书的，先摊成位图再画。
    private static func bitmap(_ image: UIImage) -> CGImage? {
        if let cgImage = image.cgImage { return cgImage }
        let side: CGFloat = 900
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: side, height: side),
            format: format
        )
        return renderer.image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }.cgImage
    }

    // MARK: - 画面

    private static func compose(
        _ source: CGImage,
        size: CGSize,
        aspect: LockScreenArtwork.Aspect
    ) throws -> CGImage {
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

        // 位图坐标系是左下原点，翻一次再画，导出的视频才是正的。
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)

        let full = CGRect(origin: .zero, size: size)
        if let background = blurred(source) {
            drawFilling(background, in: full, context: context)
        } else {
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.fill(full)
        }

        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.28))
        context.fill(full)

        switch aspect {
        case .square:
            drawFilling(source, in: full, context: context)
        case .tall:
            let side = min(size.width, size.height)
            let rect = CGRect(
                x: (size.width - side) / 2,
                y: (size.height - side) / 2,
                width: side,
                height: side
            )
            drawFilling(source, in: rect, context: context)
        }

        guard let composed = context.makeImage() else {
            throw Failure(reason: "could not compose the frame")
        }
        return composed
    }

    private static func blurred(_ source: CGImage) -> CGImage? {
        let input = CIImage(cgImage: source)
        let blurred = input
            .clampedToExtent()
            .applyingGaussianBlur(sigma: 26)
            .cropped(to: input.extent)
        return ciContext.createCGImage(blurred, from: input.extent)
    }

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

    // MARK: - 编码

    private static func write(_ composed: CGImage, size: CGSize, to destination: URL) throws {
        let width = Int(size.width)
        let height = Int(size.height)
        try? FileManager.default.removeItem(at: destination)

        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 3_000_000,
                    AVVideoMaxKeyFrameIntervalKey: Int(framesPerSecond),
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
            let total = Int(framesPerSecond) * seconds
            for index in 0..<total {
                guard writer.status == .writing else {
                    throw Failure(reason: writer.error?.localizedDescription ?? "writing stopped")
                }
                while !input.isReadyForMoreMediaData {
                    Thread.sleep(forTimeInterval: 0.002)
                    if writer.status != .writing {
                        throw Failure(
                            reason: writer.error?.localizedDescription ?? "writing stopped"
                        )
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

                try draw(composed, into: buffer, size: size, frame: index, total: total)
                let time = CMTime(value: CMTimeValue(index), timescale: framesPerSecond)
                guard adaptor.append(buffer, withPresentationTime: time) else {
                    throw Failure(reason: "the writer rejected a frame")
                }
            }

            input.markAsFinished()
            writer.endSession(
                atSourceTime: CMTime(value: CMTimeValue(Int(framesPerSecond) * seconds),
                                     timescale: framesPerSecond)
            )
            let done = DispatchSemaphore(value: 0)
            writer.finishWriting { done.signal() }
            done.wait()
            guard writer.status == .completed else {
                throw Failure(reason: writer.error?.localizedDescription ?? "finishWriting failed")
            }
        } catch let error {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private static func draw(
        _ image: CGImage,
        into buffer: CVPixelBuffer,
        size: CGSize,
        frame: Int,
        total: Int
    ) throws {
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

        let scale = zoomScale(frame: frame, total: total)
        let width = size.width * scale
        let height = size.height * scale
        context.interpolationQuality = .high
        context.draw(
            image,
            in: CGRect(
                x: (size.width - width) / 2,
                y: (size.height - height) / 2,
                width: width,
                height: height
            )
        )
    }

    /// 余弦从 1.0 出发、到 1.04 再回 1.0，首末帧一致，循环无缝。末帧取 `total` 的
    /// 位置（不是 `total - 1`），否则第 0 帧和第 95 帧会一样，循环时多停一拍。
    private static func zoomScale(frame: Int, total: Int) -> CGFloat {
        guard total > 1 else { return 1 }
        let phase = Double(frame) / Double(total) * 2 * Double.pi
        return 1 + zoom * CGFloat(0.5 - 0.5 * cos(phase))
    }
}
