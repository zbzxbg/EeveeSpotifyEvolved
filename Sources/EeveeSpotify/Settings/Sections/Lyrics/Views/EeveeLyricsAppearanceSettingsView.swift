import Foundation
import SwiftUI

/// 「歌词外观」页：字号 / 行距 / 歌词背景颜色。
///
/// 从「歌词」页拆出来的理由：
/// · 那一页装的是**取词源与行为**（逐词、AMLL、Genius 回退、罗马音、自动翻译……），
///   字号属于"长什么样"，混在里面要翻很久才找得到；
/// · 字号倍率对**全屏歌词页、页内歌词层、锁屏歌词**三处都生效
///   （`AppleMusicLyricsOverlayView` 的 `.fullscreen` / `.player` 与
///   `LyricClipRenderer` 的 `textScale`），跟「逐词歌词」开关无关 —— 留在原来那个门禁里时，
///   关掉逐词就再也够不到字号。
///
/// 背景颜色那一节原来在「定制」页；那页拆掉之后归到这里 —— 它改的是歌词层本身的底色，
/// 与字号同属"歌词长什么样"。只有歌词替换启用时才显示（没有歌词层就没有底色可改）。
///
/// 预览仍然只在 iOS 26+ 显示：它就是生产页的缩小版（`AppleMusicLyricsPage`）。
struct EeveeLyricsAppearanceSettingsView: View {
    @StateObject var viewModel = EeveeLyricsSettingsViewModel()

    @State private var lyricsColors = UserDefaults.lyricsColors

    var body: some View {
        List {
            lyricsTypographySection()

            lyricsDuetSection()

            lyricsBackgroundColorSection()

            NonIPadSpacerView()
        }
        .listStyle(InsetGroupedListStyle())
        .animation(.default, value: viewModel.animationValues)
        .animation(.default, value: lyricsColors)
    }

    /// 「文字」：字号 / 行距两档倍率 + 一块实时预览。
    ///
    /// 为什么用**倍率**而不是几个固定档位：全屏歌词页与「歌词进播放器」那一层各有自己的
    /// 基准字号（22pt 对 22pt，但容器一高一矮、行距 15 对 26），固定档位会让两处各自跳变；
    /// 倍率让两处保持同一比例，见 `LyricsTypographyScale.applyingUserScale`。
    @ViewBuilder private func lyricsTypographySection() -> some View {
        Section {
            // 预览直接塞生产那一页的缩小版，所以它要 iOS 26 —— 滑块本身不设版本门。
            if #available(iOS 26.0, *) {
                LyricsTypographyPreview(typography: viewModel.previewTypography)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("lyrics_text_scale".localized)
                    Spacer()
                    // `Text(verbatim:)`：带插值的字面量会被当成 LocalizedStringKey。
                    Text(verbatim: "\(Int((viewModel.lyricsTextScale * 100).rounded()))%")
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }

                Slider(value: $viewModel.lyricsTextScale, in: 0.8...1.3, step: 0.05)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("lyrics_line_spacing".localized)
                    Spacer()
                    Text(verbatim: "\(Int((viewModel.lyricsLineSpacingScale * 100).rounded()))%")
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }

                Slider(value: $viewModel.lyricsLineSpacingScale, in: 0.7...1.5, step: 0.05)
            }

            Button("lyrics_typography_reset".localized) {
                viewModel.lyricsTextScale = 1
                viewModel.lyricsLineSpacingScale = 1
            }
            .disabled(
                viewModel.lyricsTextScale == 1
                    && viewModel.lyricsLineSpacingScale == 1
            )
        } header: {
            Text("lyrics_typography_section".localized)
        } footer: {
            Text("lyrics_typography_description".localized)
        }
    }

    /// 「对唱」：另一位歌手的行排到另一端。
    ///
    /// 为什么在「外观」里、而且只有一颗开关：它改的是**排版**（谁站哪边），不是取词行为；
    /// 数据来自 TTML 的 `ttm:agent`（AMLL / Apple 官方 TTML 两路），别的源没有歌手信息，
    /// 所以这一颗开关对那些源不起作用 —— 页脚把这一点写明，免得被当成"按了没反应"。
    @ViewBuilder private func lyricsDuetSection() -> some View {
        Section {
            Toggle(
                "lyrics_duet_layout".localized,
                isOn: Binding(
                    get: { NgzhwmSettingsViewModel.lyricsDuetLayout },
                    set: { NgzhwmSettingsViewModel.lyricsDuetLayout = $0 }
                )
            )
        } footer: {
            Text("lyrics_duet_layout_description".localized)
        }
    }

    /// 「歌词背景颜色」：两个开关（显示原始颜色 / 使用静态颜色）+ 取色器或标准参数。
    ///
    /// 只在**歌词替换**启用时显示：这一节改的是我们自己画的歌词层，来源选「不替换」时
    /// 根本没有这一层。
    ///
    /// 「标准参数」决定深色变浅、浅色变暗的程度 —— 它只在不使用静态颜色时才有意义，
    /// 所以两者是互斥的两条分支，不是叠加。
    @ViewBuilder private func lyricsBackgroundColorSection() -> some View {
        if UserDefaults.lyricsSource.isReplacingLyrics {
            Section(
                header: Text("lyrics_background_color_section".localized),
                footer: Text("lyrics_background_color_section_description".localized)
            ) {
                Toggle(
                    "display_original_colors".localized,
                    isOn: $lyricsColors.displayOriginalColors
                )

                Toggle(
                    "use_static_color".localized,
                    isOn: $lyricsColors.useStaticColor
                )

                if lyricsColors.useStaticColor {
                    ColorPicker(
                        "static_color".localized,
                        selection: Binding<Color>(
                            get: { Color(hex: lyricsColors.staticColor) },
                            set: { lyricsColors.staticColor = $0.hexString }
                        ),
                        supportsOpacity: false
                    )
                }
                else {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("color_normalization_factor".localized)

                        Slider(
                            value: $lyricsColors.normalizationFactor,
                            in: 0.2...0.8,
                            step: 0.1
                        )
                    }
                }
            }
            .onChange(of: lyricsColors) { value in
                UserDefaults.lyricsColors = value
            }
        }
    }
}
