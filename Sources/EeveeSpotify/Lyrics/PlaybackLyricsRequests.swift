import Foundation

private let playbackLock = NSLock()
private var playbackState = LyricsLoadingState()
var lyricsState: LyricsLoadingState {
    playbackLock.lock(); defer { playbackLock.unlock() }
    return playbackState
}

final class PlaybackRequest {
    let track: String
    let source: LyricsSource
    let options: LyricsOptions
    fileprivate let task = LyricsTaskState()
    fileprivate var consumed = false
    fileprivate var invalidated = false
    fileprivate var finished = false

    init(_ track: String, _ source: LyricsSource, _ options: LyricsOptions) {
        self.track = track
        self.source = source
        self.options = options
    }
}
private var latestRequest: PlaybackRequest?
private var inFlight: [String: PlaybackRequest] = [:]

func publishPlaybackLyrics(_ request: PlaybackRequest, state: LyricsLoadingState, karaoke: KaraokeLyricsDto?) {
    playbackLock.lock()
    if inFlight[request.track] === request && UserDefaults.lyricsSource == request.source
        && UserDefaults.lyricsOptions.downloadOptions == request.options {
        if latestRequest === request { playbackState = state }
        if let karaoke { KaraokeLyricsStore.shared.set(trackId: request.track, lyrics: karaoke) }
        else { KaraokeLyricsStore.shared.remove(trackId: request.track) }
    }
    playbackLock.unlock()
}

func invalidateLyricsForSourceChange() {
    playbackLock.lock()
    latestRequest?.invalidated = true
    for request in inFlight.values { request.invalidated = true }
    inFlight.removeAll()
    latestRequest = nil
    playbackState = LyricsLoadingState()
    KaraokeLyricsStore.shared.clear()
    playbackLock.unlock()
}

func requestPlaybackLyrics(_ track: String, prefetch: Bool, fetch: @escaping (PlaybackRequest) throws -> Data,
                           completion: @escaping (Result<Data, Error>) -> Void) {
    let source = UserDefaults.lyricsSource
    let options = UserDefaults.lyricsOptions.downloadOptions
    playbackLock.lock()
    let request: PlaybackRequest
    if let current = inFlight[track] ?? latestRequest, current.track == track, current.source == source, current.options == options {
        request = current
    } else {
        request = PlaybackRequest(track, source, options)
        inFlight[track]?.invalidated = true
        inFlight[track] = request
        playbackState = LyricsLoadingState()
        KaraokeLyricsStore.shared.remove(trackId: track)
    }
    latestRequest = request
    if !prefetch {
        request.consumed = true
        if request.finished { latestRequest = nil }
    }
    playbackLock.unlock()

    request.task.load({ try fetch(request) }) { result in
        playbackLock.lock()
        request.finished = true
        if inFlight[track] === request { inFlight[track] = nil }
        if latestRequest === request {
            if case .failure = result { latestRequest = nil }
            else if request.consumed { latestRequest = nil }
        }
        let valid = !request.invalidated
        playbackLock.unlock()
        guard valid, UserDefaults.lyricsSource == source, UserDefaults.lyricsOptions.downloadOptions == options else {
            completion(.failure(URLError(.cancelled)))
            return
        }
        completion(result)
    }
}
