import Foundation

// 「Spotify 功能」页数据层的回归测试（Foundation-only，不需要 iOS SDK）。
//
// 跑法（需要 Swift 工具链）：
//   swiftc Tests/SpotifyFeatures/main.swift \
//          Sources/EeveeSpotify/Flags/SpotifyFeaturesCatalog.swift \
//          -o /tmp/spotify-features-tests && /tmp/spotify-features-tests
//
// 钉的是「键没写错」。视图写覆盖时是**按第一个点把 `scope.name` 拆开**的
// （`SpotifyFeaturesCatalog.scope(of:)` / `name(of:)`），所以键里多一个点、或者根本没有点，
// 后果都是"写了一条永远不会命中的覆盖"：点了没反应、也不报错。
// 这一页的行是数据驱动的，`swiftc -parse` 与 l10n 检查都挡不住这类错。

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAIL: \(message)") }
}

let sections = SpotifyFeaturesCatalog.sections
require(!sections.isEmpty, "the page must have at least one section")

var seen = Set<String>()

for section in sections {
    require(!section.titleKey.isEmpty, "every section needs a title key")
    require(
        section.titleKey.hasPrefix("spotify_features_section_"),
        "section \(section.titleKey) must use the spotify_features_section_ prefix"
    )
    require(!section.flags.isEmpty, "section \(section.titleKey) must not be empty")

    for feature in section.flags {
        let key = feature.key

        require(seen.insert(key).inserted, "duplicate flag key \(key)")
        require(
            feature.labelKey.hasPrefix("spotify_features_"),
            "\(key): label key \(feature.labelKey) must use the spotify_features_ prefix"
        )
        require(!feature.labelKey.isEmpty, "\(key) must have a label key")

        // `<scope>.<name>`：视图与 l10n 检查脚本都靠"第一个点"切分。
        require(key.filter { $0 == "." }.count == 1, "\(key) must contain exactly one dot")

        let scope = SpotifyFeaturesCatalog.scope(of: key)
        let name = SpotifyFeaturesCatalog.name(of: key)
        require(!scope.isEmpty, "\(key) must have a scope")
        require(!name.isEmpty, "\(key) must have a flag name")
        require(scope + "." + name == key, "\(key) must round-trip through scope + name")
        require(!scope.contains("."), "\(key): the scope must not contain a dot")
    }
}

// MARK: - 「隐藏 AI 徽章」那一组

let aiFlags = SpotifyFeaturesCatalog.aiBadgeFlags
require(aiFlags.count == 7, "the AI badge group is seven flags (four badge surfaces + attribution)")
for key in aiFlags {
    require(seen.insert(key).inserted, "duplicate flag key \(key)")
    let scope = SpotifyFeaturesCatalog.scope(of: key)
    let name = SpotifyFeaturesCatalog.name(of: key)
    require(!scope.isEmpty && !name.isEmpty, "\(key) must be <scope>.<name>")
    require(scope + "." + name == key, "\(key) must round-trip through scope + name")
}

// MARK: - 合计

let allKeys = SpotifyFeaturesCatalog.allKeys
require(allKeys.count == seen.count, "allKeys must be every row plus the AI group, without repeats")
require(
    allKeys.contains("ios-feature-yourlibaryx.recents_enabled"),
    "the page must still carry the library switches"
)

// 刻意排除的几条：锁屏动态封面另有开关、DJ 入口不提供、摇一摇与艺人排序在 9.2.2 已不存在。
// 这条断言防的是"顺手把上游那页整份抄回来"。
for excluded in [
    "ios-feature-lockscreen.animated_artwork_enabled",
    "ios-home-evopage-impl.idj_show_dj_button",
    "ios-feature-yourlibaryx.shake_to_random_enabled",
    "ios-feature-yourlibaryx.recently_updated_artists_sort_enabled"
] {
    require(!allKeys.contains(excluded), "\(excluded) is deliberately not on this page")
}

print("Spotify features catalog tests passed")
