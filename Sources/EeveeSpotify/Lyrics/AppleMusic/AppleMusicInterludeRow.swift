import SwiftUI

// 本项目新增（对齐 MeloX `AppleMusicLyricInterludeView` 的点阵部分，GPL-3.0）：
// AM 歌词页里那条**间奏行** —— 用户说的「三个呼吸点」。
//
// 三层分工（谁都能单独换掉）：
//   · `LyricInterludeTimeline`   —— 哪两句之间算间奏、这一拍该不该显示（纯逻辑）；
//   · `AppleMusicInterludeDotsPresentation` —— 这一拍三个点各多亮、整排缩放/淡出（纯数学）；
//   · 本文件                     —— 把那三个数画出来（几何来自 `AppleMusicInterludeMotionProfile`）。
//
// ⚠️ **时钟不在这里**：这一页的宿主 `AppleMusicLyricsTickView` 已经用 CADisplayLink
//    每帧把 `playbackTime` 送进来（见 `AppleMusicLyricsPage` 顶部"为什么不用
//    `TimelineView`"那一段），所以这里只做"给定播放时间 → 画成什么样"的映射，
//    不自己开计时器、也不做补间动画 —— 补间由 `presentation` 逐帧算出来，
//    这样点阵与歌词走的是**同一条时钟**，不会互相错拍。
//
// 与 MeloX / Apple Music 真机行为的已知差别（都在这一层，改不改一眼能看见）：
//   1. **不做"提升"**：点阵退出完到下一句真正开始之间（约 1.8s），高亮仍留在上一句
//      —— 本项目的焦点由 `LyricPlaybackTimeline` 独家决定，不在这里抢。
//      Apple Music 会把下一句提前变成焦点行；要接的话数据已经在了
//      （`LyricInterludeTimeline.position(at:in:)` 的 `promotedLyricID`）。
//   2. 间奏行**不参与**"点行跳转"：它没有可 seek 的歌词时间，点它不做任何事
//      （MeloX 把它交给 `onInterfaceInteraction` 去收起界面，本项目没有那一层）。

@available(iOS 26.0, *)
struct AppleMusicInterludeRow: View {

    /// 这一行代表哪一段间奏。
    let interlude: LyricInterlude
    /// 这一拍该显示什么（整页算一次，由 `LyricInterludeTimeline.position(at:in:)` 给出，
    /// **不要**每行各算一遍 —— 那是 O(间奏数) × 行数）。
    let position: LyricInterludePlaybackPosition
    /// 当前播放时间（每帧由宿主更新）。
    let playbackTime: TimeInterval
    /// 点阵颜色：跟歌词同一个主色（Apple Music 那边是白色，本项目跟着主题色走）。
    let primaryColor: Color

    /// 「减弱动态效果」：不呼吸、不冲峰，只按阶段点亮（`presentation` 里有对应的一档）。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static var profile: AppleMusicInterludeMotionProfile { .iOS26_6 }

    /// 点阵此刻是否归这一行。
    ///
    /// ⚠️ 判据用 `visibleInterludeID` 而不是"播放时间落在间奏里"：生命的最后一段
    /// （点已画空、下一句还没开始）槽位**仍然**归它 —— 那时整排不透明度已经是 0，
    /// 但高度照样要占着，否则下面的歌词会在这 1.8s 里往上跳一截。
    private var isVisible: Bool {
        position.visibleInterludeID == interlude.id
    }

    var body: some View {
        Group {
            if isVisible {
                dots(
                    presentation: AppleMusicInterludeDotsPresentation.make(
                        playbackTime: playbackTime,
                        interlude: interlude,
                        reducesMotion: reduceMotion,
                        profile: Self.profile
                    )
                )
            } else {
                // 驻留（resident）行：不显示时也占着 40pt，见上面 `isVisible` 的说明。
                Color.clear
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: Self.profile.viewHeight,
            maxHeight: Self.profile.viewHeight,
            alignment: .leading
        )
        // 它表达的是"这里有一段没人唱"，不是可读、可点的一行 —— 别让读屏把它念出来。
        .accessibilityHidden(true)
    }

    /// 三个点。
    ///
    /// ⚠️ 缩放锚点必须用 `dotAnchorX(at:)`：外侧两点是**越界锚点**（1.8 / −0.8），
    /// 于是整排缩放时外两点朝外"展开"、而不是从中心一起鼓起来 ——
    /// 那一下冲峰的样子就是这么来的（把锚点改成 0.5 会明显不像 Apple Music）。
    private func dots(
        presentation: AppleMusicInterludeDotsPresentation
    ) -> some View {
        HStack(spacing: Self.profile.dotMargin) {
            ForEach(presentation.dotOpacities.indices, id: \.self) { index in
                Circle()
                    .fill(primaryColor.opacity(presentation.dotOpacities[index]))
                    .frame(
                        width: Self.profile.dotLength,
                        height: Self.profile.dotLength
                    )
                    .scaleEffect(
                        presentation.scale,
                        anchor: UnitPoint(
                            x: Self.profile.dotAnchorX(at: index),
                            y: 0.5
                        )
                    )
            }
        }
        .frame(
            width: Self.profile.contentWidth,
            height: Self.profile.viewHeight,
            alignment: .leading
        )
        .opacity(presentation.opacity)
    }
}
