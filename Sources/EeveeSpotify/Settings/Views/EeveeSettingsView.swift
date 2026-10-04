import SwiftUI
import UIKit

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
            
            //
            
            Button {
                pushSettingsController(
                    with: EeveePatchingSettingsView(),
                    title: "patching".localized
                )
            } label: {
                NavigationSectionView(
                    color: .orange,
                    title: "patching".localized,
                    imageSystemName: "hammer.fill"
                )
            }
            
            Button {
                pushSettingsController(
                    with: EeveeLyricsSettingsView(),
                    title: "lyrics".localized
                )
            } label: {
                NavigationSectionView(
                    color: .blue,
                    title: "lyrics".localized,
                    imageSystemName: "quote.bubble.fill"
                )
            }
            
            Button {
                pushSettingsController(
                    with: EeveeUISettingsView(),
                    title: "customization".localized
                )
            } label: {
                NavigationSectionView(
                    color: Color(hex: "#64D2FF"),
                    title: "customization".localized,
                    imageSystemName: "paintpalette.fill"
                )
            }
            
            Button {
                pushSettingsController(
                    with: EeveeExperimentsSettingsView(),
                    title: "experiments".localized
                )
            } label: {
                NavigationSectionView(
                    color: .purple,
                    title: "experiments".localized,
                    imageSystemName: "sparkle"
                )
            }

            Button {
                pushSettingsController(
                    with: SponsorBlockSettingsView(),
                    title: "sponsorblock".localized
                )
            } label: {
                NavigationSectionView(
                    color: .red,
                    title: "sponsorblock".localized,
                    imageSystemName: "forward.end.fill"
                )
            }

            Button {
                pushSettingsController(
                    with: EeveeAppIconPickerView(),
                    title: "appIcon".localized
                )
            } label: {
                NavigationSectionView(
                    color: .pink,
                    title: "appIcon".localized,
                    imageSystemName: "app.badge.fill"
                )
            }

            Button {
                pushSettingsController(
                    with: EeveeMiscellaneousSettingsView(),
                    title: "miscellaneous".localized
                )
            } label: {
                NavigationSectionView(
                    color: .gray,
                    title: "miscellaneous".localized,
                    imageSystemName: "ellipsis.circle.fill"
                )
            }

            // 后加的一批（深色栏 / 隐私 / 触感 / Flag 覆盖）集中一页：根页只多一行，
            // 功能各进自己的页 —— spoti.pw 的根页就是这个结构（分类在根、功能在子页）。
            Button {
                pushSettingsController(
                    with: EeveeExtrasSettingsView(navigationController: navigationController),
                    title: "extras_title".localized
                )
            } label: {
                NavigationSectionView(
                    color: Color(hex: "#5E5CE6"),
                    title: "extras_title".localized,
                    imageSystemName: "sparkles"
                )
            }

            // 「调试」页：只装**排查/验证型**开关（补时间轴 / 补卡片元素 / 强制歌词入口）。
            // 它们以前散在「歌词」页里，和用户真正的偏好混在一起 —— 见
            // `EeveeDebugSettingsViewModel` 的说明。l10n 沿用既有的 `debug_title`。
            //
            // ⚠️ 这**不是**下面那个「Debug」区（日志记录 / 导出 / 清空）的替代品，
            // 两者是并列的：这里是"排查开关"，那里是"日志工具"。
            Button {
                pushSettingsController(
                    with: EeveeDebugSettingsView(),
                    title: "debug_title".localized
                )
            } label: {
                NavigationSectionView(
                    color: Color(hex: "#8E8E93"),
                    title: "debug_title".localized,
                    imageSystemName: "wrench.and.screwdriver.fill"
                )
            }

            //

            // （已移除：Reincarnated 的「开发者手记」入口 EeveeDevNoteView ——
            //   它从 SideloadLabs 仓库在线拉取 devnote.txt，内容是"只从官方
            //   Telegram 频道下载 IPA"的提醒，与本仓库无关）

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

            // 「转储 customize 响应体」：**只为一件事**存在 —— 换掉随包的种子快照。
            //
            // 背景：flag 改写依赖 customize 的响应体，而 304 无 body 时我们只能回放
            // 种子（`SpotifyResponsePatcher.seedCustomizeDataIfNeeded`，用的是 9.1.76
            // 时期转存的 `.bnk`）。打开这个开关 + 用一次「覆盖配置」（它会清缓存、
            // 逼服务器回 200）→ 下次启动就能从日志里取到**你这版**的真 body。
            // 单独一个 Section：它写在日志里，而日志是要导出的，别和"清空日志"混。
            Section(footer: Text("dump_customize_body_description".localized)) {
                Toggle(
                    "dump_customize_body".localized,
                    isOn: Binding<Bool>(
                        get: { UserDefaults.dumpCustomizeBody },
                        set: { UserDefaults.dumpCustomizeBody = $0 }
                    )
                )
            }
            
            // 「分享日志前脱敏」：只影响**导出**这一份 → 见 `DebugLogSanitizer.redactForSharing`。
            // 单独一个 Section（不塞进上面那个），因为上面那个的 footer 讲的是"要不要记日志"。
            Section(footer: Text("redact_shared_log_description".localized)) {
                Toggle(
                    "redact_shared_log".localized,
                    isOn: Binding<Bool>(
                        get: { UserDefaults.redactSharedLog },
                        set: { UserDefaults.redactSharedLog = $0 }
                    )
                )
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
                        // ★ 2026-10-11 修：这里原来是 `resetSubtitle` —— 那个键是
                        // **SponsorBlock「重置」ActionSheet 的 message**（en：「Each is independent.」
                        // / 中文「各项互不影响。」），于是**每一种语言的"完全重置"确认框都在说
                        // "各项互不影响。"**（真机反馈 + 审计发现，`it` 里甚至因此出现了同一个键
                        // 的两条不同意译）。
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
        //   本仓库所有自建设置页统一用这一档（`InsetGroupedListStyle` 是 iOS 14+，
        //   与我们的最低版本一致；仓库里原本就有 4 个页面在用）。
        .listStyle(InsetGroupedListStyle())
        
        .animation(.default, value: isClearingData)
        .animation(.default, value: hasShownCommonIssuesTip)

        .onAppear {
            WindowHelper.shared.overrideUserInterfaceStyle(.dark)
        }
    }
}
