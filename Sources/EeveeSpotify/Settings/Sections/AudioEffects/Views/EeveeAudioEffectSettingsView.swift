import SwiftUI

/// 「音频效果」页 —— 十段图形 EQ + 前置增益（`AudioDSP`）。
///
/// 所有改动都是"滑杆一动就重算系数"，不需要重启；唯一需要重启的是**第一次打开**：
/// 音频图的回调是在 Spotify 启动时挂上的，我们的包装要等到下一次挂回调才会生效，
/// 状态行会如实显示"已接管 / 还没接管"，不玩猜的。
struct EeveeAudioEffectSettingsView: View {

    /// 本页拥有的键（写属性名即可 —— 本仓库的键名与属性名同名）。
    private static let ownedKeys = [
        "dspEnabled",
        "dspPreampDb",
        "dspBandGainsDb",
        "dspPreset",
    ]

    /// 「自己调过」不是 `AudioDSPPreset` 的档位，但选择器要能显示它。
    private static let customPreset = "custom"

    @State private var enabled = UserDefaults.dspEnabled
    @State private var preamp = UserDefaults.dspPreampDb
    @State private var gains = UserDefaults.dspBandGainsDb
    @State private var preset = UserDefaults.dspPreset
    @State private var insertActive = AudioDSP.isInsertActive

    var body: some View {
        List {
            Section(footer: Text("audio_effects_description".localized)) {
                Toggle("audio_effects_enabled".localized, isOn: $enabled)
                    .onChange(of: enabled) { value in
                        UserDefaults.dspEnabled = value
                        AudioDSP.syncWithSettings()
                        insertActive = AudioDSP.isInsertActive
                    }

                statusRow
            }

            Section(header: Text("audio_effects_preamp".localized)) {
                HStack(spacing: 10) {
                    Slider(value: $preamp, in: -12...6, step: 0.5)
                        .onChange(of: preamp) { value in
                            UserDefaults.dspPreampDb = value
                            AudioDSP.reloadParameters()
                        }
                    Text(verbatim: String(format: "%+.1f dB", preamp))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                        .frame(width: 58, alignment: .trailing)
                }
            }

            Section(header: Text("audio_effects_equalizer".localized)) {
                ForEach(Array(AudioDSPBands.frequencies.enumerated()), id: \.offset) { index, frequency in
                    bandRow(index: index, frequency: frequency)
                }
            }

            Section(header: Text("audio_effects_presets".localized)) {
                Picker("audio_effects_presets".localized, selection: $preset) {
                    ForEach(AudioDSPPreset.allCases, id: \.self) { value in
                        Text(value.titleKey.localized).tag(value.rawValue)
                    }
                    if preset == Self.customPreset {
                        Text("audio_effects_preset_custom".localized).tag(Self.customPreset)
                    }
                }
                .onChange(of: preset) { value in
                    applyPreset(named: value)
                }
            }

            SettingsResetSection(
                keys: Self.ownedKeys,
                afterReset: {
                    // 键回默认（全直通）之后：影子值跟上，并把系数重算一遍。
                    enabled = UserDefaults.dspEnabled
                    preamp = UserDefaults.dspPreampDb
                    gains = UserDefaults.dspBandGainsDb
                    preset = UserDefaults.dspPreset
                    AudioDSP.syncWithSettings()
                    insertActive = AudioDSP.isInsertActive
                }
            )
        }
                // inset-grouped（胶囊卡片）—— 为什么、怎么做的见 `EeveeSettingsView` 顶部那段
        .listStyle(InsetGroupedListStyle())
        .onAppear {
            enabled = UserDefaults.dspEnabled
            preamp = UserDefaults.dspPreampDb
            gains = UserDefaults.dspBandGainsDb
            preset = UserDefaults.dspPreset
            AudioDSP.syncWithSettings()
            insertActive = AudioDSP.isInsertActive
        }
    }

    /// 一行：频点 + 滑杆 + 当前 dB。拖动时把预设切到「自定义」，避免选择器说谎。
    private func bandRow(index: Int, frequency: Double) -> some View {
        HStack(spacing: 10) {
            Text(verbatim: AudioDSPBands.label(for: frequency))
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 56, alignment: .leading)

            Slider(
                value: Binding(
                    get: { gains[index] },
                    set: { value in
                        gains[index] = value
                        UserDefaults.dspBandGainsDb = gains
                        UserDefaults.dspPreset = Self.customPreset
                        preset = Self.customPreset
                        AudioDSP.reloadParameters()
                    }
                ),
                in: AudioDSPBands.minGainDb...AudioDSPBands.maxGainDb,
                step: 0.5
            )

            Text(verbatim: String(format: "%+.1f", gains[index]))
                .font(.caption)
                .monospacedDigit()
                .foregroundColor(.secondary)
                .frame(width: 42, alignment: .trailing)
        }
    }

    /// 状态行：这一版有没有真的接管音频输出。`AudioDSP.isInsertActive` 不是 `@Published`，
    /// 所以在进页面 / 动开关 / 重置之后各重读一次就够。
    private var statusRow: some View {
        HStack(spacing: 8) {
            Image(systemName: insertActive ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundColor(insertActive ? Color.green : Color.secondary)
            Text(
                insertActive
                    ? "audio_effects_status_active".localized
                    : "audio_effects_status_restart".localized
            )
            .font(.footnote)
            .foregroundColor(.secondary)
        }
    }

    private func applyPreset(named name: String) {
        guard let selected = AudioDSPPreset(rawValue: name) else { return }
        gains = selected.gainsDb
        preamp = selected.preampDb
        UserDefaults.dspBandGainsDb = gains
        UserDefaults.dspPreampDb = preamp
        UserDefaults.dspPreset = name
        AudioDSP.reloadParameters()
    }
}
