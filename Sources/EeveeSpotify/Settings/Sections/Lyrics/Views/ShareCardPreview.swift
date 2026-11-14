import SwiftUI
import UIKit

/// 设置页「分享卡」那块里的实时预览。
///
/// 预览和成品走**同一个渲染器**（`LyricShareCardRenderer`），所以模板 / 画幅 / 背景 /
/// 文字颜色四组选项在这里看到什么，长按分享出来就是什么。没有封面时用一张合成图代替 ——
/// 模糊背景那一档在真机上靠的就是这张图。
struct LyricShareCardPreview: View {

    let content: LyricShareCardRenderer.Content

    @State private var image: UIImage?

    /// 只在影响画面的选项变化时重渲；`content` 里其它字段预览用不到。
    private var fingerprint: String {
        [
            content.template.rawValue,
            content.background.rawValue,
            content.ink.rawValue,
            content.size.rawValue,
            content.customInkHex ?? ""
        ].joined(separator: "|")
    }

    /// 预览高度固定 300，宽度按画幅算 —— 这样切换 9:16 / 4:5 / 1:1 时轮廓会真的变。
    private static let previewHeight: CGFloat = 300

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(
                        width: Self.previewHeight * content.size.aspectRatio,
                        height: Self.previewHeight
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                Color.clear
                    .frame(
                        width: Self.previewHeight * content.size.aspectRatio,
                        height: Self.previewHeight
                    )
            }
        }
        .frame(maxWidth: .infinity)
        .task(id: fingerprint) {
            image = await Self.render(content)
        }
    }

    private static func render(
        _ content: LyricShareCardRenderer.Content
    ) async -> UIImage {
        await withCheckedContinuation { (continuation: CheckedContinuation<UIImage, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var sample = content
                sample.cover = sampleCover
                let image = LyricShareCardRenderer.image(for: sample)
                continuation.resume(returning: image)
            }
        }
    }

    /// 预览用的"封面"：一张夜空渐变 + 一点星光，纯粹为了看出模糊背景那一档的观感。
    private static let sampleCover: UIImage = {
        let size = CGSize(width: 640, height: 640)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let colors = [
                UIColor(red: 0.08, green: 0.14, blue: 0.28, alpha: 1).cgColor,
                UIColor(red: 0.30, green: 0.58, blue: 0.74, alpha: 1).cgColor
            ] as CFArray
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors,
                locations: [0, 1]
            ) {
                context.cgContext.drawLinearGradient(
                    gradient,
                    start: .zero,
                    end: CGPoint(x: size.width, y: size.height),
                    options: []
                )
            }
            context.cgContext.setFillColor(UIColor.white.withAlphaComponent(0.9).cgColor)
            context.cgContext.fillEllipse(
                in: CGRect(x: 460, y: 130, width: 7, height: 7)
            )
            context.cgContext.setFillColor(UIColor.white.withAlphaComponent(0.55).cgColor)
            context.cgContext.fillEllipse(
                in: CGRect(x: 150, y: 420, width: 4, height: 4)
            )
        }
    }()
}
