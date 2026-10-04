import Foundation
import UIKit

private let liveMessagingAssignmentKeys = Set([
    "ios-campfire-properties-impl.campfire_feature_enabled",
    "ios-feature-sidedrawer-platform.is_list_page_enabled"
])

func modifyRemoteConfiguration(_ configuration: inout UcsResponse) {
    // ★★ 2026-10-12：**账号在服务端本来就是 Premium 时，一个账号态字段都不改**。
    //
    // 判据、依据（用户那轮 A/B 的结论 + `EeveePremiumForce.x.swift:88` 那条老账 +
    // 上游 `have_premium_popup` 用的同一个信号）全部写在
    // `ServerSidedFeaturePolicy.shouldSpoofPremium(_:)` 里 —— **这里不许再写第二份判据**。
    //
    // ⚠️ 必须在 `modifyAttributes` **之前**读 attributes：那个函数会把它们整个盖掉。
    // ⚠️ 只跳过"账号态伪装"这一块；下面 flag 替换（`modifyAssignedValues`：歌词入口、
    //    广告 flag、up-sell 卡片……）照旧跑 —— 那些是**用户要的功能**，与账号档位无关。
    if ServerSidedFeaturePolicy.shouldSpoofPremium(configuration.attributes.accountAttributes) {
        modifyAttributes(&configuration.attributes.accountAttributes)
    }

    let overwriteRequested = UserDefaults.overwriteConfiguration
    if ServerSidedFeaturePolicy.shouldOverwriteResolvedConfiguration(
        requested: overwriteRequested
    ) {
        // Messaging availability is assigned to the current account. A bundled
        // Premium snapshot can otherwise hide the chat UI for a different cohort.
        let liveMessagingAssignments = configuration.assignedValues.filter {
            liveMessagingAssignmentKeys.contains("\($0.propertyID.scope).\($0.propertyID.name)")
        }

        configuration.resolve.configuration = try! BundleHelper.shared.resolveConfiguration()

        configuration.assignedValues.removeAll {
            liveMessagingAssignmentKeys.contains("\($0.propertyID.scope).\($0.propertyID.name)")
        }
        configuration.assignedValues.append(contentsOf: liveMessagingAssignments)
    }

    // Apply targeted changes after an optional full overwrite. Doing it
    // before replacement discarded every ad/upsell fix along with Spotify's
    // current feature assignments.
    modifyAssignedValues(&configuration.assignedValues)
}

private let propertyReplacements = [
    // Append when the account's config omits them, so they work without overwrite-configuration.
    EeveePropertyReplacement(name: "crossfade_enabled", scope: "ios-feature-settings", modification: .forceBool(true)),
    EeveePropertyReplacement(name: "automix_enabled", scope: "ios-feature-settings", modification: .forceBool(true)),

    // ios featue only draws the row, the player core gates the fade on its own scope
    EeveePropertyReplacement(name: "crossfade_enabled", scope: "core-playback-setup", modification: .forceBool(true)),

    EeveePropertyReplacement(name: "use_playback_settings_crossfade", scope: "ios-feature-settings", modification: .forceBool(false)),
    EeveePropertyReplacement(name: "use_playback_settings_gapless", scope: "ios-feature-settings", modification: .forceBool(false)),

    // capping
    EeveePropertyReplacement(name: "enable_common_capping", modification: .remove),
    EeveePropertyReplacement(name: "enable_pns_common_capping", modification: .remove),
    EeveePropertyReplacement(name: "enable_pick_and_shuffle_common_capping", modification: .remove),
    EeveePropertyReplacement(name: "enable_pick_and_shuffle_dynamic_cap", modification: .remove),
    EeveePropertyReplacement(name: "pick_and_shuffle_timecap", modification: .remove),
    EeveePropertyReplacement(scope: "ios-feature-queue", modification: .remove),
    
    // also capping idk
    EeveePropertyReplacement(name: "enable_free_on_demand_experiment", modification: .remove),
    EeveePropertyReplacement(name: "enable_free_on_demand_context_menu_experiment", modification: .remove),
    EeveePropertyReplacement(name: "enable_mft_plus_queue", modification: .remove),
    EeveePropertyReplacement(name: "enable_mft_plus_extended_queue", modification: .remove),
    EeveePropertyReplacement(name: "enable_playback_timeout_service", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_playback_timeout_error_ui", modification: .setBool(false)),
    EeveePropertyReplacement(name: "playback_timeout_action", modification: .setEnum("Nothing")),
    EeveePropertyReplacement(name: "is_remove_from_queue_enabled_for_mft_plus", modification: .remove),
    EeveePropertyReplacement(name: "is_reordering_for_mft_plus_allowed", modification: .remove),
    
    // Ads & Campaigns
    EeveePropertyReplacement(name: "ads", modification: .setBool(false)),
    EeveePropertyReplacement(name: "ad_metadata", modification: .remove),
    EeveePropertyReplacement(name: "ad_slots", modification: .remove),
    EeveePropertyReplacement(name: "enable_ads", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_audio_ads", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_display_ads", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_video_ads", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_premium_upsell", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_upsell", modification: .setBool(false)),
    EeveePropertyReplacement(name: "show_upsell", modification: .setBool(false)),
    EeveePropertyReplacement(name: "show_premium_upsell", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_campaigns", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_promotions", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_search_ad", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_search_ads", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_search_banner_ad", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_search_banner_ads", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_search_sponsored_ad", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_search_sponsored_ads", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_search_upsell", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_home_ad", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_home_ads", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_home_banner_ad", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_home_banner_ads", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_home_sponsored_ad", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_home_sponsored_ads", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_home_upsell", modification: .setBool(false)),

    // Spotify 9.1.66+ moved the most visible free-tier prompts into dedicated
    // Swift services. Seed these scoped values even when the account's UCS
    // response omits them; setBool-only replacements cannot do that.
    EeveePropertyReplacement(name: "is_enabled_pt2", scope: "ios-feature-shuffletoggleupsell", modification: .forceBool(false)),
    EeveePropertyReplacement(name: "linear_upsell_new_style_experiment_enabled", scope: "ios-feature-shuffletoggleupsell", modification: .forceBool(false)),
    EeveePropertyReplacement(name: "play_modes_upsell_new_style_experiment_enabled", scope: "ios-feature-shuffletoggleupsell", modification: .forceBool(false)),
    EeveePropertyReplacement(name: "free_user_shuffle_upsell_sheet_enabled", scope: "ios-jam-freeusershuffleupsellsheetpage-impl", modification: .forceBool(false)),
    EeveePropertyReplacement(name: "free_user_skip_upsell_sheet_enabled", scope: "ios-jam-freeuserskipupsellpage-impl", modification: .forceBool(false)),
    EeveePropertyReplacement(name: "free_hosted_jams_upsell_enabled", scope: "ios-jam-freehostedjamsupsell-impl", modification: .forceBool(false)),
    EeveePropertyReplacement(
        name: ServerSidedFeaturePolicy.premiumGatedJamEntryPoint.name,
        scope: ServerSidedFeaturePolicy.premiumGatedJamEntryPoint.scope,
        modification: .forceBool(false)
    ),
    EeveePropertyReplacement(name: "is_promo_cta_enabled", scope: "ios-reinventfree-contextualupsellpremiumpromo-impl", modification: .forceBool(false)),
    EeveePropertyReplacement(name: "show_time_cap_upsell_with_premium_badge", scope: "ios-reinventfree-contextualupsellpremiumpromo-impl", modification: .forceBool(false)),
    EeveePropertyReplacement(name: "enable_video_time_cap_upsell", scope: "ios-reinventfree-controllerui-impl", modification: .forceBool(false)),
    EeveePropertyReplacement(name: "enable_video_time_cap_upsell_on_search", scope: "ios-reinventfree-controllerui-impl", modification: .forceBool(false)),
    EeveePropertyReplacement(name: "music_video_upsell_enabled", scope: "ios-reinventfree-timecappivot-impl", modification: .forceBool(false)),
    EeveePropertyReplacement(name: "is_gbb_upsell_enabled", scope: "ios-settings-mediaqualitypageplugin-impl", modification: .forceBool(false)),
    EeveePropertyReplacement(name: "should_show_pigeon_upsell", scope: "ios-settings-mediaqualitypageplugin-impl", modification: .forceBool(false)),
    EeveePropertyReplacement(name: "preview_ended_upsell_enabled", scope: "ios-system-listeningparties", modification: .forceBool(false)),
    EeveePropertyReplacement(name: "enable_now_playing_ad", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_now_playing_ads", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_now_playing_banner_ad", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_now_playing_banner_ads", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_now_playing_sponsored_ad", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_now_playing_sponsored_ads", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_now_playing_upsell", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_artist_ad", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_artist_ads", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_artist_banner_ad", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_artist_banner_ads", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_artist_sponsored_ad", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_artist_sponsored_ads", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_artist_upsell", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_playlist_ad", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_playlist_ads", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_playlist_banner_ad", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_playlist_banner_ads", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_playlist_sponsored_ad", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_playlist_sponsored_ads", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_playlist_upsell", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_album_ad", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_album_ads", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_album_banner_ad", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_album_banner_ads", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_album_sponsored_ad", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_album_sponsored_ads", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_album_upsell", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_library_ad", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_library_ads", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_library_banner_ad", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_library_banner_ads", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_library_sponsored_ad", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_library_sponsored_ads", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_library_upsell", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_audiobook_ad", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_audiobook_ads", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_audiobook_banner_ad", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_audiobook_banner_ads", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_audiobook_sponsored_ad", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_audiobook_sponsored_ads", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_audiobook_upsell", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_podcast_ad", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_podcast_ads", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_podcast_banner_ad", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_podcast_banner_ads", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_podcast_sponsored_ad", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_podcast_sponsored_ads", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_podcast_upsell", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_content", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_playlists", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_sessions", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_stories", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_videos", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_artist", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_artists", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_album", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_albums", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_track", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_tracks", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_show", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_shows", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_episode", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_episodes", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_audiobook", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_audiobooks", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_podcast", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_podcasts", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_search", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_search_results", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_search_banner", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_search_banners", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_home", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_home_banner", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_home_banners", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_now_playing", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_now_playing_banner", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_now_playing_banners", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_artist_banner", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_artist_banners", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_playlist_banner", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_playlist_banners", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_album_banner", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_album_banners", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_library_banner", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_library_banners", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_audiobook_banner", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_audiobook_banners", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_podcast_banner", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_podcast_banners", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_search_sponsored_ad", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_search_sponsored_ads", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_home_sponsored_ad", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_home_sponsored_ads", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_now_playing_sponsored_ad", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_now_playing_sponsored_ads", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_artist_sponsored_ad", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_artist_sponsored_ads", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_playlist_sponsored_ad", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_playlist_sponsored_ads", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_album_sponsored_ad", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_album_sponsored_ads", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_library_sponsored_ad", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_library_sponsored_ads", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_audiobook_sponsored_ad", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_audiobook_sponsored_ads", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_podcast_sponsored_ad", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_podcast_sponsored_ads", modification: .setBool(false)),
    
    // ─────────────────────────────────────────────────────────────────────
    // Ad on App Open — the "Advertisement" home-screen banner (Pepsi, etc.)
    // ─────────────────────────────────────────────────────────────────────
    EeveePropertyReplacement(scope: "ios-ad-on-app-open", modification: .remove),
    // The modern RemoteConfig scope for AdOnAppOpen (confirmed in binary).
    // This is the scope that the AuthFetcher re-fetches after minimumFetchIntervalSeconds
    // (typically a few hours), causing ads to reappear. Removing this scope prevents
    // the AdOnAppOpenServiceImpl from enabling the ad on subsequent re-fetches.
    EeveePropertyReplacement(scope: "ios-feature-adonappopen", modification: .remove),
    // Explicitly disable the individual flags within ios-feature-adonappopen scope
    // to ensure they are disabled even if the scope removal is not effective.
    EeveePropertyReplacement(name: "enabled", scope: "ios-feature-adonappopen", modification: .setBool(false)),
    EeveePropertyReplacement(name: "background_refresh_frequency_seconds", scope: "ios-feature-adonappopen", modification: .setBool(false)),
    EeveePropertyReplacement(name: "is_ad_on_app_open_enabled", modification: .setBool(false)),
    EeveePropertyReplacement(name: "ad_on_app_open_enabled", modification: .setBool(false)),
    EeveePropertyReplacement(name: "adonappopen_enabled", modification: .setBool(false)),

    // ─────────────────────────────────────────────────────────────────────
    // Marquee — full-screen artist/brand ad overlay
    // ─────────────────────────────────────────────────────────────────────
    EeveePropertyReplacement(scope: "marquee", modification: .remove),
    // Modern RemoteConfig scope for Marquee (confirmed in binary as 'ios-feature-marquee').
    EeveePropertyReplacement(scope: "ios-feature-marquee", modification: .remove),

    // ─────────────────────────────────────────────────────────────────────
    // Leave Behind ads — shown when leaving Now Playing
    // ─────────────────────────────────────────────────────────────────────
    EeveePropertyReplacement(scope: "leavebehindadsbase", modification: .remove),
    // Modern RemoteConfig scope for Leave Behind ads (confirmed in binary as 'ios-feature-leavebehindadsbase').
    EeveePropertyReplacement(scope: "ios-feature-leavebehindadsbase", modification: .remove),

    // Unified leave-behind cards are delivered into the Now Playing scroll
    // independently of the older EmbeddedNPV switches. These are the flags
    // used by Spotify 9.1.76 for the ad shown in issue #104.
    EeveePropertyReplacement(name: "unified_leavebehind_npv_scroll_music_enabled", scope: "ios-nowplaying-scroll-impl", modification: .forceBool(false)),
    EeveePropertyReplacement(name: "unified_leavebehind_npv_scroll_podcast_enabled", scope: "ios-nowplaying-scroll-impl", modification: .forceBool(false)),
    EeveePropertyReplacement(name: "use_unified_leavebehind_fetch", scope: "ios-feature-embeddedplaylist", modification: .forceBool(false)),

    // Keep the older EmbeddedNPV renderer dormant as a second line of defence.
    EeveePropertyReplacement(name: "foreground_enabled", scope: "ios-adsnowplaying-embeddednpv-impl", modification: .forceBool(false)),
    EeveePropertyReplacement(name: "music_track_change_enabled", scope: "ios-adsnowplaying-embeddednpv-impl", modification: .forceBool(false)),
    EeveePropertyReplacement(name: "enable_ads_on_podcast", scope: "ios-adsnowplaying-embeddednpv-impl", modification: .forceBool(false)),

    // ─────────────────────────────────────────────────────────────────────
    // In-stream / audio / video stream ads
    // ─────────────────────────────────────────────────────────────────────
    EeveePropertyReplacement(scope: "ios-feature-instreamads", modification: .remove),

    // ─────────────────────────────────────────────────────────────────────
    // Embedded ad CTA elements — search-page and home-page display ads
    // These scopes are responsible for the 'Advertisement' banners shown
    // in the screenshots (Cartier on Search, Ross on Home).
    // Confirmed scope names from binary analysis of the decrypted IPA.
    // ─────────────────────────────────────────────────────────────────────
    EeveePropertyReplacement(scope: "ios-adsembedded-embeddedctaelements-impl", modification: .remove),
    EeveePropertyReplacement(scope: "ios-adsnowplaying-embeddednpv-impl", modification: .remove),
    EeveePropertyReplacement(scope: "ios-adsplatform-elementimpl", modification: .remove),
    EeveePropertyReplacement(scope: "ios-system-adssponsoredcontext", modification: .remove),

    // ─────────────────────────────────────────────────────────────────────
    // Ads base infrastructure
    // ─────────────────────────────────────────────────────────────────────
    EeveePropertyReplacement(name: "enable_ads_connect_state_observer", scope: "ios-feature-adsbase", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_minimal_preroll_management", scope: "ios-feature-adsbase", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_swift_ads_base_movement_logger", scope: "ios-feature-adsbase", modification: .setBool(false)),

    // ─────────────────────────────────────────────────────────────────────
    // Ads Swift context tracking
    // ─────────────────────────────────────────────────────────────────────
    EeveePropertyReplacement(scope: "ios-feature-adsswift", modification: .remove),

    // ─────────────────────────────────────────────────────────────────────
    // Now Playing video ads
    // ─────────────────────────────────────────────────────────────────────
    EeveePropertyReplacement(name: "embedded_npv_video_show_with_canvas", scope: "ios-feature-adsnowplayingui", modification: .forceBool(false)),

    // ─────────────────────────────────────────────────────────────────────
    // Sponsored context (sponsored playlists in Now Playing bar)
    // ─────────────────────────────────────────────────────────────────────
    EeveePropertyReplacement(name: "sponsored_context_mismatch_aderror_enabled", scope: "ios-feature-adssponsoredcontext", modification: .setBool(false)),
    EeveePropertyReplacement(name: "sponsored_playlist_v2_enabled", scope: "ios-feature-adssponsoredcontext", modification: .setBool(false)),
    EeveePropertyReplacement(name: "sponsored_npb_slot_fetch_enabled", scope: "ios-feature-adssponsoredcontextnpbattachment", modification: .setBool(false)),

    // ─────────────────────────────────────────────────────────────────────
    // Ads identity tracking (SKAdNetwork / attribution)
    // ─────────────────────────────────────────────────────────────────────
    EeveePropertyReplacement(scope: "ios-feature-adsidentitytracking", modification: .remove),

    // ─────────────────────────────────────────────────────────────────────
    // Search page ads & promotions
    // ─────────────────────────────────────────────────────────────────────
    EeveePropertyReplacement(name: "prompted_playlist_merchandizing_enabled", scope: "ios-feature-search", modification: .setBool(false)),
    EeveePropertyReplacement(name: "social_proof_playlist_enabled", scope: "ios-feature-search", modification: .setBool(false)),
    EeveePropertyReplacement(name: "social_proof_plays_in_search_enabled", scope: "ios-feature-search", modification: .setBool(false)),
    EeveePropertyReplacement(name: "video_carousel_section_enabled", scope: "ios-feature-search", modification: .setBool(false)),
    EeveePropertyReplacement(name: "watch_feed_section_enabled", scope: "ios-feature-search", modification: .setBool(false)),

    // ─────────────────────────────────────────────────────────────────────
    // Additional legacy / non-scoped ad flags
    // ─────────────────────────────────────────────────────────────────────
    EeveePropertyReplacement(name: "enable_popups", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_leave_behind_ads_card_element", modification: .setBool(false)),
    EeveePropertyReplacement(name: "music_npv_leavebehinds_enabled", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_ads_on_podcast", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_display_element", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_video_element", modification: .setBool(false)),
    EeveePropertyReplacement(name: "is_promo_cta_enabled", modification: .setBool(false)),
    EeveePropertyReplacement(name: "show_time_cap_upsell_with_premium_badge", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_video_time_cap_upsell", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_video_time_cap_upsell_on_search", modification: .setBool(false)),
    EeveePropertyReplacement(name: "music_video_upsell_enabled", modification: .setBool(false)),
    EeveePropertyReplacement(name: "is_gbb_upsell_enabled", modification: .setBool(false)),
    EeveePropertyReplacement(name: "should_show_pigeon_upsell", modification: .setBool(false)),
    EeveePropertyReplacement(name: "disable_suggested_tracks_upsell", modification: .setBool(true)),
    EeveePropertyReplacement(name: "is_enabled_pt2", modification: .setBool(false)),
    EeveePropertyReplacement(name: "show_skip_button_during_skippable_ads", modification: .setBool(true)),
    EeveePropertyReplacement(name: "sponsored_playlist_v2_header_dismissible", modification: .setBool(true)),
    EeveePropertyReplacement(name: "use_mock_sponsorship_endpoint", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_popup", modification: .setBool(false)),
    EeveePropertyReplacement(name: "show_popups", modification: .setBool(false)),
    EeveePropertyReplacement(name: "show_popup", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_interstitials", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_interstitial", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_overlays", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_overlay", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_promotions_on_home", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_promotions_on_search", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_search_page_ads", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_home_page_ads", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_billboard", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_billboards", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_audio_ads_player", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_display_ads_player", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_video_ads_player", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_audio_ads_player_v2", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_display_ads_player_v2", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_video_ads_player_v2", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_search_results_v2", modification: .setBool(false)),
    EeveePropertyReplacement(name: "enable_sponsored_home_results_v2", modification: .setBool(false)),

    // 😡😡😡 spotify, stop changing the scroll logic
    EeveePropertyReplacement(name: "should_nova_scroll_use_scrollsita", modification: .remove),

    // ─────────────────────────────────────────────────────────────────────
    // Lyrics share button — Spotify gates this behind a remote-config flag
    // that is only enabled for premium accounts. Force it on so the share
    // button works even when overwrite-configuration is disabled.
    // ─────────────────────────────────────────────────────────────────────
    EeveePropertyReplacement(name: "enable_lyrics_share", scope: "ios-feature-lyrics", modification: .forceBool(true)),
    EeveePropertyReplacement(name: "lyrics_share_enabled", scope: "ios-feature-lyrics", modification: .forceBool(true)),
    EeveePropertyReplacement(name: "enable_lyrics_sharing", scope: "ios-feature-lyrics", modification: .forceBool(true)),
    EeveePropertyReplacement(name: "is_lyrics_share_enabled", scope: "ios-feature-lyrics", modification: .forceBool(true)),
    EeveePropertyReplacement(name: "lyrics_shareable", scope: "ios-feature-lyrics", modification: .forceBool(true)),
    EeveePropertyReplacement(name: "enable_share_link_preview_uploads", scope:"ios-feature-lyrics", 
    modification: .forceBool(true)),
    EeveePropertyReplacement(name: "enable_sharing_v2", scope: "ios-feature-lyrics", 
    modification: .forceBool(true)),
    // Also patch without scope in case flag is top-level / un-scoped
    EeveePropertyReplacement(name: "enable_lyrics_share", modification: .forceBool(true)),
    EeveePropertyReplacement(name: "lyrics_share_enabled", modification: .forceBool(true)),
    EeveePropertyReplacement(name: "enable_lyrics_sharing", modification: .forceBool(true)),
    EeveePropertyReplacement(name: "is_lyrics_share_enabled", modification: .forceBool(true)),
    EeveePropertyReplacement(name: "lyrics_shareable", modification: .forceBool(true)),
    EeveePropertyReplacement(name: "enable_share_link_preview_uploads", modification: .forceBool(true)),
    EeveePropertyReplacement(name: "enable_sharing_v2", modification: .forceBool(true)),

    // ─────────────────────────────────────────────────────────────────────
    // 歌词可用性检查旁路 —— 让"没有官方歌词的歌"也有歌词模块
    // ─────────────────────────────────────────────────────────────────────
    //
    // 名字逐字来自 9.1.86 解密二进制的 feature-flag 表
    // （`Scripts/dump-spotify-symbols.py` 的 [flags] 桶里确实存在
    // `enable_has_lyrics_check_bypass`，旁边还有 `enable_lyrics`）。
    // 也就是说「这首歌有没有歌词」在客户端是一道**开关控制的检查**：
    //   · `enable_lyrics`                    —— 歌词功能总开关；
    //   · `enable_has_lyrics_check_bypass`   —— 跳过「has_lyrics 吗」的检查，
    //     正是"每首歌都要有歌词模块"需要的那一个。
    //
    // 客户端读的是 track 元数据里的 `has_lyrics` 键（真机日志的
    // `[Artwork] metadata keys:` 一行里逐字可见）。EeveeSpotify 从 910 起就在
    // `SPTPlayerTrackHook.metadata()` 里把它覆写成 "true"，但那条 hook 现在挂在
    // 9.1.x 上不存在的类上（见 CustomLyrics+AllTracksLyrics.x.swift）。
    //
    // ⚠️ 刻意只用 `setBool`（**只改已存在的值，绝不新增**），理由：
    //   · `enable_has_lyrics_check_bypass` 这个**名字**是从 9.1.86 的 flag 表里
    //     逐字读出来的，可靠；
    //   · 但它归属的 **scope 名我们并不知道** —— 我先前那条
    //     `scope: "ios-lyrics-npvcommunicator-impl"` 是**猜的**。`.forceBool` 遇到
    //     "名字+scope 都不存在"会**凭空插一个 AssignedValue**，等于把臆造的数据
    //     塞进 Spotify 的配置解析路径，风险与收益不成比例。
    //   · `setBool` 只做"把服务端已经给的值钉成 true"，服务端真把它关了也能改回来，
    //     而不存在时什么都不做 —— 收益几乎一样，副作用归零。
    // 等真机日志确认了真实 scope 或真实开关名，再考虑升回 forceBool。
    EeveePropertyReplacement(name: "enable_has_lyrics_check_bypass", scope: "ios-feature-lyrics", modification: .setBool(true)),
    EeveePropertyReplacement(name: "enable_has_lyrics_check_bypass", modification: .setBool(true)),
    // 总开关：会话中途被服务端改回 false 会让歌词整体消失，这里钉死为 true。
    EeveePropertyReplacement(name: "enable_lyrics", scope: "ios-feature-lyrics", modification: .setBool(true)),
    EeveePropertyReplacement(name: "enable_lyrics", modification: .setBool(true)),

    // 「歌词入口」——2026-09-25 真机 `[Flags]` 取证：服务端下发的整份歌词 flag 清单里
    // （日志 18 行 35–48）**只有这一项是 false**，其余全是 true：
    //
    //     ios-feature-lyrics  lyrics_entry_point_enabled = false
    //
    // 而"与「关于艺人」并列的歌词卡片"正是这个词的字面意思（入口：点了才进全屏歌词）。
    // scope/name 都来自服务端实际下发的内容（不是猜的）。
    //
    // ★★ 2026-10-12（用户：「退出重进 Spotify **大概率突然无法播放任何歌词**…换代理也不行，
    //    **开启覆盖配置也只能好一小会**」）：
    //    这里原来是 `.setBool`（**只钉已下发的值、绝不新增**），而它的"空枪"是**静默**的 ——
    //    只要某一份 customize payload **没有**携带这条 flag（unauth 配置、增量/部分 payload
    //    都可能没有），我们这一枪就落空，而服务端那份的取值是 **false**
    //    （日志 59 第 16 行：`scope=ios-feature-lyrics name=lyrics_entry_point_enabled bool=false`）
    //    ⇒ **歌词入口整个消失**，用户看到的就是"没有任何歌词"。
    //    这也解释了"开覆盖能好一小会"：用户自己加的覆盖走的是 `.forceBool` / `.forceEnum`，
    //    那条路**有追加能力**（日志里 `0 match(es) (server did not send it; we append our own)`）。
    //    ⇒ 升级成 `.forceBool(true)`：**命中就钉住、没下发就补一条**。
    //      scope 来自服务端实发内容（不是猜的），所以补进去的那条能对得上。
    //    ⚠️ 开关仍然有效：`modifyAssignedValues` 里那条门禁照旧整条跳过（`SKIPPED: switch off`）。
    EeveePropertyReplacement(name: "lyrics_entry_point_enabled", scope: "ios-feature-lyrics", modification: .forceBool(true)),

    // ─────────────────────────────────────────────────────────────────────
    // ★ 2026-10-09：「封面下单行歌词」（跟唱那一行）—— **用户那个开关的第三层**。
    // ─────────────────────────────────────────────────────────────────────
    //
    // 它由远端配置控制，真机日志 53 里逐字可见（`[Flags] lyrics flag`）：
    //
    //     scope=ios-nowplaying-contentlayers-impl name=lyrics_under_cover_art_enabled bool=true
    //
    // **这个名字就是用户那句话**（设置页里那行开关叫「隐藏封面下单行歌词」）：
    // 关掉它 ⇒ 那一行、以及"把封面抬起来"的布局后果、底部那颗「显示/隐藏歌词」胶囊
    // 一起消失。为什么必须做到这一层：前两层（`DeclutterChrome` 藏那一行 / 按那颗胶囊）
    // 都只解决"看得见的那部分"——照片 58 与 60 两次现场都是这么来的。
    //
    // ⚠️ 只用 `setBool`（**只改服务端已下发的值，绝不新增**）：scope 与 name 都来自真机日志，
    //    不存在"凭空插一条 AssignedValue"的风险；服务端真没下发这条时这一枪是空的，
    //    日志里的 `[Flags] replacement … — 0 match(es)` 能一眼看出来。
    // ⚠️ **开关关着时整条跳过**（门禁在 `modifyAssignedValues`）：用户要回 Spotify 的原样。
    EeveePropertyReplacement(
        name: "lyrics_under_cover_art_enabled",
        scope: "ios-nowplaying-contentlayers-impl",
        modification: .setBool(false)
    )
]

/// 上面那条 flag 的名字（开关判定用，避免再抄一遍字面量）。
private let lyricsEntryPointFlagName = "lyrics_entry_point_enabled"

/// 「封面下单行歌词」那条 flag 的名字（同上）。
private let singalongLineFlagName = "lyrics_under_cover_art_enabled"

/// 「歌词入口 flag 已按开关跳过」只打一次 —— `modifyAssignedValues` 每次 customize
/// 响应都会跑，重复打只会刷屏。
private var entryPointFlagSkippedReported = false

private func reportEntryPointFlagSkippedOnce() {
    guard !entryPointFlagSkippedReported else { return }
    entryPointFlagSkippedReported = true
    writeDebugLog("[Flags] lyrics_entry_point_enabled — SKIPPED (switch off, A/B)")
}

/// 「封面下单行歌词」那条被跳过时也打一行（同上，只打一次）。
private var singalongFlagSkippedReported = false

private func reportSingalongFlagSkippedOnce() {
    guard !singalongFlagSkippedReported else { return }
    singalongFlagSkippedReported = true
    writeDebugLog(
        "[Flags] \(singalongLineFlagName) — SKIPPED (the hide-the-singalong-line switch is off;"
            + " Spotify's own behaviour is left alone)"
    )
}

// ─────────────────────────────────────────────────────────────────────────────
// 歌词相关 flag 取证（只读、只打日志、不改任何字节）
// ─────────────────────────────────────────────────────────────────────────────
//
// 为什么需要它：`enable_lyrics` / `enable_has_lyrics_check_bypass` 这些开关的
// **scope 名一直是我们猜的**（见上面 `propertyReplacements` 末尾那段注释），
// 而 `setBool` 只在 `name + scope` **都命中**时才生效 —— scope 猜错，这一枪就是空的，
// 而且**静默**：日志里没有任何痕迹能区分"服务端关了这个开关"和"我们根本没改到"。
//
// 服务器下发的 `assignedValues` 本来就带着真实的 `scope` 与 `name`，所以在改写它们
// **之前**先把含 "lyric" 的全部原样打出来：一次启动就能把真实 scope 钉死。
//
// 这同时也是"歌词卡片（面 B）是不是服务端 flag 说了算"这个问题的**唯一直接判据**：
// 若服务端真有一道闸，那条 flag 必然出现在这份清单里（连同它的取值）。
private var reportedLyricsFlags = Set<String>()
private var reportedLyricsReplacements = Set<String>()

/// 除了名字含 `lyric` 的，还要盯这一批 flag —— 它们决定**正在播放页的模块列表**怎么来：
///
///   · `scroll` / `nova` —— `should_nova_scroll_use_scrollsita` 就是我们在
///     `propertyReplacements` 里 **`.remove`** 掉的那一条（注释写着"spotify, stop changing
///     the scroll logic"）。它的 `.remove` 到底有没有动到东西，在此之前**完全不可见**：
///     `.remove` 命中 0 条时是静默 no-op。
///   · `prerelease` / `presave` / `moment` / `merch` / `card` —— "即将发布 / 预收藏"那张卡
///     的所有可能来源（见 `LYRICS_MODULE_NEXT_STEPS.md` §36/§37）。
private let npvFlagNeedles = [
    "scroll", "nova",
    "prerelease", "pre_release", "presave", "pre_save",
    "moment", "merch", "card",
]

/// 每次启动最多打这么多行，防止某个宽泛的词（`card` / `merch`）把日志刷爆。
private let npvFlagLogLimit = 60
private var reportedNPVFlags = Set<String>()
private var reportedNPVFlagCount = 0

/// 这一条 flag 名字是不是我们关心的（lyric 一批 + `npvFlagNeedles` 一批）。
private func isFlagOfInterest(_ name: String) -> Bool {
    let lower = name.lowercased()
    if lower.contains("lyric") { return true }
    return npvFlagNeedles.contains { lower.contains($0) }
}

/// 把 `structuredValue` 渲染成一行（两份 dump 共用，避免再次分叉）。
private func renderStructuredValue(_ value: AssignedValue) -> String {
    switch value.structuredValue {
    case .boolValue(let v)?: return "bool=\(v.value)"
    case .intValue(let v)?:  return "int=\(v.value)"
    case .enumValue(let v)?: return "enum=\(v.value)"
    case nil:                return "unset"
    }
}

private func dumpLyricsFlags(_ values: [AssignedValue]) {
    for value in values {
        let name = value.propertyID.name
        guard name.lowercased().contains("lyric") else { continue }

        let scope = value.propertyID.scope
        let rendered = renderStructuredValue(value)

        guard reportedLyricsFlags.insert("\(scope).\(name)=\(rendered)").inserted else { continue }
        writeDebugLog("[Flags] lyrics flag — scope=\(scope) name=\(name) \(rendered)")
    }
}

/// 见 `npvFlagNeedles` 的说明。与 `dumpLyricsFlags` 一样在**改写之前**打印，只读。
private func dumpNPVFlags(_ values: [AssignedValue]) {
    for value in values {
        guard reportedNPVFlagCount < npvFlagLogLimit else { return }

        let name = value.propertyID.name
        // 含 "lyric" 的那批由 `dumpLyricsFlags` 负责，这里不重复。
        guard isFlagOfInterest(name), !name.lowercased().contains("lyric") else { continue }

        let scope = value.propertyID.scope
        let rendered = renderStructuredValue(value)

        guard reportedNPVFlags.insert("\(scope).\(name)=\(rendered)").inserted else { continue }
        reportedNPVFlagCount += 1
        writeDebugLog("[Flags] npv flag — scope=\(scope) name=\(name) \(rendered)")
    }
}

/// 替换是否**真的命中**了目标。`setBool` / `remove` 命中 0 条时是静默 no-op，
/// 光看代码看不出来。这一行把"scope 猜错了"从"服务端就是这么下发的"里区分开。
///
/// ⚠️ 现在覆盖面是 `isFlagOfInterest`（lyric 一批 + `npvFlagNeedles` 一批）。
/// 判读 `should_nova_scroll_use_scrollsita` 就靠这个：`— 0 match(es)` 说明
/// **服务端根本没下发这条 flag**，那我们那条 `.remove` 是空枪，可以直接排除它。
private func reportLyricsReplacementOutcome(_ values: [AssignedValue]) {
    for replacement in propertyReplacements {
        guard let name = replacement.name,
              isFlagOfInterest(name) else { continue }

        let scope = replacement.scope
        let hits = values.filter {
            $0.propertyID.name == name && (scope == nil || $0.propertyID.scope == scope)
        }.count

        let key = "\(scope ?? "*").\(name)"
        guard reportedLyricsReplacements.insert(key).inserted else { continue }

        // 关掉开关时 `hits` 照样是 1（服务端确实下发了这条），但**我们没改**。
        // 不标出来，日志就会读成"改了"，判读 A/B 时会直接得出相反结论。
        let skipped = (name == lyricsEntryPointFlagName
                        && !NgzhwmSettingsViewModel.isLyricsEntryPointFlagForced)
            || (name == singalongLineFlagName && !UserDefaults.hideSingalongLine)

        writeDebugLog(
            "[Flags] replacement \(key) — \(hits) match(es)"
                + (skipped ? " (SKIPPED: switch off)" : "")
        )
    }
}

/// 「歌词入口」那条 flag 在**这一份 payload** 里到底有没有（**改写之前**数）。
///
/// ★ 2026-10-12（用户：「退出重进 Spotify 大概率突然无法播放任何歌词」）：
///   这条替换从 `.setBool` 升级成 `.forceBool` 之后，"服务端没下发"不再等于失效，
///   而是**我们补一条**；而"有没有"这件事直接决定歌词入口在不在，所以必须能在日志里看见。
///   ⚠️ 现成的 `reportLyricsReplacementOutcome` 帮不上：它`reportedLyricsReplacements`
///   是"每个 key 只报一次"，后续 payload 全被挡住 —— 而问题恰恰出在**后续**那份 payload 上。
///   这里只报**状态翻转**（有 → 没有，或反过来），不刷屏。
private var entryPointFlagWasPresent: Bool?

private func reportEntryPointFlagPresence(_ values: [AssignedValue]) {
    let present = values.contains {
        $0.propertyID.name == lyricsEntryPointFlagName
            && $0.propertyID.scope == "ios-feature-lyrics"
    }
    guard entryPointFlagWasPresent != present else { return }
    let isFirstPayload = entryPointFlagWasPresent == nil
    entryPointFlagWasPresent = present
    writeDebugLog(
        "[Flags] lyrics_entry_point_enabled "
            + (present
                ? "is in this payload"
                : "is MISSING from this payload - we append our own")
            + (isFirstPayload ? " (first payload of this launch)" : " (changed since the last payload)")
    )
}

/// 用户自己加的那条覆盖（设置页 → Flag 覆盖）有没有**真的够到**服务端下发的配置。
///
/// 为什么单独打一行：`reportLyricsReplacementOutcome` 只覆盖 `isFlagOfInterest`
/// （歌词 + NPV 两批），于是用户在设置页里写的**任意** flag 看不到命中数 ——
/// "覆盖没生效"和"生效了但界面没变"在日志里长得一模一样。2026-10-01 试
/// `ios-reprise-liquid-glass-override.mode` 时就卡在这里。
///
/// 读数：
///   · `1 match(es)` → 服务端下发了，我们改到了它；
///   · `0 match(es) (server did not send it…)` → 服务端根本没下发这一条，
///     改的是我们自己追加的那个（`.forceEnum` 才有追加能力；`.setEnum` 时代这里是空枪）。
///
/// ⚠️ 在**改写之前**调用 —— 数的是"服务端给了几条"，不是"改完剩几条"。
private var reportedUserOverrideOutcomes = Set<String>()

private func reportUserOverrideOutcomes(_ values: [AssignedValue]) {
    for override in FlagOverrideStore.all where override.isValid {
        let scope = override.scope.isEmpty ? nil : override.scope

        let hits = values.filter {
            $0.propertyID.name == override.name
                && (scope == nil || $0.propertyID.scope == scope)
        }.count

        let key = "\(scope ?? "*").\(override.name)"
        guard reportedUserOverrideOutcomes.insert(key).inserted else { continue }

        writeDebugLog(
            "[Flags] override \(key) — \(hits) match(es)"
                + (hits == 0 ? " (server did not send it; we append our own)" : "")
        )
    }
}

private func modifyAssignedValues(_ values: inout [AssignedValue]) {
    dumpLyricsFlags(values)
    dumpNPVFlags(values)
    // ★ 2026-10-12：**在改写之前**先记一次"这份 payload 到底有没有那条 flag"（见下面的说明）。
    reportEntryPointFlagPresence(values)
    reportUserOverrideOutcomes(values)

    // 用户自定义覆盖追加在**内置替换之后**：数组顺序即应用顺序，所以设置页里
    // 的 On/Off 能压过仓库自己的默认值（见 `FlagOverride+Replacement.swift`）。
    //
    // ⚠️ 下面那条「歌词入口」flag 的跳过开关**只作用于内置项**：用户自己在设置页
    // 写了一条同名覆盖，那是他的明确意图，不该被我们的 A/B 开关吞掉。
    let builtInReplacementCount = propertyReplacements.count
    let replacements = propertyReplacements + FlagOverrideStore.activeReplacements

    for (index, replacement) in replacements.enumerated() {
        // 「歌词入口」flag 是**唯一**还能影响正在播放页卡片渲染的我们自家改动
        // —— 另外两条路（补卡片元素 / HTTP 数据）都已被真机 A/B 与九份日志排除。
        // 关掉开关时整条替换跳过，并在启动时打一行，好让日志能区分
        // "我们没改" 与 "改了但没命中"。
        if index < builtInReplacementCount,
           replacement.name == lyricsEntryPointFlagName,
           !NgzhwmSettingsViewModel.isLyricsEntryPointFlagForced {
            reportEntryPointFlagSkippedOnce()
            continue
        }

        // ★ 2026-10-09：同一条纪律给「封面下单行歌词」——用户把那个开关关掉时，
        //   这一条内置替换**整条跳过**，让 Spotify 的行为原样保留（他没有要求我们改它）。
        if index < builtInReplacementCount,
           replacement.name == singalongLineFlagName,
           !UserDefaults.hideSingalongLine {
            reportSingalongFlagSkippedOnce()
            continue
        }

        let matchingIndices = values.indices.filter({ index in
            let value = values[index]
            let nameMatches = replacement.name.map { value.propertyID.name == $0 } ?? true
            let scopeMatches = replacement.scope.map { value.propertyID.scope == $0 } ?? true
            return nameMatches && scopeMatches
        })

        // 「没有就追加」的两种：`.forceBool`（设置页的 On/Off）与 `.forceEnum`（写入指定值）。
        // name + scope 都要给全 —— 否则无从知道追加到哪个 scope 下。这正是设置页里那句
        // "On 和 Off 需要一个 scope，才能加一条 Spotify 从没下发过的 flag" 的由来。
        if matchingIndices.isEmpty,
           let name = replacement.name, let scope = replacement.scope {
            switch replacement.modification {
            case .forceBool(let newValue):
                values.append(AssignedValue.with {
                    $0.propertyID = AssignedIdentifier.with { $0.scope = scope; $0.name = name }
                    $0.boolValue = BoolValue.with { $0.value = newValue }
                })
                continue

            case .forceEnum(let newValue):
                values.append(AssignedValue.with {
                    $0.propertyID = AssignedIdentifier.with { $0.scope = scope; $0.name = name }
                    $0.enumValue = EnumValue.with { $0.value = newValue }
                })
                continue

            case .forceInt(let newValue):
                values.append(AssignedValue.with {
                    $0.propertyID = AssignedIdentifier.with { $0.scope = scope; $0.name = name }
                    $0.intValue = IntValue.with { $0.value = newValue }
                })
                continue

            // 命中 0 条时仍然是静默 no-op（原有语义，不动）。
            case .remove, .setBool, .setEnum:
                break
            }
        }

        for index in matchingIndices.sorted(by: >) {
            switch replacement.modification {
            case .remove:
                values.remove(at: index)

            case .setBool(let newValue):
                values[index].boolValue = BoolValue.with { $0.value = newValue }

            case .setEnum(let newValue):
                values[index].enumValue = EnumValue.with { $0.value = newValue }

            case .forceBool(let newValue):
                values[index].boolValue = BoolValue.with { $0.value = newValue }

            case .forceEnum(let newValue):
                values[index].enumValue = EnumValue.with { $0.value = newValue }

            case .forceInt(let newValue):
                values[index].intValue = IntValue.with { $0.value = newValue }
            }
        }
    }

    if FlagOverrideStore.count > 0 {
        writeDebugLog("[Flags] user overrides in effect: \(FlagOverrideStore.count)")
    }

    reportLyricsReplacementOutcome(values)
}

private func modifyAttributes(_ attributes: inout [String: AccountAttribute]) {
    let serverAuthoritativeAttributes = Dictionary(
        uniqueKeysWithValues: ServerSidedFeaturePolicy.serverAuthoritativeAccountAttributes
            .compactMap { name in attributes[name].map { (name, $0) } }
    )

    let oneYearFromNow = Calendar.current.date(byAdding: .year, value: 1, to: Date())!
    
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(abbreviation: "UTC")
    
    attributes["ads"] = AccountAttribute.with {
        $0.boolValue = false
    }
    
    attributes["ab-ad-player-targeting"] = AccountAttribute.with {
        $0.stringValue = "0"
    }
    
    attributes["allow-advertising-id-transmission"] = AccountAttribute.with {
        $0.boolValue = false
    }
    
    attributes["restrict-advertising-id-transmission"] = AccountAttribute.with {
        $0.boolValue = true
    }

    attributes["can_use_superbird"] = AccountAttribute.with {
        $0.boolValue = true
    }

    attributes["enable-crossfade-product-state"] = AccountAttribute.with {
        $0.stringValue = "1"
    }

    attributes["enable-gapless-product-state"] = AccountAttribute.with {
        $0.stringValue = "1"
    }

    attributes["catalogue"] = AccountAttribute.with {
        $0.stringValue = "premium"
    }

    attributes["financial-product"] = AccountAttribute.with {
        $0.stringValue = "pr:premium,tc:0"
    }

    attributes["is-eligible-premium-unboxing"] = AccountAttribute.with {
        $0.boolValue = true
    }

    attributes["name"] = AccountAttribute.with {
        $0.stringValue = "Spotify Premium"
    }

    attributes["nft-disabled"] = AccountAttribute.with {
        $0.stringValue = "1"
    }

    attributes["on-demand"] = AccountAttribute.with {
        $0.boolValue = true
    }

    attributes["payments-initial-campaign"] = AccountAttribute.with {
        $0.stringValue = "default"
    }

    attributes["player-license"] = AccountAttribute.with {
        $0.stringValue = "premium"
    }

    attributes["player-license-v2"] = AccountAttribute.with {
        $0.stringValue = "premium"
    }

    attributes["product-expiry"] = AccountAttribute.with {
        $0.stringValue = formatter.string(from: oneYearFromNow)
    }

    attributes["shuffle-eligible"] = AccountAttribute.with {
        $0.boolValue = true
    }

    attributes["streaming-rules"] = AccountAttribute.with {
        $0.stringValue = ""
    }

    attributes["subscription-enddate"] = AccountAttribute.with {
        $0.stringValue = formatter.string(from: oneYearFromNow)
    }

    attributes["type"] = AccountAttribute.with {
        $0.stringValue = "premium"
    }

    attributes["unrestricted"] = AccountAttribute.with {
        $0.boolValue = true
    }

    // Premium-vs-free product-state deltas. boolValue serializes as "0"/"1".
    attributes["high-bitrate"] = AccountAttribute.with {
        $0.boolValue = true
    }

    // audio-quality left unforced: Very High fails to stream on a free entitlement.

    attributes["loudness-levels"] = AccountAttribute.with {
        $0.stringValue = "1:-5.0,0.0,3.0:-2.0"
    }

    attributes["pick-and-shuffle"] = AccountAttribute.with {
        $0.boolValue = false
    }

    attributes["mixing-tools"] = AccountAttribute.with {
        $0.stringValue = "EDIT"
    }

    attributes["your-library-tags"] = AccountAttribute.with {
        $0.boolValue = true
    }

    // Unknown purpose; premium sets these to 1.
    attributes["libspotify"] = AccountAttribute.with {
        $0.boolValue = true
    }

    attributes["mobile"] = AccountAttribute.with {
        $0.boolValue = true
    }

    attributes.removeValue(forKey: "payment-state")
    attributes.removeValue(forKey: "last-premium-activation-date")
    
    // Modern logout prevention (Spotify 9.1.22+)
    // Removing these forces the app to rely on the static premium attributes we set
    // and prevents it from performing "Smart Shuffle" or "Trial" validation logic
    // that often triggers a background logout.
    attributes.removeValue(forKey: "on-demand-trial")
    attributes.removeValue(forKey: "on-demand-trial-in-progress")
    attributes.removeValue(forKey: "smart-shuffle")
    
    // Additional keys that can trigger backend validation mismatches or premium popups
    attributes.removeValue(forKey: "at-signal")
    attributes.removeValue(forKey: "feature-set-id-masked")
    attributes.removeValue(forKey: "strider-key")
    attributes.removeValue(forKey: "is-eligible-for-trial")
    attributes.removeValue(forKey: "is-eligible-for-upsell")
    attributes.removeValue(forKey: "upsell-state")
    attributes.removeValue(forKey: "ad-session-persistence")
    attributes.removeValue(forKey: "ad-formats-preroll-video")
    
    for i in 1...100 {
        attributes.removeValue(forKey: "is-premium-eligible-v\(i)")
    }
    attributes.removeValue(forKey: "is-premium-eligible")

    // Restore the real account entitlements after all client-side Premium
    // mutations. Missing values remain missing instead of being synthesized.
    for name in ServerSidedFeaturePolicy.serverAuthoritativeAccountAttributes {
        if let original = serverAuthoritativeAttributes[name] {
            attributes[name] = original
        } else {
            attributes.removeValue(forKey: name)
        }
    }
}
