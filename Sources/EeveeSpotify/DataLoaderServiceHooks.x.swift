import Foundation
import Orion

// Captured Bearer token from any premium-relevant request — surfaced to
// other modules (lyrics fetch, etc) that need to talk to Spotify's API.
public var spotifyAccessToken: String?

// Hooks SPTDataLoaderService — Spotify's primary URLSession delegate for
// wg-spclient.spotify.com traffic (first-fresh-login bootstrap, customize,
// PAM endpoints).
//
// Patching logic lives in `SpotifyResponsePatcher` so the regional-route
// hook (`HttpClientURLSessionHook`) can share it.

class SPTDataLoaderServiceHook: ClassHook<NSObject>, SpotifySessionDelegate {
    typealias Group = PremiumBootstrapGroup
    static let targetName = "SPTDataLoaderService"

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

        // 304 already served — suppress the second completion.
        if SpotifyResponsePatcher.handledCustomizeTasks.remove(task.taskIdentifier) != nil {
            orig.URLSession(session, task: task, didCompleteWithError: nil)
            // 304 path never stored a buffer, but be defensive in case
            // `didReceiveData` was somehow invoked before the 304 branch.
            URLSessionHelper.shared.discardData(for: task)
            return
        }

        // Error path: the buffer (if any) is not going to be consumed below,
        // so drop it explicitly to keep the NSMapTable from accumulating
        // entries for every failed/redirected task across a long session.
        guard error == nil, SpotifyResponsePatcher.shouldModify(url) else {
            URLSessionHelper.shared.discardData(for: task)
            orig.URLSession(session, task: task, didCompleteWithError: error)
            return
        }

        guard let buffer = URLSessionHelper.shared.obtainData(for: task) else {
            // Customize 304 fallback — wg-spclient returned 304, no buffer
            // to patch, but we have a cached body from a prior 200.
            if url.isCustomize, let cached = SpotifyResponsePatcher.cachedCustomizeData {
                orig.URLSession(session, dataTask: task, didReceiveData: cached)
                orig.URLSession(session, task: task, didCompleteWithError: nil)
            } else {
                writeDebugLog("[DL] Missing buffered body for \(url.absoluteString) (taskId=\(task.taskIdentifier))")
                // Always forward completion; otherwise Spotify may hang and get watchdog-killed.
                orig.URLSession(session, task: task, didCompleteWithError: error)
            }
            return
        }

        do {
            // Lyrics — body was already pre-fetched in `didReceiveResponse`
            // and stashed in `prefetchedLyricsData` on the task, so we can
            // forward synchronously without blocking the delegate thread on
            // a 5s semaphore (which used to keep the URLSession delegate
            // queue wedged and is a known contributor to the
            // "use-after-free in didCompleteWithError" crash signature).
            if url.isLyrics {
                let customLyricsData = LyricsPrefetch.pop(task)
                orig.URLSession(session, dataTask: task, didReceiveData: customLyricsData ?? buffer)
                orig.URLSession(session, task: task, didCompleteWithError: nil)
                return
            }

            if let result = try SpotifyResponsePatcher.patch(url: url, buffer: buffer) {
                writeDebugLog("[DL] Patched \(result.tag.rawValue)")
                orig.URLSession(session, dataTask: task, didReceiveData: result.data)
                orig.URLSession(session, task: task, didCompleteWithError: nil)
                return
            }
            // patch() returned nil — no transform happened, but didReceiveData
            // already suppressed the original. Replay the buffer or the
            // consumer hangs forever (casita/browsita with no ad sections).
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
            // Server says "not modified" — but our cached copy is the
            // already-patched body, not whatever the server has. Replace
            // the response status with 200 so the consumer accepts the
            // cached data we hand it next.
            let synthetic = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "2.0", headerFields: [:])!
            orig.URLSession(session, dataTask: task, didReceiveResponse: synthetic, completionHandler: handler)
            orig.URLSession(session, dataTask: task, didReceiveData: cached)
            SpotifyResponsePatcher.handledCustomizeTasks.insert(task.taskIdentifier)
            return
        }

        // Lyrics — kick off the async custom-lyrics fetch NOW (in
        // didReceiveResponse) so the body is ready by the time
        // didCompleteWithError fires. This replaces the old in-line
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

        // Suppress original data for endpoints we'll replace in
        // didCompleteWithError — otherwise the consumer sees both.
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