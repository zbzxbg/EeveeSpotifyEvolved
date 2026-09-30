import Foundation

// Flag 覆盖表的回归测试。
//
// 跑法（需要 Swift 工具链，Windows 上不可用）：
//   swiftc Tests/FlagOverrideStore/main.swift \
//          Sources/EeveeSpotify/Flags/FlagOverride.swift \
//          -o /tmp/flag-override-tests && /tmp/flag-override-tests
//
// 锁的是"这张表的语义本身"：同 id 覆盖而不是追加、scope 参与 id、Codable 往返、
// 删除与清空。UCS 那边怎么应用由 `modifyAssignedValues` 负责，不在这个测试范围。

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAIL: \(message)") }
}

let suiteName = "eevee.flag-override.regression-tests"
let defaults = UserDefaults(suiteName: suiteName)!
defaults.removePersistentDomain(forName: suiteName)
FlagOverrideStore.container = defaults

// MARK: - 空表

require(FlagOverrideStore.all.isEmpty, "a fresh store must be empty")
require(FlagOverrideStore.count == 0, "count must follow all")

// MARK: - 追加与覆盖

require(
    FlagOverrideStore.upsert(FlagOverride(name: "enable_video_ads", mode: .off)) == false,
    "first insert must append"
)
require(FlagOverrideStore.count == 1, "one insert must yield one row")
require(FlagOverrideStore.all[0].mode == .off, "stored mode must round trip")

require(
    FlagOverrideStore.upsert(FlagOverride(name: "enable_video_ads", mode: .on)) == true,
    "same scope+name must replace instead of append"
)
require(FlagOverrideStore.count == 1, "replace must not grow the table")
require(FlagOverrideStore.all[0].mode == .on, "replace must write the new mode")

// MARK: - scope 参与 id

FlagOverrideStore.upsert(
    FlagOverride(name: "enable_video_ads", scope: "ios-feature-settings", mode: .off)
)
require(FlagOverrideStore.count == 2, "a different scope must be a different row")
require(
    FlagOverrideStore.all.contains { $0.scope.isEmpty } &&
        FlagOverrideStore.all.contains { $0.scope == "ios-feature-settings" },
    "both scopes must survive"
)

// MARK: - Codable 往返（表就是靠它落盘的）

let encoded = try! JSONEncoder().encode(FlagOverrideStore.all)
let decoded = try! JSONDecoder().decode([FlagOverride].self, from: encoded)
require(decoded == FlagOverrideStore.all, "codable round trip must be lossless")

// MARK: - `.set`（枚举值）与旧数据兼容

let setItem = FlagOverride(
    name: "video_ad_card_click_behavior",
    scope: "ios-adsnowplaying-embeddednpv-impl",
    mode: .set,
    value: "count"
)
require(setItem.isValid, "a .set override that carries a value must be valid")
require(
    !FlagOverride(name: "x", mode: .set, value: "   ").isValid,
    "a .set override with a blank value must be invalid"
)
require(
    FlagOverride(name: "x", mode: .on).isValid,
    "On/Off/Remove must not need a value"
)

// 早期落盘的数据里没有 `value` 字段 —— 必须还能解码，否则升级会把整张表清空
// （`all` 解码失败返回 []，用户已有的覆盖就没了）。
let legacyPayload = #"[{"name":"a","scope":"s","mode":"off"}]"#.data(using: .utf8)!
let legacyDecoded = try! JSONDecoder().decode([FlagOverride].self, from: legacyPayload)
require(
    legacyDecoded.count == 1 && legacyDecoded[0].value == "" && legacyDecoded[0].mode == .off,
    "a payload written before `value` existed must still decode"
)

// MARK: - 删除

FlagOverrideStore.remove(id: "enable_video_ads")
require(FlagOverrideStore.count == 1, "remove by id must drop exactly one row")
require(
    FlagOverrideStore.all[0].id == "ios-feature-settings.enable_video_ads",
    "remove must not touch the row that has a scope"
)

FlagOverrideStore.removeAll()
require(FlagOverrideStore.all.isEmpty, "removeAll must empty the table")

defaults.removePersistentDomain(forName: suiteName)

print("Flag override store regression tests passed")
