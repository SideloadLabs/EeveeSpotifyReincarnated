import Foundation

/// A non-200 Spotify response may need a provider fetch before its headers can
/// be replaced. Save that result, but let the real completion deliver the body.
/// Sending data/completion here as well caused a second fetch and completion.
func prepareEeveeLyricsResponse(task: URLSessionDataTask, response: HTTPURLResponse,
                               reply: @escaping (HTTPURLResponse) -> Void) -> Bool {
    guard let url = task.currentRequest?.url, url.isLyrics, response.statusCode != 200,
          UserDefaults.lyricsSource.isReplacingLyrics else { return false }
    LyricsTaskState.forTask(task).load({ try eeveeLyricsData(url.path) }) { result in
        DispatchQueue.main.async {
            switch result {
            case .success:
                reply(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "2.0", headerFields: [:]) ?? response)
            case .failure(let error):
                if url.path.contains("/download/"), !(200..<300).contains(response.statusCode),
                   let id = extractTrackId(from: url.path) {
                    // A marker protects the audio download while external lyrics
                    // are unavailable. It is not a provider "not found" entry.
                    NativeOfflineLyrics.shared.markNoLyrics(trackId: id,
                        reason: "Spotify \(response.statusCode), external lyrics unavailable: \(error)")
                }
                reply(response)
            }
        }
    }
    return true
}

/// Each delegate may relay one completion down its native chain. Both relays
/// share the same fetch result; a second completion for that delegate is ignored.
func finishEeveeLyricsTask(task: URLSessionTask, delegate: String, error: Error?,
                          deliver: @escaping (HTTPURLResponse?, Data?, Error?) -> Void) -> Bool {
    guard let url = task.currentRequest?.url, url.isLyrics else { return false }
    if !UserDefaults.lyricsSource.isReplacingLyrics {
        // The delegate may have buffered bytes before the user selected Spotify.
        guard let data = URLSessionHelper.shared.obtainData(for: task) else { return false }
        DispatchQueue.main.async { deliver(nil, data, error) }
        return true
    }
    let state = LyricsTaskState.forTask(task)
    guard state.claimCompletion(delegate: delegate) else { return true }
    let buffer = URLSessionHelper.shared.obtainData(for: task)
    func publish(_ response: HTTPURLResponse?, _ data: Data?, _ error: Error?) {
        DispatchQueue.main.async { deliver(response, data, error) }
    }
    if (error as? URLError)?.code == .cancelled { publish(nil, nil, error); return true }
    if let error, !state.hasStarted {
        state.load({
            guard let id = extractTrackId(from: url.path),
                  let lyrics = cachedOfflineLyrics(trackId: id, offline: true) else { throw error }
            if !url.path.contains("/download/") { KaraokePlaybackTracker.shared.updateTrackIdFromLyricsFetch(id) }
            return try lyrics.serializedData()
        }) { result in
            switch result {
            case .success(let data):
                publish(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "2.0", headerFields: [:]), data, nil)
            case .failure: publish(nil, buffer, error)
            }
        }
        return true
    }
    state.load({
        if let error { throw error }
        return try eeveeLyricsData(url.path, originalLyrics: buffer.flatMap { try? Lyrics(serializedBytes: $0) })
    }) { result in
        switch result {
        case .success(let data): publish(nil, data, nil)
        case .failure: publish(nil, error == nil ? buffer ?? Data() : buffer, error)
        }
    }
    return true
}
