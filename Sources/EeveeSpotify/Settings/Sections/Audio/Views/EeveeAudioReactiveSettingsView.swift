import SwiftUI
import UIKit

/// 「律动与节拍触感」页：两件事共用一条**只读**的音频特征通道（`AudioReactiveEngine`）。
///
/// · **律动**：封面跟着低频起伏，模糊底图跟着动；
/// · **节拍触感**：kick / snare 瞬态变成轻触（`MusicHaptics`，走 Taptic Engine）。
///
/// 两者都不改音频样本 —— 改样本的是「音频效果」页。开关当场起停，不必重启 Spotify；
/// 如果打开时已经有歌在播，要暂停再播一次那条 tap 才会挂上（页脚各自写清楚）。
struct EeveeAudioReactiveSettingsView: View {

    /// 本页拥有的键（写属性名即可 —— 本仓库的键名与属性名同名）。
    private static let ownedKeys = [
        "coverPulseEnabled",
        "musicHapticsEnabled",
        "musicHapticsStrength",
    ]

    @State private var coverPulse = UserDefaults.coverPulseEnabled
    @State private var musicHaptics = UserDefaults.musicHapticsEnabled
    @State private var musicHapticsStrength = UserDefaults.musicHapticsStrength

    var body: some View {
        List {
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
            Section(footer: Text("music_haptics_description".localized)) {
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

            SettingsResetSection(
                keys: Self.ownedKeys,
                afterReset: {
                    refreshShadowFromDefaults()
                    AudioReactiveEngine.shared.refresh()
                }
            )
        }
        // inset-grouped（胶囊卡片）—— 与设置里其它页一致。
        .listStyle(InsetGroupedListStyle())
        .onAppear {
            refreshShadowFromDefaults()
            AudioReactiveEngine.shared.refresh()
        }
    }

    /// 本页的影子值读回来（备份导入 / 重置 / 重新进页面时用）。
    private func refreshShadowFromDefaults() {
        coverPulse = UserDefaults.coverPulseEnabled
        musicHaptics = UserDefaults.musicHapticsEnabled
        musicHapticsStrength = UserDefaults.musicHapticsStrength
    }
}
