import Foundation

func check(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
let gate = LyricsRequestGate()
check(gate.reserve(host: "one", now: 100) == 100, "first request should start immediately")
check(gate.reserve(host: "one", now: 100) == 100.5, "duplicate host was not paced")
check(gate.reserve(host: "one", now: 100.1) == 101, "rapid requests escaped the host queue")
check(gate.reserve(host: "two", now: 100) == 100, "unrelated providers shared a cooldown")
check(gate.reserve(host: "one", now: 120) == 120, "idle provider remained throttled")
check(LyricsRequestGate.retryDelay("12", now: Date()) == 12, "Retry-After seconds not honored")
check(LyricsRequestGate.retryDelay(nil, now: Date()) == 30, "missing Retry-After needs a bounded default")
check(LyricsRequestGate.retryDelay("Tue, 17 Nov 2026 12:00:30 GMT", now: Date(timeIntervalSince1970: 1794916800)) == 30, "HTTP-date Retry-After not honored")
let request = URLRequest(url: URL(string: "https://provider.example/lyrics")!)
let limited = HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "2"])!
let before = ProcessInfo.processInfo.systemUptime
do { try gate.check(limited, request: request); fatalError("429 was accepted as lyrics") }
catch is LyricsRequestLimitError {}
check(gate.reserve(host: "provider.example", now: before) >= before + 1.9, "next request ignored server cooldown")
let lock = NSLock()
var reservations: [Double] = []
DispatchQueue.concurrentPerform(iterations: 30) { _ in
    let slot = gate.reserve(host: "concurrent", now: 100)
    lock.lock(); reservations.append(slot); lock.unlock()
}
check(Set(reservations).count == 30 && reservations.max() == 114.5, "concurrent requests received the same slot")
// Playback holds downloads only while its request is in flight, at most playbackHold.
let playback = LyricsRequestGate()
playback.playbackStarted(now: 200)
check(playback.playbackHoldEnd() == 200 + playback.playbackHold, "playback request did not hold downloads")
playback.playbackStarted(now: 201)
playback.playbackFinished(nil, request: nil, now: 202)
check(playback.playbackHoldEnd() > 202, "one finished playback request released another's hold")
playback.playbackFinished(nil, request: nil, now: 203)
check(playback.playbackHoldEnd() == 203, "finished playback kept holding downloads")
playback.playbackFinished(nil, request: nil, now: 204)
check(playback.playbackHoldEnd() == 203, "an unmatched end moved the hold")
// A 429 that playback receives pauses downloads to that provider, as a download's own does.
let playbackRequest = URLRequest(url: URL(string: "https://spicy.example/lyrics")!)
let playbackLimited = HTTPURLResponse(url: playbackRequest.url!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "8"])!
playback.playbackStarted(now: 300)
playback.playbackFinished(playbackLimited, request: playbackRequest, now: 300)
check(playback.reserve(host: "spicy.example", now: 300) == 308, "playback's 429 did not pause downloads")
check(playback.reserve(host: "other.example", now: 300) == 300, "playback's 429 paused another provider")
let ok = HTTPURLResponse(url: playbackRequest.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
playback.playbackStarted(now: 400)
playback.playbackFinished(ok, request: playbackRequest, now: 400)
check(playback.reserve(host: "spicy.example", now: 400) == 400, "a successful playback answer paused downloads")
print("LyricsRequestGate tests passed")
