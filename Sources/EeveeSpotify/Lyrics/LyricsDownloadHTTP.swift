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
/// thread. Shared online repository instances remain unthrottled. Responses are
/// checked on that same worker after the URLSession callback signals its result.
enum LyricsDownloadHTTP {
    typealias RequestStart = (() -> Void) throws -> Void
    private final class Context {
        let isCancelled: () -> Bool
        let startRequest: RequestStart

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
        dictionary[key] = Context(isCancelled: isCancelled, startRequest: startRequest)
        defer { if let previous { dictionary[key] = previous } else { dictionary.removeObject(forKey: key) } }
        var attempt = 0
        while true {
            if isCancelled() { throw URLError(.cancelled) }
            do { return try body() }
            catch {
                // URLSession may cancel its own request after a connection or
                // lifecycle interruption. Only our revision/settings predicate
                // means the user actually stopped this download.
                if isCancelled() { throw URLError(.cancelled) }
                guard let transport = error as? URLError, isTransient(transport) else { throw error }
                guard attempt < 2 else { throw LyricsDownloadTransportError(underlying: transport) }
                attempt += 1
                let deadline = ProcessInfo.processInfo.systemUptime + Double(attempt) * 0.5
                while ProcessInfo.processInfo.systemUptime < deadline {
                    if isCancelled() { throw URLError(.cancelled) }
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }
        }
    }
    private static func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        case .cancelled, .networkConnectionLost, .timedOut,
             .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed: return true
        default: return false
        }
    }
    static var isDownloading: Bool { Thread.current.threadDictionary[key] is Context }

    static func waitForRetry(_ delay: TimeInterval) throws {
        guard let context = Thread.current.threadDictionary[key] as? Context else {
            Thread.sleep(forTimeInterval: delay)
            return
        }
        let deadline = ProcessInfo.processInfo.systemUptime + delay
        while true {
            if context.isCancelled() { throw URLError(.cancelled) }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 { return }
            Thread.sleep(forTimeInterval: min(remaining, 0.1))
        }
    }

    static func prepare(_ request: URLRequest) throws {
        guard let context = Thread.current.threadDictionary[key] as? Context else { return }
        try context.startRequest {}
        try LyricsRequestGate.shared.wait(for: request, isCancelled: context.isCancelled)
    }
    static func start(_ task: URLSessionTask) throws {
        guard let context = Thread.current.threadDictionary[key] as? Context else {
            task.resume()
            return
        }
        do { try context.startRequest { task.resume() } }
        catch {
            task.cancel()
            throw error
        }
    }
    static func waitForResponse(_ completion: DispatchSemaphore, task: URLSessionTask) throws {
        guard let context = Thread.current.threadDictionary[key] as? Context else {
            completion.wait()
            return
        }
        while !context.isCancelled() {
            if completion.wait(timeout: .now() + .milliseconds(100)) == .success { return }
        }
        task.cancel()
        throw URLError(.cancelled)
    }
    static func validate(_ response: URLResponse?, request: URLRequest, handlesQueuedResponse: Bool = false) throws {
        guard let context = Thread.current.threadDictionary[key] as? Context else { return }
        if context.isCancelled() { throw URLError(.cancelled) }
        guard let http = response as? HTTPURLResponse else { return }
        try LyricsRequestGate.shared.check(http, request: request)
        // A server/transport failure must not become a permanent "no lyrics".
        if handlesQueuedResponse && http.statusCode == 503 { return }
        if http.statusCode == 408 || http.statusCode >= 500 {
            throw LyricsProviderHTTPError(status: http.statusCode)
        }
    }
}
