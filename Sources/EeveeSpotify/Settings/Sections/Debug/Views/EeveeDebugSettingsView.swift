import SwiftUI

/// 「调试」页：只装**排查/验证型**开关（见 `EeveeDebugSettingsViewModel` 的说明）。
///
/// 三个 Section 全部**沿用原来的 l10n 键**（`ngzhwm_synthetic_line_timing` 等），
/// 所以不需要任何新增翻译；而且它们访问的 UserDefaults key 也没变
/// —— 用户设备上已经设过的值会原样保留。
///
/// ⚠️ 这里的开关是"待清理清单"，不是长期功能：
/// 验证完就写死 + 删 key + 删 l10n（先在歌词页、现在在这个页面上都待过的那几个），
/// 最终理想形态是这个页面**空着**。
struct EeveeDebugSettingsView: View {
    @StateObject var viewModel = EeveeDebugSettingsViewModel()

    var body: some View {
        List {
            // 「补全歌词时间轴」：Genius 这类纯文本源在这个版本上会被判成"不可用"，
            // 补一层按曲目时长估算的行级时间轴之后，歌词模块才会出现。
            //
            // 故意**没有 footer**：它的用途是排查"不补时间轴会怎样"，
            // 不需要一段解释文字（与页面上其它开关不同，它们都有 `_description`）。
            syntheticLineTimingSection()

            // 「给没有歌词卡片的曲目补一张」：往元素列表里补 `5`。
            // 同样没有 footer —— 用途是判定"404 曲目上那张卡是不是这个元素渲出来的"。
            injectLyricsCardElementSection()

            // 「强制歌词入口开关」：把服务端那条 `lyrics_entry_point_enabled` 钉成 true。
            lyricsEntryPointFlagSection()
        }
        .listStyle(GroupedListStyle())
        .animation(.default, value: viewModel.animationValues)
    }

    /// 「给无时间轴的歌词补时间轴」。
    @ViewBuilder private func syntheticLineTimingSection() -> some View {
        Section {
            Toggle(
                "ngzhwm_synthetic_line_timing".localized,
                isOn: $viewModel.syntheticLineTiming
            )
        }
    }

    /// 「给没有歌词卡片的曲目补一个卡片元素」。
    @ViewBuilder private func injectLyricsCardElementSection() -> some View {
        Section {
            Toggle(
                "ngzhwm_inject_lyrics_card_element".localized,
                isOn: $viewModel.injectLyricsCardElement
            )
        }
    }

    /// 「把服务端那条 `lyrics_entry_point_enabled` 钉成 true」。
    @ViewBuilder private func lyricsEntryPointFlagSection() -> some View {
        Section {
            Toggle(
                "ngzhwm_lyrics_entry_point_flag".localized,
                isOn: $viewModel.lyricsEntryPointFlag
            )
        }
    }
}
