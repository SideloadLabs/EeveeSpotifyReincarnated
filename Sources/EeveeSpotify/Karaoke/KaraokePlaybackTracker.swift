import Foundation
import ObjectiveC.runtime
import EeveeSpotifyC

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
    private var lastPlaybackSpeed: Double = 1.0
    private var lastIsPlaying: Bool = false
    private var lastTrackId: String?

    private var didDumpStateShape = false

    /// The player the karaoke observer is registered on (SPTEsperantoPlayer
    /// via provideStateObservable) — used for tap-to-seek.
    weak var player: AnyObject?
    private var seekSelector: Selector?

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
        let trackId: String? = uriString.hasPrefix("spotify:track:")
            ? String(uriString.dropFirst("spotify:track:".count))
            : nil

        // Same unit handling as SponsorBlockSkipper.normalizeSeconds: the
        // player state can report position/duration in milliseconds, and
        // reading that as seconds put currentPositionMs() 1000x ahead —
        // every syllable instantly "sung", no progressive fill at all.
        let durationRaw: Double = (safeValue("duration") as? NSNumber)?.doubleValue ?? 0
        let positionRaw: Double = (safeValue("position") as? NSNumber).map {
            Self.normalizeSeconds($0.doubleValue, durationHint: durationRaw)
        } ?? lastPosition
        let reportedSpeed = (safeValue("playbackSpeed") as? NSNumber)?.doubleValue
        // isPlaying stays true while paused on this player state (it means
        // "has an active playback"), so the overlay kept running through a
        // pause. Paused shows up as isPaused, or as a playback speed of 0.
        let isPaused = (safeValue("isPaused") as? Bool) ?? false
        let isPlaying: Bool = ((safeValue("isPlaying") as? Bool) ?? lastIsPlaying)
            && !isPaused
            && reportedSpeed != 0
        let playbackSpeed: Double = reportedSpeed.flatMap { $0 > 0 ? $0 : nil } ?? lastPlaybackSpeed

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

    /// Seeks playback and moves the estimate there immediately, so the
    /// lyrics jump without waiting for the next state callback.
    func seek(toMs ms: Int) {
        guard let player = player else {
            writeDebugLog("[Karaoke] seek skipped: no player captured")
            return
        }
        if seekSelector == nil || !player.responds(to: seekSelector!) {
            seekSelector = ["seekTo:", "seekToPosition:", "seekToMs:"]
                .map(NSSelectorFromString)
                .first { player.responds(to: $0) }
        }
        guard let selector = seekSelector,
              let method = class_getInstanceMethod(object_getClass(player), selector) else {
            writeDebugLog("[Karaoke] seek skipped: \(type(of: player)) has no seek selector")
            return
        }
        // Same unit rule as SponsorBlockSkipper.seek: a Double argument
        // is seconds, anything else milliseconds.
        let argType: String = {
            guard let raw = method_copyArgumentType(method, 2) else { return "?" }
            defer { free(raw) }
            return String(cString: raw)
        }()
        let seconds = Double(max(0, ms)) / 1000
        EeveeSBInvokeSeekDouble(player, selector, argType == "d" ? seconds : seconds * 1000)
        queue.async {
            self.lastPosition = seconds
            self.lastPositionStamp = self.uptimeSec()
        }
        writeDebugLog("[Karaoke] seek to \(ms)ms via \(NSStringFromSelector(selector))")
    }

    func currentTrackId() -> String? {
        queue.sync { lastTrackId }
    }

    func isPlaying() -> Bool {
        queue.sync { lastIsPlaying }
    }

    private static func normalizeSeconds(_ raw: Double, durationHint: Double) -> Double {
        if raw > 10_000 || durationHint > 10_000 { return raw / 1000.0 }
        return raw
    }

    private func uptimeSec() -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000.0
    }
}
