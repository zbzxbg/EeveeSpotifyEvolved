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
            // 「补充模块5」：往元素列表里补 `5`。
            // 没有 footer —— 用途是判定"404 曲目上那张卡是不是这个元素渲出来的"。
            injectLyricsCardElementSection()

            // 「歌词入口开关」：把服务端那条 `lyrics_entry_point_enabled` 钉成 true。
            lyricsEntryPointFlagSection()

            // 「转储视图树」：给还没写的界面 hook 铺路（AMOLED / 隐藏区块 / 手势）。
            dumpViewTreeSection()

            // 「替换寻找歌词时的占位符」：**彩蛋**（用户 2026-10-12 点名要的），放在上面那一节下面。
            lyricsSearchPlaceholderEasterEggSection()
        }
                // ★ 2026-10-12：inset-grouped（胶囊卡片）—— 为什么、怎么做的见 `EeveeSettingsView` 顶部那段
        .listStyle(InsetGroupedListStyle())
        .animation(.default, value: viewModel.animationValues)
    }

    /// 「补充模块5」（往元素列表里补 `5` = 保留官方布局时那个歌词预览模块）。
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

    /// 「替换寻找歌词时的占位符」——用户 2026-10-12 点名要的**彩蛋**。**默认关**。
    ///
    /// 只做一件事：还在取词的时候，那句「正在查找歌词…」写成「少女祈祷中…」
    /// （改的只有 `NowPlayingLyricsPlate.noticeText()` 里"还在查"那一档，全仓库就那一处）。
    ///
    /// ⚠️ 本页的定位是"排查工具、验证完就删"，这一节是**例外**（用户要求放这里，它是个长期彩蛋）：
    ///    将来清理这一页时**别顺手删它**。
    @ViewBuilder private func lyricsSearchPlaceholderEasterEggSection() -> some View {
        Section(footer: Text("lyrics_search_placeholder_easter_egg_description".localized)) {
            Toggle(
                "lyrics_search_placeholder_easter_egg".localized,
                isOn: $viewModel.lyricsSearchPlaceholderEasterEgg
            )
        }
    }
}
