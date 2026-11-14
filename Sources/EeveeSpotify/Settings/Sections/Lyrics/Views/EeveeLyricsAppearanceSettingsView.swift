import Foundation
import SwiftUI

/// 「歌词外观」页：字号 / 行距。
///
/// 从「歌词」页拆出来的两个理由：
/// · 那一页装的是**取词源与行为**（逐词、AMLL、Genius 回退、罗马音、自动翻译……），
///   字号属于"长什么样"，混在里面要翻很久才找得到；
/// · 字号倍率对**全屏歌词页、页内歌词层、锁屏歌词**三处都生效
///   （`AppleMusicLyricsOverlayView` 的 `.fullscreen` / `.player` 与
///   `LyricClipRenderer` 的 `textScale`），跟「逐词歌词」开关无关 —— 留在原来那个门禁里时，
///   关掉逐词就再也够不到字号。
///
/// 预览仍然只在 iOS 26+ 显示：它就是生产页的缩小版（`AppleMusicLyricsPage`）。
struct EeveeLyricsAppearanceSettingsView: View {
    @StateObject var viewModel = EeveeLyricsSettingsViewModel()

    var body: some View {
        List {
            lyricsTypographySection()

            NonIPadSpacerView()
        }
        .listStyle(InsetGroupedListStyle())
        .animation(.default, value: viewModel.animationValues)
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
}
