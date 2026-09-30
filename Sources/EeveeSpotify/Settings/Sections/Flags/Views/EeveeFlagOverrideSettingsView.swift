import SwiftUI
import UIKit

/// 「Flag 覆盖」页 —— Spotify 远端配置（UCS）里单条 flag 的 Auto / 强制 / 删除 / 写值。
///
/// 它不改网络，也不自己造一条修改配置的路径：写进 `FlagOverrideStore`，由
/// `modifyAssignedValues` 追加在内置替换**之后**应用（见 `FlagOverride+Replacement.swift`），
/// 所以用户的选择能压过仓库自己的默认值。
///
/// 页面上半是"已知 flag"目录：那些名字与 scope 来自**用户自己设备** 9.1.86 的
/// `[Flags]` 调试日志（见 `KnownFlagCatalog`），点一下即按建议填好，省得手打
/// `ios-feature-socialrecommendationsassistedcurationplugins` 这种 scope ——
/// 写错 scope 的后果是覆盖静默不命中。
struct EeveeFlagOverrideSettingsView: View {

    @State private var overrides = FlagOverrideStore.all
    @State private var newName = ""
    @State private var newScope = ""
    @State private var newMode: FlagOverride.Mode = .off
    @State private var newValue = ""

    var body: some View {
        List {
            addSection
            activeSection

            if !overrides.isEmpty {
                Section {
                    Button("flag_override_clear_all".localized) {
                        FlagOverrideStore.removeAll()
                        overrides = FlagOverrideStore.all
                    }
                    .foregroundColor(.red)
                }
            }

            knownFlagSections
        }
        .listStyle(GroupedListStyle())
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

            Button("flag_override_add".localized) {
                add()
            }
            .disabled(isAddDisabled)
        }
    }

    private var isAddDisabled: Bool {
        if newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if newMode == .set, newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return false
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

                    if item.mode == .set, !item.value.isEmpty {
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

    // MARK: - 已知 flag 目录

    @ViewBuilder private var knownFlagSections: some View {
        Section(
            header: Text("flag_catalog_section".localized),
            footer: Text("flag_catalog_description".localized)
        ) {
            EmptyView()
        }

        ForEach(KnownFlagCatalog.groups, id: \.titleKey) { group in
            Section(header: Text(group.titleKey.localized)) {
                ForEach(group.flags, id: \.self) { flag in
                    knownFlagRow(flag)
                }
            }
        }
    }

    private func knownFlagRow(_ flag: KnownFlag) -> some View {
        Button {
            applyKnownFlag(flag)
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

    /// 点目录行：能改的直接落一条覆盖；enum 那种需要用户填值的，预填到上面的表单。
    private func applyKnownFlag(_ flag: KnownFlag) {
        guard let prefilled = KnownFlagCatalog.prefilledOverride(for: flag) else { return }

        if prefilled.mode == .set {
            newName = prefilled.name
            newScope = prefilled.scope
            newMode = .set
            newValue = prefilled.value
            return
        }

        FlagOverrideStore.upsert(prefilled)
        overrides = FlagOverrideStore.all
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
