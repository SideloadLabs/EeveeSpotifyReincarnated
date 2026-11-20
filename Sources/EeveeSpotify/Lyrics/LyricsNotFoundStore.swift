import Foundation

/// Only definitive provider misses belong here. Legacy entries could include
/// HTTP 429, so invalidate them once; the saved lyric files are unaffected.
final class LyricsNotFoundStore {
    static let shared = LyricsNotFoundStore(defaults: UserDefaults.container)
    private let defaults: UserDefaults
    private let lock = NSLock()
    private let schemaKey = "EeveeLyricsProviderNotFoundSchema"
    init(defaults: UserDefaults) {
        self.defaults = defaults
        let schema = defaults.integer(forKey: schemaKey)
        if schema < 3 {
            // Retry Genius misses now that ID lookup is available. Older Spicy
            // misses may also include responses where lyrics were still queued.
            for source in schema == 2 ? [0, 5] : [0, 1, 3, 5] {
                defaults.removeObject(forKey: key(source))
            }
        }
        if schema < 4 {
            // LRCLIB used to turn transport and decoding errors into permanent misses.
            defaults.removeObject(forKey: key(1))
            defaults.set(4, forKey: schemaKey)
        }
    }
    private func key(_ source: Int) -> String { "EeveeLyricsProviderNotFound-\(source)" }
    func resetForLookupOptionsChange() {
        lock.lock(); defer { lock.unlock() }
        for source in [0, 1, 3, 5] { defaults.removeObject(forKey: key(source)) }
    }
    func entries(source: Int) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(defaults.stringArray(forKey: key(source)) ?? [])
    }
    func record(_ id: String, source: Int) {
        lock.lock(); defer { lock.unlock() }
        var ids = Set(defaults.stringArray(forKey: key(source)) ?? [])
        if ids.insert(id).inserted { defaults.set(ids.sorted(), forKey: key(source)) }
    }
    func succeeded(_ id: String, source: Int) {
        lock.lock(); defer { lock.unlock() }
        var ids = Set(defaults.stringArray(forKey: key(source)) ?? [])
        if ids.remove(id) != nil { defaults.set(ids.sorted(), forKey: key(source)) }
    }
}
