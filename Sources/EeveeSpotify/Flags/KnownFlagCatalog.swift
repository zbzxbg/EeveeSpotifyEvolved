import Foundation

/// flag 的取值类型，照抄真机日志 `[Flags]` 行里那个标记（`bool=` / `enum=` / `int=`）。
enum FlagValueType: String {
    case bool
    case enumValue = "enum"
    case int
}

/// 一条**已知**的 Spotify 远端配置。
///
/// 「已知」的定义是硬的：它出现在用户设备 9.1.86 的 `[Flags]` 调试日志里，
/// 也就是说服务端确实下发过、名字与 scope 都对得上。这不是猜的清单。
///
/// 为什么需要它：让用户手打 `ios-feature-socialrecommendationsassistedcurationplugins`
/// 这样的 scope 不现实，而写错 scope 的后果是"覆盖静默不命中"（仓库里
/// `reportLyricsReplacementOutcome` 就是为区分这两种情况才存在的）。
struct KnownFlag: Hashable {
    let name: String
    let scope: String
    let type: FlagValueType

    /// 真机日志里观察到的那次取值，只用来给用户一个参照（不是建议）。
    let observedValue: String

    /// 需要提醒的少数几条（l10n 键）；nil 表示名字已经够清楚。
    let noteKey: String?

    init(
        _ name: String,
        _ scope: String,
        _ type: FlagValueType = .bool,
        observed: String,
        noteKey: String? = nil
    ) {
        self.name = name
        self.scope = scope
        self.type = type
        self.observedValue = observed
        self.noteKey = noteKey
    }
}

struct KnownFlagGroup {
    let titleKey: String
    let flags: [KnownFlag]
}

/// 9.1.86 真机日志里出现过的 flag，按它影响的地方分组。
///
/// 数据来源：用户设备导出的 `eeveespotify_debug*.log`（19 份，2026-09-26 ~ 09-30）
/// 里的 `[Flags] lyrics flag` / `[Flags] npv flag` 行。**没有一条是猜的。**
///
/// ⚠️ 这仍然只是"服务端在这台设备上发过的子集"——日志本身对 NPV 那批有数量上限
/// （`npvFlagLogLimit`），所以清单会随日志变长。用户随时可以在上面的表单里
/// 手填没被收录的 flag。
enum KnownFlagCatalog {

    static let groups: [KnownFlagGroup] = [
        KnownFlagGroup(
            titleKey: "flag_group_lyrics",
            flags: [
                KnownFlag("is_get_lyrics_v2_enabled", "ios-feature-lyrics", observed: "true",
                          noteKey: "flag_note_lyrics_v2"),
                KnownFlag("lyrics_offline_enabled", "ios-feature-lyrics", observed: "true"),
                KnownFlag("enable_lyrics", "ios-feature-lyrics", observed: "true"),
                KnownFlag("enable_lyrics_character_count_fix", "ios-feature-lyrics", observed: "true"),
                KnownFlag("is_lyrics_cache_v2_enabled", "ios-feature-lyrics", observed: "true"),
                KnownFlag("lyrics_context_menu_toggle_enabled", "ios-feature-lyrics", observed: "true"),
                KnownFlag("lyrics_entry_point_enabled", "ios-feature-lyrics", observed: "false"),
                KnownFlag("is_lyrics_cover_art_refactor_enabled", "ios-nowplaying-contentlayers-impl", observed: "true"),
                KnownFlag("lyrics_under_cover_art_enabled", "ios-nowplaying-contentlayers-impl", observed: "true"),
                KnownFlag("lyrics_on_canvas_enabled", "ios-feature-canvas", observed: "true",
                          noteKey: "flag_note_canvas_lyrics"),
                KnownFlag("sync_lyrics_enabled", "ios-zephyr", observed: "true"),
                KnownFlag("enhanced_share_card_enabled", "ios-feature-lyrics", observed: "true"),
                KnownFlag("chat_lyrics_sticker_request_enabled", "ios-campfire-properties-impl", observed: "true"),
                KnownFlag("lyrics_sticker_suggestions_enabled", "ios-campfire-properties-impl", observed: "true"),
                KnownFlag("entity_type_lyrics_stickers_enabled", "ios-campfire-chatcontentpickerpage-impl", observed: "true"),
            ]
        ),

        KnownFlagGroup(
            titleKey: "flag_group_npv",
            flags: [
                // 卡片类：关掉一个就少一张卡。
                KnownFlag("agent_card_enabled", "ios-feature-aiagent", observed: "true"),
                KnownFlag("social_recommendations_card_enabled",
                          "ios-feature-socialrecommendationsassistedcurationplugins", observed: "true"),
                KnownFlag("suggested_episodes_card_enabled", "ios-feature-assistedcurationmigration", observed: "true"),
                KnownFlag("listening_party_card_enabled", "ios-prerelease-feature", observed: "true"),
                KnownFlag("related_audio_card_enabled", "ios-videorecommendations-npvprovider-impl", observed: "true"),
                KnownFlag("npv_scroll_card_enabled", "ios-feature-companioncontent", observed: "true"),
                KnownFlag("npv_scroll_card_audiobooks_enabled", "ios-feature-companioncontent", observed: "true"),
                KnownFlag("npv_scroll_card_enabled_on_ipad", "ios-smartshuffle-npvscrollrecscard-impl", observed: "true"),
                // ⚠️ 同名不同 scope：这两条正是 scope 必须参与 id 的理由。
                KnownFlag("npv_scroll_card_enabled", "ios-smartshuffle-npvscrollrecscard-impl", observed: "true"),
                KnownFlag("card_cc_exclude_enabled", "ios-feature-readalong", observed: "true"),
                KnownFlag("card_streaming_text_animation_enabled", "ios-martini-npvcardprovider-impl", observed: "false"),

                // 滚动页的行为类。
                KnownFlag("enable_nowplaying_scroll_events_card", "ios-feature-ontour", observed: "true"),
                KnownFlag("enable_nowplaying_scroll_events_card_on_ipad", "ios-feature-ontour", observed: "true"),
                KnownFlag("nowplaying_scroll_response_cache_enabled", "ios-feature-ontour", observed: "true"),
                KnownFlag("update_focused_item_index_while_scrolling", "ios-watchfeed-feature-impl", observed: "true"),
                KnownFlag("entrypoint_card_stop_player_on_background_thread", "ios-watchfeed-impl", observed: "true"),

                // 广告 / 推广。
                KnownFlag("video_ad_card_click_behavior", "ios-adsnowplaying-embeddednpv-impl",
                          .enumValue, observed: "expandFullVideo"),
                KnownFlag("experiment_first_card_disable", "ios-system-available-plans-page", observed: "true"),
                KnownFlag("prompted_playlist_merchandizing_enabled", "ios-feature-search", observed: "true"),
                KnownFlag("album_presave_second_step_enabled", "ios-feature-search", observed: "true"),
                KnownFlag("top_presaved_prereleases_highlight", "ios-upcoming-releaseshubpage-impl",
                          .enumValue, observed: "count"),

                // 取值不是布尔的：本项目现在只能改 bool 与 enum，int 只列出、不可点。
                KnownFlag("nova_scroll_peek_animation_delay", "ios-nowplaying-scroll-impl",
                          .int, observed: "100"),
            ]
        ),

        KnownFlagGroup(
            titleKey: "flag_group_home",
            flags: [
                KnownFlag("simple_card_visual_identity_trait_cover_enabled", "ios-home-evopage-impl", observed: "true"),
                KnownFlag("action_card_visual_identity_trait_enabled", "ios-home-evopage-impl", observed: "true"),
                KnownFlag("shareable_card_add_to_queue_button_enabled", "ios-campfire-properties-impl", observed: "true"),
                KnownFlag("enable_enhanced_share_card", "ios-feature-stickers", observed: "true"),
            ]
        ),
    ]

    /// 目录里一条的稳定 id —— 与 `FlagOverride.id` 同一套规则（scope 参与）。
    static func id(for flag: KnownFlag) -> String {
        "\(flag.scope).\(flag.name)"
    }

    static var allFlags: [KnownFlag] {
        groups.flatMap { $0.flags }
    }

    /// 点一下目录行时预填的取值：能在本项目里改的给"关"（多数是卡片/入口），
    /// 改不了的（int）返回 nil，让 UI 直接禁掉那一行。
    static func prefilledOverride(for flag: KnownFlag) -> FlagOverride? {
        switch flag.type {
        case .bool:
            return FlagOverride(name: flag.name, scope: flag.scope, mode: .off)
        case .enumValue:
            return FlagOverride(name: flag.name, scope: flag.scope, mode: .set, value: "")
        case .int:
            return nil
        }
    }
}
