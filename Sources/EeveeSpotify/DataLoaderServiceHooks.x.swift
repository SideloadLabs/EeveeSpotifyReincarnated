import Foundation
import Orion

// Written from concurrent URLSession delegate queues; unguarded access crashed on release.
private let accessTokenLock = NSLock()
private var storedAccessToken: String?

var spotifyAccessToken: String? {
    accessTokenLock.lock(); defer { accessTokenLock.unlock() }; return storedAccessToken
}

func captureAccessToken(from request: URLRequest?, session: URLSession? = nil) {
    // The Pixie companion reads these already-observed headers for its offline device manager.
    SpriteAuthentication.capture(request, session: session)
    guard let auth = request?.value(forHTTPHeaderField: "Authorization"), auth.hasPrefix("Bearer ") else { return }
    let token = String(auth.dropFirst(7))
    accessTokenLock.lock()
    let first = storedAccessToken == nil
    if storedAccessToken != token { storedAccessToken = token }
    accessTokenLock.unlock()
    if first {
        eeveeLog("[EeveeSpotify][TokenCapture] First token, len %d from %@%@", token.count, request?.url?.host ?? "?", request?.url?.path ?? "")
    }
}

// Spotify's primary URLSession delegate; patching is shared with HttpClientURLSessionHook via SpotifyResponsePatcher.

class SPTDataLoaderServiceHook: ClassHook<NSObject>, SpotifySessionDelegate {
    typealias Group = PremiumBootstrapGroup
    static let targetName = "SPTDataLoaderService"

    func URLSession(
        _ session: URLSession,
        task: URLSessionDataTask,
        didCompleteWithError error: Error?
    ) {
        captureAccessToken(from: task.currentRequest, session: session)

        guard let url = task.currentRequest?.url else {
            orig.URLSession(session, task: task, didCompleteWithError: error)
            return
        }

        if CasitaResponseProbe.shouldProbe(url) {
            CasitaResponseProbe.flush(task, url: url)
        }

        if SpotifyResponsePatcher.shouldBlock(url) {
            orig.URLSession(session, dataTask: task, didReceiveData: SpotifyResponsePatcher.blockedResponseData(for: url))
            orig.URLSession(session, task: task, didCompleteWithError: nil)
            return
        }

        // 304 already served — suppress the second completion.
        if SpotifyResponsePatcher.consumeCustomizeTask(task.taskIdentifier) {
            orig.URLSession(session, task: task, didCompleteWithError: nil)
            return
        }

        guard error == nil, SpotifyResponsePatcher.shouldModify(url) else {
            orig.URLSession(session, task: task, didCompleteWithError: error)
            return
        }

        guard let buffer = URLSessionHelper.shared.obtainData(for: task) else {
            // Customize 304 has no body; a fresh process falls back to the persisted patched copy.
            if url.isCustomize, let cached = SpotifyResponsePatcher.cachedCustomizeData
                ?? UserDefaults.cachedCustomizeData {
                orig.URLSession(session, dataTask: task, didReceiveData: cached)
                orig.URLSession(session, task: task, didCompleteWithError: nil)
            } else {
                // Consumers crash on completion without a prior didReceiveData.
                writeDebugLog("[DL] Missing buffered body for \(url.absoluteString) (taskId=\(task.taskIdentifier))")
                orig.URLSession(session, dataTask: task, didReceiveData: Data())
                orig.URLSession(session, task: task, didCompleteWithError: error)
            }
            return
        }

        do {
            // Since 9.1.60 the lyrics consumer is @MainActor; calling orig off-main traps.
            if url.isLyrics {
                let originalLyrics = try? Lyrics(serializedBytes: buffer)

                let semaphore = DispatchSemaphore(value: 0)
                var customLyricsData: Data?

                DispatchQueue.global(qos: .userInitiated).async {
                    customLyricsData = try? getLyricsDataForCurrentTrack(url.path, originalLyrics: originalLyrics)
                    semaphore.signal()
                }

                _ = semaphore.wait(timeout: .now() + .milliseconds(18000))
                let lyricsPayload = customLyricsData ?? buffer
                DispatchQueue.main.async { [self] in
                    orig.URLSession(session, dataTask: task, didReceiveData: lyricsPayload)
                    orig.URLSession(session, task: task, didCompleteWithError: nil)
                }
                return
            }

            if let result = try SpotifyResponsePatcher.patch(url: url, buffer: buffer) {
                writeDebugLog("[DL] Patched \(result.tag.rawValue)")
                orig.URLSession(session, dataTask: task, didReceiveData: result.data)
                orig.URLSession(session, task: task, didCompleteWithError: nil)
                return
            }
            // didReceiveData already swallowed the original, so replay it or the consumer hangs.
            orig.URLSession(session, dataTask: task, didReceiveData: buffer)
            orig.URLSession(session, task: task, didCompleteWithError: nil)
        } catch {
            orig.URLSession(session, task: task, didCompleteWithError: error)
        }
    }

    func URLSession(
        _ session: URLSession,
        dataTask task: URLSessionDataTask,
        didReceiveResponse response: HTTPURLResponse,
        completionHandler handler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let url = task.currentRequest?.url, url.isCustomize, response.statusCode == 304 {
            // A 304 would make Spotify use its unpatched disk-cached config, so replay ours as a 200.
            if let cached = SpotifyResponsePatcher.cachedCustomizeData
                ?? UserDefaults.cachedCustomizeData,
               let synthetic = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "2.0", headerFields: [:]) {
                orig.URLSession(session, dataTask: task, didReceiveResponse: synthetic, completionHandler: handler)
                orig.URLSession(session, dataTask: task, didReceiveData: cached)
                SpotifyResponsePatcher.markCustomizeTaskHandled(task.taskIdentifier)
                return
            }
            orig.URLSession(session, dataTask: task, didReceiveResponse: response, completionHandler: handler)
            return
        }

        // Fetching on this delegate queue deadlocks; the held completion handler keeps the task waiting.
        guard let url = task.currentRequest?.url, url.isLyrics, response.statusCode != 200 else {
            orig.URLSession(session, dataTask: task, didReceiveResponse: response, completionHandler: handler)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let data = try? getLyricsDataForCurrentTrack(url.path)

            guard let lyricsData = data,
                  let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "2.0", headerFields: [:]) else {
                handler(.allow)
                orig.URLSession(session, dataTask: task, didReceiveResponse: response, completionHandler: { _ in })
                return
            }

            DispatchQueue.main.async { [self] in
                orig.URLSession(session, dataTask: task, didReceiveResponse: ok, completionHandler: handler)
                orig.URLSession(session, dataTask: task, didReceiveData: lyricsData)
                orig.URLSession(session, task: task, didCompleteWithError: nil)
            }
        }
    }

    func URLSession(
        _ session: URLSession,
        dataTask task: URLSessionDataTask,
        didReceiveData data: Data
    ) {
        guard let url = task.currentRequest?.url else { return }

        // Replaced in didCompleteWithError; passing it through would deliver both.
        if SpotifyResponsePatcher.shouldBlock(url) { return }
        if CasitaResponseProbe.shouldProbe(url) {
            CasitaResponseProbe.append(data, for: task)
        }
        if SpotifyResponsePatcher.shouldModify(url) {
            URLSessionHelper.shared.setOrAppend(data, for: task)
            return
        }
        orig.URLSession(session, dataTask: task, didReceiveData: data)
    }
}
