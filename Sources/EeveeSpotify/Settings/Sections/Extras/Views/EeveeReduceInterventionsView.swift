import SwiftUI
import UIKit

/// 「减少打扰」独立页：把 Spotify 自己的**提示 / 推广 / 新功能气泡**逐条关掉。
///
/// ## 它是什么、为什么这么做
///
/// Spotify 内部有一个模块 `ios-messaging-reduceinterventions-impl`，**一条提示一个 flag**
/// （账号切换 / AI 歌单创建 / 演唱会通知 / 现场活动 / Puffin / 智能随机 / 探索提示 …）。
/// 关掉哪条 flag，就少哪一条打扰 —— 这是"在 Spotify 自己的开关上做减法"，
/// 属于本仓库更稳的那一路（不隐藏视图、不碰布局、可撤销）。
///
/// 原料**不是**这一页带来的：`KnownFlagCatalog` 的 `flag_group_interventions` 那两组
/// 早在 2026-10-02 就收录并**逐条在 `.spotify-ipa/flag-table.txt` 里核对过**
/// （见 `SPOTIFY_GAP.md` §5.2 的 25 条 `Hide …` 清单）。这一页只做一件事：
/// **把"要读 flag 名 + 选 on/off + 再点一次取消"三步，变成一个人话开关**。
///
/// ## 三条实现纪律
///
/// 1. **不另开改配置的路径**：开关写的仍是 `FlagOverrideStore`（`scope` 一定带上 ——
///    `.forceBool` 只有在给了 scope 时才**追加**服务端没下发过的条目，见
///    `DynamicModifyingFunctions.modifyAssignedValues` 那段"没有就追加"）。
/// 2. **`UserDefaults` 不参与语义**：点过就写覆盖，取消就删覆盖；页面重进时用
///    `existingOverride(for:)` 反查，所以在「Flag 覆盖」页手改过的条目也能正确显示。
/// 3. **默认值两端一致**：`flag.observedValue == "false"` 的提示按"本来就不发"处理
///    （开关显示关），其余按"默认发"（开关显示开）；不会出现"显示开着、
///    其实 Spotify 本来就不发"的假象。
///
/// ## 依赖与代价（照实写）
///
/// * flag 覆盖要**重启 Spotify** 才生效（远端配置按会话下发一次），页头写明。
/// * 少数 flag（`observedValue` 为空 = 只在 IPA 字面量表里见过）是否被服务端采纳，
///   只能从下一份日志的 `[Flags] replacement … N match(es)` 判断，**这一页不许诺 100% 生效**。
struct EeveeReduceInterventionsView: View {

    /// 当前**已生效**的覆盖表（页面重进时用它反查，而不是自己记状态）。
    @State private var overrides = FlagOverrideStore.all

    var body: some View {
        List {
            // ── 总闸：`ios-messaging-reduceinterventions-impl.enabled` ────────────────
            if let master = Self.masterFlag {
                Section(
                    header: Text("reduce_interventions_master".localized),
                    footer: Text("reduce_interventions_master_footer".localized)
                ) {
                    toggle(
                        flag: master,
                        labelKey: "reduce_interventions_master",
                        descriptionKey: "reduce_interventions_master_description"
                    )
                }
            }

            // ── 逐条提示。驱动源就是目录，不另维护一份名单 ────────────────────────────
            Section(
                header: Text("reduce_interventions_tips_section".localized),
                footer: Text("reduce_interventions_tips_footer".localized)
            ) {
                ForEach(Self.tipFlags, id: \.self) { flag in
                    toggle(
                        flag: flag,
                        labelKey: Self.labelKey(for: flag),
                        descriptionKey: Self.descriptionKey(for: flag)
                    )
                }
            }
        }
        .listStyle(GroupedListStyle())
        .onAppear { overrides = FlagOverrideStore.all }
    }

    // MARK: - 一行开关

    private func toggle(flag: KnownFlag, labelKey: String, descriptionKey: String) -> some View {
        Toggle(isOn: binding(for: flag)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(labelKey.localized)
                // flag 名留在副标题里：这一页的价值之一就是"看得见它关的是哪条"。
                Text("\(flag.scope).\(flag.name)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(descriptionKey.localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    /// `get` = 现在有没有这条覆盖；`set` = 写 / 删覆盖。
    private func binding(for flag: KnownFlag) -> Binding<Bool> {
        Binding(
            get: { self.existingOverride(for: flag) != nil },
            set: { isOn in
                if isOn {
                    FlagOverrideStore.upsert(
                        FlagOverride(name: flag.name, scope: flag.scope, mode: .off)
                    )
                } else {
                    FlagOverrideStore.remove(id: flag.id)
                }
                // 立刻回读，让重进页面/切换开关都看到真实状态。
                overrides = FlagOverrideStore.all
            }
        )
    }

    /// 已有的、且**确实把这条关掉**的覆盖。`on` / `set` / `number` 不算 —— 那样会让
    /// 用户在「Flag 覆盖」页写的其它模式被这一页误读成"已关闭"。
    private func existingOverride(for flag: KnownFlag) -> FlagOverride? {
        overrides.first { $0.id == flag.id && $0.mode == .off }
    }

    // MARK: - 名单（全部来自目录）

    private static let interventionsScope = "ios-messaging-reduceinterventions-impl"

    /// 总闸：目录里唯一那条带 `noteKey` 的（`flag_note_interventions_master`）。
    private static var masterFlag: KnownFlag? {
        knownFlags.first { $0.scope == interventionsScope && $0.name == "enabled" }
    }

    /// 逐条提示 = 这一组里除总闸、整数开关之外的 bool。
    ///
    /// ⚠️ `live_events_event_entity_safe_tooltip` 与 `…venuename_header_too` 是**同一条提示的
    /// 另外两个开关**（都归在"演唱会 / 现场活动"那一行下），所以不各占一行 ——
    /// 每多一行就是多一个用户要猜"这条和那条差在哪"的地方。
    /// ⇒ 这一页最终是 **7 行**（目录里 9 条 bool 提示 − 2 条合并）。
    private static let mergedIntoAnotherRow: Set<String> = [
        "enable_message_live_events_event_entity_safe_tooltip",
        "enable_message_live_events_event_entity_venuename_header_too",
    ]

    private static var tipFlags: [KnownFlag] {
        knownFlags.filter {
            $0.scope == interventionsScope
                && $0.name != "enabled"
                && $0.type == .bool
                && !mergedIntoAnotherRow.contains($0.name)
        }
    }

    private static var knownFlags: [KnownFlag] {
        KnownFlagCatalog.groups
            .first { $0.titleKey == "flag_group_interventions" }?
            .flags ?? []
    }

    /// 人话标签的 l10n 键 = `reduce_interventions_flag_<短名>`。
    ///
    /// ⚠️ 键名必须与 `KnownFlagCatalog` 里那条 flag 的**短名**一一对应；
    /// 名字改了而这里没改，表现是界面上出现**裸键名**（仓库已知的一种事故形状）。
    static func labelKey(for flag: KnownFlag) -> String {
        "reduce_interventions_flag_\(shortName(of: flag))"
    }

    static func descriptionKey(for flag: KnownFlag) -> String {
        "reduce_interventions_flag_\(shortName(of: flag))_description"
    }

    /// `enable_message_account_switching_tooltip` → `account_switching_tooltip`
    /// （去掉统一的 `enable_message_` 前缀，纯为可读）。
    ///
    /// ⚠️ 两张被合并进"演唱会 / 现场活动"那一行的 flag 也走这里 → 它们的标签键与那行相同。
    /// 键名改了而这里没改的表现是界面上出现**裸键名**（仓库已知的事故形状），
    /// 所以 `KnownFlagCatalog` 里那条 flag 的短名与本函数的产物必须一一对应。
    private static func shortName(of flag: KnownFlag) -> String {
        switch flag.name {
        case "enable_message_live_events_event_entity_safe_tooltip",
             "enable_message_live_events_event_entity_venuename_header_too":
            return "live_events_concert_notifications_tooltip"
        default:
            break
        }

        let prefix = "enable_message_"
        return flag.name.hasPrefix(prefix)
            ? String(flag.name.dropFirst(prefix.count))
            : flag.name
    }
}
