import Foundation

/// Holds the most recently parsed karaoke (per-syllable) lyrics, keyed by
/// Spotify track ID. SpicyLyricsRepository populates this as a side effect
/// whenever it parses a Type=="Syllable" response — it's the bridge between
/// the existing LyricsRepository protocol (which only returns flattened
/// LyricsDto, matching Spotify's native line-only protobuf schema) and the
/// custom karaoke overlay view, which needs the richer per-syllable timing
/// that LyricsDto has nowhere to carry.
///
/// Not persisted, not thread-safety-hardened beyond a simple lock — this is
/// just a same-process handoff between "lyrics were fetched" and "the
/// overlay wants to render them," both of which happen on the main app
/// process during normal playback.
/// Holds the most recently parsed karaoke (per-syllable) lyrics, keyed by
/// Spotify track ID. SpicyLyricsRepository populates this as a side effect
/// whenever it parses a Type=="Syllable" response — it's the bridge between
/// the existing LyricsRepository protocol (which only returns flattened
/// LyricsDto, matching Spotify's native line-only protobuf schema) and the
/// custom karaoke overlay view, which needs the richer per-syllable timing
/// that LyricsDto has nowhere to carry.
///
/// Not persisted, not thread-safety-hardened beyond a simple lock — this is
/// just a same-process handoff between "lyrics were fetched" and "the
/// overlay wants to render them," both of which happen on the main app
/// process during normal playback.
final class KaraokeLyricsStore {
    static let shared = KaraokeLyricsStore()

    private let lock = NSLock()
    private var current: (trackId: String, lyrics: KaraokeLyricsDto)?

    /// The track ID of the most recently *started* fetch — set by
    /// noteRequestStarted(trackId:), which CustomLyrics.x.swift's
    /// loadCustomLyricsForTrackId calls right before it asks a repository
    /// for lyrics, on both the prefetch and real-time-fetch paths (the only
    /// two ways a fetch begins).
    ///
    /// Rapid skipping starts several of these fetches back to back, and
    /// they're independent network calls that can finish in any order — a
    /// track skipped several songs ago can finish (or come back from a
    /// 429/503 retry) well after a later, currently-relevant track already
    /// got its own answer. Gating set(trackId:lyrics:) below on THIS value
    /// (last *started*, not last *finished*) means a late straggler for an
    /// already-superseded track can't clobber the store: by the time it
    /// finishes, latestRequestedTrackId has already moved on to whatever
    /// was requested after it, so the stale write is simply dropped.
    ///
    /// This is what was behind the Word-Synced button appearing for a
    /// second then disappearing after skipping through several tracks: the
    /// button watches lyrics(forTrackId:) for the now-current track, which
    /// briefly saw its own correct data (button on), until a slower,
    /// already-irrelevant track's fetch finished afterward and overwrote
    /// `current` with its own (mismatched) trackId — the read guard below
    /// still worked correctly, there just wasn't anything left to read
    /// once the wrong track's data won the race to be `current`.
    private var latestRequestedTrackId: String?

    private init() {}

    /// Call as soon as a fetch for `trackId` begins (before the network
    /// call, not after) — see the doc comment on latestRequestedTrackId.
    func noteRequestStarted(trackId: String) {
        guard !trackId.isEmpty else { return }
        lock.lock()
        latestRequestedTrackId = trackId
        lock.unlock()
    }

    func set(trackId: String, lyrics: KaraokeLyricsDto) {
        lock.lock()
        defer { lock.unlock() }
        // Drop a result for a track that's no longer the latest one asked
        // for — see latestRequestedTrackId's doc comment. If nothing was
        // ever recorded as "requested" (shouldn't normally happen, since
        // every fetch path calls noteRequestStarted first), fail open
        // rather than silently discarding real data.
        if let latest = latestRequestedTrackId, latest != trackId { return }
        current = (trackId, lyrics)
    }

    /// Returns the stored karaoke lyrics only if they match the requested
    /// track — guards against the overlay reading stale data left over from
    /// the previous track if the new track's lyrics fetch is still in flight
    /// or failed/fell back to a non-Syllable source.
    func lyrics(forTrackId trackId: String) -> KaraokeLyricsDto? {
        lock.lock()
        defer { lock.unlock() }
        guard current?.trackId == trackId else { return nil }
        return current?.lyrics
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        current = nil
    }
}
