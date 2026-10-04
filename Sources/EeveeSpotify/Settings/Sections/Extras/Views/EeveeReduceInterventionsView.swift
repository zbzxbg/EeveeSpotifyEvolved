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
/// 2. **`UserDefaults` 不参与语义**：点过就写覆盖、取消就删覆盖；页面重进时用
///    `existingOverride(for:)` 反查真实状态 —— 所以在「Flag 覆盖」页手写/手删过的条目
///    这一页也显示得对（开关的唯一含义就是"**有没有一条把它关掉的覆盖**"）。
/// 3. **只认 `.off` 那一种覆盖**：`on` / `set` / `number` 在这条路径上是空操作，
///    所以要按"有没有**关掉**"来显示，而不是"有没有覆盖"。
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
                    // ⚠️ 这一行的标签/说明键是**写死**的（不像其它行由 flag 名拼出来），
                    // 所以单独造一个 `Row` 传给同一个渲染函数 —— 上一版这里漏改，
                    // 还在用重构前的 `toggle(flag:labelKey:descriptionKey:)`，
                    // 编译期报 "extra arguments at positions #2, #3"。
                    toggle(Self.masterRow(for: master))
                }
            }

            // ── 逐条提示。驱动源就是目录，不另维护一份名单 ────────────────────────────
            Section(
                header: Text("reduce_interventions_tips_section".localized),
                footer: Text("reduce_interventions_tips_footer".localized)
            ) {
                ForEach(Self.interventionRows, id: \.key) { row in
                    toggle(row)
                }
            }

            // ── 第二批：别的 scope 里的同类提示（每个 scope 一节，副标题写清是哪条）──────
            ForEach(Self.hintSections, id: \.scope) { section in
                Section(
                    header: Text(Self.hintSectionTitleKey(for: section.scope).localized),
                    footer: Text(Self.hintFooterKey(for: section.scope).localized)
                ) {
                    ForEach(section.rows, id: \.key) { row in
                        toggle(row)
                    }
                }
            }
        }
                // ★ 2026-10-12：inset-grouped（胶囊卡片）—— 为什么、怎么做的见 `EeveeSettingsView` 顶部那段
        .listStyle(InsetGroupedListStyle())
        .onAppear { overrides = FlagOverrideStore.all }
    }

    // MARK: - 行模型

    /// 一行开关。把一个 `KnownFlag` 需要的东西**预先算好**，行视图里就只做渲染 ——
    /// 这样 `body` 里的表达式都很小，不会喂给类型检查器一个长链（见 `existingOverride` 的注释）。
    private struct Row: Hashable {
        let flag: KnownFlag
        let labelKey: String
        let descriptionKey: String
        var key: String { Self.stableKey(for: flag) }

        static func stableKey(for flag: KnownFlag) -> String {
            flag.scope + "|" + flag.name
        }
    }

    private struct RowSection: Hashable {
        let scope: String
        let rows: [Row]
    }

    /// 一行开关（渲染）。
    private func toggle(_ row: Row) -> some View {
        Toggle(isOn: binding(for: row.flag)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.labelKey.localized)
                // flag 名留在副标题里：这一页的价值之一就是"看得见它关的是哪条"。
                Text("\(row.flag.scope).\(row.flag.name)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(row.descriptionKey.localized)
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
                    FlagOverrideStore.remove(id: Self.overrideId(for: flag))
                }
                // 立刻回读，让重进页面/切换开关都看到真实状态。
                overrides = FlagOverrideStore.all
            }
        )
    }

    /// 覆盖表里的稳定 id。
    ///
    /// ⚠️ **不能写 `flag.id`**：`KnownFlag` 只有 `name` / `scope` / `type` / `observedValue` /
    /// `noteKey`，**没有 `id`** —— 有 `id` 的是 `FlagOverride`。
    /// 规则必须与 `FlagOverride.id` 那行（`scope.isEmpty ? name : "\(scope).\(name)"`）
    /// **逐字一致**，否则这一页反查不到已存在的覆盖，「Flag 覆盖」页里手写的条目会显示成"没关"。
    /// 这里 scope 恒非空（目录里每条都带 scope），但空 scope 的分支照抄，保持与那边同构。
    private static func overrideId(for flag: KnownFlag) -> String {
        let scope: String = flag.scope
        let name: String = flag.name
        if scope.isEmpty {
            return name
        }
        return scope + "." + name
    }

    /// 已有的、且**确实把这条关掉**的覆盖。`on` / `set` / `number` 不算 —— 那样会让
    /// 用户在「Flag 覆盖」页写的其它模式被这一页误读成"已关闭"。
    ///
    /// ⚠️ 写法刻意为"**逐句、显式类型**"，不要合并回一个长表达式：
    /// 第一版写的是 `overrides.first { $0.id == flag.id && $0.mode == .off }`，CI 直接报
    /// `the compiler is unable to type-check this expression in reasonable time`
    /// （真实原因之一是里面那个不存在的 `flag.id` 让求解器发散；但即使修掉它，
    /// `first(where:)` + 两个成员比较 + 隐私字段访问仍容易踩同一条线）。
    private func existingOverride(for flag: KnownFlag) -> FlagOverride? {
        let wantedId: String = Self.overrideId(for: flag)
        let matches: [FlagOverride] = overrides.filter { item in
            let sameId: Bool = item.id == wantedId
            let muted: Bool = item.mode == .off
            return sameId && muted
        }
        return matches.first
    }

    // MARK: - 名单（全部来自目录）

    private static let interventionsScope = "ios-messaging-reduceinterventions-impl"

    /// 总闸：目录里那条 `enabled`（带 `flag_note_interventions_master`）。
    private static var masterFlag: KnownFlag? {
        let all: [KnownFlag] = knownFlags
        let matches: [KnownFlag] = all.filter { flag in
            let inScope: Bool = flag.scope == interventionsScope
            let isMaster: Bool = flag.name == "enabled"
            return inScope && isMaster
        }
        return matches.first
    }

    /// 逐条提示 = 这一组里除总闸、整数开关之外的 bool。
    ///
    /// ⚠️ `live_events_event_entity_safe_tooltip` 与 `…venuename_header_too` 是**同一条提示的
    /// 另外两个开关**（都归在"演唱会 / 现场活动"那一行下），所以不各占一行 ——
    /// 每多一行就是多一个用户要猜"这条和那条差在哪"的地方。
    /// ⇒ 这一组最终是 **7 行**（目录里 9 条 bool 提示 − 2 条合并）。
    private static let mergedIntoAnotherRow: Set<String> = [
        "enable_message_live_events_event_entity_safe_tooltip",
        "enable_message_live_events_event_entity_venuename_header_too",
    ]

    private static var interventionRows: [Row] {
        // ⚠️ 逐句、显式类型：一处 `&&` 链里混四种判据（含 Set.contains）也是
        // `unable to type-check in reasonable time` 的常见触发形状。宁可多几行。
        //
        // ⚠️ **必须同时卡 scope**：`flag_group_interventions` 里还混着 6 条**别的 scope** 的
        // 同名/近名 flag（`ios-feature-nowplayingbar.data_saver_tooltip`、
        // `ios-datasaver-automatic-impl.messaging_enabled`、
        // `ios-reinventfree-contextualupsellpremiumpromo-impl.is_promo_cta_enabled`、
        // `ios-feature-search.concerts_enabled`、`ios-blend-socialprompting-impl.social_prompting_enabled`
        // …）。不卡 scope 的话它们会挤进这一节、并且显示裸键名。
        let all: [KnownFlag] = knownFlags
        let candidates: [KnownFlag] = all.filter { flag in
            let inScope: Bool = flag.scope == interventionsScope
            let notMaster: Bool = flag.name != "enabled"
            let isBool: Bool = flag.type == .bool
            let standalone: Bool = !mergedIntoAnotherRow.contains(flag.name)
            return inScope && notMaster && isBool && standalone
        }
        let rows: [Row] = candidates.map { flag in makeRow(flag) }
        return rows
    }

    /// 第二批（`flag_group_hints`）里**这一页要显示的行** —— 显式白名单，键是 `scope|name`。
    ///
    /// ⚠️ 为什么不直接渲染整组：那个组里还躺着 3 条我**没写文案**的 flag
    /// （`ios-feature-nowplayingbar.data_saver_tooltip` / `ios-feature-search.concerts_enabled` /
    /// `ios-reinventfree-contextualupsellpremiumpromo-impl.is_promo_cta_enabled`）。
    /// 直接渲染整组的话，它们会**自动上屏并且显示裸键名** —— 2026-10-03 就是靠
    /// `check_reduce_interventions_l10n.py` 才发现的（它会列出"这一页会拼出来的每个键"）。
    /// 所以规则定死：**想让它上屏，先在这里加一行、再补两个 l10n 键**。
    private static let curatedHints: Set<String> = [
        // Connect：名字就叫 disable。
        "ios-feature-connectnotifications|disable_connect_nudges",
        // 睡眠定时器：只在有声书上弹的推销。
        "ios-feature-sleeptimer|nudge_on_audiobooks",
        // 设备提示（"智能控制"那套）。
        "ios-device-predictability|is_smart_control_nudge_enabled",
        // 音乐库：Euterpe 气泡 + 新单集卡 + "置顶更多"横幅。
        "ios-feature-yourlibaryx|enable_euterpe_tooltip",
        "ios-feature-yourlibaryx|show_new_episodes_offboarding_card",
        "ios-feature-yourlibaryx|pin_more_items_banner_enabled",
    ]

    /// 见 `curatedHints`。这里做的是"白名单 + 保持目录里的顺序"。
    private static var curatedHintFlags: [KnownFlag] {
        let all: [KnownFlag] = hintFlags
        let picked: [KnownFlag] = all.filter { flag in
            let key: String = flag.scope + "|" + flag.name
            return curatedHints.contains(key)
        }
        return picked
    }

    /// 第二批：按 scope 分组渲染（每节的标题/脚注由 scope 末段拼出来）。
    private static var hintSections: [RowSection] {
        let all: [KnownFlag] = curatedHintFlags
        var order: [String] = []
        var grouped: [String: [KnownFlag]] = [:]
        for flag in all {
            let scope: String = flag.scope
            if grouped[scope] == nil {
                order.append(scope)
                grouped[scope] = []
            }
            grouped[scope]?.append(flag)
        }

        var sections: [RowSection] = []
        for scope in order {
            let flags: [KnownFlag] = grouped[scope] ?? []
            let rows: [Row] = flags.map { flag in makeRow(flag) }
            sections.append(RowSection(scope: scope, rows: rows))
        }
        return sections
    }

    /// 一行要用的三个东西一次算完：l10n 标签键、说明键、以及它关的那条 flag。
    private static func makeRow(_ flag: KnownFlag) -> Row {
        let label: String = labelKey(for: flag)
        let description: String = descriptionKey(for: flag)
        return Row(flag: flag, labelKey: label, descriptionKey: description)
    }

    /// 总闸那一行：标签/说明键**写死**（它就是"一键全关"，不该跟着 flag 名走）。
    private static func masterRow(for flag: KnownFlag) -> Row {
        Row(
            flag: flag,
            labelKey: "reduce_interventions_master",
            descriptionKey: "reduce_interventions_master_description"
        )
    }

    /// 第二批每节的标题/脚注键。scope 里带 `-` 与 `.`，不能直接拼进键名 →
    /// 用 scope 的**最后一段**（`ios-feature-yourlibaryx` → `yourlibaryx`）。
    static func hintSectionTitleKey(for scope: String) -> String {
        "reduce_interventions_scope_" + lastScopeSegment(scope)
    }

    static func hintFooterKey(for scope: String) -> String {
        "reduce_interventions_scope_" + lastScopeSegment(scope) + "_footer"
    }

    private static func lastScopeSegment(_ scope: String) -> String {
        let parts: [Substring] = scope.split(separator: "-")
        let last: Substring? = parts.last
        guard let last else { return scope }
        return String(last)
    }

    private static var knownFlags: [KnownFlag] {
        KnownFlagCatalog.groups
            .first { $0.titleKey == "flag_group_interventions" }?
            .flags ?? []
    }

    /// 第二批（`flag_group_hints`）的 flag —— 全是**别的 scope** 里的同类提示。
    private static var hintFlags: [KnownFlag] {
        KnownFlagCatalog.groups
            .first { $0.titleKey == "flag_group_hints" }?
            .flags ?? []
    }

    /// 人话标签的 l10n 键。
    ///
    /// ⚠️ 键名与 `KnownFlagCatalog` 里那条 flag **一一对应**，且**按 scope 决定形状**：
    /// * scope 就是「减少打扰」那个模块（`ios-messaging-reduceinterventions-impl`）→
    ///   `reduce_interventions_flag_<去掉 enable_message_ 前缀的名字>`（历史键名，别改）；
    /// * 别的 scope → `reduce_interventions_flag_<scope 末段>_<flag 名>`。
    ///
    /// 为什么要分段：第二批里 `is_enabled` / `nudges` 这种名字在多个 scope 里都会出现，
    /// 只用 flag 名拼键必然撞车 —— 撞了的表现就是**两行显示同一段文字**（不报错，只难看）。
    ///
    /// 名字改了而词典没跟上，表现是界面上出现**裸键名**（仓库已知的事故形状），
    /// 所以 `Tools/eevee-hookfinder/check_reduce_interventions_l10n.py` 会把这一页**会拼出来的
    /// 每个键**都拿去词典里找一遍 —— 改目录或改这里的规则之后，都要跑它。
    static func labelKey(for flag: KnownFlag) -> String {
        "reduce_interventions_flag_" + shortName(of: flag)
    }

    static func descriptionKey(for flag: KnownFlag) -> String {
        "reduce_interventions_flag_" + shortName(of: flag) + "_description"
    }

    /// 见 `labelKey(for:)` 的说明：先按 scope 分段，再对「减少打扰」那一组去掉
    /// `enable_message_` 前缀。两张被合并进"演唱会 / 现场活动"那行的 flag 也走这里
    /// （所以它们的键与那一行相同，是有意的）。
    private static func shortName(of flag: KnownFlag) -> String {
        switch flag.name {
        case "enable_message_live_events_event_entity_safe_tooltip",
             "enable_message_live_events_event_entity_venuename_header_too":
            return scoped("live_events_concert_notifications_tooltip", for: flag)
        default:
            break
        }

        let prefix = "enable_message_"
        if flag.name.hasPrefix(prefix) {
            let dropped: Substring = flag.name.dropFirst(prefix.count)
            return scoped(String(dropped), for: flag)
        }
        return scoped(flag.name, for: flag)
    }

    /// 「减少打扰」那个 scope 之外的 flag，键里带上 scope 末段，避免同名撞车。
    private static func scoped(_ name: String, for flag: KnownFlag) -> String {
        if flag.scope == interventionsScope {
            return name
        }
        return lastScopeSegment(flag.scope) + "_" + name
    }
}
