import Foundation

struct LyricsProviderHTTPError: Error, CustomStringConvertible {
    let status: Int
    var description: String { "Lyrics provider returned HTTP \(status); not a missing song" }
}

struct LyricsDownloadTransportError: Error, CustomStringConvertible {
    let underlying: URLError
    var description: String { "Lyrics download transport failed after 3 attempts: \(underlying)" }
}

/// A synchronous repository call carries its download policy on its worker
/// thread. Providers call `start` and `wait` in place of `resume()` and
/// `semaphore.wait()`; outside a download both do exactly what they replace.
enum LyricsDownloadHTTP {
    typealias RequestStart = (() -> Void) throws -> Void
    private final class Context {
        let isCancelled: () -> Bool
        let startRequest: RequestStart
        /// The custom view's lyrics a provider made in this download (see `downloadedKaraoke`).
        var karaoke: KaraokeLyricsDto?

        init(isCancelled: @escaping () -> Bool, startRequest: @escaping RequestStart) {
            self.isCancelled = isCancelled
            self.startRequest = startRequest
        }
    }
    private static let key = "EeveeSpotify.lyricsDownloadHTTP"
    static func perform<T>(isCancelled: @escaping () -> Bool, startRequest: @escaping RequestStart = { $0() },
                           _ body: () throws -> T) throws -> T {
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[key]
        let context = Context(isCancelled: isCancelled, startRequest: startRequest)
        dictionary[key] = context
        defer { if let previous { dictionary[key] = previous } else { dictionary.removeObject(forKey: key) } }
        var attempt = 0
        while true {
            if isCancelled() { throw URLError(.cancelled) }
            // A retry starts without the previous attempt's lyrics.
            context.karaoke = nil
            do { return try body() }
            catch {
                // URLSession may cancel its own request after a connection or
                // lifecycle interruption. Only our revision/settings predicate
                // means the user actually stopped this download.
                if isCancelled() { throw URLError(.cancelled) }
                guard let transport = error as? URLError, isTransient(transport) else { throw error }
                guard attempt < 2 else { throw LyricsDownloadTransportError(underlying: transport) }
                attempt += 1
                try LyricsRequestGate.shared.sleep(until: LyricsRequestGate.uptime + Double(attempt) * 0.5,
                                                   isCancelled: isCancelled)
            }
        }
    }
    private static func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        // Not a timeout: a provider that did not answer in time is asked again tomorrow
        // rather than holding the one-at-a-time queue for several more deadlines.
        case .cancelled, .networkConnectionLost,
             .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed: return true
        default: return false
        }
    }
    static var isDownloading: Bool { Thread.current.threadDictionary[key] is Context }

    /// Word timing a provider produced during a download. It goes into the saved file,
    /// never into the playback store. Always nil outside a download.
    static var downloadedKaraoke: KaraokeLyricsDto? {
        get { (Thread.current.threadDictionary[key] as? Context)?.karaoke }
        set { (Thread.current.threadDictionary[key] as? Context)?.karaoke = newValue }
    }

    /// A provider's `task.resume()`. Outside a download it is exactly that. In a
    /// download it first waits for the host's pacing, the foreground and the network.
    static func start(_ task: URLSessionTask) throws {
        guard let context = Thread.current.threadDictionary[key] as? Context else {
            // Playback or prefetch: downloads wait until it ends (see wait below).
            LyricsRequestGate.shared.playbackStarted()
            task.resume()
            return
        }
        do {
            if let request = task.originalRequest {
                try LyricsRequestGate.shared.wait(for: request, isCancelled: context.isCancelled)
            }
            try context.startRequest { task.resume() }
        } catch {
            task.cancel()
            throw error
        }
    }

    /// A provider's `semaphore.wait()`. Outside a download it is exactly that. In a
    /// download it stops when the download is no longer wanted, and statuses the
    /// provider does not read itself (429, 5xx, ...) become typed errors, so they
    /// are retried later instead of being taken for a missing song.
    static func wait(_ completion: DispatchSemaphore, task: URLSessionTask, accepting statuses: Set<Int> = []) throws {
        guard let context = Thread.current.threadDictionary[key] as? Context else {
            completion.wait()
            LyricsRequestGate.shared.playbackFinished(task.response as? HTTPURLResponse, request: task.originalRequest)
            return
        }
        try LyricsRequestGate.shared.waitForRequest(task, finished: completion, isCancelled: context.isCancelled)
        guard task.error == nil, let request = task.originalRequest else { return }
        try validate(task.response, request: request, accepting: statuses)
    }

    static func validate(_ response: URLResponse?, request: URLRequest,
                         accepting statuses: Set<Int> = []) throws {
        guard let context = Thread.current.threadDictionary[key] as? Context else { return }
        if context.isCancelled() { throw URLError(.cancelled) }
        guard let http = response as? HTTPURLResponse else { return }
        try LyricsRequestGate.shared.check(http, request: request)
        guard (200..<300).contains(http.statusCode) || statuses.contains(http.statusCode) else {
            throw LyricsProviderHTTPError(status: http.statusCode)
        }
    }
}
