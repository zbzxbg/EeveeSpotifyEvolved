import SwiftUI
import UIKit

/// 设置根页。
///
/// 分五组：播放与歌词 / 外观 / 进阶 / 高级 / 维护。每一行都带**副标题**
/// （`NavigationSectionView.subtitle`）—— 一眼能看出这一行进去有什么。
///
/// ## 页面按"一件事一页"收口
///
/// · **锁屏**：封面与歌词合成 `EeveeLockScreenSettingsView` 一页 —— 它们是同一块屏幕上的
///   两件事，原来各占一行、各只有一颗开关和一个缓存；
/// · **音频**：音频效果 / 律动 / 节拍触感 / 头部手势合成 `EeveeAudioSettingsView` 一页。
///   前两者跑在同一条解码后的音频上（一个改样本、一个只读特征），后两者是设备能力；
///   它们默认全关、排障时又常常要一起看，入口原来却占三行；
/// · **外观**：主题与「标签栏与迷你条」同属界面外壳，歌词背景颜色归「歌词外观」，
///   深色弹窗归「杂项」—— 原来那页「定制」拆掉，外观组因此少一行；
/// · **Flag 覆盖**：并入「减少打扰」页作为二级入口（那一页还要继续推「手动写入」，
///   所以由这里把导航栈传下去），根页不再单独占一行；
/// · **日志工具**（开启 / 导出 / 清除）归「调试」页 —— 它和那些排查开关读写的是同一条
///   调试日志，不该在根页再占一组。
///
/// 自建页大多带「重置本页」（`SettingsResetSection`；合并后的页拿到的是原几页键的并集），
/// 备份 / 导入 / 重置覆盖的键一个都没少（`UserDefaults.ownedKeys` 也一个没删）。
///
/// ⚠️ 刻意**没有**跟上游那样加 logo 大标题：我们 bundle 里只有 `github.png`，
/// 上游那个 `EeveeLogo.png` 不是本项目的素材（与 Spicy Lyrics 条款里"图片权利"是同一个坑）。
struct EeveeSettingsView: View {
    let navigationController: UINavigationController
    static let spotifyAccentColor = Color(hex: "#1ed760")
    
    @State private var hasShownCommonIssuesTip = UserDefaults.hasShownCommonIssuesTip
    @State private var isClearingData = false


    private func confirmDestructive(
        title: String,
        message: String,
        confirmTitle: String,
        onConfirm: @escaping () -> Void
    ) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel".uiKitLocalized, style: .cancel))
        alert.addAction(UIAlertAction(title: confirmTitle, style: .destructive) { _ in
            onConfirm()
        })
        WindowHelper.shared.present(alert)
    }

    private func pushSettingsController(with view: any View, title: String) {
        let viewController = EeveeSettingsViewController(
            navigationController.view.frame,
            settingsView: AnyView(view),
            navigationTitle: title
        )
        navigationController.pushViewController(viewController, animated: true)
    }

    /// 根页的一行：彩色图标 + 标题 + **灰色副标题** + 右箭头，点开推一个自建页。
    ///
    /// 抽成一个函数是因为根页有二十多行 —— 每行再手写一遍
    /// `Button { push… } label: { NavigationSectionView(…) }` 会看不出结构。
    @ViewBuilder
    private func settingsRow(
        color: Color,
        title: String,
        subtitle: String,
        imageSystemName: String,
        destination: @escaping () -> AnyView
    ) -> some View {
        Button {
            pushSettingsController(with: destination(), title: title.localized)
        } label: {
            NavigationSectionView(
                color: color,
                title: title.localized,
                imageSystemName: imageSystemName,
                subtitle: subtitle.localized
            )
        }
    }
    
    init(navigationController: UINavigationController) {
        self.navigationController = navigationController
        UIView.appearance().tintColor = UIColor(EeveeSettingsView.spotifyAccentColor)
    }

    var body: some View {
        List {
            EeveeSettingsVersionView()
            
            if !hasShownCommonIssuesTip {
                CommonIssuesTipView(
                    onDismiss: {
                        hasShownCommonIssuesTip = true
                        UserDefaults.hasShownCommonIssuesTip = true
                    }
                )
            }

            // ── ① 播放与歌词
            Section(header: Text("settings_group_playback".localized)) {
                settingsRow(
                    color: .blue,
                    title: "lyrics",
                    subtitle: "settings_sub_lyrics",
                    imageSystemName: "quote.bubble.fill"
                ) { AnyView(EeveeLyricsSettingsView()) }

                // 「歌词外观」：字号 / 行距 / 歌词背景颜色。
                // 那一页是取词源与行为开关；这些属于"长什么样"，而且字号倍率对
                // 全屏歌词页、页内歌词层、锁屏歌词都生效，与逐词开关无关。
                settingsRow(
                    color: .blue,
                    title: "lyrics_appearance_title",
                    subtitle: "settings_sub_lyrics_appearance",
                    imageSystemName: "textformat.size"
                ) { AnyView(EeveeLyricsAppearanceSettingsView()) }

                // 「导入歌词」：用户自己的文件比任何在线源都准，入口就放在歌词相关页旁边。
                settingsRow(
                    color: .blue,
                    title: "imported_lyrics_title",
                    subtitle: "settings_sub_imported_lyrics",
                    imageSystemName: "doc.text"
                ) { AnyView(EeveeImportedLyricsSettingsView()) }

                // 歌词偏移：会随听歌不断长出条目，所以是独立页。
                // 从"网易云歌词偏移"扩成**所有源**（Genius 除外），标题与副标题跟着改成通用的。
                settingsRow(
                    color: Color(hex: "#30B0C7"),
                    title: "lyrics_offset_title",
                    subtitle: "settings_sub_lyrics_offset",
                    imageSystemName: "timer"
                ) { AnyView(EeveeLyricsOffsetSettingsView()) }

                // 听歌页那一整页开关（听歌页样式、清爽、卡片）。
                settingsRow(
                    color: Color(hex: "#0A84FF"),
                    title: "now_playing_section",
                    subtitle: "settings_sub_now_playing",
                    imageSystemName: "music.note.list"
                ) { AnyView(NowPlayingSettingsView()) }

                settingsRow(
                    color: .orange,
                    title: "patching",
                    subtitle: "settings_sub_patching",
                    imageSystemName: "hammer.fill"
                ) { AnyView(EeveePatchingSettingsView()) }

                settingsRow(
                    color: .red,
                    title: "sponsorblock",
                    subtitle: "settings_sub_sponsorblock",
                    imageSystemName: "forward.end.fill"
                ) { AnyView(SponsorBlockSettingsView()) }

                // 屏蔽艺人：与 SponsorBlock 同一类"跳过不想听的东西"，所以放在它后面。
                settingsRow(
                    color: Color(hex: "#FF9F0A"),
                    title: "blocked_artists_title",
                    subtitle: "settings_sub_blocked_artists",
                    imageSystemName: "person.slash.fill"
                ) { AnyView(EeveeBlockedArtistsSettingsView()) }

                // 睡眠定时器：到点暂停播放（见 `SleepTimerController`）。Spotify 自己那份
                // 在播客菜单里，那条不受影响，两者可以同时开。
                settingsRow(
                    color: .indigo,
                    title: "sleep_timer_title",
                    subtitle: "settings_sub_sleep_timer",
                    imageSystemName: "moon.zzz.fill"
                ) { AnyView(EeveeSleepTimerSettingsView()) }

                // 听歌统计：本地记录播放次数与时长（见 `ListeningStatsRecorder`）。
                settingsRow(
                    color: .teal,
                    title: "listening_stats_title",
                    subtitle: "settings_sub_listening_stats",
                    imageSystemName: "chart.bar.fill"
                ) { AnyView(EeveeListeningStatsSettingsView()) }
            }

            // ── ② 外观
            Section(header: Text("settings_group_appearance".localized)) {
                // 标签栏、迷你条，外加整页配色（纯黑 / 强调色）—— 都是"界面外壳"。
                settingsRow(
                    color: Color(hex: "#5E5CE6"),
                    title: "tabs_and_mini_bar_title",
                    subtitle: "settings_sub_tabs",
                    imageSystemName: "rectangle.on.rectangle"
                ) { AnyView(TabBarAndMiniBarSettingsView()) }

                settingsRow(
                    color: Color(hex: "#64D2FF"),
                    title: "home_and_library_title",
                    subtitle: "settings_sub_home_library",
                    imageSystemName: "rectangle.stack.fill"
                ) { AnyView(PagesAppearanceSettingsView()) }

                settingsRow(
                    color: .pink,
                    title: "appIcon",
                    subtitle: "settings_sub_app_icon",
                    imageSystemName: "app.badge.fill"
                ) { AnyView(EeveeAppIconPickerView()) }

                // 锁屏封面与锁屏歌词合成一页（见 `EeveeLockScreenSettingsView` 的文件头）。
                settingsRow(
                    color: Color(hex: "#1ED760"),
                    title: "lock_screen_title",
                    subtitle: "settings_sub_lock_screen",
                    imageSystemName: "lock.rectangle"
                ) { AnyView(EeveeLockScreenSettingsView()) }
            }

            // ── ③ 进阶
            Section(header: Text("settings_group_advanced".localized)) {
                settingsRow(
                    color: .purple,
                    title: "experiments",
                    subtitle: "settings_sub_experiments",
                    imageSystemName: "sparkle"
                ) { AnyView(EeveeExperimentsSettingsView()) }

                // 「减少打扰」带着一个二级入口进「Flag 覆盖」—— 那一页需要导航栈
                // 才能继续推「手动写入」，所以这里把栈传进去。
                settingsRow(
                    color: Color(hex: "#FF6482"),
                    title: "reduce_interventions_title",
                    subtitle: "settings_sub_reduce",
                    imageSystemName: "bell.slash.fill"
                ) { AnyView(EeveeReduceInterventionsView(navigationController: navigationController)) }

                settingsRow(
                    color: Color(hex: "#FF375F"),
                    title: "haptics_title",
                    subtitle: "settings_sub_haptics",
                    imageSystemName: "waveform"
                ) { AnyView(EeveeHapticsSettingsView()) }

                settingsRow(
                    color: Color(hex: "#30B0C7"),
                    title: "privacy_title",
                    subtitle: "settings_sub_privacy",
                    imageSystemName: "hand.raised.fill"
                ) { AnyView(EeveePrivacySettingsView()) }

                settingsRow(
                    color: .gray,
                    title: "miscellaneous",
                    subtitle: "settings_sub_misc",
                    imageSystemName: "ellipsis.circle.fill"
                ) { AnyView(EeveeMiscellaneousSettingsView()) }
            }

            // ── ④ 高级（音频 / 设备能力）
            //
            // 这一组装的是「要连到系统能力上、都不是纯 UI」的功能：音频效果、音频特征驱动的
            // 律动与节拍触感、AirPods 头部姿态。它们默认全关，出错时影响面也比外观类开关大，
            // 所以单独成组；四件事现在同在一页（`EeveeAudioSettingsView`）。
            Section(header: Text("settings_group_high".localized)) {
                settingsRow(
                    color: Color(hex: "#FF2D55"),
                    title: "audio_title",
                    subtitle: "settings_sub_audio",
                    imageSystemName: "waveform.path.ecg"
                ) { AnyView(EeveeAudioSettingsView()) }
            }

            // ── ⑤ 维护
            //
            // 「调试」页：排查/验证型开关 + 转储 + 日志工具（开启 / 导出 / 清除）。
            // 它**不是**下面两个重置按钮的替代品：这里是"排查与日志"，那里是"清数据"。
            Section(header: Text("maintenance_section".localized)) {
                settingsRow(
                    color: Color(hex: "#64D2FF"),
                    title: "backup_title",
                    subtitle: "settings_sub_backup",
                    imageSystemName: "externaldrive.badge.timemachine"
                ) { AnyView(EeveeBackupSettingsView()) }

                settingsRow(
                    color: Color(hex: "#32ADE6"),
                    title: "updates_title",
                    subtitle: "settings_sub_updates",
                    imageSystemName: "clock.arrow.circlepath"
                ) { AnyView(EeveeUpdatesSettingsView()) }

                settingsRow(
                    color: Color(hex: "#8E8E93"),
                    title: "licenses_title",
                    subtitle: "settings_sub_licenses",
                    imageSystemName: "doc.badge.ellipsis"
                ) { AnyView(EeveeLicensesSettingsView()) }

                settingsRow(
                    color: Color(hex: "#8E8E93"),
                    title: "debug_title",
                    subtitle: "settings_sub_debug",
                    imageSystemName: "wrench.and.screwdriver.fill"
                ) { AnyView(EeveeDebugSettingsView()) }
            }

            Section(footer: Text("reset_data_description".localized)) {
                Button {
                    confirmDestructive(
                        title: "reset_data".localized,
                        message: "reset_data_description".localized,
                        confirmTitle: "reset_data".localized
                    ) {
                        isClearingData = true

                        DispatchQueue.global(qos: .userInitiated).async {
                            OfflineHelper.resetData(clearCaches: true)

                            DispatchQueue.main.async {
                                exitApplication()
                            }
                        }
                    }
                } label: {
                    if isClearingData {
                        ProgressView()
                    }
                    else {
                        Text("reset_data".localized)
                    }
                }
            }

            Section(footer: Text("resetFooter".localized)) {
                Button {
                    confirmDestructive(
                        title: "resetButtonTitle".localized,
                        // 用 `resetFooter` 而不是 `resetSubtitle`：后者是 SponsorBlock
                        // 「重置」ActionSheet 的 message（"各项互不影响。"），拿它当确认框正文
                        // 会让每一种语言的"完全重置"都在说"各项互不影响"。
                        // `resetFooter` 就是这条 Section 下面那段擦除说明，语义正确。
                        message: "resetFooter".localized,
                        confirmTitle: "resetButtonTitle".localized
                    ) {
                        isClearingData = true
                        DispatchQueue.global(qos: .userInitiated).async {
                            FullResetHelper.wipeSpotifyState()
                            DispatchQueue.main.async {
                                exitApplication()
                            }
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text("resetButtonTitle".localized)
                    }
                    .foregroundColor(.red)
                }
            }

            Section {
                Color.clear
                    .frame(height: 90)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
        }
        // 胶囊卡片式的分组：`InsetGroupedListStyle`。
        // spoti.pw 的设置页也是这一档（`UITableViewStyleInsetGrouped` + iOS 14 的
        // `UIListContentConfiguration`），SwiftUI 里的等价物就是它：
        // · `GroupedListStyle`（我们原来用的）= **贴边、直角**的分组卡；
        // · `InsetGroupedListStyle` = 每一节左右各内缩 ≈20pt、四角是圆角的卡片，
        // 在 **iOS 26 上系统会把它画成很圆的"胶囊卡片"**。
        // 本仓库所有自建设置页统一用这一档。
        .listStyle(InsetGroupedListStyle())
        
        .animation(.default, value: isClearingData)
        .animation(.default, value: hasShownCommonIssuesTip)

        .onAppear {
            WindowHelper.shared.overrideUserInterfaceStyle(.dark)
        }
    }
}
