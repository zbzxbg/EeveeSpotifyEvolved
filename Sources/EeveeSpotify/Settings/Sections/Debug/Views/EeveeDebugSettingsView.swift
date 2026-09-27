import SwiftUI

/// 「调试」页：只装**排查/验证型**开关（见 `EeveeDebugSettingsViewModel` 的说明）。
///
/// 两个 Section 全部**沿用原来的 l10n 键**（`ngzhwm_inject_lyrics_card_element` 等），
/// 所以不需要任何新增翻译；而且它们访问的 UserDefaults key 也没变
/// —— 用户设备上已经设过的值会原样保留。
///
/// ⚠️ 这里的开关是"待清理清单"，不是长期功能：
/// 验证完就写死 + 删 key + 删 l10n（`hideOfficialLyrics` 与 `syntheticLineTiming` 都是这么走的），
/// 最终理想形态是这个页面**空着**。
struct EeveeDebugSettingsView: View {
    @StateObject var viewModel = EeveeDebugSettingsViewModel()

    var body: some View {
        List {
            // 「给没有歌词卡片的曲目补一张」：往元素列表里补 `5`。
            // 没有 footer —— 用途是判定"404 曲目上那张卡是不是这个元素渲出来的"。
            injectLyricsCardElementSection()

            // 「强制歌词入口开关」：把服务端那条 `lyrics_entry_point_enabled` 钉成 true。
            lyricsEntryPointFlagSection()
        }
        .listStyle(GroupedListStyle())
        .animation(.default, value: viewModel.animationValues)
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
