import Foundation

/// Tracks live playback position and the current track's Spotify ID, for the
/// karaoke overlay's animation loop. Modeled directly on the same KVC-based
/// reading pattern SponsorBlockSkipper already uses in production (state.value
/// (forKey: "position") etc.) — that pattern is proven to work via the real
/// SPTPlayerServiceImplementation observer hook, so this reuses the exact same
/// keys rather than rediscovering them.
///
/// Kept as its own observer/store (registered separately, see
/// KaraokeHooks.x.swift) rather than reading through SponsorBlockSkipper
/// directly, so the karaoke feature has no dependency on SponsorBlock being
/// enabled or its internal state machine.
final class KaraokePlaybackTracker {
    static let shared = KaraokePlaybackTracker()

    private let queue = DispatchQueue(label: "com.eevee.karaoke.playback")

    private var lastPosition: Double = 0
    private var lastPositionStamp: TimeInterval = 0
    private var lastPlaybackSpeed: Double = 1.0
    private var lastIsPlaying: Bool = false
    private var lastTrackId: String?

    private init() {}

    /// Call from the player-state-change observer with the raw state object.
    func processStateChange(state: AnyObject) {
        let trackObj = state.value(forKey: "track") as AnyObject?
        let uriObj   = trackObj?.value(forKey: "URI")
        let uriString: String = {
            if let s = uriObj as? String { return s }
            if let u = uriObj as? URL { return u.absoluteString }
            return ""
        }()

        // spotify:track:<id> — same extraction style used elsewhere in the
        // codebase for episode URIs (extractEpisodeID in SponsorBlockSkipper).
        let trackId: String? = uriString.hasPrefix("spotify:track:")
            ? String(uriString.dropFirst("spotify:track:".count))
            : nil

        let positionRaw: Double = (state.value(forKey: "position") as? NSNumber)?.doubleValue ?? 0
        let playbackSpeed: Double = (state.value(forKey: "playbackSpeed") as? NSNumber)?.doubleValue ?? 1.0
        let isPlaying: Bool = (state.value(forKey: "isPlaying") as? Bool) ?? false

        queue.async {
            self.lastPosition = positionRaw
            self.lastPositionStamp = self.uptimeSec()
            self.lastPlaybackSpeed = playbackSpeed
            self.lastIsPlaying = isPlaying
            if let trackId = trackId, !trackId.isEmpty {
                self.lastTrackId = trackId
            }
        }
    }

    /// Track-ID-only update, independent of processStateChange above.
    ///
    /// Added because on the 9.1.78 IPA I was given to inspect, the
    /// -addPlayerObserver: registration this class otherwise depends on
    /// fails to hook at all (Spotify appears to have moved that API to a
    /// generic SPTObserverManager<Protocol> pattern — a much deeper native
    /// change than a simple rename, not something to guess at blind) —
    /// meaning processStateChange above is never actually called on that
    /// build, and currentTrackId() would stay nil forever, which is exactly
    /// what was keeping the Word-Synced button permanently hidden even with
    /// syllable lyrics confirmed fetched.
    ///
    /// CustomLyrics.x.swift's getLyricsDataForCurrentTrack already reliably
    /// learns the current track ID a different way on this build — by
    /// reading it straight off the path of Spotify's own native
    /// /color-lyrics/v2/track/{trackId} request, which fires on every real
    /// track change regardless of the observer issue above (confirmed via
    /// the debug log: lyrics were being fetched correctly for each track in
    /// sequence throughout). Feeding that same value in here as soon as it's
    /// known — instead of only via the broken observer — is what should get
    /// the button showing correctly again.
    ///
    /// This does NOT restore position/playbackSpeed/isPlaying tracking —
    /// those still depend on the broken observer, so the karaoke lyrics
    /// view's own line-by-line highlighting timing may still be affected
    /// until that's fixed for real. This only unblocks the button's own
    /// "is there data for this track" check, which is all it needs.
    func updateTrackIdFromLyricsFetch(_ trackId: String) {
        guard !trackId.isEmpty else { return }
        queue.async {
            self.lastTrackId = trackId
        }
    }

    /// Estimated current playback position in milliseconds, interpolated
    /// between actual state-change callbacks the same way SponsorBlockSkipper
    /// does — needed because callbacks don't fire every frame, but the
    /// karaoke animation needs a smooth value every frame.
    func currentPositionMs() -> Int {
        queue.sync {
            let elapsed = (lastPositionStamp == 0) ? 0 : (uptimeSec() - lastPositionStamp)
            let estSeconds = lastIsPlaying
                ? lastPosition + elapsed * lastPlaybackSpeed
                : lastPosition
            return Int(max(0, estSeconds) * 1000)
        }
    }

    func currentTrackId() -> String? {
        queue.sync { lastTrackId }
    }

    func isPlaying() -> Bool {
        queue.sync { lastIsPlaying }
    }

    private func uptimeSec() -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000.0
    }
}
