import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import UIKit

/// 把下载回来的短片变成"系统那个键要的形状"。
///
/// 系统对动态封面的验收标准是**画幅**：1:1 的键只收方图、3:4 的键只收竖图，差得多时整份
/// 丢掉、退回静态封面。Canvas 是竖屏（比 3:4 还窄），Apple Music 的 editorial video 则可能
/// 两个画幅各有一份，所以两条源都要经过这里裁一次，而不是原样交出去。
///
/// 画幅已经对上时直接返回原文件（不重新编码）；HLS 分片拼出来的文件即使画幅对，
/// 也要再导出一次 —— 那是为了把分片容器变成系统播放器更稳的 mp4。
enum AnimatedArtworkVideo {

    struct Failure: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    private static let maximumClipSeconds = 30.0

    /// 画幅容差。差 2% 以内系统就收，没必要为它重编码一遍。
    private static let aspectSlack: CGFloat = 0.02

    /// 裁到 `aspect` 并落到一个临时 mp4。调用方负责删除返回值（若与入参不同）。
    static func cropped(
        _ source: URL,
        to aspect: LockScreenArtwork.Aspect,
        alwaysExport: Bool
    ) async throws -> URL {
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            throw Failure(reason: "no video track")
        }

        let naturalSize = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)
        let nominalRate = (try? await track.load(.nominalFrameRate)) ?? 30
        let duration = try await asset.load(.duration)

        let shown = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let shownSize = CGSize(width: abs(shown.width), height: abs(shown.height))
        guard shownSize.width > 1, shownSize.height > 1 else {
            throw Failure(reason: "no picture")
        }

        let target = aspect.aspectRatio
        let sourceRatio = shownSize.width / shownSize.height
        if !alwaysExport, abs(sourceRatio - target) < aspectSlack {
            return source
        }

        let upright = preferredTransform.concatenating(
            CGAffineTransform(translationX: -shown.minX, y: -shown.minY)
        )

        // "填满目标画幅"= 先取中心那一块，再按最长边压到 960。两步必须一起进 layer 的
        // transform：只改 renderSize 不缩放内容，会变成裁左上角而不是缩放到画布。
        let cropped: CGSize
        if sourceRatio > target {
            cropped = CGSize(width: shownSize.height * target, height: shownSize.height)
        } else {
            cropped = CGSize(width: shownSize.width, height: shownSize.width / target)
        }
        let cap: CGFloat = 960
        let scale = min(1, cap / max(cropped.width, cropped.height))
        let render = CGSize(
            width: even(cropped.width * scale),
            height: even(cropped.height * scale)
        )
        let origin = CGPoint(
            x: (shownSize.width - cropped.width) / 2,
            y: (shownSize.height - cropped.height) / 2
        )

        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        let transform = upright
            .concatenating(CGAffineTransform(translationX: -origin.x, y: -origin.y))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
        layer.setTransform(transform, at: .zero)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layer]

        let composition = AVMutableVideoComposition()
        composition.renderSize = render
        composition.frameDuration = CMTime(value: 1, timescale: frameTimescale(nominalRate))
        composition.instructions = [instruction]

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("eevee-lockart-crop-\(UUID().uuidString).mp4")

        guard let export = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw Failure(reason: "no exporter")
        }
        export.outputURL = output
        export.outputFileType = .mp4
        export.videoComposition = composition

        let longest = CMTime(seconds: maximumClipSeconds, preferredTimescale: 600)
        if CMTimeCompare(duration, longest) > 0 {
            export.timeRange = CMTimeRange(start: .zero, duration: longest)
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { continuation.resume() }
        }

        guard export.status == .completed else {
            try? FileManager.default.removeItem(at: output)
            throw Failure(
                reason: export.error?.localizedDescription ?? "export did not finish"
            )
        }
        return output
    }

    /// 取缓存里那条片子的第一帧，给锁屏当加载期间的预览图。失败不是错误 —— 没有它
    /// 系统会继续用静态封面，视觉上只是多闪一下。
    static func previewImage(of url: URL, size: CGSize) async throws -> UIImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = size
        let (image, _) = try await generator.image(at: .zero)
        return UIImage(cgImage: image)
    }

    // MARK: - 工具

    private static func even(_ value: CGFloat) -> CGFloat {
        max(2, 2 * (value / 2).rounded(.down))
    }

    private static func frameTimescale(_ rate: Float) -> CMTimeScale {
        CMTimeScale(max(24, min(30, Int(rate.rounded()))))
    }
}
