import Foundation
import ObjectiveC.runtime

/// Tracks live playback position and the current track's Spotify ID, for the
/// karaoke overlay's animation loop.
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
    private var lastDuration: Double = 0
    private var lastPlaybackSpeed: Double = 1.0
    private var lastIsPlaying: Bool = false
    private var lastTrackId: String?
    // Only ever set from the player observer, unlike lastTrackId (which a lyrics fetch also sets).
    private var observedTrackId: String?

    private var didDumpStateShape = false

    private init() {}

    /// Call from the player-state-change observer with the raw state object.
    ///
    /// The key names below ("track"/"URI"/"position"/"playbackSpeed"/
    /// "isPlaying") were the assumed shape of the OLD SPTPlayerServiceImplementation
    /// -addPlayerObserver: callback's state object. As of the 9.1.78 IPA I
    /// inspected, that whole registration path doesn't exist anymore — the
    /// real one is SPTEsperantoPlayer (obtained via provideStateObservable(),
    /// see KaraokeHooks.x.swift) calling didChangeState: with an SPTPlayerState
    /// object, which is a DIFFERENT class than whatever the old assumed shape
    /// was modeled on, and its actual property names haven't been confirmed
    /// yet.
    ///
    /// Every value(forKey:) below is now guarded with responds(to:) first —
    /// calling value(forKey:) with a key the object doesn't actually have
    /// raises an uncatchable NSException (an actual crash, not a Swift nil),
    /// so guessing these key names unguarded against a still-unconfirmed
    /// class would be a real regression risk now that this is actually being
    /// called (previously safe purely because the broken hook meant this
    /// function was never invoked in practice). If any of these keys turn
    /// out wrong, this just silently keeps the previous/default value for
    /// that field rather than crashing — see the one-time dump below for
    /// getting the REAL key names for a proper follow-up fix.
    func processStateChange(state: AnyObject) {
        if !didDumpStateShape {
            didDumpStateShape = true
            karaokeDumpClassMethods("playerState", of: state)
        }

        func safeValue(_ key: String) -> Any? {
            guard state.responds(to: Selector(key)) else { return nil }
            return state.value(forKey: key)
        }

        let trackObj = safeValue("track") as AnyObject?
        let uriObj: Any? = trackObj.flatMap { obj -> Any? in
            guard obj.responds(to: Selector("URI")) else { return nil }
            return obj.value(forKey: "URI")
        }
        let uriString: String = {
            if let s = uriObj as? String { return s }
            if let u = uriObj as? URL { return u.absoluteString }
            return ""
        }()

        // spotify:track:<id> — same extraction style used elsewhere in the
        // codebase for episode URIs (extractEpisodeID in SponsorBlockSkipper).
        let cleanURI = uriString.components(separatedBy: "#").first?
            .components(separatedBy: "?").first ?? uriString
        let rawTrackId = cleanURI.hasPrefix("spotify:track:")
            ? String(cleanURI.dropFirst("spotify:track:".count))
            : nil
        let trackId = rawTrackId.flatMap { $0.isEmpty ? nil : $0 }

        let positionRaw: Double = (safeValue("position") as? NSNumber)?.doubleValue ?? lastPosition
        let durationRaw: Double = (safeValue("duration") as? NSNumber)?.doubleValue ?? 0
        let playbackSpeed: Double = (safeValue("playbackSpeed") as? NSNumber)?.doubleValue ?? lastPlaybackSpeed
        let isPlaying: Bool = (safeValue("isPlaying") as? Bool) ?? lastIsPlaying

        // A state whose item is not a music track (podcast episode, ad, local file)
        // means the previous track's lyrics no longer apply.
        let isNonTrackItem = trackId == nil && !uriString.isEmpty

        queue.async {
            self.lastPosition = positionRaw
            self.lastPositionStamp = self.uptimeSec()
            if durationRaw > 0 {
                self.lastDuration = durationRaw
            }
            self.lastPlaybackSpeed = playbackSpeed
            self.lastIsPlaying = isPlaying

            let previousTrackId = self.lastTrackId
            let previousObservedTrackId = self.observedTrackId
            if let trackId = trackId, !trackId.isEmpty {
                self.lastTrackId = trackId
                self.observedTrackId = trackId
            } else if isNonTrackItem {
                self.lastTrackId = nil
                self.observedTrackId = nil
            }
            // Button visibility follows the track, so tell it when the track changes.
            if self.lastTrackId != previousTrackId || self.observedTrackId != previousObservedTrackId {
                KaraokeLyricsStore.shared.notify()
            }
        }
    }

    func updateTrackIdFromLyricsFetch(_ trackId: String) {
        guard !trackId.isEmpty else { return }
        queue.async {
            guard self.lastTrackId != trackId else { return }
            self.lastTrackId = trackId
            KaraokeLyricsStore.shared.notify()
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

    /// The track the player itself reports as playing, or nil when the observer hasn't reported one.
    func playerReportedTrackId() -> String? {
        queue.sync { observedTrackId }
    }

    func currentTrackId() -> String? {
        queue.sync { lastTrackId }
    }

    func isPlaying() -> Bool {
        queue.sync { lastIsPlaying }
    }

    func durationMs() -> Int {
        queue.sync { Int(max(0, lastDuration) * 1000) }
    }

    private func uptimeSec() -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000.0
    }
}
