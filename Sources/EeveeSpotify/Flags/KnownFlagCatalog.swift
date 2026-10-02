import Foundation

/// flag 的取值类型，照抄真机日志 `[Flags]` 行里那个标记（`bool=` / `enum=` / `int=`）。
enum FlagValueType: String {
    case bool
    case enumValue = "enum"
    case int
}

/// 一条**已知**的 Spotify 远端配置。
///
/// 「已知」有**两种证据来源**（`observedValue` 与分组脚注会写清是哪一种）：
///   1. **真机硬证据**：它出现在用户设备 9.1.86 的 `[Flags]` 调试日志里 —— 服务端确实下发过、
///      名字与 scope 都对得上，`observedValue` 就是那次观察到的取值；
///   2. **IPA 字面量表**（2026-10-02 起收录）：它出现在 `.spotify-ipa/flag-table.txt`
///      （从 9.1.86 主二进制抽出的 2485 条 `scope.name`）里，但**没在设备日志里出现过**。
///      这种条目 `observedValue` 留空 —— 点一下会写一条覆盖，**命中与否看日志里那行
///      `[Flags] override … N match(es)`**：0 命中说明服务端没下发（`.forceBool` / `.forceEnum`
///      / `.forceInt` 会自己追加一条，所以仍然可能生效）。
///
/// 为什么需要它：让用户手打 `ios-feature-socialrecommendationsassistedcurationplugins`
/// 这样的 scope 不现实，而写错 scope 的后果是"覆盖静默不命中"（仓库里
/// `reportLyricsReplacementOutcome` 就是为区分这两种情况才存在的）。
struct KnownFlag: Hashable {
    let name: String
    let scope: String
    let type: FlagValueType

    /// 真机日志里观察到的那次取值，只用来给用户一个参照（不是建议）。
    /// **空串 = 只在 IPA 字面量表里见过**（见上面的说明）。
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

    /// 分组脚注（l10n 键）：写清"这一组的证据来自哪儿"。
    /// ⚠️ **必须带 `= nil`**：`var` 带默认值才会被成员逐一初始化器收成"可省略参数"，
    /// 于是旧的分组还能继续用 `KnownFlagGroup(titleKey:flags:)` 这个两参写法
    /// （`let` 带默认值会被直接排除掉，`var` 不带默认值则会变成必填）。
    var footerKey: String? = nil

    var flags: [KnownFlag]
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

        // ── 2026-10-02 新增：证据来自 **IPA 字面量表**（没在设备日志里见过）─────────
        //
        // 这一组是"pw 那 25 条清理开关"里**能用 flag 直接关掉**的那部分：
        // Spotify 自己有一个"减少打扰"模块 `ios-messaging-reduceinterventions-impl`，
        // 里面**一条提示一个 flag**（账号切换 / 演唱会通知 / 现场活动 / Puffin /
        // 智能随机 / 探索提示 / AI 歌单创建）。逐条都在 `.spotify-ipa/flag-table.txt` 里核对过，
        // 没有一条是照着名字猜的。
        KnownFlagGroup(
            titleKey: "flag_group_interventions",
            footerKey: "flag_group_interventions_footer",
            flags: [
                // 总闸：关掉它，下面这批提示由 Spotify 自己统一收手。
                KnownFlag("enabled", "ios-messaging-reduceinterventions-impl", observed: "",
                          noteKey: "flag_note_interventions_master"),

                KnownFlag("enable_message_account_switching_tooltip",
                          "ios-messaging-reduceinterventions-impl", observed: ""),
                KnownFlag("enable_message_your_library_ai_playlist_creation_tooltip",
                          "ios-messaging-reduceinterventions-impl", observed: ""),
                KnownFlag("enable_message_live_events_concert_notifications_tooltip",
                          "ios-messaging-reduceinterventions-impl", observed: ""),
                KnownFlag("enable_message_live_events_event_entity_safe_tooltip",
                          "ios-messaging-reduceinterventions-impl", observed: ""),
                KnownFlag("enable_message_live_events_event_entity_venuename_header_too",
                          "ios-messaging-reduceinterventions-impl", observed: ""),
                KnownFlag("enable_message_puffin_nudge_end_optimization",
                          "ios-messaging-reduceinterventions-impl", observed: ""),
                KnownFlag("enable_message_smart_shuffle_helper_tooltip",
                          "ios-messaging-reduceinterventions-impl", observed: ""),
                KnownFlag("enable_message_watch_feed_entity_explorer_tooltip",
                          "ios-messaging-reduceinterventions-impl", observed: ""),
                KnownFlag("enable_message_reinvent_free_n_p_v_suggestions_upsell",
                          "ios-messaging-reduceinterventions-impl", observed: ""),

                // 整数开关：现在能改（「写入数字」这一档就是为它们加的）。
                KnownFlag("max_account_age_days", "ios-messaging-reduceinterventions-impl",
                          .int, observed: "", noteKey: "flag_note_int_needs_number"),

                // 同一件事的其它 scope（都在 IPA 表里核过）。
                KnownFlag("data_saver_tooltip", "ios-feature-nowplayingbar", observed: "",
                          noteKey: "flag_note_data_saver"),
                KnownFlag("video_optionality_tooltips", "ios-feature-nowplayingbar", observed: ""),
                KnownFlag("messaging_enabled", "ios-datasaver-automatic-impl", observed: ""),
                KnownFlag("is_promo_cta_enabled",
                          "ios-reinventfree-contextualupsellpremiumpromo-impl", observed: ""),
                KnownFlag("concerts_enabled", "ios-feature-search", observed: ""),
                KnownFlag("social_prompting_enabled", "ios-blend-socialprompting-impl", observed: ""),
            ]
        ),

        KnownFlagGroup(
            titleKey: "flag_group_chrome",
            footerKey: "flag_group_chrome_footer",
            flags: [
                // 迷你播放条/播放条上的元素（我们现在是"藏视图"，这里是"关元素"——更稳）。
                KnownFlag("add_button", "ios-feature-nowplayingbar", observed: ""),
                KnownFlag("connect_promotional_content_label", "ios-feature-nowplayingbar", observed: ""),
                KnownFlag("queue_badge", "ios-feature-nowplayingbar", observed: ""),
                KnownFlag("two_lines_information_unit", "ios-feature-nowplayingbar", observed: ""),
                KnownFlag("companion_content_in_npb_enabled", "ios-feature-nowplayingbar", observed: ""),
                KnownFlag("show_skip_on_podcasts", "ios-feature-nowplayingbar", observed: ""),
                KnownFlag("hold_and_drag_to_resize", "ios-feature-nowplayingbar", observed: ""),

                // 封面 / 彩蛋。
                KnownFlag("canvas_enabled", "ios-feature-canvas", observed: "",
                          noteKey: "flag_note_canvas_off"),
                KnownFlag("enabled", "ios-feature-cover-art-snake", observed: "",
                          noteKey: "flag_note_snake_on"),

                // 多账号（它的"账号切换提示"背后的功能本身）。
                KnownFlag("is_enabled", "ios-account-switching", observed: ""),
                KnownFlag("account_switching_taste_onboarding_enabled",
                          "ios-feature-allboarding", observed: ""),
            ]
        ),

        // ── 2026-10-03：第二批"能关的打扰"，跨 scope ────────────────────────────────
        //
        // 起因：用户问"实际能关的是不是比这多很多" —— 是。上面那组只覆盖
        // `ios-messaging-reduceinterventions-impl`（Spotify 自己那个"减少打扰"模块，
        // 11 条已全覆盖）；而 IPA flag 表（`.spotify-ipa/flag-table.txt`，2485 条）里
        // 还有一批**同性质的提示/推销**散在别的 scope。
        //
        // ⚠️ 这一组每条都只是**IPA 字面量**（`observedValue` 留空）：这台设备上没见过
        // 服务端下发它们，所以"关掉有没有效果"要靠日志里的 `[Flags] replacement … N match(es)`
        // 判 —— 0 命中说明这条没被下发（`.forceBool` 仍会追加一条，但效果未知）。
        //
        // 入选标准（刻意保守）：**名字里明确写着"提示/推销"**，且**关掉不会拿掉真功能**。
        // 因此排除了 `specialized_connect_nudge_for_video_variant`（变体选择器，取值不是开关）、
        // `nudge_cooldown_ms` / `min_period_between_nudges` / `recommendation_nudge_delay`
        // （节流秒数，属"写入数字"档，不是开关）这类。
        KnownFlagGroup(
            titleKey: "flag_group_hints",
            footerKey: "flag_group_hints_footer",
            flags: [
                // Spotify Connect：名字直接就叫 disable。
                KnownFlag("disable_connect_nudges", "ios-feature-connectnotifications", observed: ""),
                // ⚠️ 刻意**不收**：`show_new_userawareness_nudge`
                //（"新用户引导提示"——那是给新用户的功能，不属于"打扰"），
                // 以及 `specialized_connect_nudge_for_video_variant`（变体选择器，不是开关）。

                // 睡眠定时器：只在有声书上弹的推销。
                KnownFlag("nudge_on_audiobooks", "ios-feature-sleeptimer", observed: ""),

                // 设备提示（"智能控制"那套）。
                KnownFlag("is_smart_control_nudge_enabled", "ios-device-predictability", observed: ""),

                // 音乐库：Euterpe 提示 + 新单集引导卡 + "置顶更多"横幅。
                KnownFlag("enable_euterpe_tooltip", "ios-feature-yourlibaryx", observed: ""),
                KnownFlag("show_new_episodes_offboarding_card", "ios-feature-yourlibaryx", observed: ""),
                KnownFlag("pin_more_items_banner_enabled", "ios-feature-yourlibaryx", observed: ""),
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

    /// 点一下目录行时写入的取值：
    ///   · bool → "关"（这些条目绝大多数是卡片/入口开关）；
    ///   · enum → **服务端下发的那个值**（日志里观察到的）。写回它本身是"钉住"，
    ///     真正要改值的人去「Flag 覆盖」页把模式改成"写入指定值"再填；
    ///   · int → 观察到的那个数字（`observedValue`）；**没观察到过就是 nil**，
    ///     那一行会提示去「Flag 覆盖」页用"写入数字"自己填（例如节流秒数）。
    static func prefilledOverride(for flag: KnownFlag) -> FlagOverride? {
        switch flag.type {
        case .bool:
            return FlagOverride(name: flag.name, scope: flag.scope, mode: .off)
        case .enumValue:
            return FlagOverride(
                name: flag.name,
                scope: flag.scope,
                mode: .set,
                value: flag.observedValue
            )
        case .int:
            guard Int32(flag.observedValue) != nil else { return nil }
            return FlagOverride(
                name: flag.name,
                scope: flag.scope,
                mode: .number,
                value: flag.observedValue
            )
        }
    }
}
