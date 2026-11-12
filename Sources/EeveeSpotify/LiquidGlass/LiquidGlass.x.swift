import EeveeSpotifyC
import Foundation
import Orion

enum LiquidGlass {
    static let launchOptions = UserDefaults.liquidGlassOptions

    private static let spotifyOverrideKey = "LiquidGlassOverride"
    private static let swiftUIOptOutKey = "com.apple.SwiftUI.IgnoreSolariumOptOut"

    fileprivate static func applyDefaults() {
        UserDefaults.standard.set(true, forKey: spotifyOverrideKey)
        UserDefaults.standard.set(true, forKey: swiftUIOptOutKey)
    }

    // Spotify persists these itself and re-applies them next launch, so turning off must clear them.
    static func clearDefaults() {
        UserDefaults.standard.removeObject(forKey: spotifyOverrideKey)
        UserDefaults.standard.removeObject(forKey: swiftUIOptOutKey)
    }

    fileprivate static let glassFlags: [String: Any] = [
        "ios-reprise-liquid-glass-override.mode": "force_enabled",
        "ios-reprise-liquid-glass-properties.context_menu_in_navigation_bar_enabled": true,
        "ios-album-albumfeatureproperties-impl.context_menu_in_navigation_bar_enabled": true,
        "ios-audiobookprerelease-prereleasepage-impl.context_menu_in_navigation_bar_enabled": true,
        "ios-creator-impl.context_menu_in_navigation_bar_enabled_artist": true,
        "ios-creator-impl.context_menu_in_navigation_bar_enabled_author": true,
        "ios-feature-audiobook-featureproperties-impl.context_menu_in_navigation_bar_enabled": true,
        "ios-feature-freetierplaylist.context_menu_in_navigation_bar_enabled": true,
        "ios-feature-modernepisodepage.context_menu_in_navigation_bar_enabled": true,
        "ios-podcastuiplatform-podcastimpl.context_menu_in_navigation_bar_enabled": true,
        "ios-prerelease-feature.context_menu_in_navigation_bar_enabled": true,
    ]

    fileprivate static let newPlayerFlags: [String: Any] = [
        "ios-feature-encoreexperiments.new_npv_slider_enabled": true,
        "ios-feature-nowplaying.sheet_style_npv": true,
        "ios-feature-nowplaying.bottom_sheet_queue_enabled": true,
        "ios-feature-nowplaying.new_redesign_header_with_context_menu_enabled": true,
        "ios-feature-nowplaying-elements.enable_connect_bottom_sheet": true,
        "ios-playbackcontrol-audiovideoswitcher-impl.enable_connect_bottom_sheet": true,
        "ios-feature-sleeptimer.use_options_sheet": true,
    ]
}

struct LiquidGlassGroup: HookGroup {}

class HubLiquidGlassNavigationHook: ClassHook<NSObject> {
    typealias Group = LiquidGlassGroup
    static let targetName = "SPTHubViewController"

    func prefersLiquidGlassNavigationBar() -> Bool {
        true
    }
}

func activateLiquidGlass() {
    let start = CFAbsoluteTimeGetCurrent()
    let options = LiquidGlass.launchOptions
    var active = [String]()
    var plist: String?
    func add(_ name: String, _ on: Bool) { if on { active.append(name) } }
    defer {
        if !active.isEmpty || options.enabled {
            eeveeLog("[EeveeSpotify][Glass] Active: %@; plist %@ (%.2f ms)", active.isEmpty ? "none" : active.joined(separator: ", "),
                     plist ?? "untouched", (CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
    }

    activateNowPlayingBarConnect()
    activatePlayerDeclutter()
    activateRoundedArtwork()
    if options.newPlayerDesign {
        RemoteFlags.shared.force(LiquidGlass.newPlayerFlags, by: "NewPlayer")
    }

    let player = UserDefaults.playerOptions
    if player.backdrop {
        add("player backdrop", activate(PlayerBackdropGroup(), PlayerBackgroundHook.targetName, PlayerCoverListHook.targetName,
                                        PlayerArtworkHook.targetName, PlayerDurationHook.targetName))
    }

    guard options.enabled else { return }
    guard #available(iOS 26.0, *) else {
        eeveeLog("[EeveeSpotify][Glass] Skipped: needs iOS 26")
        return
    }

    LiquidGlass.applyDefaults()
    plist = EeveeSetMainInfoValue("UIDesignRequiresCompatibility", false as NSNumber) ? "patched" : "FAILED"

    var tabBar = false, nowPlaying = false
    if options.spotifyGlass {
        RemoteFlags.shared.force(LiquidGlass.glassFlags, by: "Glass")
        add("spotify glass", activate(LiquidGlassGroup(), HubLiquidGlassNavigationHook.targetName))
    }
    if options.tabBar {
        tabBar = activate(GlassTabBarGroup(), GlassTabBarViewHook.targetName, GlassTabBarContainerHook.targetName)
        add("tab bar", tabBar)
    }
    if options.nowPlayingBar {
        nowPlaying = activate(GlassNowPlayingBarGroup(), GlassNowPlayingBarContainerHook.targetName, GlassNowPlayingBarHook.targetName)
        add("now playing bar", nowPlaying)
    }
    if player.glassLyricsCard {
        add("lyrics card", activate(PlayerLyricsCardGroup(), PlayerLyricsCardHook.targetName, GlassLyricsPageHook.targetName))
    }
    if options.search != false {
        add("search", activate(GlassSearchGroup(), GlassSearchFieldHook.targetName, GlassSearchCardHook.targetName, GlassFindFieldHook.targetName))
    }
    if options.home != false {
        add("home", activate(GlassHomeGroup(), GlassHomeShortcutHook.targetName))
    }
    if options.playlist != false {
        add("playlist", activate(GlassPlaylistGroup(), GlassPlaylistHook.targetName, PlaylistPlayStateHook.targetName, PlaylistListHook.targetName, PlaylistArtworkHook.targetName, PlaylistHeaderLayoutHook.targetName, PlaylistChipHook.targetName))
        add("album", activate(GlassAlbumGroup(), GlassAlbumHook.targetName, GlassAlbumListHook.targetName))
        if activate(GlassArtistGroup(), GlassArtistHook.targetName) {
            EeveePixieInstallArtistFollow()
            active.append("artist")
        }
    }
    if tabBar || nowPlaying {
        add("transitions", activate(GlassTransitionGroup(), BarOverlayTransitionHook.targetName, CompactOverlayTransitionHook.targetName))
    }
}

private func activate(_ group: HookGroup, _ classes: String...) -> Bool {
    let missing = classes.filter { NSClassFromString($0) == nil }
    guard missing.isEmpty else {
        eeveeLog("[EeveeSpotify][Glass] Skipped %@: missing %@", "\(type(of: group))", missing.joined(separator: ", "))
        return false
    }
    group.activate()
    return true
}
