import Foundation

func check(_ ok: @autoclosure () -> Bool, _ message: String) {
    if !ok() { fatalError(message) }
}
func pump(_ condition: () -> Bool) {
    let until = Date().addingTimeInterval(2)
    while !condition() && Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
    check(condition(), "Metadata completion timed out")
}

var calls = 0 // main only
var delay: TimeInterval = 0
var returnMetadata = true
var serviceFailed = false
func EeveePixieFetchLyricsMetadata(_ uri: String, _ reply: @escaping (NSDictionary?) -> Void) {
    DispatchQueue.main.async {
        calls += 1
        let result: NSDictionary? = returnMetadata ? ["name": "Fresh track", "artist_name": "Native artist"]
            : serviceFailed ? ["unavailable": true] : nil
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { reply(result) }
    }
}
func isUnavailable(_ value: NativeLyricsMetadataLookup) -> Bool { if case .unavailable = value { return true }; return false }
func isMissing(_ value: NativeLyricsMetadataLookup) -> Bool { if case .missing = value { return true }; return false }

check(isUnavailable(nativeLyricsMetadata(trackId: "0000000000000000000001", timeout: 1)),
      "A main-thread caller waited for a native callback on main")
check(calls == 0, "A main-thread request started work it could not await")

var completed = 0
DispatchQueue.global().async {
    let value = nativeLyricsMetadata(trackId: "0000000000000000000001", timeout: 1).metadata
    DispatchQueue.main.async {
        check(value?.title == "Fresh track" && value?.artist == "Native artist", "Fresh native metadata was lost")
        completed += 1
    }
}
pump { completed == 1 }
returnMetadata = false
DispatchQueue.global().async {
    let value = nativeLyricsMetadata(trackId: "0000000000000000000002", timeout: 1)
    DispatchQueue.main.async { check(isMissing(value), "Spotify's answer without a title was not a definite miss"); completed += 1 }
}
pump { completed == 2 }
serviceFailed = true
DispatchQueue.global().async {
    let value = nativeLyricsMetadata(trackId: "0000000000000000000004", timeout: 1)
    DispatchQueue.main.async { check(isUnavailable(value), "A failed native service call became a definite miss"); completed += 1 }
}
pump { completed == 3 }
serviceFailed = false
returnMetadata = true
delay = 0.1
DispatchQueue.global().async {
    let value = nativeLyricsMetadata(trackId: "0000000000000000000003", timeout: 0.02)
    DispatchQueue.main.async { check(isUnavailable(value), "The metadata deadline did not bound the wait"); completed += 1 }
}
pump { completed == 4 }
RunLoop.current.run(until: Date().addingTimeInterval(0.2))
check(completed == 4 && calls == 4, "A late callback restarted completed lyrics work")
print("Native lyrics metadata deadline and thread tests passed")
