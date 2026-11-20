import SwiftUI

/// 「调试」页：排查/验证型开关 + 只读转储工具（见 `EeveeDebugSettingsViewModel`）。
///
/// 现在的几行分三类：
/// · **A/B 开关**（补充模块5 / 歌词入口开关）—— 会改行为、待定性，验完就写死 + 删 key + 删 l10n；
/// · **只读转储**（更详细的日志记录 = 视图树 + customize 响应体）—— 不改任何行为；
/// · **长期住户**：导出前脱敏，默认开。
///
/// 所有 UserDefaults 键**都沿用旧的**（`ngzhwm_inject_lyrics_card_element` /
/// `redact_shared_log` / `dumpViewTree` / `dumpCustomizeBody` 等）⇒ 设备上已设的值原样保留；
/// 只有合并后的 `detailed_logging` 是新增的一条 l10n。
struct EeveeDebugSettingsView: View {
    @StateObject var viewModel = EeveeDebugSettingsViewModel()

    /// 「转储某个类」那个输入框的内容（本页唯一一处不需要 view model 的状态，
    /// 照 `redactSharedLogSection` 的先例直接用 `@State`）。
    @State private var dumpClassName = ""

    /// 「测试 Apple Music 令牌」的结果（每步一行，失败停在那一步）。
    @State private var appleSelfTestLines: [String] = []

    var body: some View {
        List {
            // 顶部警示：这一页是排查开关，不是日常设置。
            // 这里的开关会改行为（补元素 / 钉入口），也会持续把视图树与响应体写进调试日志
            // （文件变大，且可能带上曲目与账号相关信息）。日志只在本机，导出时才离开设备 ——
            // 所以"导出前脱敏"必须留在开的位置。不弹窗、不拦操作，只把后果写在最上面。
            debugWarningSection()

            // 「补充模块5」：往元素列表里补 `5`。
            // 没有 footer —— 用途是判定"404 曲目上那张卡是不是这个元素渲出来的"。
            injectLyricsCardElementSection()

            // 「歌词入口开关」：把服务端那条 `lyrics_entry_point_enabled` 钉成 true。
            lyricsEntryPointFlagSection()

            // 「更详细的日志记录」：视图树 + customize 响应体两条转储合并成一颗。
            detailedLoggingSection()

            // 「音频输出探针」：只读诊断，确认 9.2.0 的 RemoteIO 能不能拿到 PCM。
            audioTapProbeSection()

            // 「测试 Apple Music 令牌」：把令牌 / storefront / 搜索 / 取词四步各跑一遍。
            appleMusicSelfTestSection()

            // 「转储某个类的方法/ivar」：与上面同一目的、答的是另一半问题
            // —— 视图树给"谁在谁里面"，这个给"这个类里有什么"。
            dumpClassSection()

            // 「分享日志前脱敏」：**Debug区搬进这里**。
            // 转储是把东西写进日志，这一条是"把日志发出去之前先假名化" —— 同一条线的最后一环。
            redactSharedLogSection()
        }
                // inset-grouped（胶囊卡片）—— 为什么、怎么做的见 `EeveeSettingsView` 顶部那段
        .listStyle(InsetGroupedListStyle())
        .animation(.default, value: viewModel.animationValues)
    }

    /// 顶部警示：只陈述后果，不拦操作（排查时它不该碍事）。
    ///
    /// 写法照「实验」页那一格：独立 Section、footnote、次要色、左对齐、长文本自动换行。
    /// 文字直接用字面量，**不走本地化** —— 这一页是给排查的人看的，26 种语言各翻一遍没有意义。
    @ViewBuilder private func debugWarningSection() -> some View {
        Section {
            Text(verbatim: "请注意：这里的开关会改变 Spotify 行为，在不了解这些功能的用途的情况下，请不要随便开关任何选项或修改任何值。否则可能造成日志冗余，隐私泄露等日常使用不该出现的问题。")
                .font(.footnote)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
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
    /// 「转储视图树，转储响应体两个融合，换成 更详细的日志记录」。
    /// 打开 ⇒ 同时写视图树（`ViewTreeDumper`，每 2s 一行）与 customize 响应体
    /// （`SpotifyResponsePatcher.dumpCustomizeBodyIfEnabled`，只在你需要换种子快照时用）。
    /// 底下仍是原来的两个键，备份与已设值不受影响（见 `UserDefaults.detailedLogging`）。
    @ViewBuilder private func detailedLoggingSection() -> some View {
        Section {
            Toggle(
                "detailed_logging".localized,
                isOn: $viewModel.detailedLogging
            )
        }
    }

    /// 「音频输出探针」—— 只读：记录 RemoteIO 的格式 + PostRender 的 RMS，
    /// 用来确认 9.2.0 上能不能拿到解码后的 PCM（见 `AudioTapProbe`）。
    ///
    /// 默认关；打开即装 hook，不需要重启 —— 第一次拿到数据要等下一次
    /// `AudioOutputUnitStart`（开始播放 / 换歌 / 暂停再播）。
    ///
    /// 页脚说明已删掉（这一页只留开关与顶部那一句警示）。
    @ViewBuilder private func audioTapProbeSection() -> some View {
        Section {
            Toggle(
                "audio_tap_probe".localized,
                isOn: $viewModel.audioTapProbe
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
        Section {
            TextField("dump_class_placeholder".localized, text: $dumpClassName)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            Button("dump_class_action".localized) {
                ClassDumper.dump(name: dumpClassName)
            }
            .disabled(dumpClassName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    /// 「测试 Apple Music 令牌」：结果直接画在按钮下面，同时写调试日志。
    @ViewBuilder private func appleMusicSelfTestSection() -> some View {
        Section(
            header: Text("apple_self_test_section".localized),
            footer: Text("apple_self_test_description".localized)
        ) {
            Button("apple_self_test_run".localized) {
                appleSelfTestLines = AppleMusicOfficialTtmlLyricsRepository.runTokenSelfTest()
            }
            if !appleSelfTestLines.isEmpty {
                Text(appleSelfTestLines.joined(separator: "\n"))
                    .font(.caption)
                    .monospaced()
                    .textSelection(.enabled)
            }
        }
    }

    /// 「分享日志前脱敏」。
    ///
    /// 默认**开**（`UserDefaults.redactSharedLog` 的 getter：键不存在 ⇒ true）：
    /// 导出这个动作 99% 是为了把日志发给别人，而日志主体就是"你听了哪些歌"。
    ///
    /// 只影响**导出**的那一份（`DebugLogSanitizer.sharedLogFile(from:redact:)`，出口在
    /// `EeveeSettingsView` 的导出按钮那一节）；写入口的凭证/设备标识脱敏没有开关、也不受它控制。
    /// 脱敏版生成失败时导出会**直接报错**，绝不回退明文（fail-closed）。
    ///
    /// ⚠️ 这一节不是"验证完就删"的临时件，而是**导出的隐私默认值**。它不在
    /// `EeveeDebugSettingsViewModel` 里（沿用 `dumpClassSection` 的先例，用 `Binding` 直接读写）。
    @ViewBuilder private func redactSharedLogSection() -> some View {
        Section {
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
