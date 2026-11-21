import Foundation

enum SpotifySyncType: String, Codable, CustomStringConvertible {
    case unknown = "unsynced", line = "lineSynced", syllable = "syllableSynced"
    var description: String { "Localized description unrelated to the wire format" }
}
let decoded = try NativeOfflineLyricsFormat.validateUnsynced(SpotifySyncType.self)
precondition(decoded == "unsynced")
// The incorrect guessed raw values from build010 must not enter the cache.
for candidate in ["UNKNOWN", "unknown", "UNSYNCED", "NONE"] {
    let json = try JSONEncoder().encode(candidate)
    do { _ = try JSONDecoder().decode(SpotifySyncType.self, from: json); fatalError("accepted a non-native raw value") } catch {}
}
enum IncompatibleType: String, Codable { case unknown = "UNKNOWN" }
do { _ = try NativeOfflineLyricsFormat.validateUnsynced(IncompatibleType.self); fatalError("accepted incompatible native type") } catch {}
print("NativeOfflineLyricsFormat: exact native unsynced value, description independence and incompatible type rejection passed")

// Match the full native Line Codable contract, including the startTime omitted
// by its reflection metadata (the actual build011 device failure).
struct NativeLineFixture: Decodable {
    let startTime: Int64
    let text: String
    let syllables: [Int]
}
let timed = try NativeOfflineLyricsFormat.project(text: ["First", "Second"], offsetsMs: [1234, 5678], timeSynced: true)
let decodedLines = try JSONDecoder().decode([NativeLineFixture].self, from: JSONSerialization.data(withJSONObject: timed.lines))
precondition(timed.sync == "lineSynced")
precondition(decodedLines.map(\.startTime) == [1234, 5678])
precondition(decodedLines.map(\.text) == ["First", "Second"])
let plain = try NativeOfflineLyricsFormat.project(text: ["Plain", "Text"], offsetsMs: [999, 1999], timeSynced: false)
precondition(plain.sync == "unsynced" && plain.times == [0, 0])
for offsets: [Int64] in [[0, 0], [-1, 100], [200, 100]] {
    let rejected = try NativeOfflineLyricsFormat.project(text: ["A", "B"], offsetsMs: offsets, timeSynced: true)
    precondition(rejected.sync == "unsynced")
}
do { _ = try NativeOfflineLyricsFormat.project(text: ["A"], offsetsMs: [], timeSynced: true); fatalError("accepted mismatched line arrays") } catch {}
print("NativeOfflineLyricsFormat: required Int64 startTime, genuine line timing and unsynced fallback passed")

// Spotify's own rows from our protobuf: activeLine → textBase/brightAccent, line → subdued.
// Unsynced text renders in textBase, so it must be white, not black.
let online = NativeOfflineLyricsFormat.palette(background: 0xFF8E8E93, line: 0xFF000000,
    activeLine: 0xFFFFFFFF, fallbackBackground: 0xFF404040)
precondition(online == .init(background: 0xFF8E8E93, textBase: 0xFFFFFFFF,
    textSubdued: 0xFF000000, textBrightAccent: 0xFFFFFFFF))
let unset = NativeOfflineLyricsFormat.palette(background: nil, line: 0, activeLine: nil,
    fallbackBackground: 0xFF123456)
precondition(unset == .init(background: 0xFF123456, textBase: NativeOfflineLyricsFormat.white,
    textSubdued: NativeOfflineLyricsFormat.black, textBrightAccent: NativeOfflineLyricsFormat.white))
print("NativeOfflineLyricsFormat: native color mapping keeps unsynced text in the active (white) color")
