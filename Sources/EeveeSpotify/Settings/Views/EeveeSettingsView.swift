import SwiftUI
import UIKit

/// 设置根页。
///
/// 分组与行的来源是 `SettingsCatalog`：这里只负责渲染、搜索入口与两个重置按钮，
/// 不再逐行调用 `settingsRow(...)`。分组按**对象**切（播放 / 歌词 / 界面 / 音频 / 高级 /
/// 关于），不按"难度"切 —— 后者会造出两个都叫"高级"的组，且把补丁、跳段、定时器
/// 塞进"播放与歌词"里。
///
/// 一条约束：根页只放**入口**，不放开关。开关都在各自的页里，一页一件事；
/// 需要归类的用组头，不用合并页（合并页会让"找某个开关"变成"在长页里滚"）。
///
/// 自建页大多带「重置本页」（`SettingsResetSection`）；备份 / 导入 / 重置覆盖的键
/// 与拆分前一致（`UserDefaults.ownedKeys` 没有删键）。
///
/// ⚠️ 刻意**没有**跟上游那样加 logo 大标题：我们 bundle 里只有 `github.png`。
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

            searchSection

            // 行序就是 `SettingsCatalog.entries` 里的声明顺序，分组按 `allCases`。
            ForEach(SettingsGroup.allCases) { group in
                Section(header: Text(group.titleKey.localized)) {
                    ForEach(SettingsCatalog.entries(in: group)) { entry in
                        settingsRow(for: entry)
                    }
                }
            }

            // 日志入口放在「关于与维护」之后、重置之前：遇到问题的顺序是
            // "看版本 → 开记录 → 导出 → 发给人"，重置是最后一步。
            SettingsLogSection()

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
        // `UIListContentConfiguration`），SwiftUI 里的等价物就是它。本仓库所有自建设置页
        // 统一用这一档。
        .listStyle(InsetGroupedListStyle())

        .animation(.default, value: isClearingData)
        .animation(.default, value: hasShownCommonIssuesTip)

        .onAppear {
            WindowHelper.shared.overrideUserInterfaceStyle(.dark)
        }
    }

    /// 搜索入口：单独一行，点开是一个带输入框的过滤页。
    ///
    /// 为什么不做成导航栏上的搜索框：根页是 `UIHostingController` 挂在
    /// `SPTPageViewController` 里的，`UISearchController` 要挂到导航栏上，
    /// 会和 Spotify 自己的导航条抢位置；独立一页最稳，也方便以后加"最近搜索"。
    private var searchSection: some View {
        Section {
            Button {
                SettingsPagePresenter.push(
                    AnyView(EeveeSettingsSearchView(navigationController: navigationController)),
                    title: "settings_search_title".localized,
                    from: navigationController
                )
            } label: {
                NavigationSectionView(
                    color: .gray,
                    title: "settings_search_title".localized,
                    imageSystemName: "magnifyingglass",
                    subtitle: "settings_search_subtitle".localized
                )
            }
        }
    }

    /// 根页的一行：彩色图标 + 标题 + **灰色副标题** + 可选状态 + 右箭头。
    ///
    /// 状态文字（补丁"已启用 / 未启用"）在渲染时求值，所以从补丁页返回后不需要
    /// 额外刷新 —— `List` 重绘时会重新读 `UserDefaults`。
    @ViewBuilder
    private func settingsRow(for entry: SettingsEntry) -> some View {
        Button {
            SettingsPagePresenter.push(
                entry.destination(navigationController),
                title: entry.titleKey.localized,
                from: navigationController
            )
        } label: {
            NavigationSectionView(
                color: entry.color,
                title: entry.titleKey.localized,
                imageSystemName: entry.iconName,
                subtitle: entry.subtitleKey.localized,
                status: entry.status?()
            )
        }
    }
}
