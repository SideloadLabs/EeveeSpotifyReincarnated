import Foundation
extension UserDefaults { static var container: UserDefaults { .standard } }
func check(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { fatalError(message) } }
let name = "LyricsNotFoundTests-\(UUID())", defaults = UserDefaults(suiteName: name)!
defer { defaults.removePersistentDomain(forName: name) }
let store = LyricsNotFoundStore(defaults: defaults)
check(store.entries(source: 5).isEmpty, "a fresh install started with misses")
store.record("genuine404", source: 5)
check(store.entries(source: 5) == ["genuine404"], "genuine miss not remembered")
let restarted = LyricsNotFoundStore(defaults: defaults)
check(restarted.entries(source: 5) == ["genuine404"], "a miss did not survive a restart")
check(restarted.entries(source: 3).isEmpty, "a miss leaked to another provider")
restarted.succeeded("genuine404", source: 5)
check(restarted.entries(source: 5).isEmpty, "successful retry remained blacklisted")
print("Lyrics misses: persistence, per-provider scope and success cleanup passed")
