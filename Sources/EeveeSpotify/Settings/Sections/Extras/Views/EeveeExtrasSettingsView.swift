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

    /// 本页所有开关与选择的**影子值**。理由见 `Shadow`。
    @State private var shadow = Shadow()

    /// ⚠️ 为什么每个控件都要一个本地影子值（2026-10-01 用户报的 bug）
    ///
    /// 原来每个控件直接绑一个**读 UserDefaults 的临时 Binding**：
    /// `Binding(get: { UserDefaults.xxx }, set: { UserDefaults.xxx = $0 })`。
    /// 写 `UserDefaults` **不会**让 SwiftUI 失效重绘 ——
    ///   · `Toggle` 自己会重绘，所以看不出问题；
    ///   · `Picker` 的标签是**父视图求值**出来的，于是「双击手势 → 动作」选完仍显示旧值，
    ///     要等页面被重建（重启 Spotify）才更新。用户报的正是这一条。
    ///
    /// 对照本仓库里没这个毛病的两页：`SponsorBlockSettingsView` 用 `@State options`、
    /// Flag 覆盖页用 `@State newMode` —— 它们先改本地状态（触发重绘）再落盘。
    /// 这里照同一套做法：`set` 里**先改影子值，再写 UserDefaults**。
    private struct Shadow {
        var hideMiniPlayerBar = UserDefaults.hideMiniPlayerBar
        var hideSingalongLine = UserDefaults.hideSingalongLine
        var hideHomeHeader = UserDefaults.hideHomeHeader
        var hideConnectButton = UserDefaults.hideConnectButton
        var hideAddToButton = UserDefaults.hideAddToButton

        var libraryLargeTitle = UserDefaults.libraryLargeTitle
        var tabBarGlass = UserDefaults.tabBarGlass
        var tabBarHideLabels = UserDefaults.tabBarHideLabels
        var miniBarGlass = UserDefaults.miniBarGlass
        var nowPlayingBackdrop = UserDefaults.nowPlayingBackdrop
        var nowPlayingOneScreen = UserDefaults.nowPlayingOneScreen
        var nowPlayingVolume = UserDefaults.nowPlayingVolume
    }

    var body: some View {
        List {
            // ⛔「深色栏底色」(AMOLED) 已于 2026-10-02 删除：
            // 新设计语言下它每次布局都主动让位，是个纯空操作（见 `Tweak.x.swift` 里那段说明）。

            Section(footer: Text("declutter_description".localized)) {
                Toggle(
                    "hide_mini_player_bar".localized,
                    isOn: declutterBinding(
                        \.hideMiniPlayerBar,
                        persist: { UserDefaults.hideMiniPlayerBar = $0 }
                    )
                )

                Toggle(
                    "hide_singalong_line".localized,
                    isOn: declutterBinding(
                        \.hideSingalongLine,
                        persist: { UserDefaults.hideSingalongLine = $0 }
                    )
                )
            }

            Section(
                header: Text("declutter_home_player_section".localized),
                footer: Text("declutter_home_player_description".localized)
            ) {
                Toggle(
                    "hide_home_header".localized,
                    isOn: declutterBinding(
                        \.hideHomeHeader,
                        persist: { UserDefaults.hideHomeHeader = $0 }
                    )
                )

                Toggle(
                    "hide_connect_button".localized,
                    isOn: declutterBinding(
                        \.hideConnectButton,
                        persist: { UserDefaults.hideConnectButton = $0 }
                    )
                )

                Toggle(
                    "hide_add_to_button".localized,
                    isOn: declutterBinding(
                        \.hideAddToButton,
                        persist: { UserDefaults.hideAddToButton = $0 }
                    )
                )
            }

            // ⛔「双击手势」整节已于 2026-10-04 删除（用户拍板：先删掉，之后再搞）。
            //   它不是"坏了"才删：切歌那条路日志 8/17 证明能用；删是因为 ——
            //   ① 手势挂在页面根视图上，**在播放键上方双击也会跳歌**（本该是播放/暂停）；
            //   ② 最该起作用的全屏歌词那一面默认关、从没验过；
            //   ③ 最近 8 份日志里它一次都没被用过。
            //   重做时的三条要求（控件上不认 / 单击让位 / 另选挂点）见
            //   `Tools/eevee-hookfinder/SESSION_2026-10-03_NIGHT.md` §10。

            // ⛔ 听歌页那一整节（自绘壳 / 自绘顶栏 / 顶栏玻璃）已于 2026-10-02 **整节删除**：
            // 那几版 bug 太多（糊底、两颗 ⌄、与原生吸顶头打架……），先放一边，
            // 等导航栏这条线收干净再重做。

            // 底部标签栏玻璃：每颗标签后面垫一层真液态玻璃（iOS 26+）或材质。
            Section(
                header: Text("tab_bar_glass_section".localized),
                footer: Text("tab_bar_glass_description".localized)
            ) {
                Toggle(
                    "tab_bar_glass".localized,
                    isOn: shadowBinding(
                        \.tabBarGlass,
                        persist: { UserDefaults.tabBarGlass = $0 }
                    )
                )

                // 照片 21/23/25 里那条栏是**没有文字**的；藏掉之后玻璃自然收到 ~40pt。
                // 思路借自 spoti.pw 的「Hide labels」（只借思路，代码自己写）。
                Toggle(
                    "tab_bar_hide_labels".localized,
                    isOn: shadowBinding(
                        \.tabBarHideLabels,
                        persist: { UserDefaults.tabBarHideLabels = $0 }
                    )
                )
            }

            // 迷你播放条：用户 2026-10-02 点名要的（照片 33：那条实心封面色底太扎眼）。
            // 与上面那条**同高同材质**，宽度贴它自己的内容 —— 两条胶囊之间的间隙保持不动。
            Section(
                header: Text("mini_bar_glass_section".localized),
                footer: Text("mini_bar_glass_description".localized)
            ) {
                Toggle(
                    "mini_bar_glass".localized,
                    isOn: shadowBinding(
                        \.miniBarGlass,
                        persist: { value in
                            UserDefaults.miniBarGlass = value
                            // 迷你条的布局回合不常有：改完当场落地（撤玻璃/还原底色都在这一句里）。
                            MiniBarGlassPlate.reconcileNow()
                        }
                    )
                )
            }

            // 听歌页（NPV）：仿 Apple Music 的**整页取色渐变底**。
            // 借鉴来源与"为什么不模糊"写在 `NowPlayingBackdrop` 的文件头。
            Section(
                header: Text("now_playing_backdrop_section".localized),
                footer: Text("now_playing_backdrop_description".localized)
            ) {
                Toggle(
                    "now_playing_backdrop".localized,
                    isOn: shadowBinding(
                        \.nowPlayingBackdrop,
                        persist: { value in
                            UserDefaults.nowPlayingBackdrop = value
                            // 关掉要**当场**还原（不用等下一次进听歌页）；
                            // 打开就顺手刷一次，用户可以在听歌页里立刻看到。
                            if value {
                                refreshNowPlayingBackdrop()
                            } else {
                                NowPlayingBackdrop.remove(reason: "switch off")
                            }
                        }
                    )
                )

                // 一屏：把播放器下面那些卡片折起来 + 把列表钉在它的顶部
                // （kumone / Music app 那种"一屏一首歌、滚不动"）。
                // 思路与算法借自 spoti.pw v0.21.1（GPL-3.0），写在 `NowPlayingOneScreen` 文件头。
                Toggle(
                    "now_playing_one_screen".localized,
                    isOn: shadowBinding(
                        \.nowPlayingOneScreen,
                        persist: { value in
                            UserDefaults.nowPlayingOneScreen = value
                            // 关掉要**当场**把 inset 写回（不用等下一次进听歌页）；
                            // 打开就顺手落地一次。
                            if value {
                                NowPlayingOneScreen.reapply()
                            } else {
                                NowPlayingOneScreen.restore()
                            }
                        }
                    )
                )

                // 底部音量条：kumone 播放页下半屏的那一条（Apple Music 没有）。
                // 落在**我们自己的透明覆盖层**上（`NowPlayingPageOverlay`），不碰 Spotify 属性。
                Toggle(
                    "now_playing_volume".localized,
                    isOn: shadowBinding(
                        \.nowPlayingVolume,
                        persist: { value in
                            UserDefaults.nowPlayingVolume = value
                            // 打开就当场落地（页面还挂着的话），关掉当场把那一层拿走。
                            if value {
                                NowPlayingPageOverlay.reapply()
                            } else {
                                NowPlayingPageOverlay.remove(reason: "switch off")
                            }
                        }
                    )
                )

                // ⛔「禁止回弹」已于 2026-10-03 夜删除（真机日志 41）：
                // 它把列表的 `alwaysBounceVertical` 关掉，用户实测**开了就划不掉播放器**
                // （下拉关闭是经过列表那一层接管的，那个属性是链条的一环）。
                // 列表拖拽时剩下的那点橡皮筋是"一屏"**无法消除**的残留 ——
                // 要碰它就得先有办法自己接管关闭手势。理由写在 `NowPlayingOneScreen` 文件头。
            }

            // 音乐库：**改原生**的第一批（不是加壳）—— 大标题左对齐 + 收掉顶部渐隐灰纱。
            Section(
                header: Text("library_section".localized),
                footer: Text("library_large_title_description".localized)
            ) {
                Toggle(
                    "library_large_title".localized,
                    isOn: shadowBinding(
                        \.libraryLargeTitle,
                        persist: { UserDefaults.libraryLargeTitle = $0 }
                    )
                )
            }

            // ⛔「顶部大标题」（旧"样品"开关）已于 2026-10-02 删除：
            // 壳自己会画顶栏标题（`header=ON` 时），那条是**另一套**标题 —— 两个都开就会画两遍。

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

                Button {
                    push(with: EeveeBlockedArtistsSettingsView(), title: "blocked_artists_title")
                } label: {
                    NavigationSectionView(
                        color: Color(hex: "#FF9F0A"),
                        title: "blocked_artists_title".localized,
                        imageSystemName: "person.slash.fill"
                    )
                }

                // 「减少打扰」：把 Spotify 自己的提示/推广/新功能气泡逐条关掉。
                // 做法是写 flag 覆盖（`FlagOverrideStore`），**不隐藏视图、不碰布局** ——
                // 原料（`ios-messaging-reduceinterventions-impl` 那批 flag）早在
                // `KnownFlagCatalog` 里，这一页只把它变成人话开关。
                Button {
                    push(with: EeveeReduceInterventionsView(), title: "reduce_interventions_title")
                } label: {
                    NavigationSectionView(
                        color: Color(hex: "#FF6482"),
                        title: "reduce_interventions_title".localized,
                        imageSystemName: "bell.slash.fill"
                    )
                }
            }

            // 设置本身的维护 + 关于（2026-10-02 新增）。
            // 三页全是"离线/只读"性质：备份与重置只碰我们自己的键、许可页是静态、
            // 更新日志只读 GitHub —— 都不需要新 hook，也不需要新取证。
            Section(header: Text("maintenance_section".localized)) {
                Button {
                    push(with: EeveeBackupSettingsView(), title: "backup_title")
                } label: {
                    NavigationSectionView(
                        color: Color(hex: "#64D2FF"),
                        title: "backup_title".localized,
                        imageSystemName: "externaldrive.badge.timemachine"
                    )
                }

                Button {
                    push(with: EeveeUpdatesSettingsView(), title: "updates_title")
                } label: {
                    NavigationSectionView(
                        color: Color(hex: "#32ADE6"),
                        title: "updates_title".localized,
                        imageSystemName: "clock.arrow.circlepath"
                    )
                }

                Button {
                    push(with: EeveeLicensesSettingsView(), title: "licenses_title")
                } label: {
                    NavigationSectionView(
                        color: Color(hex: "#8E8E93"),
                        title: "licenses_title".localized,
                        imageSystemName: "doc.badge.ellipsis"
                    )
                }
            }
        }
        .listStyle(GroupedListStyle())
        // 每次进页重新同步一次：别处（Flag 页、重置、上一版遗留的存储）改了 UserDefaults 时
        // 影子值不该停在旧值上。与 Flag 覆盖页的 `.onAppear` 同一套做法。
        .onAppear { shadow = Shadow() }
    }

    // MARK: - 绑定

    /// 影子值 + 落盘：`set` 里**先改影子值**（让 SwiftUI 失效重绘），再写 UserDefaults。
    private func shadowBinding<Value>(
        _ keyPath: WritableKeyPath<Shadow, Value>,
        persist: @escaping (Value) -> Void
    ) -> Binding<Value> {
        Binding(
            get: { shadow[keyPath: keyPath] },
            set: { value in
                shadow[keyPath: keyPath] = value
                persist(value)
            }
        )
    }

    /// 清爽开关：在影子绑定的基础上多一步**当场复查**。
    ///
    /// 为什么需要：这些开关是运行期读的，撤销本来只在"目标视图下一次 layout"时生效 ——
    /// 而被我们藏过的视图不一定再有 layout 回合，用户那边的表现就是"关掉开关它也不回来"。
    /// `reconcileNow()` 会当场把当前窗口复查一遍（见 `DeclutterChrome`），
    /// 所以关掉开关的瞬间那条 chrome 就回来了，不用等布局、也不用重启。
    private func declutterBinding(
        _ keyPath: WritableKeyPath<Shadow, Bool>,
        persist: @escaping (Bool) -> Void
    ) -> Binding<Bool> {
        shadowBinding(keyPath) { value in
            persist(value)
            DeclutterChrome.reconcileNow()
        }
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
