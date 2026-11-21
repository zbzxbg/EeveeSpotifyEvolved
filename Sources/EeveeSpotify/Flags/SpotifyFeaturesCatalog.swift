import Foundation

// 「Spotify 功能」页的数据。
//
// 与 `KnownFlagCatalog` 的分工：那张表是「减少打扰」页的条目来源（扫到的已知 flag，
// 带人话文案），这里只列 Spotify 自己那几个开关的标题与键名。
// 这张只放**写好文案、并且在这个 Spotify 版本里确实存在**的那几条 —— 一行一个真开关，
// 一页翻完，不用记 scope。
//
// 键的形态是 `<scope>.<name>`：scope 只含小写字母、数字与 `-`（没有点），所以按**第一个点**
// 切分即可。这条规则同时被 `SpotifyFeaturesSettingsView`（写覆盖）与
// `Tools/eevee-hookfinder/check_spotify_features_l10n.py`（查词典）依赖。
//
// 刻意**没有**收进来的三条：
// · `ios-feature-lockscreen.animated_artwork_enabled` —— 本仓库「锁屏封面」页已经用
//   Canvas + 账号属性那条路管着同一件事，这里再放一条就是两个开关管一个现象；
// · `ios-home-evopage-impl.idj_show_dj_button` —— DJ 入口不提供；
// · `ios-feature-yourlibaryx.shake_to_random_enabled` 与
//   `…recently_updated_artists_sort_enabled` —— 9.2.2 的主二进制里已经没有这两个 flag
//   （上游那批 18 条里有，8.x 时代的残留）。
//
// 数据来源：9.2.2 主二进制的 flag 表（`Payload/Spotify.app/Spotify` 里的
// `<scope>.<name>` 连续字符串），逐条核对过存在性 —— 不存在的条目上屏就是"点了没反应"。

/// 一条可读的 Spotify 开关。
struct SpotifyFeatureFlag: Hashable {
    /// `scope.name`。
    let key: String
    let labelKey: String

    /// 需要额外提醒的行；`nil` = 名字已经够清楚。
    var noteKey: String? = nil

    var scope: String { SpotifyFeaturesCatalog.scope(of: key) }
    var name: String { SpotifyFeaturesCatalog.name(of: key) }
}

struct SpotifyFeatureSection: Hashable {
    let titleKey: String
    let flags: [SpotifyFeatureFlag]
}

enum SpotifyFeaturesCatalog {

    static let sections: [SpotifyFeatureSection] = [
        SpotifyFeatureSection(
            titleKey: "spotify_features_section_playback",
            flags: [
                SpotifyFeatureFlag(
                    key: "ios-playbackcontrol-playbackspeed-impl.enable_trim_silence",
                    labelKey: "spotify_features_trim_silence"
                ),
            ]
        ),
        SpotifyFeatureSection(
            titleKey: "spotify_features_section_library",
            flags: [
                SpotifyFeatureFlag(
                    key: "ios-feature-yourlibaryx.recents_enabled",
                    labelKey: "spotify_features_recents"
                ),
                SpotifyFeatureFlag(
                    key: "ios-feature-yourlibaryx.recents_sort_order_enabled",
                    labelKey: "spotify_features_recents_sort"
                ),
                SpotifyFeatureFlag(
                    key: "ios-feature-yourlibaryx.recently_updated_playlists_sort_enabled",
                    labelKey: "spotify_features_sort_playlists"
                ),
                SpotifyFeatureFlag(
                    key: "ios-feature-yourlibaryx.denser_rows_enabled",
                    labelKey: "spotify_features_denser_rows"
                ),
                SpotifyFeatureFlag(
                    key: "ios-feature-yourlibaryx.library_settings_enabled",
                    labelKey: "spotify_features_library_settings"
                ),
                SpotifyFeatureFlag(
                    key: "ios-feature-yourlibaryx.your_library_pro_enabled",
                    labelKey: "spotify_features_library_pro"
                ),
            ]
        ),
        SpotifyFeatureSection(
            titleKey: "spotify_features_section_lockscreen",
            flags: [
                SpotifyFeatureFlag(
                    key: "ios-feature-lockscreen.like_dislike_enabled",
                    labelKey: "spotify_features_lock_like"
                ),
                SpotifyFeatureFlag(
                    key: "ios-feature-lockscreen.skip_button_on_podcasts",
                    labelKey: "spotify_features_lock_podcast_skip"
                ),
                SpotifyFeatureFlag(
                    key: "ios-feature-lockscreen.enable_chapter_skip_controls",
                    labelKey: "spotify_features_lock_chapters"
                ),
            ]
        ),
        SpotifyFeatureSection(
            titleKey: "sleep_timer_title",
            flags: [
                SpotifyFeatureFlag(
                    key: "ios-feature-sleeptimer.enable_fade_out",
                    labelKey: "spotify_features_sleep_fade"
                ),
                SpotifyFeatureFlag(
                    key: "ios-feature-sleeptimer.enable_one_minute_option",
                    labelKey: "spotify_features_sleep_one_minute"
                ),
            ]
        ),
        SpotifyFeatureSection(
            titleKey: "spotify_features_section_home",
            flags: [
                SpotifyFeatureFlag(
                    key: "ios-home-evopage-impl.dj_mdc_beta_badge_enabled",
                    labelKey: "spotify_features_dj_badge"
                ),
            ]
        ),
        SpotifyFeatureSection(
            titleKey: "spotify_features_section_other",
            flags: [
                SpotifyFeatureFlag(
                    key: "ios-feature-localfiles.documents_enabled",
                    labelKey: "spotify_features_local_files"
                ),
            ]
        ),
    ]

    /// 「隐藏 AI 徽章」一条开关 = 这一组全部写 off。
    ///
    /// 六条徽章/标注（艺人页三条、搜索两条、列表行一条）+ Instant Mix 分区的 AI 品牌位
    /// 一条。7 条是同一个产品语义（"在内容上标注这是不是 AI"），所以只给一条开关；
    /// 想单独改某一条走「Flag 覆盖」。
    static let aiBadgeFlags: [String] = [
        "ios-creator-impl.is_ai_attribution_enabled",
        "ios-creator-impl.is_ai_persona_badge_enabled",
        "ios-creator-impl.is_likely_ai_persona_badge_enabled",
        "ios-feature-search.ai_persona_badge_enabled",
        "ios-feature-search.likely_ai_persona_badge_enabled",
        "ios-listuxplatformconsumers-defaultrowslotplugins.ai_persona_badge_enabled",
        "ios-feature-search.instant_mix_section_ai_branding_enabled",
    ]

    /// 这一页会写的全部 flag 键（重置按钮与检查脚本都从这里取）。
    static var allKeys: [String] {
        sections.flatMap { section in section.flags.map(\.key) } + aiBadgeFlags
    }

    /// `scope.name` → `scope`。没有点就原样返回（那种键在页面上会被检查脚本抓出来）。
    static func scope(of key: String) -> String {
        guard let dot = key.firstIndex(of: ".") else { return key }
        return String(key[key.startIndex..<dot])
    }

    /// `scope.name` → `name`。
    static func name(of key: String) -> String {
        guard let dot = key.firstIndex(of: ".") else { return "" }
        return String(key[key.index(after: dot)...])
    }
}
