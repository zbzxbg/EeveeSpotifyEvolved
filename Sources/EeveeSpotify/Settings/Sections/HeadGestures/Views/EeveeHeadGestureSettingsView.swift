import SwiftUI

/// 「头部手势」页 —— 设置根页「高级」组里那一行。
///
/// 这一页只做三件事：把开关落盘并**当场**生效、显示耳机现在给不给头部姿态数据、
/// 把这一页拥有的键交给「重置本页」。判定与起流都在 `HeadGestureControls` 里，
/// 真正的切歌动作走 `WordByWordPlaybackControl`（与自绘壳那三颗按钮同一条路），
/// 这里不碰播放器。
struct EeveeHeadGestureSettingsView: View {

    /// 本页拥有的键（写属性名即可 —— 本仓库的键名与属性名同名）。
    private static let ownedKeys = ["headGestureControlsEnabled"]

    @State private var enabled = UserDefaults.headGestureControlsEnabled
    /// 「现在有没有能出姿态数据的耳机」不是 `@Published`，所以在进页面、动开关、重置之后
    /// 各重读一次，够用了 —— 它只在耳机插拔时变。
    @State private var motionAvailable = HeadGestureControls.isMotionAvailable

    var body: some View {
        List {
            Section(footer: Text("head_gestures_description".localized)) {
                Toggle(
                    "head_gestures_enabled".localized,
                    isOn: $enabled
                )
                .onChange(of: enabled) { value in
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
                    // 只回读影子值 + 让运行层按"键已回默认（关）"重新对齐。
                    enabled = UserDefaults.headGestureControlsEnabled
                    motionAvailable = HeadGestureControls.isMotionAvailable
                    HeadGestureControls.syncWithSettings()
                }
            )
        }
                // inset-grouped（胶囊卡片）—— 为什么、怎么做的见 `EeveeSettingsView` 顶部那段
        .listStyle(InsetGroupedListStyle())
        .onAppear {
            // 备份导入 / 别处改过键 / 耳机刚插拔过：进页面先把显示与运行态都对齐一次。
            enabled = UserDefaults.headGestureControlsEnabled
            motionAvailable = HeadGestureControls.isMotionAvailable
            HeadGestureControls.syncWithSettings()
        }
    }

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
}
