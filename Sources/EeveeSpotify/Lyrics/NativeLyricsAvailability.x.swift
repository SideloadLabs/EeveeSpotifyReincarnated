import Foundation
import Orion

/// Spotify 9.2 runs the v91 hook set, which leaves LyricsErrorHandlingGroup (and its
/// "has_lyrics = true for every track") off. Spotify then shows its native lyrics
/// preview only for tracks it has lyrics for itself. Mark has_lyrics only for tracks
/// whose provider lyrics we already have saved, so tracks with no lyrics at all keep
/// showing nothing.
struct NativeLyricsAvailabilityGroup: HookGroup { }

class SPTPlayerTrackLyricsAvailabilityHook: ClassHook<NSObject> {
    typealias Group = NativeLyricsAvailabilityGroup
    static let targetName = "SPTPlayerTrack"

    // NSDictionary, not [String: String]: Spotify reads track metadata very often,
    // and a Swift dictionary would be bridged in and out on every call.
    func metadata() -> NSDictionary {
        let meta = orig.metadata()
        guard NativeOfflineLyrics.shared.hasAnyProviderLyrics,
              meta["has_lyrics"] as? String != "true",
              let uri = target.perform(NSSelectorFromString("URI"))?.takeUnretainedValue() as? NSURL,
              let text = uri.absoluteString, text.hasPrefix("spotify:track:"),
              NativeOfflineLyrics.shared.hasProviderLyrics(trackId: String(text.dropFirst(14))),
              let marked = meta.mutableCopy() as? NSMutableDictionary else { return meta }
        marked["has_lyrics"] = "true"
        return marked
    }
}
