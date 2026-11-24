import Foundation

/// What the automatic lyrics refresh must not ask again, per provider:
/// - definite misses (no lyrics, or Spotify has no title/artist to search with),
///   kept until the lookup options change or the download is removed;
/// - tracks whose last attempt failed temporarily (network, HTTP 429/5xx), and a
///   provider that refused access (key rejected): both wait a day.
/// Explicit downloads (the library button, a new album) still ask.
final class LyricsNotFoundStore {
    static let shared = LyricsNotFoundStore(defaults: UserDefaults.container)
    static let retryDelay: TimeInterval = 24 * 60 * 60
    private static let sources = [0, 1, 3, 5]
    private let defaults: UserDefaults
    private let lock = NSLock()
    init(defaults: UserDefaults) { self.defaults = defaults }
    private func key(_ source: Int) -> String { "EeveeLyricsProviderNotFound-\(source)" }
    private func retryKey(_ source: Int) -> String { "EeveeLyricsProviderRetryAfter-\(source)" }
    private func refusedKey(_ source: Int) -> String { "EeveeLyricsProviderRefusedUntil-\(source)" }
    private func retries(_ source: Int) -> [String: Double] {
        defaults.dictionary(forKey: retryKey(source)) as? [String: Double] ?? [:]
    }

    func resetForLookupOptionsChange() {
        lock.lock(); defer { lock.unlock() }
        for source in Self.sources {
            defaults.removeObject(forKey: key(source))
            defaults.removeObject(forKey: retryKey(source))
            defaults.removeObject(forKey: refusedKey(source))
        }
    }
    func entries(source: Int) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(defaults.stringArray(forKey: key(source)) ?? [])
    }
    func record(_ id: String, source: Int) {
        lock.lock(); defer { lock.unlock() }
        var ids = Set(defaults.stringArray(forKey: key(source)) ?? [])
        if ids.insert(id).inserted { defaults.set(Array(ids), forKey: key(source)) }
        removeRetry(id, source: source)
    }
    func succeeded(_ id: String, source: Int) {
        lock.lock(); defer { lock.unlock() }
        var ids = Set(defaults.stringArray(forKey: key(source)) ?? [])
        if ids.remove(id) != nil { defaults.set(Array(ids), forKey: key(source)) }
        removeRetry(id, source: source)
        defaults.removeObject(forKey: refusedKey(source))
    }

    /// A temporary failure: the automatic refresh asks again after `retryDelay`.
    func retryLater(_ id: String, source: Int, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        var values = retries(source)
        values[id] = now.addingTimeInterval(Self.retryDelay).timeIntervalSince1970
        defaults.set(values, forKey: retryKey(source))
    }
    /// Tracks still waiting for their next-day retry. Expired entries are dropped.
    func waiting(source: Int, now: Date = Date()) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        let values = retries(source)
        let current = values.filter { $0.value > now.timeIntervalSince1970 }
        if current.count != values.count { defaults.set(current, forKey: retryKey(source)) }
        return Set(current.keys)
    }
    private func removeRetry(_ id: String, source: Int) {
        var values = retries(source)
        if values.removeValue(forKey: id) != nil { defaults.set(values, forKey: retryKey(source)) }
    }

    /// The provider rejected access (not a property of any track).
    func providerRefused(source: Int, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        defaults.set(now.timeIntervalSince1970, forKey: refusedKey(source))
    }
    /// When the provider last refused access, while that refusal still blocks the
    /// automatic refresh.
    func refusal(source: Int, now: Date = Date()) -> Date? {
        lock.lock(); defer { lock.unlock() }
        let value = defaults.double(forKey: refusedKey(source))
        guard value > 0 else { return nil }
        let date = Date(timeIntervalSince1970: value)
        guard date.addingTimeInterval(Self.retryDelay) > now else {
            defaults.removeObject(forKey: refusedKey(source))
            return nil
        }
        return date
    }

    /// A removed download starts over if it is downloaded again. `nil`: every download was removed.
    func forget(_ ids: [String]?) {
        lock.lock(); defer { lock.unlock() }
        guard let ids else {
            for source in Self.sources {
                defaults.removeObject(forKey: key(source))
                defaults.removeObject(forKey: retryKey(source))
            }
            return
        }
        let removed = Set(ids)
        guard !removed.isEmpty else { return }
        for source in Self.sources {
            let misses = Set(defaults.stringArray(forKey: key(source)) ?? [])
            if !misses.isDisjoint(with: removed) { defaults.set(Array(misses.subtracting(removed)), forKey: key(source)) }
            let values = retries(source)
            let kept = values.filter { !removed.contains($0.key) }
            if kept.count != values.count { defaults.set(kept, forKey: retryKey(source)) }
        }
    }
}
