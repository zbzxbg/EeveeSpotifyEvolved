import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 「音频效果」页：插入在 Spotify 音源单元与输出单元之间的那条链。
///
/// 一节一件事：总开关（含安装状态）/ 前置增益 / 架式 / 十段 EQ / 压缩器 / 交叉馈送 / 预设。
/// 压缩器与交叉馈送都有"关"的档（0 即直通），所以不再各给一颗总开关 —— 多一颗开关
/// 只会多一种"开了没反应"的解释。
///
/// 与「律动与节拍触感」的分工：那一页只**读**解码后的 PCM，不改样本；这一页改样本。
/// 两页分开是因为它们管的东西不同，合并成一页会让"找 EQ"变成在长页里滚。
struct EeveeAudioEffectsSettingsView: View {

    /// 本页拥有的键（写属性名即可 —— 本仓库的键名与属性名同名）。
    private static let ownedKeys = [
        "dspEnabled",
        "dspPreampDb",
        "dspBandGainsDb",
        "dspPreset",
        "dspLowShelfDb",
        "dspHighShelfDb",
        "dspCompanderAmount",
        "dspCompanderSpeed",
        "dspCrossfeedLevel",
        "dspBalance",
        "dspDeviceProfilesEnabled",
        "dspDeviceProfiles",
        "dspAutoEqText",
        "dspAutoEqName",
    ]

    /// 「自己调过」不是 `AudioDSPPreset` 的档位，但选择器要能显示它。
    private static let customPreset = "custom"

    @State private var enabled = UserDefaults.dspEnabled
    @State private var preamp = UserDefaults.dspPreampDb
    @State private var gains = UserDefaults.dspBandGainsDb
    @State private var preset = UserDefaults.dspPreset
    @State private var lowShelf = UserDefaults.dspLowShelfDb
    @State private var highShelf = UserDefaults.dspHighShelfDb
    @State private var compander = UserDefaults.dspCompanderAmount
    @State private var companderSpeed = UserDefaults.dspCompanderSpeed
    @State private var crossfeed = UserDefaults.dspCrossfeedLevel
    @State private var balance = UserDefaults.dspBalance
    @State private var perDevice = UserDefaults.dspDeviceProfilesEnabled
    @State private var insertActive = AudioDSP.isInsertActive
    @State private var autoEqName = UserDefaults.dspAutoEqName
    @State private var isImportingAutoEq = false
    @State private var autoEqFailed = false

    var body: some View {
        List {
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

                HStack(spacing: 10) {
                    Text("audio_effects_compander_speed".localized)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 56, alignment: .leading)
                    Slider(value: $companderSpeed, in: 0...1, step: 0.05)
                        .onChange(of: companderSpeed) { value in
                            UserDefaults.dspCompanderSpeed = value
                            AudioDSP.reloadParameters()
                        }
                    Text(verbatim: speedLabel(companderSpeed))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                        .frame(width: 64, alignment: .trailing)
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

            Section(
                header: Text("audio_effects_autoeq".localized),
                footer: Text("audio_effects_autoeq_footer".localized)
            ) {
                if let autoEqName {
                    Text(verbatim: autoEqName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("audio_effects_autoeq_remove".localized, role: .destructive) {
                        AudioDSPAutoEq.removeProfile()
                        self.autoEqName = nil
                        autoEqFailed = false
                    }
                } else {
                    Button("audio_effects_autoeq_import".localized) {
                        isImportingAutoEq = true
                    }
                }

                if autoEqFailed {
                    Text("audio_effects_autoeq_error".localized)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }

            Section(
                header: Text("audio_effects_balance".localized),
                footer: Text("audio_effects_balance_description".localized)
            ) {
                HStack(spacing: 10) {
                    Text(verbatim: "L")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Slider(value: $balance, in: -1...1, step: 0.05)
                        .onChange(of: balance) { value in
                            UserDefaults.dspBalance = value
                            AudioDSP.reloadParameters()
                        }
                    Text(verbatim: "R")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(verbatim: balanceLabel(balance))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
            }

            Section(footer: Text("audio_effects_per_device_description".localized)) {
                Toggle("audio_effects_per_device".localized, isOn: $perDevice)
                    .onChange(of: perDevice) { value in
                        UserDefaults.dspDeviceProfilesEnabled = value
                        if value {
                            // 打开的那一刻把当前这套记到当前设备桶里，否则第一次换设备会"没有旧值可存"。
                            AudioDSPDeviceProfiles.storeCurrent(into: AudioDSPDeviceProfiles.activeBucket())
                        }
                    }
            }

            SettingsResetSection(
                keys: Self.ownedKeys,
                afterReset: {
                    refreshShadowFromDefaults()
                    AudioDSP.syncWithSettings()
                    insertActive = AudioDSP.isInsertActive
                }
            )
        }
        // inset-grouped（胶囊卡片）—— 与设置里其它页一致。
        .listStyle(InsetGroupedListStyle())
        .fileImporter(
            isPresented: $isImportingAutoEq,
            allowedContentTypes: [.plainText, .text],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { importAutoEq(from: url) }
            case .failure:
                autoEqFailed = true
            }
        }
        .onAppear {
            // 备份导入 / 别处改过键时，显示与运行态都对齐一次。
            // 先同步再读影子：开启按设备记住时，同步会先把这台设备的设置装进来。
            AudioDSP.syncWithSettings()
            refreshShadowFromDefaults()
            insertActive = AudioDSP.isInsertActive
        }
        .onReceive(NotificationCenter.default.publisher(for: AudioDSPDeviceProfiles.didSwitchNotification)) { _ in
            // 换设备时链上的值已经被换掉，影子要跟着读回来，否则滑杆显示的是上一台设备。
            refreshShadowFromDefaults()
        }
    }

    /// 压缩器速度那格：直接显示换算出来的攻击/释放时间，比 0…100% 更好判断。
    private func speedLabel(_ value: Double) -> String {
        let attack = 3 * pow(6, 0.5 - value)
        let release = 120 * pow(4, 0.5 - value)
        return String(format: "%.0f/%.0f ms", attack, release)
    }

    /// 平衡滑杆右侧那格：居中显示 `C`，两侧显示百分比（`L 40%` / `R 25%`）。
    private func balanceLabel(_ value: Double) -> String {
        let magnitude = Int((abs(value) * 100).rounded())
        if magnitude < 1 { return "C" }
        return (value < 0 ? "L " : "R ") + "\(magnitude)%"
    }

    /// 读一份 AutoEq 文本（或任意 `.txt`）并接到链上；失败只留一行提示，不改现有档。
    private func importAutoEq(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            autoEqFailed = true
            return
        }
        let imported = AudioDSPAutoEq.importProfile(text: text, name: url.lastPathComponent)
        autoEqName = UserDefaults.dspAutoEqName
        autoEqFailed = !imported
    }

    // MARK: - 行

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

    // MARK: - 预设

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

    // MARK: - 影子值

    /// 本页的影子值一次全读回来（备份导入 / 重置 / 重新进页面时用）。
    private func refreshShadowFromDefaults() {
        enabled = UserDefaults.dspEnabled
        preamp = UserDefaults.dspPreampDb
        gains = UserDefaults.dspBandGainsDb
        preset = UserDefaults.dspPreset
        lowShelf = UserDefaults.dspLowShelfDb
        highShelf = UserDefaults.dspHighShelfDb
        compander = UserDefaults.dspCompanderAmount
        companderSpeed = UserDefaults.dspCompanderSpeed
        crossfeed = UserDefaults.dspCrossfeedLevel
        balance = UserDefaults.dspBalance
        perDevice = UserDefaults.dspDeviceProfilesEnabled
        autoEqName = UserDefaults.dspAutoEqName
        autoEqFailed = false
    }
}
