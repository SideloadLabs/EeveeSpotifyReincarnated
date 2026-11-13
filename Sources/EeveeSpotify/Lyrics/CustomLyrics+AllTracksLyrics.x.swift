import Orion
import UIKit

private var shouldOverrideLocalTrackURI = false

// SPTPlayerTrack metadata hooks not compatible with 9.1.x
class SPTPlayerTrackHook: ClassHook<NSObject> {
    typealias Group = LyricsErrorHandlingGroup  // Not activated for 9.1.x
    static let targetName = EeveeSpotify.hookTarget == .v90
        ? "SPTPlayerTrackImplementation"
        : "SPTPlayerTrack"

    func metadata() -> [String: String] {
        var meta = orig.metadata()
        meta["has_lyrics"] = "true"
        return meta
    }
    
    func URI() -> NSURL? {
        let uri = orig.URI()

        guard shouldOverrideLocalTrackURI,
              let absoluteString = uri?.absoluteString,
              absoluteString.isLocalTrackIdentifier else {

            // Trigger a background lyrics prefetch as soon as the track URI is
            // observed — well before Spotify fires its /color-lyrics/v2 request.
            if let uriString = uri?.absoluteString,
               uriString.hasPrefix("spotify:track:") {
                let trackId = uriString.replacingOccurrences(of: "spotify:track:", with: "")
                if !trackId.isEmpty {
                    prefetchLyricsIfNeeded(trackId: trackId)
                }
            }

            return uri
        }

        return NSURL(string: "spotify:track:")!
    }
}

// LyricsScrollProvider not compatible with 9.1.x
class LyricsScrollProviderHook: ClassHook<NSObject> {
    typealias Group = LyricsErrorHandlingGroup  // Not activated for 9.1.x
    static let targetName = "Lyrics_CoreImpl.LyricsScrollProvider"
    
    func isEnabledForTrack(_ track: SPTPlayerTrack) -> Bool {
        return true
    }
}

// NPVScrollViewController not compatible with 9.1.x  
class NPVScrollViewControllerHook: ClassHook<NSObject> {
    typealias Group = LyricsErrorHandlingGroup  // Not activated for 9.1.x (moved from ModernLyricsGroup)
    static var targetName = "NowPlaying_ScrollImpl.NPVScrollViewController"

    func viewWillAppear(_ animated: Bool) {
        shouldOverrideLocalTrackURI = true
        orig.viewWillAppear(animated)
    }
    
    func viewWillDisappear(_ animated: Bool) {
        shouldOverrideLocalTrackURI = false
        orig.viewWillDisappear(animated)
    }
}

// V91-compatible version of NPVScrollViewController hook
class NPVScrollViewControllerV91Hook: ClassHook<NSObject> {
    typealias Group = V91LyricsGroup
    static var targetName = "NowPlaying_ScrollImpl.NPVScrollViewController"

    func viewWillAppear(_ animated: Bool) {
        shouldOverrideLocalTrackURI = true
        orig.viewWillAppear(animated)
    }
    
    func viewWillDisappear(_ animated: Bool) {
        shouldOverrideLocalTrackURI = false
        orig.viewWillDisappear(animated)
    }
}

class NowPlayingScrollViewControllerHook: ClassHook<NSObject> {
    typealias Group = LegacyLyricsGroup
    static var targetName = EeveeSpotify.hookTarget == .v91
        ? "UIView" // Dummy target for 9.1.6
        : "NowPlaying_ScrollImpl.NowPlayingScrollViewController"
    
    func nowPlayingScrollViewModelWithDidLoadComponentsFor(
        _ track: SPTPlayerTrack,
        withDifferentProviders: Bool,
        scrollEnabledValueChanged: Bool
    ) -> NowPlayingScrollViewController {
        let controller = orig.nowPlayingScrollViewModelWithDidLoadComponentsFor(
            track,
            withDifferentProviders: withDifferentProviders,
            scrollEnabledValueChanged: scrollEnabledValueChanged
        )
        
        if !scrollEnabledValueChanged {
            controller.scrollEnabled = true
            controller.nowPlayingScrollViewModelDidChangeScrollEnabledValue()
        }
        
        return controller
    }
}
