import ActivityKit
import SwiftUI

/// 「实时活动」页 —— 设置根页「高级」组里那一行。
///
/// 一颗开关，立即生效（`LiveActivityController.syncWithSettings()` 当场起 / 停轮询与卡片）。
/// 系统侧的限制比开关本身多，所以页脚把它们写清楚：卡片由随包打进 IPA 的 widget 扩展提供，
/// 安装方式里没带上它、或者签名时不签嵌套扩展，都不会有卡；此外还要在 iOS 设置里允许
/// Spotify 使用实时活动。最后这条可以当场读出来，所以单独一行提示。
struct EeveeLiveActivitySettingsView: View {

    /// 本页拥有的键（写属性名即可 —— 本仓库的键名与属性名同名）。
    private static let ownedKeys = [
        "liveActivityEnabled",
    ]

    @State private var enabled = UserDefaults.liveActivityEnabled
    /// 系统给本 App 的实时活动授权。和开关是两件事：开关是我们的意愿，系统可以不同意。
    @State private var isAllowed = ActivityAuthorizationInfo().areActivitiesEnabled

    var body: some View {
        List {
            Section(footer: Text("live_activity_description".localized)) {
                Toggle(
                    "live_activity_enabled".localized,
                    isOn: $enabled
                )
                .onChange(of: enabled) { value in
                    UserDefaults.liveActivityEnabled = value
                    // 当场起 / 停（轮询与卡片都在这里发起），不必重启 Spotify。
                    LiveActivityController.syncWithSettings()
                }
            }

            if !isAllowed {
                Section {
                    Label(
                        "live_activity_unavailable".localized,
                        systemImage: "exclamationmark.triangle"
                    )
                }
            }

            SettingsResetSection(
                keys: Self.ownedKeys,
                afterReset: {
                    // 键回默认（关）之后：开关的影子值要跟上，卡片也要当场收掉。
                    enabled = UserDefaults.liveActivityEnabled
                    LiveActivityController.syncWithSettings()
                }
            )
        }
        // inset-grouped（胶囊卡片）—— 与设置里其它页一致。
        .listStyle(InsetGroupedListStyle())
        .onAppear {
            // 从 iOS 设置里回来、或者备份导入改过键：开关显示与系统授权都对齐一次。
            enabled = UserDefaults.liveActivityEnabled
            isAllowed = ActivityAuthorizationInfo().areActivitiesEnabled
        }
    }
}
