import SwiftUI
import UIKit

/// 「扩展功能」—— 后加的这批（思路来自 spoti.pw，代码自己写）集中在一页。
///
/// 为什么这样放：EeveeSpotify 根页原来因为每加一个功能就多一行，涨到了 18 行——
/// 用户反馈"页面臃肿"。spoti.pw 的结构正好相反：**根页只放分类，功能各进自己的页**。
/// 这里照同样的做法，根页只多一行。
///
/// 里面四项：深色栏底色（`amoled`，就地开关）、隐私与上报、触感、Flag 覆盖。
/// 深色栏刻意**不**做成子页——它只有一个开关，为它单开一页反而是另一种臃肿。
struct EeveeExtrasSettingsView: View {

    let navigationController: UINavigationController

    var body: some View {
        List {
            Section(footer: Text("amoled_description".localized)) {
                Toggle(
                    "amoled".localized,
                    isOn: Binding<Bool>(
                        get: { UserDefaults.amoledEnabled },
                        set: { UserDefaults.amoledEnabled = $0 }
                    )
                )
            }

            Section(footer: Text("declutter_description".localized)) {
                Toggle(
                    "hide_mini_player_bar".localized,
                    isOn: Binding<Bool>(
                        get: { UserDefaults.hideMiniPlayerBar },
                        set: { UserDefaults.hideMiniPlayerBar = $0 }
                    )
                )

                Toggle(
                    "hide_tab_bar_fade".localized,
                    isOn: Binding<Bool>(
                        get: { UserDefaults.hideTabBarFade },
                        set: { UserDefaults.hideTabBarFade = $0 }
                    )
                )

                Toggle(
                    "hide_free_tier_bar".localized,
                    isOn: Binding<Bool>(
                        get: { UserDefaults.hideFreeTierBar },
                        set: { UserDefaults.hideFreeTierBar = $0 }
                    )
                )

                Toggle(
                    "hide_singalong_line".localized,
                    isOn: Binding<Bool>(
                        get: { UserDefaults.hideSingalongLine },
                        set: { UserDefaults.hideSingalongLine = $0 }
                    )
                )
            }

            Section(
                header: Text("declutter_home_player_section".localized),
                footer: Text("declutter_home_player_description".localized)
            ) {
                Toggle(
                    "hide_home_header".localized,
                    isOn: Binding<Bool>(
                        get: { UserDefaults.hideHomeHeader },
                        set: { UserDefaults.hideHomeHeader = $0 }
                    )
                )

                Toggle(
                    "hide_connect_button".localized,
                    isOn: Binding<Bool>(
                        get: { UserDefaults.hideConnectButton },
                        set: { UserDefaults.hideConnectButton = $0 }
                    )
                )

                Toggle(
                    "hide_add_to_button".localized,
                    isOn: Binding<Bool>(
                        get: { UserDefaults.hideAddToButton },
                        set: { UserDefaults.hideAddToButton = $0 }
                    )
                )
            }

            Section(
                header: Text("gesture_section".localized),
                footer: Text("gesture_description".localized)
            ) {
                Picker(
                    "gesture_behavior".localized,
                    selection: Binding<Int>(
                        get: { UserDefaults.playerGestureBehavior },
                        set: { UserDefaults.playerGestureBehavior = $0 }
                    )
                ) {
                    Text("gesture_behavior_skip".localized).tag(0)
                    Text("gesture_behavior_seek".localized).tag(1)
                }
                .pickerStyle(MenuPickerStyle())

                Toggle(
                    "gesture_on_now_playing".localized,
                    isOn: Binding<Bool>(
                        get: { UserDefaults.playerGestureNowPlaying },
                        set: { UserDefaults.playerGestureNowPlaying = $0 }
                    )
                )

                Toggle(
                    "gesture_on_fullscreen_lyrics".localized,
                    isOn: Binding<Bool>(
                        get: { UserDefaults.playerGestureFullscreenLyrics },
                        set: { UserDefaults.playerGestureFullscreenLyrics = $0 }
                    )
                )

                Toggle(
                    "gesture_on_mini_bar".localized,
                    isOn: Binding<Bool>(
                        get: { UserDefaults.playerGestureMiniBar },
                        set: { UserDefaults.playerGestureMiniBar = $0 }
                    )
                )
            }

            Section(footer: Text("extras_description".localized)) {
                Button {
                    push(with: EeveePrivacySettingsView(), title: "privacy_title")
                } label: {
                    NavigationSectionView(
                        color: Color(hex: "#30B0C7"),
                        title: "privacy_title".localized,
                        imageSystemName: "hand.raised.fill"
                    )
                }

                Button {
                    push(with: EeveeHapticsSettingsView(), title: "haptics_title")
                } label: {
                    NavigationSectionView(
                        color: Color(hex: "#FF375F"),
                        title: "haptics_title".localized,
                        imageSystemName: "waveform"
                    )
                }

                Button {
                    push(
                        with: EeveeFlagOverrideSettingsView(
                            navigationController: navigationController
                        ),
                        title: "flag_override_title"
                    )
                } label: {
                    NavigationSectionView(
                        color: Color(hex: "#5E5CE6"),
                        title: "flag_override_title".localized,
                        imageSystemName: "slider.horizontal.3"
                    )
                }
            }
        }
        .listStyle(GroupedListStyle())
    }

    /// 与根页 `EeveeSettingsView.pushSettingsController` 同一套做法：把 SwiftUI 页塞进
    /// 一个 `EeveeSettingsViewController`，再推上 Spotify 自己的导航栈。
    private func push(with view: any View, title: String) {
        let viewController = EeveeSettingsViewController(
            navigationController.view.frame,
            settingsView: AnyView(view),
            navigationTitle: title.localized
        )

        navigationController.pushViewController(viewController, animated: true)
    }
}
