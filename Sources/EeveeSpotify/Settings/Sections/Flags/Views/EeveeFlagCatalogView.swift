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
                // `footer:` 用**非可选**的 `Text`（空串就是不显示）：`Text?` 的写法会跟
                // "header/footer 类型可不同"的那个重载撞上，编译器说不清用哪个。
                Section(
                    header: Text(group.titleKey.localized),
                    footer: Text(group.footerKey.map { $0.localized } ?? "")
                ) {
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

            return flags.isEmpty
                ? nil
                : KnownFlagGroup(titleKey: group.titleKey, footerKey: group.footerKey, flags: flags)
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

                    // `observedValue` 为空 = 只在 IPA 字面量表里见过（没在设备日志里出现过），
                    // 这一行就只显示 scope，别编一个假的"观察值"出来。
                    Text(verbatim: flag.observedValue.isEmpty
                         ? flag.scope
                         : "\(flag.scope) · \(flag.observedValue)")
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
                } else if KnownFlagCatalog.prefilledOverride(for: flag) == nil {
                    // 目前只有"没观察到过数值的 int"会走到这里：点不了，但可以在
                    // 「Flag 覆盖」页用「写入数字」自己填 —— 那条提示挂在 flag 的 `noteKey` 上。
                    Text("flag_catalog_unsupported".localized)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .disabled(KnownFlagCatalog.prefilledOverride(for: flag) == nil && !isOverridden(flag))
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
