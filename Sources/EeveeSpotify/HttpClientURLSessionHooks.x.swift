import Foundation
import Orion

// Sibling delegate to SPTDataLoaderService. Some regions (e.g. gae2) ship
// bootstrap / customize / PAM responses through this delegate instead — without
// hooking both, server-rendered free-tier strings slip through.
class HttpClientURLSessionHook: ClassHook<NSObject>, SpotifySessionDelegate {
    typealias Group = PremiumBootstrapGroup
    static let targetName = "Connectivity_HttpClientKit.HttpClientURLSession"

    func URLSession(
        _ session: URLSession,
        task: URLSessionDataTask,
        didCompleteWithError error: Error?
    ) {
        if let request = task.currentRequest,
           let headers = request.allHTTPHeaderFields,
           let auth = headers["Authorization"] ?? headers["authorization"],
           auth.hasPrefix("Bearer ") {
            spotifyAccessToken = String(auth.dropFirst(7))
        }

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

        if SpotifyResponsePatcher.handledCustomizeTasks.remove(task.taskIdentifier) != nil {
            orig.URLSession(session, task: task, didCompleteWithError: nil)
            URLSessionHelper.shared.discardData(for: task)
            return
        }

        // Error / non-patch path — the buffer is not consumed below, so drop
        // it explicitly. The previous version leaked one entry per failed
        // or non-patched task; over a long session the helper map grew to
        // the point where its `ObjectIdentifier` keys started colliding
        // with newly-allocated task addresses — a use-after-free waiting to
        // happen the moment a URLSession delegate callback ran on a stale
        // entry.
        guard error == nil, SpotifyResponsePatcher.shouldModify(url) else {
            URLSessionHelper.shared.discardData(for: task)
            orig.URLSession(session, task: task, didCompleteWithError: error)
            return
        }

        guard let buffer = URLSessionHelper.shared.obtainData(for: task) else {
            // We decided this URL should be modified, but we never captured any body bytes.
            // This can happen with 0-byte responses, early completion, redirects, or concurrent callbacks.
            // IMPORTANT: Always forward completion, otherwise Spotify may hang and get watchdog-killed.
            if url.isCustomize, let cached = SpotifyResponsePatcher.cachedCustomizeData {
                orig.URLSession(session, dataTask: task, didReceiveData: cached)
                orig.URLSession(session, task: task, didCompleteWithError: nil)
            } else {
                writeDebugLog("[HCUS] Missing buffered body for \(url.absoluteString) (taskId=\(task.taskIdentifier))")
                orig.URLSession(session, task: task, didCompleteWithError: error)
            }
            return
        }

        do {
            // Lyrics — body was pre-fetched in didReceiveResponse (see
            // `LyricsPrefetch`). Replaces the old in-line semaphore.wait
            // that used to block this delegate thread for up to 5s.
            if url.isLyrics {
                let customLyricsData = LyricsPrefetch.pop(task)
                orig.URLSession(session, dataTask: task, didReceiveData: customLyricsData ?? buffer)
                orig.URLSession(session, task: task, didCompleteWithError: nil)
                return
            }

            if let result = try SpotifyResponsePatcher.patch(url: url, buffer: buffer) {
                writeDebugLog("[HCUS] Patched \(result.tag.rawValue)")
                orig.URLSession(session, dataTask: task, didReceiveData: result.data)
                orig.URLSession(session, task: task, didCompleteWithError: nil)
                return
            }
            // patch() returned nil — no transform, but didReceiveData already
            // suppressed the original. Replay or consumer hangs.
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
        if let url = task.currentRequest?.url, url.isCustomize, response.statusCode == 304,
           let cached = SpotifyResponsePatcher.cachedCustomizeData {
            let synthetic = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "2.0", headerFields: [:])!
            orig.URLSession(session, dataTask: task, didReceiveResponse: synthetic, completionHandler: handler)
            orig.URLSession(session, dataTask: task, didReceiveData: cached)
            SpotifyResponsePatcher.handledCustomizeTasks.insert(task.taskIdentifier)
            return
        }

        // Lyrics — kick off the async custom-lyrics fetch NOW so the body
        // is ready by didCompleteWithError. This replaces the old in-line
        // `semaphore.wait` in didCompleteWithError, which blocked the
        // URLSession delegate thread for up to 5 seconds and was a
        // documented contributor to the "use-after-free in
        // didCompleteWithError" crash signature.
        //
        // For 4xx/5xx we also synthesise a 200 response — the original
        // behaviour (and the only way the downstream parser will accept
        // the custom body it never asked for).
        if let url = task.currentRequest?.url, url.isLyrics {
            if response.statusCode != 200 {
                let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "2.0", headerFields: [:])!
                orig.URLSession(session, dataTask: task, didReceiveResponse: ok, completionHandler: handler)
            } else {
                orig.URLSession(session, dataTask: task, didReceiveResponse: response, completionHandler: handler)
            }
            LyricsPrefetch.start(task: task, path: url.path)
            return
        }

        orig.URLSession(session, dataTask: task, didReceiveResponse: response, completionHandler: handler)
    }

    func URLSession(
        _ session: URLSession,
        dataTask task: URLSessionDataTask,
        didReceiveData data: Data
    ) {
        guard let url = task.currentRequest?.url else { return }
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