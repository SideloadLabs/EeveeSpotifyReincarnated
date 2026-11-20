import Foundation
#if canImport(EeveeSpotifyC)
import EeveeSpotifyC
#endif

/// Provider searches run on workers. Native read callbacks use main; never wait
/// for them from main, or retain a late metadata reply as a lyrics result.
func nativeLyricsMetadata(trackId: String, timeout: TimeInterval,
                          startRequest: (() -> Void) throws -> Void = { $0() }) -> (title: String, artist: String)? {
    guard !Thread.isMainThread else { return nil }
    let result = NativeLyricsMetadataResult()
    let ready = DispatchSemaphore(value: 0)
    do {
        try startRequest {
            EeveePixieFetchLyricsMetadata("spotify:track:\(trackId)") { row in
                if let title = row?["name"] as? String, let artist = row?["artist_name"] as? String,
                   !title.isEmpty, !artist.isEmpty {
                    result.set((title, artist))
                }
                ready.signal()
            }
        }
    } catch { return nil }
    guard ready.wait(timeout: .now() + timeout) == .success else { return nil }
    return result.get()
}

private final class NativeLyricsMetadataResult {
    private let lock = NSLock()
    private var value: (title: String, artist: String)?
    func set(_ value: (title: String, artist: String)) {
        lock.lock(); self.value = value; lock.unlock()
    }
    func get() -> (title: String, artist: String)? {
        lock.lock(); defer { lock.unlock() }; return value
    }
}
