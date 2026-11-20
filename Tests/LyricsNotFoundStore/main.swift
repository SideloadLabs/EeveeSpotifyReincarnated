import Foundation
extension UserDefaults { static var container: UserDefaults { .standard } }
func check(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { fatalError(message) } }
let name = "LyricsNotFoundTests-\(UUID())", defaults = UserDefaults(suiteName: name)!
defer { defaults.removePersistentDomain(forName: name) }
defaults.set(["limited", "missing"], forKey: "EeveeLyricsProviderNotFound-5")
let store = LyricsNotFoundStore(defaults: defaults)
check(store.entries(source: 5).isEmpty, "legacy HTTP 429 entries survived migration")
store.record("genuine404", source: 5)
check(store.entries(source: 5) == ["genuine404"], "genuine miss not remembered")
let restarted = LyricsNotFoundStore(defaults: defaults)
check(restarted.entries(source: 5) == ["genuine404"], "migration cleared newly verified misses again")
restarted.succeeded("genuine404", source: 5)
check(restarted.entries(source: 5).isEmpty, "successful retry remained blacklisted")
defaults.set(2, forKey: "EeveeLyricsProviderNotFoundSchema")
defaults.set(["oldGeniusMiss"], forKey: "EeveeLyricsProviderNotFound-0")
defaults.set(["stillQueued"], forKey: "EeveeLyricsProviderNotFound-5")
defaults.set(["oldTransportError"], forKey: "EeveeLyricsProviderNotFound-1")
defaults.set(["otherProvider"], forKey: "EeveeLyricsProviderNotFound-3")
let migrated = LyricsNotFoundStore(defaults: defaults)
check(migrated.entries(source: 0).isEmpty && migrated.entries(source: 5).isEmpty, "outdated Genius or Spicy misses were not retried")
check(migrated.entries(source: 1).isEmpty, "LRCLIB transport failure remained blacklisted")
check(migrated.entries(source: 3) == ["otherProvider"], "unrelated provider misses were reset")
print("Lyrics misses: one-time legacy invalidation, persistence and success cleanup passed")
