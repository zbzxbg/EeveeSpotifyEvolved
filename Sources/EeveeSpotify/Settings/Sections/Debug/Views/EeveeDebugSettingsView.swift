import SwiftUI

/// 「调试」页：排查/验证型开关 + 只读转储工具（见 `EeveeDebugSettingsViewModel` 的说明）。
///
/// 现在的几行分三类：
///   · **A/B 开关**（补充模块5 / 歌词入口开关）—— 会改行为、待定性，验完就写死 + 删 key + 删 l10n；
///   · **只读转储**（更详细的日志记录 = 视图树 + customize 响应体；某个类的方法/ivar）—— 只往日志里写，不改任何行为；
///   · **长期住户**：导出前脱敏（2026-10-17 从主设置页的「Debug」区搬来，默认开）。
///
/// ★★ 2026-10-30（用户）：「转储视图树，转储响应体两个融合，换成 更详细的日志记录」；
///   并删掉了「替换寻找歌词时的占位符」那颗彩蛋（连同 UserDefaults 键与 l10n）。
///
/// 所有 UserDefaults 键**都沿用旧的**（`ngzhwm_inject_lyrics_card_element` /
/// `redact_shared_log` / `dumpViewTree` / `dumpCustomizeBody` 等）⇒ 设备上已设的值原样保留；
/// 只有合并后的 `detailed_logging` 是新增的一条 l10n。
struct EeveeDebugSettingsView: View {
    @StateObject var viewModel = EeveeDebugSettingsViewModel()

    /// 「转储某个类」那个输入框的内容（本页唯一一处不需要 view model 的状态，
    /// 照 `redactSharedLogSection` 的先例直接用 `@State`）。
    @State private var dumpClassName = ""

    var body: some View {
        List {
            // 「补充模块5」：往元素列表里补 `5`。
            // 没有 footer —— 用途是判定"404 曲目上那张卡是不是这个元素渲出来的"。
            injectLyricsCardElementSection()

            // 「歌词入口开关」：把服务端那条 `lyrics_entry_point_enabled` 钉成 true。
            lyricsEntryPointFlagSection()

            // 「更详细的日志记录」：视图树 + customize 响应体两条转储合并成一颗。
            detailedLoggingSection()

            // 「转储某个类的方法/ivar」：与上面同一目的、答的是另一半问题
            //   —— 视图树给"谁在谁里面"，这个给"这个类里有什么"。
            dumpClassSection()

            // 「分享日志前脱敏」：**2026-10-17 用户要求从主设置页的「Debug」区搬进这里**。
            //   转储是把东西写进日志，这一条是"把日志发出去之前先假名化" —— 同一条线的最后一环。
            redactSharedLogSection()
        }
                // ★ 2026-10-12：inset-grouped（胶囊卡片）—— 为什么、怎么做的见 `EeveeSettingsView` 顶部那段
        .listStyle(InsetGroupedListStyle())
        .animation(.default, value: viewModel.animationValues)
    }

    /// 「补充模块5」（往元素列表里补 `5` = 保留官方布局时那个歌词预览模块）。
    @ViewBuilder private func injectLyricsCardElementSection() -> some View {
        Section {
            Toggle(
                "inject_lyrics_card_element".localized,
                isOn: $viewModel.injectLyricsCardElement
            )
        }
    }

    /// 「把服务端那条 `lyrics_entry_point_enabled` 钉成 true」。
    @ViewBuilder private func lyricsEntryPointFlagSection() -> some View {
        Section {
            Toggle(
                "lyrics_entry_point_flag".localized,
                isOn: $viewModel.lyricsEntryPointFlag
            )
        }
    }

    /// 「更详细的日志记录」：把**视图树**与**customize 响应体**两条转储合成一颗。
    ///
    /// ★★ 2026-10-30（用户）：「转储视图树，转储响应体两个融合，换成 更详细的日志记录」。
    ///   打开 ⇒ 同时写视图树（`ViewTreeDumper`，每 2s 一行）与 customize 响应体
    ///   （`SpotifyResponsePatcher.dumpCustomizeBodyIfEnabled`，只在你需要换种子快照时用）。
    ///   底下仍是原来的两个键，备份与已设值不受影响（见 `UserDefaults.detailedLogging`）。
    @ViewBuilder private func detailedLoggingSection() -> some View {
        Section {
            Toggle(
                "detailed_logging".localized,
                isOn: $viewModel.detailedLogging
            )
        }
    }

    /// 「转储某个类」—— 把类名 + 方法表 + ivar 表写进调试日志（见 `ClassDumper`）。
    ///
    /// 与上面那节的分工：`ViewTreeDumper` 答"谁在谁里面"，这里答"这个类里有什么"。
    /// 界面工作反复卡在后者上（AMOLED 的导航栏、隐藏区块、播放器手势都卡过）。
    ///
    /// ⚠️ 只读：runtime 反射**枚举**而已，找到的方法一个都不会被调用 ——
    /// 猜 `value(forKey:)` 在键不存在时会抛不可捕获的异常、把 Spotify 直接弄崩。
    /// 同样属于"验证完就删"的临时工具（本页定位）。
    @ViewBuilder private func dumpClassSection() -> some View {
        Section(footer: Text("dump_class_description".localized)) {
            TextField("dump_class_placeholder".localized, text: $dumpClassName)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            Button("dump_class_action".localized) {
                ClassDumper.dump(name: dumpClassName)
            }
            .disabled(dumpClassName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    /// 「分享日志前脱敏」——**2026-10-17 用户要求从主设置页的「Debug」区搬进「调试」页**。
    ///
    /// 默认**开**（`UserDefaults.redactSharedLog` 的 getter：键不存在 ⇒ true）：
    /// 导出这个动作 99% 是为了把日志发给别人，而日志主体就是"你听了哪些歌"。
    ///
    /// 只影响**导出**的那一份（`DebugLogSanitizer.sharedLogFile(from:redact:)`，出口在
    /// `EeveeSettingsView` 的导出按钮那一节）：写入口的凭证/设备标识脱敏没有开关、也不受它控制。
    /// 脱敏版生成失败时导出会**直接报错**，绝不回退明文（fail-closed）。
    ///
    /// ⚠️ 这一节与上面几节不同：不是"验证完就删"的临时件，而是**导出的隐私默认值**。
    ///    它不在 `EeveeDebugSettingsViewModel` 里（沿用 `dumpClassSection` 的先例，
    ///    用 `Binding` 直接读写）—— 没有新状态要记，l10n 键与 UserDefaults 键都没变。
    @ViewBuilder private func redactSharedLogSection() -> some View {
        Section(footer: Text("redact_shared_log_description".localized)) {
            Toggle(
                "redact_shared_log".localized,
                isOn: Binding<Bool>(
                    get: { UserDefaults.redactSharedLog },
                    set: { UserDefaults.redactSharedLog = $0 }
                )
            )
        }
    }
}
