import SwiftUI
import UIKit

/// 「远端开关」页 —— 把 Spotify 远端配置（flag）**自动扫出来的**清单直接摆出来改。
///
/// （关于 flag 这部分，可不可以看看上游的 flag 页面设置，然后用他们的）：
/// 这一页与 `RemoteFlags.swift` / `RemoteFlagsHooks.x.swift` 一起从上游
/// `SideloadLabs/EeveeSpotifyReincarnated`（`Flags/FlagBrowserView.swift`）移植，
/// 界面结构照他们的，数据源换成我们自己的 `FlagOverrideStore`（不另存一份，见
/// `RemoteFlags.overrides` 的说明）。
///
/// ## 它比原来的「Flag 覆盖」页好在哪
///
/// 原来那一页要用户**自己**填 name + scope + 模式（Auto/开/关/写值/写数字）+ 值，
/// 这一页列的是**真被 Spotify 读过的东西**
/// （`RemoteFlags.resolve` 顺手记下来的 `FlagInfo`：种类 / 当前值 / 整数上下限 /
/// enum 可选值），于是：
/// · bool → 一个菜单（自动 / 开 / 关）；
/// · enum → 一个菜单（自动 + 服务端给的那几个取值）；
/// · int → 一个数字框，范围就是那条 flag 自己的 lower…upper；
/// · 顶部一个搜索框 + 一个「只看改过的」。
///
/// ## 没扫到的时候（重要）
///
/// 采集是**按 Spotify 版本**做的：升级完 Spotify 之后第一次启动只记不判，20 秒后落盘。
/// 所以刚装 / 刚升级时这一页可能是空的，footer 会写明"重启 Spotify、几秒后再进来"。
/// 这期间**不是没辙**：下面还有一行「手动写入」进原来的编辑页（那张表与这一页同一份存储）。
/// `FlagOverrideStore` → 以 id 为键的字典。
///
/// 放在**文件级**而不是 `private static func`：`@State` 的默认值里不能写 `Self.…`
/// （Swift 只允许在实例方法 / 静态上下文里用 `Self`），写成文件级函数两头都能用。
private func flagOverridesByID() -> [String: FlagOverride] {
    Dictionary(FlagOverrideStore.all.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
}

struct EeveeFlagBrowserView: View {

    let navigationController: UINavigationController

    @State private var catalog: [FlagInfo] = []
    @State private var loaded = false
    @State private var overrides: [String: FlagOverride] = flagOverridesByID()
    @State private var query = ""
    @State private var changedOnly = false

    private let forced = RemoteFlags.shared.forced

    private var visible: [FlagInfo] {
        catalog.filter { flag in
            let changed = overrides[flag.key] != nil || forced[flag.key] != nil
            let matches = query.isEmpty
                || flag.key.localizedCaseInsensitiveContains(query)
            return (!changedOnly || changed) && matches
        }
    }

    var body: some View {
        List {
            Section(
                footer: Text(
                    "flags_count".localizeWithFormat(catalog.count, RemoteFlags.shared.spotifyVersion)
                )
            ) {
                TextField("flags_search".localized, text: $query)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)

                Toggle("flags_changed_only".localized, isOn: $changedOnly)
            }

            actions

            if loaded && catalog.isEmpty {
                Section {
                    Text("flags_empty".localized)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }

            Section {
                ForEach(visible) { flag in
                    FlagBrowserRow(
                        flag: flag,
                        appliedOverride: overrides[flag.key],
                        forced: forced[flag.key]
                    ) { value in
                        applyOverride(flag.key, value)
                    }
                }
            }
        }
                // inset-grouped（胶囊卡片）—— 为什么、怎么做的见 `EeveeSettingsView` 顶部那段
        .listStyle(InsetGroupedListStyle())
        .onAppear(perform: loadCatalogIfNeeded)
    }

    private var actions: some View {
        Section {
            if RemoteFlags.needsRestart {
                Button("flags_restart".localized, action: exitApplication)
            }

            if !overrides.isEmpty {
                Button("flags_reset".localized) {
                    FlagOverrideStore.removeAll()
                    overrides = [:]
                }
                .foregroundColor(.red)
            }

            Button("flags_rescan".localized) {
                RemoteFlags.requestCapture()
                exitApplication()
            }

            // ⚠️ 这条是**本仓库的退路**，上游没有：手工写一条 flag（含"服务端从没下发过"的情况，
            // 那种必须填 scope）。它写的是同一张表，所以两页永远一致。
            Button(action: pushManualEditor) {
                HStack {
                    Image(systemName: "square.and.pencil")
                    Text("flag_override_title".localized)
                }
            }
        }
    }

    private func pushManualEditor() {
        let controller = EeveeSettingsViewController(
            navigationController.view.frame,
            settingsView: AnyView(EeveeFlagOverrideSettingsView(navigationController: navigationController)),
            navigationTitle: "flag_override_title".localized
        )
        navigationController.pushViewController(controller, animated: true)
    }

    private func loadCatalogIfNeeded() {
        guard !loaded else {
            overrides = flagOverridesByID()
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let start = CFAbsoluteTimeGetCurrent()
            let flags = RemoteFlags.shared.loadCatalog()
            let cost = String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - start) * 1000)
            writeDebugLog("[Flags] browser loaded \(flags.count) flag(s) in \(cost) ms")
            DispatchQueue.main.async {
                catalog = flags
                overrides = flagOverridesByID()
                loaded = true
            }
        }
    }

    // MARK: - 写回
    //
    // 把一次选择映射成 `FlagOverride`（这张表是唯一真相，见 `RemoteFlags.overrides`）。
    private func applyOverride(_ key: String, _ value: Any?) {
        guard let (scope, name) = Self.parseFlagKey(key) else { return }

        guard let value else {
            FlagOverrideStore.remove(id: key)
            overrides = flagOverridesByID()
            return
        }

        let entry: FlagOverride
        if let bool = value as? Bool {
            entry = FlagOverride(name: name, scope: scope, mode: bool ? .on : .off)
        } else if let number = value as? Int {
            entry = FlagOverride(name: name, scope: scope, mode: .number, value: String(number))
        } else {
            // enum：`FlagOverride.Mode.set` 写的是字符串，改响应体那条路会 `.forceEnum`。
            entry = FlagOverride(name: name, scope: scope, mode: .set, value: "\(value)")
        }

        FlagOverrideStore.upsert(entry)
        overrides = flagOverridesByID()
        writeDebugLog("[Flags] \(key) = \(value)")
    }

    /// `scope.property` → `(scope, property)`。`FlagOverride.id` 就是这两种拼法，
    /// 所以按**第一个** `.` 切开才不会把 id 拼歪（scope 里没有 `.`）。
    private static func parseFlagKey(_ key: String) -> (scope: String, name: String)? {
        guard let dot = key.firstIndex(of: ".") else {
            return key.isEmpty ? nil : ("", key)
        }
        return (String(key[..<dot]), String(key[key.index(after: dot)...]))
    }
}

/// 一行。上游同名类型叫 `FlagRow`（`FlagBrowserView.swift` 里的 private struct），
/// 这里换个名字是为了在仓库里 grep 时不与上游的移植记录混淆。
private struct FlagBrowserRow: View {
    let flag: FlagInfo
    let appliedOverride: FlagOverride?
    let forced: Any?
    let onSet: (Any?) -> Void

    var body: some View {
        if forced != nil {
            row
        } else {
            switch flag.kind {
            case .bool:
                menu([("flags_on".localized, true), ("flags_off".localized, false)])
            case .choice:
                menu((flag.options ?? []).map { ($0, $0) })
            case .int:
                Button(action: editInt) { row }
                    .buttonStyle(PlainButtonStyle())
            }
        }
    }

    private var row: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(flag.property)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                Text(flag.component)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let forced {
                Label(display(forced), systemImage: "lock.fill")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else {
                valueLabel
            }
        }
        .contentShape(Rectangle())
    }

    private func menu(_ options: [(String, AnyHashable)]) -> some View {
        let current = appliedOverride.map { displayValue($0) }
        return Menu {
            Button("flags_auto".localized) { onSet(nil) }
            ForEach(options, id: \.0) { option in
                Button {
                    onSet(option.1)
                } label: {
                    if current == display(option.1) {
                        Label(option.0, systemImage: "checkmark")
                    } else {
                        Text(option.0)
                    }
                }
            }
        } label: {
            row
        }
    }

    /// 当前值：**没有覆盖**时显示服务端那份（灰字），有覆盖时显示我们的值（强调色）。
    private var valueLabel: some View {
        Text(appliedOverride.map { displayValue($0) } ?? flag.value)
            .font(.footnote.weight(appliedOverride == nil ? .regular : .semibold))
            .foregroundColor(appliedOverride == nil ? .secondary : EeveeSettingsView.spotifyAccentColor)
            .lineLimit(1)
    }

    private func displayValue(_ appliedOverride: FlagOverride) -> String {
        switch appliedOverride.mode {
        case .on:
            return "flags_on".localized
        case .off:
            return "flags_off".localized
        default:
            return appliedOverride.value
        }
    }

    private func display(_ value: Any) -> String {
        if flag.kind == .bool {
            let on = (value as? Bool) ?? (value as? NSNumber)?.boolValue ?? (value as? String == "true")
            return (on ? "flags_on" : "flags_off").localized
        }
        return "\(value)"
    }

    /// int：一个数字框，范围就是这条 flag 自己的上下限（上游同款）。
    private func editInt() {
        let lower = flag.lower ?? Int.min
        let upper = flag.upper ?? Int.max
        // 预填当前生效的值：覆盖值是数字/字符串时才用它，否则用服务端那份
        // （`.on` / `.off` 的 `value` 是空串，直接拿去预填会得到一个空框）。
        let currentValue: String = {
            guard let appliedOverride else { return flag.value }
            switch appliedOverride.mode {
            case .number, .set:
                return appliedOverride.value
            case .on, .off, .remove:
                return flag.value
            }
        }()
        let alert = UIAlertController(
            title: String(flag.property),
            message: "\(lower) – \(upper)",
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.keyboardType = .numbersAndPunctuation
            field.text = currentValue
        }
        alert.addAction(UIAlertAction(title: "flags_auto".localized, style: .default) { _ in
            onSet(nil)
        })
        alert.addAction(UIAlertAction(title: "Cancel".uiKitLocalized, style: .cancel))
        alert.addAction(UIAlertAction(title: "OK".uiKitLocalized, style: .default) { [weak alert] _ in
            guard let text = alert?.textFields?.first?.text, let number = Int(text) else { return }
            onSet(min(max(number, lower), upper))
        })
        WindowHelper.shared.present(alert)
    }
}
