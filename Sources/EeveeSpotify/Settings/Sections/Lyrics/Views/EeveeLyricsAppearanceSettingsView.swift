import Foundation
import SwiftUI

/// 「歌词外观」页：字号 / 行距 + 分享卡。
///
/// 从「歌词」页拆出来的两个理由：
/// · 那一页装的是**取词源与行为**（逐词、AMLL、Genius 回退、罗马音、自动翻译……），
///   字号与分享卡属于"长什么样"，混在里面要翻很久才找得到；
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
            shareCardSection()

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

    /// 「分享卡」：模板 / 画幅 / 背景 / 文字颜色 + 实时预览。
    ///
    /// 选项都很少，所以用分段选择器而不是菜单：这里最想给的是"换一下长什么样"，
    /// 上面那张预览会立刻跟着重画，不用分享出去才知道。
    @ViewBuilder private func shareCardSection() -> some View {
        Section {
            LyricShareCardPreview(content: viewModel.shareCardPreviewContent)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)

            Picker("share_card_template".localized, selection: $viewModel.shareCardTemplate) {
                Text("share_card_template_native".localized)
                    .tag(LyricShareCardTemplate.native)
                Text("share_card_template_polaroid".localized)
                    .tag(LyricShareCardTemplate.polaroid)
                Text("share_card_template_minimal".localized)
                    .tag(LyricShareCardTemplate.minimal)
            }
            .pickerStyle(.segmented)

            Picker("share_card_size".localized, selection: $viewModel.shareCardSize) {
                Text("9:16").tag(LyricShareCardSize.story)
                Text("4:5").tag(LyricShareCardSize.portrait)
                Text("1:1").tag(LyricShareCardSize.square)
            }
            .pickerStyle(.segmented)

            Picker("share_card_background".localized, selection: $viewModel.shareCardBackground) {
                Text("share_card_background_cover".localized)
                    .tag(LyricShareCardBackground.cover)
                Text("share_card_background_blur".localized)
                    .tag(LyricShareCardBackground.blurredCover)
                Text("share_card_background_black".localized)
                    .tag(LyricShareCardBackground.black)
            }
            .pickerStyle(.segmented)

            Picker("share_card_ink".localized, selection: $viewModel.shareCardInk) {
                Text("share_card_ink_auto".localized)
                    .tag(LyricShareCardInk.auto)
                Text("share_card_ink_black".localized)
                    .tag(LyricShareCardInk.black)
                Text("share_card_ink_white".localized)
                    .tag(LyricShareCardInk.white)
                Text("share_card_ink_custom".localized)
                    .tag(LyricShareCardInk.custom)
            }
            .pickerStyle(.segmented)

            if viewModel.shareCardInk == .custom {
                ColorPicker(
                    "share_card_ink_custom_value".localized,
                    selection: $viewModel.shareCardCustomInk,
                    supportsOpacity: false
                )
            }
        } header: {
            Text("share_card_section".localized)
        } footer: {
            Text("share_card_footer".localized)
        }
    }
}
