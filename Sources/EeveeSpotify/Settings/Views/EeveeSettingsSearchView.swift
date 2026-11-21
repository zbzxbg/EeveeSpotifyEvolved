import SwiftUI
import UIKit

/// 设置搜索：一个输入框 + 过滤后的入口列表，点进去就是对应的设置页。
///
/// 匹配的是**本地化后的标题与副标题**加每行的别名（`SettingsEntry.aliases`，
/// 常见俗称如"会员""广告""EQ""震动"），所以中英文两种叫法都搜得到。
/// 结果保留目录里的原始顺序 —— 同组的行仍然相邻，用户能看出它属于哪一块。
struct EeveeSettingsSearchView: View {
    let navigationController: UINavigationController

    @State private var query = ""

    private var results: [SettingsEntry] {
        SettingsCatalog.search(query)
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)

                    TextField("settings_search_placeholder".localized, text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if results.isEmpty {
                Section {
                    Text("settings_search_empty".localized)
                        .foregroundColor(.secondary)
                }
            } else {
                Section {
                    ForEach(results) { entry in
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
                                subtitle: entry.group.titleKey.localized
                            )
                        }
                    }
                }
            }
        }
        // 与其它自建页一致的胶囊卡片分组。
        .listStyle(InsetGroupedListStyle())
    }
}
