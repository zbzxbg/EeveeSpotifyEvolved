import SwiftUI
import UIKit

/// 「Spotify 功能」：把 Spotify 自己的那批开关收成一页可读的入口。
///
/// 每行**三档**：`Auto` / `Force off` / `Force on`。
/// · `Auto`    = 删掉这一行的覆盖，由 Spotify 的远端配置自己决定；
/// · 开 / 关   = 往 `FlagOverrideStore` 写一条覆盖。
/// 为什么不是 Toggle：这些 flag 的默认值由服务端下发，用户想要的往往是"钉住某个值"
/// （"我就要最近播放，哪怕这一版默认关"），而不是"和默认相反"。三档才表达得出这件事。
///
/// 与「减少打扰」页共用同一张 `FlagOverrideStore`，所以「Flag 覆盖」浏览器里手写过的
/// 条目在这里也显示得对；反过来，这里写的也能在那页看到、删掉。
///
/// 生效时机：远端配置按会话下发一次，改完要**重启 Spotify** —— 页顶那行说明写的就是这个。
struct SpotifyFeaturesSettingsView: View {

    /// 当前已生效的覆盖表。页面重进时用它反查，而不是自己记状态。
    @State private var overrides = FlagOverrideStore.all

    private static var sections: [SpotifyFeatureSection] {
        SpotifyFeaturesCatalog.sections
    }

    var body: some View {
        List {
            Section {
                Text("restart_is_required_description".localized)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            ForEach(Self.sections, id: \.titleKey) { section in
                Section(header: Text(section.titleKey.localized)) {
                    ForEach(section.flags, id: \.key) { feature in
                        row(feature)
                    }
                }
            }

            Section(
                header: Text("spotify_features_section_content".localized),
                footer: Text("spotify_features_hide_ai_badges_footer".localized)
            ) {
                Toggle("spotify_features_hide_ai_badges".localized, isOn: aiBadgesBinding)
            }

            Section(footer: Text("spotify_features_reset_footer".localized)) {
                Button(action: resetPage) {
                    Label("spotify_features_reset".localized, systemImage: "arrow.counterclockwise")
                }
            }
        }
                // inset-grouped（胶囊卡片）—— 为什么、怎么做的见 `EeveeSettingsView` 顶部那段
        .listStyle(InsetGroupedListStyle())
        .onAppear { overrides = FlagOverrideStore.all }
    }

    // MARK: - 一行

    /// 一行：标题 + 当前档位。点一下弹三档菜单。
    ///
    /// 不渲染 flag 键名（`scope.name`）：它对用户不是可读信息，长 scope 还会把标题挤成两行；
    /// 排查时看日志里的 `[Flags]` 行更准。
    private func row(_ feature: SpotifyFeatureFlag) -> some View {
        Menu {
            Button {
                clearOverride(for: feature.key)
            } label: {
                Text("flags_auto".localized)
            }
            Button {
                writeOverride(.off, for: feature.key)
            } label: {
                Text("flag_override_mode_off".localized)
            }
            Button {
                writeOverride(.on, for: feature.key)
            } label: {
                Text("flag_override_mode_on".localized)
            }
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(feature.labelKey.localized)
                    if let noteKey = feature.noteKey {
                        Text(noteKey.localized)
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                }

                Spacer(minLength: 8)

                Text(stateLabel(for: feature.key))
                    .font(.footnote)
                    .foregroundColor(stateColor(for: feature.key))

                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - 档位

    /// 这行现在有没有覆盖、是哪种模式。
    ///
    /// ⚠️ 刻意的"逐句、显式类型"写法：`first { $0.id == key && $0.mode == .off }` 那种
    /// 长表达式在本仓库踩过 `unable to type-check this expression in reasonable time`
    /// （见 `EeveeReduceInterventionsView.existingOverride`）。
    private func existingOverride(for key: String) -> FlagOverride? {
        let matches: [FlagOverride] = overrides.filter { item in
            let sameId: Bool = item.id == key
            return sameId
        }
        return matches.first
    }

    private func isOff(_ key: String) -> Bool {
        guard let current = existingOverride(for: key) else { return false }
        return current.mode == .off
    }

    /// `nil` = 没有覆盖（Auto）；否则显示那个模式的名字（`flag_override_mode_*` 是现成的键）。
    private func stateLabel(for key: String) -> String {
        guard let current = existingOverride(for: key) else {
            return "flags_auto".localized
        }
        return current.mode.localizedKey.localized
    }

    private func stateColor(for key: String) -> Color {
        existingOverride(for: key) == nil ? Color.secondary : Color.accentColor
    }

    private func writeOverride(_ mode: FlagOverride.Mode, for key: String) {
        FlagOverrideStore.upsert(
            FlagOverride(
                name: SpotifyFeaturesCatalog.name(of: key),
                scope: SpotifyFeaturesCatalog.scope(of: key),
                mode: mode
            )
        )
        // 立刻回读：重进页面 / 切到「Flag 覆盖」页都要看到真实状态。
        overrides = FlagOverrideStore.all
    }

    /// 删掉这一行的覆盖（回到 Auto，由 Spotify 自己的远端配置决定）。
    private func clearOverride(for key: String) {
        FlagOverrideStore.remove(id: key)
        overrides = FlagOverrideStore.all
    }

    // MARK: - AI 徽章（一条开关 = 一组 flag）

    /// `on` = 这一组全部写 off；`off` = 全部删掉（回到 Auto）。
    ///
    /// 读的状态是"**全部**都被关掉"：如果用户单独在「Flag 覆盖」里改过其中一条，
    /// 这里显示为关（说明这一组不再统一），点开就会把 7 条一起写掉 —— 这是有意的，
    /// 比"看起来开着、其实只关了一半"诚实。
    private var aiBadgesBinding: Binding<Bool> {
        Binding(
            get: {
                let flags: [String] = SpotifyFeaturesCatalog.aiBadgeFlags
                let allOff: Bool = flags.allSatisfy { key in self.isOff(key) }
                return allOff
            },
            set: { hide in
                let flags: [String] = SpotifyFeaturesCatalog.aiBadgeFlags
                for key in flags {
                    if hide {
                        FlagOverrideStore.upsert(
                            FlagOverride(
                                name: SpotifyFeaturesCatalog.name(of: key),
                                scope: SpotifyFeaturesCatalog.scope(of: key),
                                mode: .off
                            )
                        )
                    } else {
                        FlagOverrideStore.remove(id: key)
                    }
                }
                overrides = FlagOverrideStore.all
            }
        )
    }

    // MARK: - 重置

    /// 只删这一页写过的覆盖，别的页（含手写条目）一个都不碰。
    private func resetPage() {
        let keys: [String] = SpotifyFeaturesCatalog.allKeys
        for key in keys {
            FlagOverrideStore.remove(id: key)
        }
        overrides = FlagOverrideStore.all
        writeDebugLog("[Settings] reset Spotify features — \(keys.count) flag override(s) removed")
    }
}
