import SwiftUI
import UIKit

/// 「音频与手势」页：把原来分开的音频与设备能力四件事并成一页。
///
/// 四节，各管一件事：
/// · **音频效果** —— 前置增益 / 架式 / 十段 EQ / 压缩器 / 交叉馈送（`AudioDSP`）；
/// · **律动** —— 封面跟着低频起伏（`AudioReactiveEngine`）；
/// · **节拍触感** —— 鼓点变成轻触（同一个引擎，Taptic Engine）；
/// · **头部手势** —— AirPods 点头 / 摇头切歌（`HeadGestureControls`，走 CoreMotion）。
///
/// 为什么并成一页：前两者跑在同一条解码后的音频上（一个改样本、一个只读特征），
/// 后两者是设备能力；它们默认全关、出问题时的表现又常常要一起看，入口却各占一行。
/// 各功能的生效时机不同：音频效果的滑杆一动就重算系数，但**第一次接管**仍要等下一次
/// 音频回调（状态行会如实显示）；律动 / 触感 / 头部手势当场起停，不必重启。
struct EeveeAudioSettingsView: View {

    /// 本页拥有的键（写属性名即可 —— 本仓库的键名与属性名同名）。
    /// 四节各带自己的键，合成一页后「重置本页」的范围是原来三页的并集。
    private static let ownedKeys = [
        // 音频效果（`AudioDSP`）
        "dspEnabled",
        "dspPreampDb",
        "dspBandGainsDb",
        "dspPreset",
        "dspLowShelfDb",
        "dspHighShelfDb",
        "dspCompanderAmount",
        "dspCrossfeedLevel",
        // 律动与节拍触感（`AudioReactiveEngine`）
        "coverPulseEnabled",
        "musicHapticsEnabled",
        "musicHapticsStrength",
        // 头部手势（`HeadGestureControls`）
        "headGestureControlsEnabled",
    ]

    /// 「自己调过」不是 `AudioDSPPreset` 的档位，但选择器要能显示它。
    private static let customPreset = "custom"

    // ── 音频效果
    @State private var enabled = UserDefaults.dspEnabled
    @State private var preamp = UserDefaults.dspPreampDb
    @State private var gains = UserDefaults.dspBandGainsDb
    @State private var preset = UserDefaults.dspPreset
    @State private var lowShelf = UserDefaults.dspLowShelfDb
    @State private var highShelf = UserDefaults.dspHighShelfDb
    @State private var compander = UserDefaults.dspCompanderAmount
    @State private var crossfeed = UserDefaults.dspCrossfeedLevel
    @State private var insertActive = AudioDSP.isInsertActive

    // ── 律动与节拍触感
    @State private var coverPulse = UserDefaults.coverPulseEnabled
    @State private var musicHaptics = UserDefaults.musicHapticsEnabled
    @State private var musicHapticsStrength = UserDefaults.musicHapticsStrength

    // ── 头部手势
    @State private var headGestures = UserDefaults.headGestureControlsEnabled
    /// 「现在有没有能出姿态数据的耳机」不是 `@Published`，所以在进页面、动开关、重置之后
    /// 各重读一次就够 —— 它只在耳机插拔时变。
    @State private var motionAvailable = HeadGestureControls.isMotionAvailable

    var body: some View {
        List {
            // ── 音频效果
            Section(
                header: Text("audio_effects_title".localized),
                footer: Text("audio_effects_description".localized)
            ) {
                Toggle("audio_effects_enabled".localized, isOn: $enabled)
                    .onChange(of: enabled) { value in
                        UserDefaults.dspEnabled = value
                        AudioDSP.syncWithSettings()
                        insertActive = AudioDSP.isInsertActive
                    }

                audioInsertStatusRow
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

            // 架式放在十段之前：它是"整体往哪边偏"，十段是"具体哪个频点"，先粗后细。
            Section(
                header: Text("audio_effects_shelves".localized),
                footer: Text("audio_effects_shelves_description".localized)
            ) {
                shelfRow(titleKey: "audio_effects_low_shelf", value: $lowShelf) { value in
                    UserDefaults.dspLowShelfDb = value
                    AudioDSP.reloadParameters()
                }
                shelfRow(titleKey: "audio_effects_high_shelf", value: $highShelf) { value in
                    UserDefaults.dspHighShelfDb = value
                    AudioDSP.reloadParameters()
                }
            }

            Section(header: Text("audio_effects_equalizer".localized)) {
                ForEach(Array(AudioDSPBands.frequencies.enumerated()), id: \.offset) { index, frequency in
                    bandRow(index: index, frequency: frequency)
                }
            }

            // 压缩器与交叉馈送都有"关"的档：滑杆/档位到 0 即直通，
            // 不必再给一颗总开关（多一颗开关只会多一种"开了没反应"的解释）。
            Section(
                header: Text("audio_effects_compander".localized),
                footer: Text("audio_effects_compander_description".localized)
            ) {
                HStack(spacing: 10) {
                    Slider(value: $compander, in: 0...1, step: 0.05)
                        .onChange(of: compander) { value in
                            UserDefaults.dspCompanderAmount = value
                            AudioDSP.reloadParameters()
                        }
                    Text(verbatim: "\(Int((compander * 100).rounded()))%")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                        .frame(width: 46, alignment: .trailing)
                }
            }

            Section(
                header: Text("audio_effects_crossfeed".localized),
                footer: Text("audio_effects_crossfeed_description".localized)
            ) {
                Picker("audio_effects_crossfeed".localized, selection: $crossfeed) {
                    ForEach(0..<AudioDSPCrossfeed.levelCount, id: \.self) { level in
                        Text(AudioDSPCrossfeed.titleKey(for: level).localized).tag(level)
                    }
                }
                .onChange(of: crossfeed) { value in
                    UserDefaults.dspCrossfeedLevel = value
                    AudioDSP.reloadParameters()
                }
            }

            Section(
                header: Text("audio_effects_presets".localized),
                footer: Text("audio_effects_presets_description".localized)
            ) {
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

            // ── 律动
            Section(
                header: Text("audio_rhythm_section".localized),
                footer: Text("cover_pulse_description".localized)
            ) {
                Toggle("cover_pulse".localized, isOn: $coverPulse)
                    .onChange(of: coverPulse) { value in
                        UserDefaults.coverPulseEnabled = value
                        // 当场起 / 停那条 30Hz 通道（hook 的安装也是这里发起的）。
                        AudioReactiveEngine.shared.refresh()
                    }
            }

            // ── 节拍触感
            Section(
                header: Text("music_haptics_section".localized),
                footer: Text("music_haptics_description".localized)
            ) {
                Toggle("music_haptics".localized, isOn: $musicHaptics)
                    .onChange(of: musicHaptics) { value in
                        UserDefaults.musicHapticsEnabled = value
                        AudioReactiveEngine.shared.refresh()
                    }

                Picker("music_haptics_strength".localized, selection: $musicHapticsStrength) {
                    Text("music_haptics_strength_low".localized).tag(1)
                    Text("music_haptics_strength_medium".localized).tag(2)
                    Text("music_haptics_strength_high".localized).tag(3)
                }
                .pickerStyle(.segmented)
                .onChange(of: musicHapticsStrength) { value in
                    UserDefaults.musicHapticsStrength = value
                }

                // 「试一下」用的是同一个引擎与同一档强度 ——
                // 能当场分辨"引擎没反应"和"设置没生效"。
                Button {
                    MusicHaptics.testTap()
                } label: {
                    Label("music_haptics_test".localized, systemImage: "hand.tap")
                }
            }

            // ── 头部手势
            Section(
                header: Text("head_gestures_title".localized),
                footer: Text("head_gestures_description".localized)
            ) {
                Toggle("head_gestures_enabled".localized, isOn: $headGestures)
                    .onChange(of: headGestures) { value in
                        UserDefaults.headGestureControlsEnabled = value
                        // 当场起 / 停那条姿态流，不必重启 Spotify。
                        HeadGestureControls.syncWithSettings()
                        motionAvailable = HeadGestureControls.isMotionAvailable
                    }
            }

            // 状态行：读的是 CoreMotion 此刻的判断，不是"开关开着"——
            // 开关开着但耳机不支持 / 没连上时，这里必须说实话，否则用户会以为手势坏了。
            Section {
                Label(motionStatusText, systemImage: motionStatusIcon)
                    .foregroundColor(motionAvailable ? Color.primary : Color.secondary)
            }

            SettingsResetSection(
                keys: Self.ownedKeys,
                afterReset: {
                    // 四节各自的影子值都回读一遍，再让各自的运行层按"键已回默认"重新对齐。
                    refreshShadowFromDefaults()
                    AudioDSP.syncWithSettings()
                    insertActive = AudioDSP.isInsertActive
                    AudioReactiveEngine.shared.refresh()
                    HeadGestureControls.syncWithSettings()
                    motionAvailable = HeadGestureControls.isMotionAvailable
                }
            )
        }
        // inset-grouped（胶囊卡片）—— 为什么、怎么做的见 `EeveeSettingsView` 顶部那段
        .listStyle(InsetGroupedListStyle())
        .onAppear {
            // 备份导入 / 别处改过键时，把四节的显示与运行态都对齐一次。
            refreshShadowFromDefaults()
            AudioDSP.syncWithSettings()
            insertActive = AudioDSP.isInsertActive
            AudioReactiveEngine.shared.refresh()
            HeadGestureControls.syncWithSettings()
            motionAvailable = HeadGestureControls.isMotionAvailable
        }
    }

    // MARK: - 音频效果

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

    /// 一行：架式名称 + 滑杆 + 当前 dB。
    private func shelfRow(
        titleKey: String,
        value: Binding<Double>,
        onChange: @escaping (Double) -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Text(titleKey.localized)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 76, alignment: .leading)

            Slider(value: value, in: AudioDSPShelves.minGainDb...AudioDSPShelves.maxGainDb, step: 0.5)
                .onChange(of: value.wrappedValue) { newValue in
                    onChange(newValue)
                }

            Text(verbatim: String(format: "%+.1f", value.wrappedValue))
                .font(.caption)
                .monospacedDigit()
                .foregroundColor(.secondary)
                .frame(width: 42, alignment: .trailing)
        }
    }

    /// 状态行：这一版有没有真的接管音频输出。`AudioDSP.isInsertActive` 不是 `@Published`，
    /// 所以在进页面 / 动开关 / 重置之后各重读一次就够。
    private var audioInsertStatusRow: some View {
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

    /// 把「自定义」预设的档位名写回盘上，并把系数重算一遍。
    private func applyPreset(named name: String) {
        guard let selected = AudioDSPPreset(rawValue: name) else { return }
        gains = selected.gainsDb
        preamp = selected.preampDb
        UserDefaults.dspBandGainsDb = gains
        UserDefaults.dspPreampDb = preamp
        UserDefaults.dspPreset = name
        AudioDSP.reloadParameters()
    }

    // MARK: - 头部手势

    /// 状态行的文案（已本地化）。
    private var motionStatusText: String {
        if motionAvailable { return "head_gestures_motion_available".localized }
        return "head_gestures_motion_unavailable".localized
    }

    /// 状态行的图标：可用是对勾、不可用是感叹号。
    ///
    /// 不用 AirPods 那套符号：耳机图标在"不可用"时反而会让人以为耳机已经连上了。
    private var motionStatusIcon: String {
        if motionAvailable { return "checkmark.circle.fill" }
        return "exclamationmark.circle.fill"
    }

    // MARK: - 影子值

    /// 四节的影子值一次全读回来（备份导入 / 重置 / 重新进页面时用）。
    private func refreshShadowFromDefaults() {
        enabled = UserDefaults.dspEnabled
        preamp = UserDefaults.dspPreampDb
        gains = UserDefaults.dspBandGainsDb
        preset = UserDefaults.dspPreset
        lowShelf = UserDefaults.dspLowShelfDb
        highShelf = UserDefaults.dspHighShelfDb
        compander = UserDefaults.dspCompanderAmount
        crossfeed = UserDefaults.dspCrossfeedLevel

        coverPulse = UserDefaults.coverPulseEnabled
        musicHaptics = UserDefaults.musicHapticsEnabled
        musicHapticsStrength = UserDefaults.musicHapticsStrength

        headGestures = UserDefaults.headGestureControlsEnabled
    }
}
