import Foundation
#if canImport(EeveeSpotifyC)
import EeveeSpotifyC
#endif

/// Outcome of Spotify's native track metadata lookup.
enum NativeLyricsMetadataLookup {
    case found(title: String, artist: String)
    /// Spotify answered, but this ID has no usable title/artist: a definite miss.
    case missing
    /// No answer (no companion, service error, deadline): may succeed later.
    case unavailable

    var metadata: (title: String, artist: String)? {
        if case .found(let title, let artist) = self { return (title, artist) }
        return nil
    }
}

/// Provider searches run on workers. Native read callbacks use main; never wait
/// for them from main, or retain a late metadata reply as a lyrics result.
func nativeLyricsMetadata(trackId: String, timeout: TimeInterval,
                          startRequest: (() -> Void) throws -> Void = { $0() }) -> NativeLyricsMetadataLookup {
    guard !Thread.isMainThread else { return .unavailable }
    let result = NativeLyricsMetadataResult()
    let ready = DispatchSemaphore(value: 0)
    do {
        try startRequest {
            EeveePixieFetchLyricsMetadata("spotify:track:\(trackId)") { row in
                if let title = row?["name"] as? String, let artist = row?["artist_name"] as? String,
                   !title.isEmpty, !artist.isEmpty {
                    result.set(.found(title: title, artist: artist))
                } else if row?["unavailable"] as? Bool != true {
                    result.set(.missing)
                }
                ready.signal()
            }
        }
    } catch { return .unavailable }
    guard ready.wait(timeout: .now() + timeout) == .success else { return .unavailable }
    return result.get()
}

private final class NativeLyricsMetadataResult {
    private let lock = NSLock()
    private var value = NativeLyricsMetadataLookup.unavailable
    func set(_ value: NativeLyricsMetadataLookup) {
        lock.lock(); self.value = value; lock.unlock()
    }
    func get() -> NativeLyricsMetadataLookup {
        lock.lock(); defer { lock.unlock() }; return value
    }
}
