import SwiftUI
import UIKit

/// 「律动与触感」页 —— 设置根页「高级」组里那一行。
///
/// 两颗开关都属于**音频驱动**：同一份只读音频特征（`AudioFeatures`）→ `AudioReactiveEngine`
/// 按 30Hz 分发给封面与 Taptic Engine。开关立即生效、不必重启；唯一的等待写在页脚里
/// （音频单元已经在跑时，渲染通知要等下一次开始播放 / 换歌才挂上）。
///
/// 「试一下」用的是同一个引擎与同一档强度 —— 能当场分辨"引擎没反应"和"设置没生效"。
struct EeveeAudioReactiveSettingsView: View {

    /// 本页拥有的键（写属性名即可 —— 本仓库的键名与属性名同名）。
    private static let ownedKeys = [
        "coverPulseEnabled",
        "musicHapticsEnabled",
        "musicHapticsStrength",
    ]

    @State private var coverPulse = UserDefaults.coverPulseEnabled
    @State private var musicHaptics = UserDefaults.musicHapticsEnabled
    @State private var strength = UserDefaults.musicHapticsStrength

    var body: some View {
        List {
            Section(footer: Text("cover_pulse_description".localized)) {
                Toggle(
                    "cover_pulse".localized,
                    isOn: $coverPulse
                )
                .onChange(of: coverPulse) { value in
                    UserDefaults.coverPulseEnabled = value
                    // 当场起 / 停那条 30Hz 通道（hook 的安装也是这里发起的）。
                    AudioReactiveEngine.shared.refresh()
                }
            }

            Section(footer: Text("music_haptics_description".localized)) {
                Toggle(
                    "music_haptics".localized,
                    isOn: $musicHaptics
                )
                .onChange(of: musicHaptics) { value in
                    UserDefaults.musicHapticsEnabled = value
                    AudioReactiveEngine.shared.refresh()
                }

                Picker("music_haptics_strength".localized, selection: $strength) {
                    Text("music_haptics_strength_low".localized).tag(1)
                    Text("music_haptics_strength_medium".localized).tag(2)
                    Text("music_haptics_strength_high".localized).tag(3)
                }
                .pickerStyle(.segmented)
                .onChange(of: strength) { value in
                    UserDefaults.musicHapticsStrength = value
                }

                Button {
                    MusicHaptics.testTap()
                } label: {
                    Label("music_haptics_test".localized, systemImage: "hand.tap")
                }
            }

            SettingsResetSection(
                keys: Self.ownedKeys,
                afterReset: {
                    // 只回读影子值 + 让引擎按"现在两个键都回默认了"重新对齐。
                    coverPulse = UserDefaults.coverPulseEnabled
                    musicHaptics = UserDefaults.musicHapticsEnabled
                    strength = UserDefaults.musicHapticsStrength
                    AudioReactiveEngine.shared.refresh()
                }
            )
        }
                // inset-grouped（胶囊卡片）—— 为什么、怎么做的见 `EeveeSettingsView` 顶部那段
        .listStyle(InsetGroupedListStyle())
        .onAppear {
            // 备份导入 / 别处改过键时，把开关显示与引擎状态都对齐一次。
            coverPulse = UserDefaults.coverPulseEnabled
            musicHaptics = UserDefaults.musicHapticsEnabled
            strength = UserDefaults.musicHapticsStrength
            AudioReactiveEngine.shared.refresh()
        }
    }
}
