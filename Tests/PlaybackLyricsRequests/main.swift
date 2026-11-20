import Foundation

enum LyricsSource { case first, second }
struct LyricsOptions: Equatable { var downloadOptions: Self { self } }
extension UserDefaults { static var lyricsSource = LyricsSource.first; static let lyricsOptions = LyricsOptions() }
struct LyricsLoadingState { var loaded = false }
struct KaraokeLyricsDto { let value: String }
final class KaraokeLyricsStore {
    static let shared = KaraokeLyricsStore()
    var values: [String: String] = [:]
    func clear() { values.removeAll() }
    func remove(trackId: String) { values.removeValue(forKey: trackId) }
    func set(trackId: String, lyrics: KaraokeLyricsDto) { values[trackId] = lyrics.value }
}
let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
let group = DispatchGroup()
func start(_ track: String, prefetch: Bool, expected: String) {
    group.enter()
    requestPlaybackLyrics(track, prefetch: prefetch, fetch: { request in
        started.signal()
        precondition(release.wait(timeout: .now() + 3) == .success)
        publishPlaybackLyrics(request, state: LyricsLoadingState(loaded: true), karaoke: KaraokeLyricsDto(value: track))
        return Data(track.utf8)
    }) { result in
        switch result {
        case .success(let bytes): precondition(String(data: bytes, encoding: .utf8) == expected)
        case .failure(let error): precondition(expected == "cancelled" && (error as? URLError)?.code == .cancelled)
        }
        group.leave()
    }
}
start("A", prefetch: true, expected: "A")
start("B", prefetch: true, expected: "B")
start("A", prefetch: false, expected: "A")
for _ in 0..<2 { precondition(started.wait(timeout: .now() + 2) == .success); release.signal() }
precondition(group.wait(timeout: .now() + 2) == .success)
precondition(started.wait(timeout: .now()) == .timedOut)
precondition(KaraokeLyricsStore.shared.values == ["A": "A", "B": "B"])
start("old", prefetch: true, expected: "cancelled")
precondition(started.wait(timeout: .now() + 2) == .success)
invalidateLyricsForSourceChange()
release.signal()
precondition(group.wait(timeout: .now() + 2) == .success && KaraokeLyricsStore.shared.values.isEmpty)
print("Playback joins interleaved prefetches, delivers each completion and rejects invalidated karaoke")
