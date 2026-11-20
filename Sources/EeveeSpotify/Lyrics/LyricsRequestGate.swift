import Foundation

struct LyricsRequestLimitError: Error, CustomStringConvertible {
    var description: String { "Lyrics provider rate limit; waiting before the next request" }
}

/// Paces background lyrics downloads only. Playback and prefetch go straight to the
/// provider exactly as upstream does; this gate never sits in front of them.
final class LyricsRequestGate {
    static let shared = LyricsRequestGate()
    private let lock = NSLock()
    private var next: [String: TimeInterval] = [:]
    private var blockedUntil: [String: TimeInterval] = [:]
    let minimumInterval: TimeInterval = 0.5

    private func host(_ request: URLRequest) -> String {
        (request.value(forHTTPHeaderField: "Host") ?? request.url?.host ?? "lyrics").lowercased()
    }
    func reserve(host: String, now: TimeInterval) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        let start = max(now, next[host, default: 0], blockedUntil[host, default: 0])
        next[host] = start + minimumInterval
        return start
    }
    func wait(for request: URLRequest, isCancelled: () -> Bool) throws {
        try wait(key: host(request), isCancelled: isCancelled)
    }
    func wait(for request: URLRequest) { wait(key: host(request)) }
    /// One slot per provider key (minimumInterval apart).
    func wait(key: String) {
        try? wait(key: key, isCancelled: { false })
    }
    func wait(key: String, isCancelled: () -> Bool) throws {
        var slot = reserve(host: key, now: ProcessInfo.processInfo.systemUptime)
        while true {
            if isCancelled() { throw URLError(.cancelled) }
            lock.lock()
            // Requests already waiting when a 429 arrives must receive distinct
            // slots after the new deadline, rather than all waking together.
            let blocked = blockedUntil[key, default: 0]
            if slot < blocked {
                slot = max(blocked, next[key, default: 0])
                next[key] = slot + minimumInterval
            }
            lock.unlock()
            let delay = slot - ProcessInfo.processInfo.systemUptime
            if delay <= 0 { return }
            Thread.sleep(forTimeInterval: min(delay, 0.25))
        }
    }
    static func retryDelay(_ value: String?, now: Date) -> TimeInterval {
        if let value, let seconds = TimeInterval(value) { return max(1, seconds) }
        if let value {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let date = formatter.date(from: value) { return max(1, date.timeIntervalSince(now)) }
        }
        return 30
    }
    func check(_ response: HTTPURLResponse?, request: URLRequest) throws {
        guard response?.statusCode == 429 else { return }
        let delay = Self.retryDelay(response?.value(forHTTPHeaderField: "Retry-After"), now: Date())
        lock.lock()
        let key = host(request)
        blockedUntil[key] = max(blockedUntil[key, default: 0], ProcessInfo.processInfo.systemUptime + delay)
        lock.unlock()
        throw LyricsRequestLimitError()
    }
}
