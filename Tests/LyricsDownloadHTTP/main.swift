import Foundation

func check(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError(message) }
}
let request = URLRequest(url: URL(string: "https://download-policy.example/lyrics")!)
func response(_ status: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Retry-After":"1"])!
}
// Identical shared repository calls remain upstream when outside a download.
try LyricsDownloadHTTP.validate(response(429), request: request)
do {
    try LyricsDownloadHTTP.perform(isCancelled: { false }) {
        try LyricsDownloadHTTP.validate(response(429), request: request)
    }
    fatalError("background 429 escaped as a missing song")
} catch is LyricsRequestLimitError {}
check(LyricsRequestGate.shared.reserve(host: request.url!.host!, now: ProcessInfo.processInfo.systemUptime) > ProcessInfo.processInfo.systemUptime + 0.8,
      "the actual HTTP host did not receive the cooldown")
// Scope must be restored even after a throw and must not leak to playback.
try LyricsDownloadHTTP.validate(response(429), request: request)
do {
    try LyricsDownloadHTTP.perform(isCancelled: { false }) {
        try LyricsDownloadHTTP.validate(response(503), request: request)
    }
    fatalError("503 became noSuchSong")
} catch let error as LyricsProviderHTTPError { check(error.status == 503, "HTTP status was lost") }
try LyricsDownloadHTTP.perform(isCancelled: { false }) {
    try LyricsDownloadHTTP.validate(response(404), request: request, accepting: [404])
}
do {
    try LyricsDownloadHTTP.perform(isCancelled: { true }) { fatalError("cancelled download started HTTP") }
} catch let error as URLError { check(error.code == .cancelled, "wrong cancellation") }

// Transport cancellation is retryable while the download is still wanted.
for code in [URLError.Code.cancelled, .networkConnectionLost] {
    var attempts = 0
    let result = try LyricsDownloadHTTP.perform(isCancelled: { false }) {
        attempts += 1
        if attempts == 1 { throw URLError(code) }
        return "saved"
    }
    check(result == "saved" && attempts == 2, "transient transport cancellation left a missing lyric")
}
var attempts = 0
do {
    try LyricsDownloadHTTP.perform(isCancelled: { false }) {
        attempts += 1; throw URLError(.cancelled)
    }
    fatalError("persistent transport cancellation escaped retry limit")
} catch let error as LyricsDownloadTransportError {
    check(attempts == 3 && error.underlying.code == .cancelled, "transport exhaustion became user cancellation")
}
var stopped = false
attempts = 0
do {
    try LyricsDownloadHTTP.perform(isCancelled: { stopped }) {
        attempts += 1; stopped = true; throw URLError(.networkConnectionLost)
    }
    fatalError("explicit Cancel was retried")
} catch let error as URLError {
    check(error.code == .cancelled && attempts == 1, "explicit cancellation did not win over transport retry")
}
stopped = false
let task = URLSession.shared.dataTask(with: request) { _, _, _ in }
do {
    try LyricsDownloadHTTP.perform(isCancelled: { stopped }) {
        stopped = true
        try LyricsDownloadHTTP.wait(DispatchSemaphore(value: 0), task: task)
    }
    fatalError("an expired download kept waiting for HTTP")
} catch let error as URLError {
    check(error.code == .cancelled && [.canceling, .completed].contains(task.state), "worker stopped without cancelling its HTTP task")
}
var noSuchAttempts = 0
enum Miss: Error { case notFound }
do {
    try LyricsDownloadHTTP.perform(isCancelled: { false }) { noSuchAttempts += 1; throw Miss.notFound }
} catch Miss.notFound {}
check(noSuchAttempts == 1, "definitive provider miss was retried")

// A cooldown arriving after waiters reserved slots must not wake them together.
let gate = LyricsRequestGate()
let pending = URLRequest(url: URL(string: "https://waiting.example/lyrics")!)
_ = gate.reserve(host: "waiting.example", now: ProcessInfo.processInfo.systemUptime)
let group = DispatchGroup(), lock = NSLock()
var starts: [TimeInterval] = []
for _ in 0..<2 {
    group.enter()
    DispatchQueue.global().async {
        try! gate.wait(for: pending, isCancelled: { false })
        lock.lock(); starts.append(ProcessInfo.processInfo.systemUptime); lock.unlock()
        group.leave()
    }
}
Thread.sleep(forTimeInterval: 0.08)
let blockedAt = ProcessInfo.processInfo.systemUptime
do {
    try gate.check(HTTPURLResponse(url: pending.url!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After":"1"]), request: pending)
} catch is LyricsRequestLimitError {}
check(group.wait(timeout: .now()+5) == .success, "cooldown never resumed")
starts.sort()
check(starts[0] >= blockedAt+0.9 && starts[1]-starts[0] >= 0.4, "waiters burst together after a 429")
// Nothing polls for cancellation: wake() stops a paced wait and an HTTP request in flight.
let wakeGate = LyricsRequestGate()
let wakeLock = NSLock()
var unwanted = false
func isUnwanted() -> Bool { wakeLock.lock(); defer { wakeLock.unlock() }; return unwanted }
let blockedRequest = URLRequest(url: URL(string: "https://blocked.example/lyrics")!)
do { try wakeGate.check(HTTPURLResponse(url: blockedRequest.url!, statusCode: 429, httpVersion: nil,
                                        headerFields: ["Retry-After": "60"]), request: blockedRequest) }
catch is LyricsRequestLimitError {}
let finished = DispatchSemaphore(value: 0)
let inFlight = URLSession.shared.dataTask(with: URLRequest(url: URL(string: "https://in-flight.example/lyrics")!)) { _, _, _ in
    finished.signal()
}
let stops = DispatchGroup()
var stopped429 = false, stoppedHTTP = false
stops.enter()
DispatchQueue.global().async {
    do { try wakeGate.wait(for: blockedRequest, isCancelled: isUnwanted) }
    catch let error as URLError where error.code == .cancelled { stopped429 = true }
    catch {}
    stops.leave()
}
stops.enter()
DispatchQueue.global().async {
    do { try wakeGate.waitForRequest(inFlight, finished: finished, isCancelled: isUnwanted) }
    catch let error as URLError where error.code == .cancelled { stoppedHTTP = true }
    catch {}
    stops.leave()
}
Thread.sleep(forTimeInterval: 0.2)
wakeLock.lock(); unwanted = true; wakeLock.unlock()
let wokenAt = ProcessInfo.processInfo.systemUptime
wakeGate.wake()
check(stops.wait(timeout: .now() + 3) == .success, "wake() did not stop a waiting download")
check(stopped429 && stoppedHTTP && ProcessInfo.processInfo.systemUptime - wokenAt < 2,
      "an unwanted download kept waiting for its 429 cooldown or its HTTP request")
check([.canceling, .completed].contains(inFlight.state), "wake() did not cancel the unwanted HTTP request")
// A provider that does not answer holds a download at most requestTimeout, and is not asked again.
let deadlineGate = LyricsRequestGate()
deadlineGate.requestTimeout = 0.3
let silentDone = DispatchSemaphore(value: 0)
let silent = URLSession.shared.dataTask(with: URLRequest(url: URL(string: "https://silent.example/lyrics")!)) { _, _, _ in
    silentDone.signal()
}
let deadlineStart = ProcessInfo.processInfo.systemUptime
do {
    try deadlineGate.waitForRequest(silent, finished: silentDone, isCancelled: { false })
    fatalError("a silent provider was waited for without a deadline")
} catch let error as URLError {
    check(error.code == .timedOut && ProcessInfo.processInfo.systemUptime - deadlineStart < 2, "the request deadline did not end the wait")
}
var timeoutAttempts = 0
do {
    try LyricsDownloadHTTP.perform(isCancelled: { false }) { timeoutAttempts += 1; throw URLError(.timedOut) }
} catch let error as URLError { check(error.code == .timedOut && timeoutAttempts == 1, "a timed-out request was retried") }
print("Background HTTP: typed 429, server failures, transport retry, real cancellation, scope isolation, paced cooldown resume, wake and deadline passed")
