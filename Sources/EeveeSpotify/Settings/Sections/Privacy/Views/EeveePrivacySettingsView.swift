import SwiftUI
import UIKit

/// 「隐私与上报」页。
///
/// 两个开关 + 一份关键词 + 一个计数：
///   · 拦截开关（默认关）—— 认哪些端点是上报，靠 `TelemetryEndpointRules`；
///   · 只观察不拦截（默认关）—— 把 host+path 打进日志，一条都不拦；
///   · 关键词 —— 真机上观察到的端点写进来，不用重新编译；
///   · 计数 —— 本次启动拦下的**不同**端点数量（去重，见 `TelemetryBlocker`）。
struct EeveePrivacySettingsView: View {

    @State private var blockedCount = TelemetryBlocker.sessionBlockedCount
    @State private var extraKeywords = UserDefaults.telemetryExtraKeywords

    var body: some View {
        List {
            Section(
                header: Text("privacy_telemetry_section".localized),
                footer: Text("block_telemetry_description".localized)
            ) {
                Toggle(
                    "block_telemetry".localized,
                    isOn: Binding<Bool>(
                        get: { UserDefaults.blockTelemetry },
                        set: { UserDefaults.blockTelemetry = $0 }
                    )
                )

                Toggle(
                    "telemetry_observe_only".localized,
                    isOn: Binding<Bool>(
                        get: { UserDefaults.telemetryObserveOnly },
                        set: { UserDefaults.telemetryObserveOnly = $0 }
                    )
                )
            }

            Section(
                header: Text("telemetry_extra_keywords_section".localized),
                footer: Text("telemetry_extra_keywords_description".localized)
            ) {
                TextField(
                    "telemetry_extra_keywords_placeholder".localized,
                    text: $extraKeywords
                )
                .onChange(of: extraKeywords) { value in
                    UserDefaults.telemetryExtraKeywords = value
                }
            }

            Section(header: Text("telemetry_stats_section".localized)) {
                HStack {
                    Text("telemetry_blocked_endpoints".localized)
                    Spacer()
                    // `Text(verbatim:)`：带插值的字面量会被当成 LocalizedStringKey
                    // 去 bundle 里找键，这里要的是纯数字。
                    Text(verbatim: "\(blockedCount)")
                        .foregroundColor(.secondary)
                }

                Button("telemetry_refresh_counters".localized) {
                    blockedCount = TelemetryBlocker.sessionBlockedCount
                }

                Button("telemetry_reset_counters".localized) {
                    TelemetryBlocker.resetCounters()
                    blockedCount = 0
                }
                .foregroundColor(.red)
            }
        }
        .listStyle(GroupedListStyle())
        .onAppear {
            blockedCount = TelemetryBlocker.sessionBlockedCount
        }
    }
}
