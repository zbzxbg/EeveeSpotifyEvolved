import Foundation

/// 把用户覆盖映射成既有的 `EeveePropertyReplacement`。
///
/// 复用 `propertyReplacements` 那一套应用逻辑（`modifyAssignedValues`），**不另开
/// 一条修改 UCS 的路径**：少一处能改配置的地方，就少一处能改坏的地方。用户覆盖被
/// 追加在内置替换之后，因此能压过内置默认值（数组顺序即应用顺序）。
extension FlagOverride {
    var replacement: EeveePropertyReplacement {
        let resolvedScope = scope.isEmpty ? nil : scope

        switch mode {
        case .on:
            return EeveePropertyReplacement(
                name: name,
                scope: resolvedScope,
                modification: .forceBool(true)
            )
        case .off:
            return EeveePropertyReplacement(
                name: name,
                scope: resolvedScope,
                modification: .forceBool(false)
            )
        case .remove:
            return EeveePropertyReplacement(
                name: name,
                scope: resolvedScope,
                modification: .remove
            )
        case .set:
            // ⚠️ `.forceEnum` 而不是 `.setEnum`（2026-10-01 改）：
            // `.setEnum` 只改服务端**已经下发**的条目 —— 而"想试一条 Spotify 从没下发的
            // flag"正是这个功能的用处（新设计那批 flag 就属于这种）。用 `.forceEnum` 后，
            // 没命中就**追加**一条同 scope/name 的 enum 值，命中就覆盖。
            return EeveePropertyReplacement(
                name: name,
                scope: resolvedScope,
                modification: .forceEnum(value)
            )
        case .number:
            // 解析失败在这里兜成 0（不合法条目会被 `activeReplacements` 提前滤掉，
            // 所以这条基本不会走到；留着是为了不让 `??` 成为一个隐形的静默失败点）。
            let number = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            return EeveePropertyReplacement(
                name: name,
                scope: resolvedScope,
                modification: .forceInt(number)
            )
        }
    }
}

extension FlagOverrideStore {
    /// 追加在内置替换**之后**，所以用户的 On/Off 能压过仓库自己的默认值。
    ///
    /// 不合法的条目（`.set` 但没填值）在这里滤掉 —— 与其往 UCS 里写一个空 enum，
    /// 不如当它不存在。
    static var activeReplacements: [EeveePropertyReplacement] {
        all.filter(\.isValid).map(\.replacement)
    }
}
