import SwiftUI
import UIKit

/// 「Flag 覆盖」页 —— Spotify 远端配置（UCS）里单条 flag 的 Auto / 强制 / 删除 / 写值。
///
/// 它不改网络，也不自己造一条修改配置的路径：写进 `FlagOverrideStore`，由
/// `modifyAssignedValues` 追加在内置替换**之后**应用（见 `FlagOverride+Replacement.swift`），
/// 所以用户的选择能压过仓库自己的默认值。
///
/// ⚠️ 这一页**只负责"编辑"**：已知 flag 的目录搬到了独立的「已知 flag」页（带过滤框）——
/// 两件事挤在一页就是上一版"表格墙"的由来（用户反馈页面臃肿）。
struct EeveeFlagOverrideSettingsView: View {

    let navigationController: UINavigationController

    @State private var overrides = FlagOverrideStore.all
    @State private var newName = ""
    @State private var newScope = ""
    @State private var newMode: FlagOverride.Mode = .off
    @State private var newValue = ""

    var body: some View {
        List {
            addSection
            activeSection
            catalogLinkSection

            if !overrides.isEmpty {
                Section {
                    Button("flag_override_clear_all".localized) {
                        FlagOverrideStore.removeAll()
                        overrides = FlagOverrideStore.all
                    }
                    .foregroundColor(.red)
                }
            }
        }
                // ★ 2026-10-12：inset-grouped（胶囊卡片）—— 为什么、怎么做的见 `EeveeSettingsView` 顶部那段
        .listStyle(InsetGroupedListStyle())
        .onAppear {
            overrides = FlagOverrideStore.all
        }
    }

    // MARK: - 手填

    private var addSection: some View {
        Section(
            header: Text("flag_override_add_section".localized),
            footer: Text("flag_override_add_description".localized)
        ) {
            TextField("flag_override_name_placeholder".localized, text: $newName)
            TextField("flag_override_scope_placeholder".localized, text: $newScope)

            Picker("flag_override_mode".localized, selection: $newMode) {
                ForEach(FlagOverride.Mode.allCases, id: \.self) { mode in
                    Text(mode.localizedKey.localized).tag(mode)
                }
            }
            .pickerStyle(MenuPickerStyle())

            if newMode == .set {
                TextField("flag_override_value_placeholder".localized, text: $newValue)
            }

            if newMode == .number {
                TextField("flag_override_number_placeholder".localized, text: $newValue)
                    .keyboardType(.numbersAndPunctuation)
            }

            Button("flag_override_add".localized) {
                add()
            }
            .disabled(isAddDisabled)
        }
    }

    private var isAddDisabled: Bool {
        let trimmedValue = newValue.trimmingCharacters(in: .whitespacesAndNewlines)

        switch newMode {
        case .set:
            return newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || trimmedValue.isEmpty
        case .number:
            return newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || Int32(trimmedValue) == nil
        default:
            return newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    // MARK: - 已生效

    private var activeSection: some View {
        Section(
            header: Text("flag_override_active_section".localized),
            footer: Text("flag_override_restart_hint".localized)
        ) {
            if overrides.isEmpty {
                Text("flag_override_empty".localized)
                    .foregroundColor(.secondary)
            }

            ForEach(overrides) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name)
                        .font(.system(.body, design: .monospaced))

                    Text(item.scope.isEmpty ? "flag_override_any_scope".localized : item.scope)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if (item.mode == .set || item.mode == .number), !item.value.isEmpty {
                        Text(verbatim: "= \(item.value)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if !item.isValid {
                        Text("flag_override_value_required".localized)
                            .font(.caption)
                            .foregroundColor(.orange)
                    }

                    Picker("flag_override_mode".localized, selection: modeBinding(for: item)) {
                        ForEach(FlagOverride.Mode.allCases, id: \.self) { mode in
                            Text(mode.localizedKey.localized).tag(mode)
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                }
            }
            .onDelete { offsets in
                var items = overrides
                items.remove(atOffsets: offsets)
                overrides = items
                FlagOverrideStore.all = items
            }
        }
    }

    // MARK: - 目录入口

    private var catalogLinkSection: some View {
        Section {
            Button {
                pushCatalog()
            } label: {
                NavigationSectionView(
                    color: Color(hex: "#5E5CE6"),
                    title: "flag_catalog_section".localized,
                    imageSystemName: "list.bullet"
                )
            }
        }
    }

    private func pushCatalog() {
        let viewController = EeveeSettingsViewController(
            navigationController.view.frame,
            settingsView: AnyView(EeveeFlagCatalogView()),
            navigationTitle: "flag_catalog_section".localized
        )

        navigationController.pushViewController(viewController, animated: true)
    }

    // MARK: - 写入

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        let item = FlagOverride(
            name: name,
            scope: newScope.trimmingCharacters(in: .whitespacesAndNewlines),
            mode: newMode,
            value: newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard item.isValid else { return }

        FlagOverrideStore.upsert(item)
        overrides = FlagOverrideStore.all

        // 只清 name：同一个 scope 下常常要连着加好几条。
        newName = ""
    }

    private func modeBinding(for item: FlagOverride) -> Binding<FlagOverride.Mode> {
        Binding(
            get: {
                overrides.first(where: { $0.id == item.id })?.mode ?? item.mode
            },
            set: { mode in
                var updated = item
                updated.mode = mode

                FlagOverrideStore.upsert(updated)
                overrides = FlagOverrideStore.all
            }
        )
    }
}
