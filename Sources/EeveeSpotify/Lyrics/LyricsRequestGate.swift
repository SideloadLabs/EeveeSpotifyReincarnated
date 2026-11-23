import Foundation

struct LyricsRequestLimitError: Error, CustomStringConvertible {
    var description: String { "Lyrics provider rate limit; waiting before the next request" }
}

/// Paces background lyrics downloads only. Playback and prefetch go straight to the
/// provider exactly as upstream does; this gate never sits in front of them. They do
/// hold downloads back: while one is in flight downloads wait, so it goes first, and a
/// 429 it receives pauses downloads to that provider as a download's own 429 does.
final class LyricsRequestGate {
    static let shared = LyricsRequestGate()
    private let lock = NSLock()
    private var next: [String: TimeInterval] = [:]
    private var blockedUntil: [String: TimeInterval] = [:]
    private var playbackRequests = 0
    private var playbackHoldUntil: TimeInterval = 0
    let minimumInterval: TimeInterval = 0.5
    /// The longest a playback request holds downloads, should its end never be reported.
    let playbackHold: TimeInterval = 5

    private func host(_ request: URLRequest) -> String {
        (request.value(forHTTPHeaderField: "Host") ?? request.url?.host ?? "lyrics").lowercased()
    }
    func reserve(host: String, now: TimeInterval) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        let start = max(now, next[host, default: 0], blockedUntil[host, default: 0])
        next[host] = start + minimumInterval
        return start
    }
    /// Until when downloads wait for playback's requests (for tests and logs).
    func playbackHoldEnd() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return playbackHoldUntil
    }
    /// A playback or prefetch request to a provider started.
    func playbackStarted(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        playbackRequests += 1
        playbackHoldUntil = max(playbackHoldUntil, now + playbackHold)
    }
    /// A playback or prefetch request ended. Its 429 pauses downloads to that provider.
    func playbackFinished(_ response: HTTPURLResponse?, request: URLRequest?,
                          now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        playbackRequests = max(0, playbackRequests - 1)
        if playbackRequests == 0 { playbackHoldUntil = min(playbackHoldUntil, now) }
        guard let response, response.statusCode == 429, let request else { return }
        // A missing Retry-After falls back to the same bounded default as a download's 429.
        let delay = Self.retryDelay(response.value(forHTTPHeaderField: "Retry-After"), now: Date())
        let key = host(request)
        blockedUntil[key] = max(blockedUntil[key, default: 0], now + delay)
    }
    func wait(for request: URLRequest, isCancelled: () -> Bool) throws {
        try wait(key: host(request), isCancelled: isCancelled)
    }
    /// One slot per provider key (minimumInterval apart).
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
            // Read every pass: the hold ends as soon as playback's request does.
            let hold = playbackHoldUntil
            lock.unlock()
            let delay = max(slot, hold) - ProcessInfo.processInfo.systemUptime
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
