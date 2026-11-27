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
    private var cache: [String: KaraokeLyricsDto] = [:]
    private var order: [String] = []
    private let capacity = 8
    /// Counts `set` calls; `written` keeps the count of each track's last one.
    private var serial = 0
    private var written: [String: Int] = [:]

    private init() {}

    func set(trackId: String, lyrics: KaraokeLyricsDto) {
        guard !trackId.isEmpty else { return }
        lock.lock()
        cache[trackId] = lyrics
        serial += 1
        written[trackId] = serial
        order.removeAll { $0 == trackId }
        order.append(trackId)
        if order.count > capacity {
            let evicted = order.removeFirst()
            cache[evicted] = nil
            written[evicted] = nil
        }
        lock.unlock()
        notify()
    }

    /// Where a provider fetch starts. The track's lyrics stay in place while it runs, so
    /// Spotify asking again for the same song never hides the button in between.
    func mark() -> Int {
        lock.lock(); defer { lock.unlock() }
        return serial
    }

    /// Whether the track's lyrics were set after `mark`.
    func wasSet(trackId: String, since mark: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return (written[trackId] ?? 0) > mark
    }

    /// Ends a provider fetch: the button shows only lyrics a fetch actually produced, so a
    /// track keeps its entry only if it was set after `mark`.
    func settle(trackId: String, since mark: Int) {
        guard !wasSet(trackId: trackId, since: mark) else { return }
        remove(trackId: trackId)
    }

    /// Drops a track's entry, so a result from an earlier source can never keep the
    /// button alive for a track whose current fetch found nothing.
    func remove(trackId: String) {
        guard !trackId.isEmpty else { return }
        lock.lock()
        let hadEntry = cache.removeValue(forKey: trackId) != nil
        written[trackId] = nil
        order.removeAll { $0 == trackId }
        lock.unlock()
        if hadEntry { notify() }
    }

    func lyrics(forTrackId trackId: String) -> KaraokeLyricsDto? {
        lock.lock()
        defer { lock.unlock() }
        return cache[trackId]
    }

    func clear() {
        lock.lock()
        cache = [:]
        order = []
        written = [:]
        lock.unlock()
        notify()
    }

    func notify() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: .eeveeKaraokeLyricsChanged, object: nil) }
    }
}
