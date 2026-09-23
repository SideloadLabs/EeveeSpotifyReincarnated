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
    /// Recent tracks, newest last. This used to be a single slot, which is
    /// what made the Word-Synced button flicker away and its taps do
    /// nothing: prefetching the *next* track's lyrics replaced the current
    /// track's karaoke data, so lyrics(forTrackId:) for the track actually
    /// playing came back nil. Keyed storage makes the order fetches finish
    /// in irrelevant — a late result for another track can't evict this one.
    private var entries: [(trackId: String, lyrics: KaraokeLyricsDto)] = []
    private static let capacity = 8

    private init() {}

    func set(trackId: String, lyrics: KaraokeLyricsDto) {
        guard !trackId.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll { $0.trackId == trackId }
        entries.append((trackId, lyrics))
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }

    /// Karaoke lyrics for exactly this track, or nil — never another
    /// track's leftovers.
    func lyrics(forTrackId trackId: String) -> KaraokeLyricsDto? {
        lock.lock()
        defer { lock.unlock() }
        return entries.last { $0.trackId == trackId }?.lyrics
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
    }
}
