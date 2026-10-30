import SwiftUI
import UIKit

/// 设置根页。
///
/// ## 2026-10-13 重排（用户：「现在的设置页面的选项…有点乱了」，拍板方案 B）
///
/// 重排前：11 行平铺 + 一个「扩展」杂物袋 —— 根页只有 11 行，但「扩展」那一页里塞着
/// **19 个开关 + 8 个子页入口**（627 行）⇒ 想找"备份/许可/更新"要进两层，
/// 而"听歌页""标签栏"这种天天用的开关要滚到扩展页第 4、5 节。
///
/// 现在：
///   · 根页分**四组**（播放与歌词 / 外观 / 进阶 / 维护），每一行都带**副标题**
///     （`NavigationSectionView.subtitle`）—— 一眼能看出这一行进去有什么；
///   · 那 8 个子页全部提到根页按语义归组，一步可达；
///   · 「扩展」页里那 24 个开关按**页面**拆成几页：
///     `NowPlayingSettingsView` / `TabBarAndMiniBarSettingsView` /
///     `PagesAppearanceSettingsView`；
///   · 每个新页各自带一颗「重置本页」（`SettingsResetSection`）。
///
/// ★ 2026-10-18（用户：「外观 页有点乱，不如把 首页音乐库 和 专辑/歌单页 合在一起，
///   然后把那些分散的/未添加的艺人页的部分加上」）：
///   原来「首页与音乐库」与「专辑 / 歌单页」是**两个入口**，各自只有三四颗开关；而 AM 页头
///   与取色底本来就同时管专辑 / 歌单 / **艺人**三页 ⇒ 艺人页被藏在「专辑 / 歌单页」的名字后面。
///   现在两页合成 `PagesAppearanceSettingsView` 一页，见该文件头。
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
    /// 抽成一个函数是因为根页现在有 20 行 —— 每行再手写一遍
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

            // ── ① 播放与歌词 ──────────────────────────────────────────────────
            Section(header: Text("settings_group_playback".localized)) {
                settingsRow(
                    color: .blue,
                    title: "lyrics",
                    subtitle: "settings_sub_lyrics",
                    imageSystemName: "quote.bubble.fill"
                ) { AnyView(EeveeLyricsSettingsView()) }

                // ★ 2026-10-23（用户：「设置页里面放个可点击进去的页面吧」）：歌词偏移
                //   从歌词页拆成独立页 —— 它会随听歌不断长出条目，内嵌在歌词页里越拖越长。
                // ★ 2026-10-24：从"网易云歌词偏移"扩成**所有源**（Genius 除外），
                //   标题与副标题跟着改成通用的。
                settingsRow(
                    color: Color(hex: "#30B0C7"),
                    title: "lyrics_offset_title",
                    subtitle: "settings_sub_lyrics_offset",
                    imageSystemName: "timer"
                ) { AnyView(EeveeLyricsOffsetSettingsView()) }

                // 听歌页那一整页开关（原「扩展」页的 `now_playing_section` + 藏 chrome 三颗）。
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
            }

            // ── ② 外观 ────────────────────────────────────────────────────────
            Section(header: Text("settings_group_appearance".localized)) {
                settingsRow(
                    color: Color(hex: "#5E5CE6"),
                    title: "tabs_and_mini_bar_title",
                    subtitle: "settings_sub_tabs",
                    imageSystemName: "rectangle.on.rectangle"
                ) { AnyView(TabBarAndMiniBarSettingsView()) }

                // ★ 2026-10-18：原「首页与音乐库」+「专辑 / 歌单页」两行合成这一行
                //   （见 `PagesAppearanceSettingsView` 的文件头）。
                settingsRow(
                    color: Color(hex: "#64D2FF"),
                    title: "home_and_library_title",
                    subtitle: "settings_sub_home_library",
                    imageSystemName: "rectangle.stack.fill"
                ) { AnyView(PagesAppearanceSettingsView()) }

                settingsRow(
                    color: Color(hex: "#64D2FF"),
                    title: "customization",
                    subtitle: "settings_sub_customization",
                    imageSystemName: "paintpalette.fill"
                ) { AnyView(EeveeUISettingsView()) }

                settingsRow(
                    color: .pink,
                    title: "appIcon",
                    subtitle: "settings_sub_app_icon",
                    imageSystemName: "app.badge.fill"
                ) { AnyView(EeveeAppIconPickerView()) }
            }

            // ── ③ 进阶 ────────────────────────────────────────────────────────
            Section(header: Text("settings_group_advanced".localized)) {
                settingsRow(
                    color: .purple,
                    title: "experiments",
                    subtitle: "settings_sub_experiments",
                    imageSystemName: "sparkle"
                ) { AnyView(EeveeExperimentsSettingsView()) }

                // Flag 覆盖：注入远程开关。⚠️ 它需要 navigationController（页内还要推「手动写入」）。
                //
                // ★ 2026-10-17（用户：「关于 flag 这部分…用上游的」）：入口换成**浏览器**
                //   （`RemoteFlags` 自动扫出来的清单 + 搜索 + 只看改过的 + 按种类给编辑器）。
                //   原来那个"自己填 name/scope/模式/值"的编辑页没有删 —— 它现在是浏览器页里
                //   的一行「手动写入」（两页写同一张表），因为采集按 Spotify 版本做，
                //   刚装/刚升级时浏览器可能是空的，那时还得有一条能动手的路。
                settingsRow(
                    color: Color(hex: "#5E5CE6"),
                    title: "flag_override_title",
                    subtitle: "settings_sub_flags",
                    imageSystemName: "slider.horizontal.3"
                ) {
                    AnyView(EeveeFlagBrowserView(navigationController: navigationController))
                }

                settingsRow(
                    color: Color(hex: "#FF6482"),
                    title: "reduce_interventions_title",
                    subtitle: "settings_sub_reduce",
                    imageSystemName: "bell.slash.fill"
                ) { AnyView(EeveeReduceInterventionsView()) }

                settingsRow(
                    color: Color(hex: "#FF375F"),
                    title: "haptics_title",
                    subtitle: "settings_sub_haptics",
                    imageSystemName: "waveform"
                ) { AnyView(EeveeHapticsSettingsView()) }

                settingsRow(
                    color: Color(hex: "#FF9F0A"),
                    title: "blocked_artists_title",
                    subtitle: "settings_sub_blocked_artists",
                    imageSystemName: "person.slash.fill"
                ) { AnyView(EeveeBlockedArtistsSettingsView()) }

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

            // ── ④ 维护 ────────────────────────────────────────────────────────
            //
            // 「调试」页：只装**排查/验证型**开关（补时间轴 / 补卡片元素 / 强制歌词入口）。
            // 它们以前散在「歌词」页里，和用户真正的偏好混在一起 —— 见
            // `EeveeDebugSettingsViewModel` 的说明。l10n 沿用既有的 `debug_title`。
            //
            // ⚠️ 这**不是**下面那个「Debug」区（日志记录 / 导出 / 清空）的替代品，
            // 两者是并列的：这里是"排查开关"，那里是"日志工具"。
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

            // （已移除：Reincarnated 的「开发者手记」入口 EeveeDevNoteView ——
            //   它从 SideloadLabs 仓库在线拉取 devnote.txt，内容是"只从官方
            //   Telegram 频道下载 IPA"的提醒，与本仓库无关）

            // ── 日志工具（属于上面「维护」组的延伸，不单独成组）──────────────────
            Section(header: Text("debug_title".localized), footer: Text("enable_log_recording_description".localized)) {
                Toggle(
                    "enable_log_recording".localized,
                    isOn: Binding<Bool>(
                        get: { UserDefaults.enableLogRecording },
                        set: { newValue in
                            UserDefaults.enableLogRecording = newValue
                            if newValue {
                                writeDebugLog("[LOG] Log recording enabled")
                            }
                        }
                    )
                )

                Button {
                    let logPath = NSTemporaryDirectory() + "eeveespotify_debug.log"
                    guard FileManager.default.fileExists(atPath: logPath),
                          let logData = FileManager.default.contents(atPath: logPath),
                          logData.count > 0 else {
                        PopUpHelper.showPopUp(message: "no_debug_log_found".localized, buttonText: "no_debug_log_found_ok".localized)
                        return
                    }
                    // 分享的是**可分享的那一份**：`redactSharedLog` 开着时是假名化后的副本，
                    // 原文件一个字都不动（排查要用的真实曲目还留在本地）。
                    // （那颗开关**2026-10-17 已搬进「调试」页** —— 默认"开"，见 `EeveeDebugSettingsView`。）
                    // 凭证/设备标识那一层不在这里 —— 它在写入口就生效了，见 `DebugLogSanitizer`。
                    //
                    // ⚠️ 脱敏版生成失败时**绝不回退到原文件**：那正好是"用户以为已经脱敏、
                    // 实际分享了明文"的场景。宁可导出失败并告诉他，也不能静默 fail-open。
                    let logURL: URL
                    if UserDefaults.redactSharedLog {
                        guard let redacted = DebugLogSanitizer.sharedLogFile(from: logPath, redact: true) else {
                            PopUpHelper.showPopUp(
                                message: "redact_log_failed".localized,
                                buttonText: "redact_log_failed_ok".localized
                            )
                            return
                        }
                        logURL = redacted
                    } else {
                        logURL = DebugLogSanitizer.sharedLogFile(from: logPath, redact: false)
                            ?? URL(fileURLWithPath: logPath)
                    }
                    let activityVC = UIActivityViewController(activityItems: [logURL], applicationActivities: nil)
                    if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                       let rootVC = scene.windows.first?.rootViewController {
                        var topVC = rootVC
                        while let presented = topVC.presentedViewController { topVC = presented }
                        if let popover = activityVC.popoverPresentationController {
                            popover.sourceView = topVC.view
                            popover.sourceRect = CGRect(x: topVC.view.bounds.midX, y: topVC.view.bounds.midY, width: 0, height: 0)
                        }
                        topVC.present(activityVC, animated: true)
                    }
                } label: {
                    HStack {
                        Image(systemName: "square.and.arrow.up")
                        Text("export_debug_log".localized)
                    }
                }
                
                Button {
                    let logPath = NSTemporaryDirectory() + "eeveespotify_debug.log"
                    guard FileManager.default.fileExists(atPath: logPath),
                          let logData = FileManager.default.contents(atPath: logPath),
                          logData.count > 0 else {
                        PopUpHelper.showPopUp(message: "no_log_to_clear".localized, buttonText: "no_log_to_clear_ok".localized)
                        return
                    }
                    try? "".write(toFile: logPath, atomically: true, encoding: .utf8)
                    writeDebugLog("Log cleared by user")
                    PopUpHelper.showPopUp(message: "debug_log_cleared".localized, buttonText: "debug_log_cleared_ok".localized)
                } label: {
                    HStack {
                        Image(systemName: "trash")
                        Text("clear_debug_log".localized)
                    }
                    .foregroundColor(.red)
                }
            }

            // ★ 2026-10-13（用户）：「把转储 customize 响应体**搬到「调试」里面去**」
            //   ⇒ 那一节已整体搬到 `EeveeDebugSettingsView`。
            // ★★ 2026-10-30：它和「转储视图树」已合并成一颗「更详细的日志记录」；
            //   底下仍写 `UserDefaults.dumpCustomizeBody` ⇒ 设备上已设的值原样保留。
            
            // 「分享日志前脱敏」：**2026-10-17 用户要求搬进「调试」页**（与三个"转储"放到一条线上：
            //   前面几个是"写进日志"，它是"发出去之前先假名化"）。它只影响**导出**的那一份
            //   （见上面导出按钮里 `DebugLogSanitizer.sharedLogFile(from:redact:)`）。
            //   ⚠️ l10n 键（`redact_shared_log` / `redact_shared_log_description`）与
            //      `UserDefaults.redactSharedLog` **都没变**、默认仍是"开" ⇒ 设备上的值原样保留。
            //   ⇒ 这里不再有那一节，别搬回来。

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
                        // ★ 2026-10-11 修：这里原来是 `resetSubtitle` —— 那个键是
                        // **SponsorBlock「重置」ActionSheet 的 message**（en：「Each is independent.」
                        // / 中文「各项互不影响。」），于是**每一种语言的"完全重置"确认框都在说
                        // "各项互不影响。"**（真机反馈 + 审计发现，`it` 里甚至因此出现了同一个键的
                        // 两条不同意译）。
                        // 改用 `resetFooter`：它就是这条 Section 下面那段**擦除说明**
                        // （"会强制重新登录…清除钥匙串/沙盒/应用组容器…"），各语言都已翻，语义正确。
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
        // ★★ 2026-10-12（用户：「现在的设置页面的选项是像这样的长方形，但是 pw 把它做成了胶囊
        //   一样的样子，怎么实现的」）—— **pw 的做法就是 `UITableViewStyleInsetGrouped`**
        //   （它的 10+ 个设置页都是 `initWithStyle:UITableViewStyleInsetGrouped`，
        //    内容用 iOS 14 的 `UIListContentConfiguration`），
        //   SwiftUI 里的等价物就是 `InsetGroupedListStyle()`：
        //   · `GroupedListStyle()`（我们原来用的）= **贴边、直角**的分组卡（照片 78 的样子）；
        //   · `InsetGroupedListStyle()` = 每一节左右各内缩 ≈20pt、四角是圆角的卡片，
        //     在 **iOS 26 上系统会把它画成很圆的"胶囊卡片"** —— 就是用户要的那个样子。
        //   本仓库所有自建设置页统一用这一档。
        .listStyle(InsetGroupedListStyle())
        
        .animation(.default, value: isClearingData)
        .animation(.default, value: hasShownCommonIssuesTip)

        .onAppear {
            WindowHelper.shared.overrideUserInterfaceStyle(.dark)
        }
    }
}
