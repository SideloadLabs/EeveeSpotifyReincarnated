import Foundation
import UIKit

func modifyRemoteConfiguration(_ configuration: inout UcsResponse) {
    modifyAttributes(&configuration.attributes.accountAttributes)
    
    // IMPORTANT:
    // Always apply our assignedValues patching. Some accounts receive different remote configs,
    // and using a static bundled resolve config alone can regress back to Free tier.
    modifyAssignedValues(&configuration.assignedValues)

    if UserDefaults.overwriteConfiguration {
        configuration.resolve.configuration = try! BundleHelper.shared.resolveConfiguration()
    }
}

private let propertyReplacements = [
    // Append when the account's config omits them, so they work without overwrite-configuration.
    EeveePropertyReplacement(name: "crossfade_enabled", scope: "ios-feature-settings", modification: .forceBool(true)),
    EeveePropertyReplacement(name: "automix_enabled", scope: "ios-feature-settings", modification: .forceBool(true)),

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
    EeveePropertyReplacement(name: "embedded_npv_video_show_with_canvas", scope: "ios-feature-adsnowplayingui", modification: .setBool(false)),

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
    EeveePropertyReplacement(name: "enable_sharing_v2", modification: .forceBool(true))
]

private func modifyAssignedValues(_ values: inout [AssignedValue]) {
    for replacement in propertyReplacements {
        let matchingIndices = values.indices.filter({ index in
            let value = values[index]
            let nameMatches = replacement.name.map { value.propertyID.name == $0 } ?? true
            let scopeMatches = replacement.scope.map { value.propertyID.scope == $0 } ?? true
            return nameMatches && scopeMatches
        })

        if matchingIndices.isEmpty, case .forceBool(let newValue) = replacement.modification,
           let name = replacement.name, let scope = replacement.scope {
            values.append(AssignedValue.with {
                $0.propertyID = AssignedIdentifier.with { $0.scope = scope; $0.name = name }
                $0.boolValue = BoolValue.with { $0.value = newValue }
            })
            continue
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
            }
        }
    }
}

private func modifyAttributes(_ attributes: inout [String: AccountAttribute]) {
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

    attributes["offline"] = AccountAttribute.with {
        $0.boolValue = true // allow downloading
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

    attributes["social-session"] = AccountAttribute.with {
        $0.boolValue = true
    }

    attributes["social-session-free-tier"] = AccountAttribute.with {
        $0.boolValue = false
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

    attributes["offline-backup"] = AccountAttribute.with {
        $0.stringValue = "UNRESTRICTED"
    }

    attributes["lyrics-offline"] = AccountAttribute.with {
        $0.boolValue = true
    }

    attributes["mixing-tools"] = AccountAttribute.with {
        $0.stringValue = "EDIT"
    }

    attributes["jam-social-session"] = AccountAttribute.with {
        $0.stringValue = "EXPANDED"
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
}
