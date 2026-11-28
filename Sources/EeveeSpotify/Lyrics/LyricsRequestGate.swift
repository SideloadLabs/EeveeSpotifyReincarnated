import Foundation

struct LyricsRequestLimitError: Error, CustomStringConvertible {
    var description: String { "Lyrics provider rate limit; waiting before the next request" }
}

/// Paces background lyrics downloads only. Playback and prefetch go straight to the
/// provider exactly as upstream does; this gate never sits in front of them. They do
/// hold downloads back: while one is in flight downloads wait, so it goes first, and a
/// 429 it receives pauses downloads to that provider as a download's own 429 does.
///
/// Waiting downloads sleep until their time or until `wake()`: the downloader calls it
/// when downloads may no longer be wanted, so none polls for cancellation.
final class LyricsRequestGate {
    static let shared = LyricsRequestGate()
    private let condition = NSCondition()
    private var next: [String: TimeInterval] = [:]
    private var blockedUntil: [String: TimeInterval] = [:]
    private var playbackRequests = 0
    private var playbackHoldUntil: TimeInterval = 0
    /// Counts `wake()` calls, so a sleeper that checked for cancellation just before one
    /// does not sleep through it.
    private var wakes: UInt64 = 0
    /// Downloads' HTTP requests in flight, cancelled by `wake()` once unwanted.
    private var running: [ObjectIdentifier: (task: URLSessionTask, isCancelled: () -> Bool)] = [:]
    let minimumInterval: TimeInterval = 0.5
    /// The longest a download waits for one HTTP request.
    var requestTimeout: TimeInterval = 15
    /// The longest a playback request holds downloads, should its end never be reported.
    let playbackHold: TimeInterval = 5

    static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func host(_ request: URLRequest) -> String {
        (request.value(forHTTPHeaderField: "Host") ?? request.url?.host ?? "lyrics").lowercased()
    }
    func reserve(host: String, now: TimeInterval) -> TimeInterval {
        condition.lock(); defer { condition.unlock() }
        let start = max(now, next[host, default: 0], blockedUntil[host, default: 0])
        next[host] = start + minimumInterval
        return start
    }
    /// Until when downloads wait for playback's requests (for tests and logs).
    func playbackHoldEnd() -> TimeInterval {
        condition.lock(); defer { condition.unlock() }
        return playbackHoldUntil
    }
    /// A playback or prefetch request to a provider started.
    func playbackStarted(now: TimeInterval = LyricsRequestGate.uptime) {
        condition.lock(); defer { condition.unlock() }
        playbackRequests += 1
        playbackHoldUntil = max(playbackHoldUntil, now + playbackHold)
    }
    /// A playback or prefetch request ended. Its 429 pauses downloads to that provider.
    func playbackFinished(_ response: HTTPURLResponse?, request: URLRequest?,
                          now: TimeInterval = LyricsRequestGate.uptime) {
        condition.lock(); defer { condition.unlock() }
        playbackRequests = max(0, playbackRequests - 1)
        if playbackRequests == 0 {
            playbackHoldUntil = min(playbackHoldUntil, now)
            // The hold ended early: waiting downloads may go now.
            condition.broadcast()
        }
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
        var slot = reserve(host: key, now: Self.uptime)
        try sleepUntilDue(isCancelled: isCancelled) {
            // Requests already waiting when a 429 arrives must receive distinct
            // slots after the new deadline, rather than all waking together.
            let blocked = blockedUntil[key, default: 0]
            if slot < blocked {
                slot = max(blocked, next[key, default: 0])
                next[key] = slot + minimumInterval
            }
            // Read every pass: the hold ends as soon as playback's request does.
            return max(slot, playbackHoldUntil) - Self.uptime
        }
    }
    /// A download's pause (a retry's backoff) that ends early when it is no longer wanted.
    func sleep(until deadline: TimeInterval, isCancelled: () -> Bool) throws {
        try sleepUntilDue(isCancelled: isCancelled) { deadline - Self.uptime }
    }
    /// Sleeps until `remaining` (read under the lock) is up, waking early for `wake()` and
    /// for a playback hold that ends.
    private func sleepUntilDue(isCancelled: () -> Bool, remaining: () -> TimeInterval) throws {
        while true {
            condition.lock(); let seen = wakes; condition.unlock()
            // Outside the lock: the check reads the lyrics store, and playback's requests
            // take this lock. A wake() after `seen` is not missed: the wait below skips.
            if isCancelled() { throw URLError(.cancelled) }
            condition.lock()
            let delay = remaining()
            if delay > 0 && wakes == seen { condition.wait(until: Date(timeIntervalSinceNow: delay)) }
            condition.unlock()
            if delay <= 0 { return }
        }
    }
    /// Waits for a download's HTTP request (`finished`, signalled by its completion), at most
    /// `requestTimeout`: some providers' sessions wait 60 s, and downloads load one at a time.
    /// `wake()` cancels the request once the download is unwanted, which completes it.
    func waitForRequest(_ task: URLSessionTask, finished: DispatchSemaphore, isCancelled: @escaping () -> Bool) throws {
        let id = ObjectIdentifier(task)
        condition.lock()
        running[id] = (task, isCancelled)
        condition.unlock()
        defer { condition.lock(); running[id] = nil; condition.unlock() }
        // Checked after registering, so a `wake()` from now on cannot be missed.
        if isCancelled() {
            task.cancel()
            throw URLError(.cancelled)
        }
        if finished.wait(timeout: .now() + requestTimeout) == .timedOut {
            task.cancel()
            finished.wait() // a cancelled request still completes
            throw isCancelled() ? URLError(.cancelled) : URLError(.timedOut)
        }
        if isCancelled() { throw URLError(.cancelled) }
    }
    /// Downloads may no longer be wanted (cancel, removal, settings): waiting ones check
    /// again now, and the HTTP requests of unwanted ones are cancelled.
    func wake() {
        condition.lock()
        wakes &+= 1
        let requests = Array(running.values)
        condition.broadcast()
        condition.unlock()
        guard !requests.isEmpty else { return }
        // Wanted-checks read the lyrics store, which the main thread must not wait for.
        DispatchQueue.global(qos: .utility).async {
            for request in requests where request.isCancelled() { request.task.cancel() }
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
        condition.lock()
        let key = host(request)
        blockedUntil[key] = max(blockedUntil[key, default: 0], Self.uptime + delay)
        condition.unlock()
        throw LyricsRequestLimitError()
    }
}
