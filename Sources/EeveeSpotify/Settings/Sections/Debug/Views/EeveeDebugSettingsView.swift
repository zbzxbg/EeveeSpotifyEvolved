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

            // 「转储视图树」：给还没写的界面 hook 铺路（AMOLED / 隐藏区块 / 手势）。
            dumpViewTreeSection()
        }
                // ★ 2026-10-12：inset-grouped（胶囊卡片）—— 为什么、怎么做的见 `EeveeSettingsView` 顶部那段
        .listStyle(InsetGroupedListStyle())
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

    /// 「转储视图树」：把当前屏幕的视图结构每 2s 写一行进调试日志。
    ///
    /// ⚠️ 这也是**临时工具**（本页的定位就是"验证完就删"）：类名拿到之后就去写真正的
    /// hook，那时这一节连同 key 一起删。三条纪律见 `ViewTreeDumper` 的说明。
    @ViewBuilder private func dumpViewTreeSection() -> some View {
        Section(footer: Text("dump_view_tree_description".localized)) {
            Toggle(
                "dump_view_tree".localized,
                isOn: $viewModel.dumpViewTree
            )
        }
    }
}
