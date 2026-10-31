// 每帧时钟 / 取色底 / SwiftUI 桥。从 `AppleMusicLyricsOverlay.swift` 原样拆出。
import SwiftUI
import UIKit

// ⚠️ `@available(iOS 26.0, *)` 不能丢：这个时钟只服务于 iOS 26 那一层自绘歌词
// （`AppleMusicLyricsOverlayHost` 就是 `@available(iOS 26.0, *)` 的）。
// 的拆分把这条属性漏在了原文件末尾，CI 直接报 "expected declaration"。
@available(iOS 26.0, *)
final class AppleMusicLyricsClock: ObservableObject {
    /// 当前播放时间（秒）。每帧更新，驱动整页重绘。
    @Published var playbackTime: TimeInterval = 0
    /// 是否跟随播放（暂停时停止刷新以省电）。
    var isFollowing: Bool = true

    /// 由宿主每帧提交。时间没变就不发通知，省掉一次整页 diff。
    func submit(seconds: TimeInterval) {
        guard isFollowing else { return }
        guard seconds.isFinite else { return }
        guard abs(seconds - playbackTime) > 0.0005 else { return }
        playbackTime = seconds
    }
}

// MARK: - SwiftUI 视图

@available(iOS 26.0, *)
enum AppleMusicLyricsBackdrop {
    /// 背景：模糊封面（复用 `LyricsBackdropView` 的取图与缓存/材质逻辑）。
    ///
    /// `style` 由调用方按「是不是全屏」决定：
    /// · 全屏 → `.stage`：铺满整屏 + 均匀暗化
    /// · 预览 → `.card`：只在卡片内，上下暗中间透
    ///
    /// - Parameter solid: 全屏专档。见 `LyricsBackdropView.solidStageScrimAlpha`：
    /// 全屏时背景要负责"压住"底下的原生页面（我们不再动任何原生视图），
    /// 所以需要比默认更实。
    @ViewBuilder
    static func makeBackground(
        style: LyricsBackdropView.Style,
        solid: Bool = false
    ) -> AnyView {
        AnyView(
            LyricsBackdropRepresentable(style: style, solid: solid)
                .ignoresSafeArea()
        )
    }
}

/// 把已有的 UIKit `LyricsBackdropView` 包进 SwiftUI。复用它的取图/模糊/缓存/材质，
/// 避免同一套封面逻辑存在两份实现。
@available(iOS 26.0, *)
struct LyricsBackdropRepresentable: UIViewRepresentable {

    /// 背景样式：全屏用舞台式（铺满整屏 + 均匀暗化），预览用卡片式。
    let style: LyricsBackdropView.Style
    /// 是否走"实心"档（全屏）。
    let solid: Bool

    func makeUIView(context: Context) -> LyricsBackdropView {
        let view = LyricsBackdropView()
        view.style = style
        view.solid = solid
        // Apple Music 层是"我们替换了原生内容"的那条路：必须不透明，
        // 否则会露出底下 Spotify 原生的歌词与控件，和我们自己画的叠在一起。
        view.isBackdropOpaque = true
        view.configure(
            baseColor: .black,
            showsArtwork: true,
            material: NgzhwmSettingsViewModel.isLyricsBackdropMaterialEnabled
        )
        return view
    }

    func updateUIView(_ uiView: LyricsBackdropView, context: Context) {
        // 内嵌 ↔ 全屏切换时样式会变（stage ↔ card），这里让它跟着走，
        // 不用重建 hosting controller。
        uiView.style = style
        uiView.solid = solid
        uiView.isBackdropOpaque = true
    }
}
