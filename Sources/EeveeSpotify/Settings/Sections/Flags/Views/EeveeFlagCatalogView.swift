import SwiftUI
import UIKit

/// 「已知 flag」独立页 + 过滤框。
///
/// 为什么从覆盖页里拆出来：41 条目录挤在覆盖页里，那一页就成了"表格墙"（用户反馈
/// 页面臃肿）。spoti.pw 的 All flags 也是独立页 + 搜索框，这里照同样的结构。
///
/// 交互只有两条：
///   · **点一下 = 加一条覆盖**（bool 类默认"关"，enum 类默认写回服务端下发的那个值）；
///   · **再点一下 = 取消覆盖**（回到 Spotify 自己的值）。
/// 绿色勾表示这条已经被覆盖。改具体取值（Auto/开/关/写值）去上一层「Flag 覆盖」页。
struct EeveeFlagCatalogView: View {

    @State private var overrides = FlagOverrideStore.all
    @State private var filter = ""

    var body: some View {
        List {
            Section(footer: Text("flag_catalog_description".localized)) {
                TextField("flag_catalog_search_placeholder".localized, text: $filter)
            }

            ForEach(filteredGroups, id: \.titleKey) { group in
                Section(header: Text(group.titleKey.localized)) {
                    ForEach(group.flags, id: \.self) { flag in
                        row(flag)
                    }
                }
            }

            if filteredGroups.isEmpty {
                Section {
                    Text("flag_catalog_empty_result".localized)
                        .foregroundColor(.secondary)
                }
            }
        }
        .listStyle(GroupedListStyle())
        .onAppear {
            overrides = FlagOverrideStore.all
        }
    }

    // MARK: - 过滤

    private var filteredGroups: [KnownFlagGroup] {
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return KnownFlagCatalog.groups }

        return KnownFlagCatalog.groups.compactMap { group in
            let flags = group.flags.filter {
                $0.name.lowercased().contains(needle) || $0.scope.lowercased().contains(needle)
            }

            return flags.isEmpty ? nil : KnownFlagGroup(titleKey: group.titleKey, flags: flags)
        }
    }

    // MARK: - 行

    private func row(_ flag: KnownFlag) -> some View {
        Button {
            toggle(flag)
        } label: {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(flag.name)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.primary)

                    Text(verbatim: "\(flag.scope) · \(flag.observedValue)")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    if let noteKey = flag.noteKey {
                        Text(noteKey.localized)
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                }

                Spacer()

                if isOverridden(flag) {
                    Image(systemName: "checkmark")
                        .foregroundColor(.green)
                } else if flag.type == .int {
                    Text("flag_catalog_unsupported".localized)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .disabled(flag.type == .int)
    }

    private func isOverridden(_ flag: KnownFlag) -> Bool {
        let id = KnownFlagCatalog.id(for: flag)
        return overrides.contains { $0.id == id }
    }

    private func toggle(_ flag: KnownFlag) {
        guard let prefilled = KnownFlagCatalog.prefilledOverride(for: flag) else { return }

        let id = KnownFlagCatalog.id(for: flag)

        if overrides.contains(where: { $0.id == id }) {
            FlagOverrideStore.remove(id: id)
        } else {
            FlagOverrideStore.upsert(prefilled)
        }

        overrides = FlagOverrideStore.all
    }
}
