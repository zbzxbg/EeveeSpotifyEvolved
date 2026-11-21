import SwiftUI
import UIKit

/// 「头部手势」页：AirPods Pro / AirPods Max 的点头、摇头切歌（`HeadGestureControls`）。
///
/// 读的是 Core Motion 的头姿流，检测刻意保守（两次反向摆动、1.5 s 冷却），默认关。
/// 开关当场起停那条流，不必重启 Spotify。
///
/// 状态行读的是 CoreMotion **此刻**的判断，不是"开关开着"：开关开着但耳机不支持 /
/// 没连上时，这里必须说实话，否则用户会以为手势坏了。
struct EeveeHeadGestureSettingsView: View {

    /// 本页拥有的键（写属性名即可 —— 本仓库的键名与属性名同名）。
    private static let ownedKeys = [
        "headGestureControlsEnabled",
    ]

    @State private var headGestures = UserDefaults.headGestureControlsEnabled
    /// 「现在有没有能出姿态数据的耳机」不是 `@Published`，所以在进页面、动开关、重置之后
    /// 各重读一次就够 —— 它只在耳机插拔时变。
    @State private var motionAvailable = HeadGestureControls.isMotionAvailable

    var body: some View {
        List {
            Section(
                header: Text("head_gestures_title".localized),
                footer: Text("head_gestures_description".localized)
            ) {
                Toggle("head_gestures_enabled".localized, isOn: $headGestures)
                    .onChange(of: headGestures) { value in
                        UserDefaults.headGestureControlsEnabled = value
                        HeadGestureControls.syncWithSettings()
                        motionAvailable = HeadGestureControls.isMotionAvailable
                    }
            }

            Section {
                Label(motionStatusText, systemImage: motionStatusIcon)
                    .foregroundColor(motionAvailable ? Color.primary : Color.secondary)
            }

            SettingsResetSection(
                keys: Self.ownedKeys,
                afterReset: {
                    headGestures = UserDefaults.headGestureControlsEnabled
                    HeadGestureControls.syncWithSettings()
                    motionAvailable = HeadGestureControls.isMotionAvailable
                }
            )
        }
        // inset-grouped（胶囊卡片）—— 与设置里其它页一致。
        .listStyle(InsetGroupedListStyle())
        .onAppear {
            headGestures = UserDefaults.headGestureControlsEnabled
            HeadGestureControls.syncWithSettings()
            motionAvailable = HeadGestureControls.isMotionAvailable
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
