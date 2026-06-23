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
final class KaraokeLyricsStore {
    static let shared = KaraokeLyricsStore()

    private let lock = NSLock()
    private var current: (trackId: String, lyrics: KaraokeLyricsDto)?

    private init() {}

    func set(trackId: String, lyrics: KaraokeLyricsDto) {
        lock.lock()
        defer { lock.unlock() }
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
