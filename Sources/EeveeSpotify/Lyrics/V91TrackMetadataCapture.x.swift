import Orion
import UIKit
import MediaPlayer

private let metadataLock = NSLock()
private var cachedMetadata: (id: String, title: String, artist: String)?

func metadataForPlayback(_ id: String) -> (String, String)? {
    metadataLock.lock(); defer { metadataLock.unlock() }
    guard let cachedMetadata, cachedMetadata.id == id else { return nil }
    return (cachedMetadata.title, cachedMetadata.artist)
}

func rememberPlaybackMetadata(_ id: String, _ title: String?, _ artist: String?) {
    guard let title, !title.isEmpty, let artist, !artist.isEmpty else { return }
    metadataLock.lock(); defer { metadataLock.unlock() }
    cachedMetadata = (id, title, artist)
}

// Function to fetch track details using Spotify API if we have a token
func fetchTrackDetails(trackId: String, token: String,
                       startRequest: (() -> Void) throws -> Void = { $0() }) throws -> (title: String, artist: String)? {
    let urlString = "https://api.spotify.com/v1/tracks/\(trackId)"
    guard let url = URL(string: urlString) else { return nil }
    
    var request = URLRequest(url: url)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 3.0
    
    var result: (String, String)?
    var transportError: Error?
    let semaphore = DispatchSemaphore(value: 0)
    
    let task = URLSession.shared.dataTask(with: request) { data, response, error in
        defer { semaphore.signal() }
        
        if let error { transportError = error; return }
        guard let data else { return }
        
        // Simple JSON parsing
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let name = json["name"] as? String,
           let artists = json["artists"] as? [[String: Any]],
           let firstArtist = artists.first,
           let artistName = firstArtist["name"] as? String {
            result = (name, artistName)
        }
    }
    
    do { try startRequest { task.resume() } }
    catch {
        task.cancel()
        throw error
    }
    guard semaphore.wait(timeout: .now() + 3.0) == .success else {
        task.cancel()
        return nil
    }
    
    if let transportError = transportError as? URLError, transportError.code == .notConnectedToInternet { throw transportError }
    return result
}
