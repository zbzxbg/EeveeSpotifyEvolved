import SwiftUI
import UIKit

/// 「触感」页。
///
/// 开关决定**装不装** `UIControl.sendAction` 那条 hook（在 `EeveeSpotify.init` 读），
/// 所以打开后要重启 Spotify；强度与关键词则立即生效 —— 设置页里的「试一下」用的就是
/// 同一个引擎，能马上分辨"引擎没反应"和"关键词没对上"。
struct EeveeHapticsSettingsView: View {

    @State private var strength = UserDefaults.hapticsStrength
    @State private var keywords = UserDefaults.hapticsSurfaceKeywords

    var body: some View {
        List {
            Section(footer: Text("haptics_description".localized)) {
                Toggle(
                    "haptics_enabled".localized,
                    isOn: Binding<Bool>(
                        get: { UserDefaults.hapticsEnabled },
                        set: { UserDefaults.hapticsEnabled = $0 }
                    )
                )

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("haptics_strength".localized)
                        Spacer()
                        // `Text(verbatim:)`：带插值的字面量会被当成 LocalizedStringKey。
                        Text(verbatim: "\(Int((strength * 100).rounded()))%")
                            .foregroundColor(.secondary)
                    }

                    Slider(value: $strength, in: 0.2...1.0, step: 0.1)
                        .onChange(of: strength) { value in
                            UserDefaults.hapticsStrength = value
                        }
                }

                Button("haptics_test".localized) {
                    HapticFeedback.tap()
                }
            }

            Section(
                header: Text("haptics_surface_keywords_section".localized),
                footer: Text("haptics_surface_keywords_description".localized)
            ) {
                TextField(
                    "haptics_surface_keywords_placeholder".localized,
                    text: $keywords
                )
                .onChange(of: keywords) { value in
                    UserDefaults.hapticsSurfaceKeywords = value
                }

                Toggle(
                    "haptics_log_controls".localized,
                    isOn: Binding<Bool>(
                        get: { UserDefaults.hapticsLogControls },
                        set: { UserDefaults.hapticsLogControls = $0 }
                    )
                )
            }
        }
                // ★ 2026-10-12：inset-grouped（胶囊卡片）—— 为什么、怎么做的见 `EeveeSettingsView` 顶部那段
        .listStyle(InsetGroupedListStyle())
    }
}
