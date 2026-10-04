import SwiftUI
import UIKit

/// 「屏蔽的艺人」页：一个总开关 + 一份可增删的名单。
///
/// 名单的语义与边界都写在脚注里（见 l10n 的 `blocked_artists_description`）——
/// 这一页刻意保持最小：**不做**"从艺人页一键屏蔽"（要 hook 艺人页的上下文菜单，
/// 风险和收益不成比例，手动打字加一样能用）。
struct EeveeBlockedArtistsSettingsView: View {

    /// 影子值（与「扩展功能」页同一套）：写 `UserDefaults` **不会**让 SwiftUI 重绘，
    /// 所以每个控件先改本地状态再落盘 —— 否则删掉一行、标签还是旧的（那是我们刚修过的 bug）。
    @State private var isEnabled = UserDefaults.blockedArtistsEnabled
    @State private var names = UserDefaults.blockedArtists
    @State private var newName = ""

    var body: some View {
        List {
            Section(footer: Text("blocked_artists_description".localized)) {
                Toggle(
                    "blocked_artists_enabled".localized,
                    isOn: Binding(
                        get: { isEnabled },
                        set: { value in
                            isEnabled = value
                            UserDefaults.blockedArtistsEnabled = value
                        }
                    )
                )
            }

            Section(header: Text("blocked_artists_list_header".localized)) {
                if names.isEmpty {
                    Text("blocked_artists_empty".localized)
                        .foregroundColor(.secondary)
                }

                ForEach(names, id: \.self) { name in
                    Text(name)
                }
                .onDelete { offsets in
                    var items = names
                    items.remove(atOffsets: offsets)
                    names = items
                    UserDefaults.blockedArtists = items
                }
            }

            Section(footer: Text("blocked_artists_add_footer".localized)) {
                HStack {
                    TextField("blocked_artists_add_placeholder".localized, text: $newName)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)

                    Button("blocked_artists_add".localized) {
                        add()
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            if !names.isEmpty {
                Section {
                    Button("blocked_artists_clear_all".localized) {
                        BlockedArtists.removeAll()
                        names = []
                    }
                    .foregroundColor(.red)
                }
            }
        }
                // ★ 2026-10-12：inset-grouped（胶囊卡片）—— 为什么、怎么做的见 `EeveeSettingsView` 顶部那段
        .listStyle(InsetGroupedListStyle())
    }

    private func add() {
        let value = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }

        // 规范化（去空白）与去重（忽略大小写）都在数据层，页面不重复实现一遍。
        BlockedArtists.add(value)
        names = UserDefaults.blockedArtists
        newName = ""
    }
}
