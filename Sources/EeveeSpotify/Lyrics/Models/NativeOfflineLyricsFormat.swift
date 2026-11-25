import Foundation

enum NativeOfflineLyricsFormat {
    // Spotify 9.2.0's SyncType.unknown raw value is "unsynced".
    // Enum case/debug descriptions are not a serialization contract.
    static let unsynced = "unsynced"
    static let lineSynced = "lineSynced"

    struct Incompatible: Error {}

    /// ARGB colors of a native LyricsOfflineDatabaseEntity.
    struct Palette: Equatable, Hashable {
        let background: UInt32
        let textBase: UInt32
        let textSubdued: UInt32
        let textBrightAccent: UInt32
    }

    static let black: UInt32 = 0xFF00_0000
    static let white: UInt32 = 0xFFFF_FFFF

    /// Map protobuf LyricsColors to the native entity the way Spotify's own
    /// plugin does (rows it stored from our responses: activeLineColor →
    /// textBaseColor and textBrightAccentColor, lineColor → textSubduedColor).
    /// Unsynced lines render in textBaseColor, so it must be the active color.
    /// A missing or fully transparent value falls back to the online defaults.
    static func palette(background: UInt32?, line: UInt32?, activeLine: UInt32?,
                        fallbackBackground: UInt32) -> Palette {
        func opaque(_ value: UInt32?) -> UInt32? { value.flatMap { $0 >> 24 == 0 ? nil : $0 } }
        let active = opaque(activeLine) ?? white
        return Palette(background: opaque(background) ?? fallbackBackground, textBase: active,
                       textSubdued: opaque(line) ?? black, textBrightAccent: active)
    }

    static func validateUnsynced(_ type: Decodable.Type) throws -> String {
        try validate(type, rawValue: unsynced)
    }

    static func validate(_ type: Decodable.Type, rawValue: String) throws -> String {
        let json = try JSONEncoder().encode(rawValue)
        let decoded = try JSONDecoder().decode(type, from: json)
        guard let encodable = decoded as? Encodable else { throw Incompatible() }
        let encoded = try JSONEncoder().encode(encodable)
        guard try JSONDecoder().decode(String.self, from: encoded) == rawValue else { throw Incompatible() }
        return rawValue
    }

    static func project(text: [String], offsetsMs: [Int64], timeSynced: Bool) throws -> (sync: String, lines: [[String: Any]], times: [Int64]) {
        guard text.count == offsetsMs.count else { throw Incompatible() }
        let validTimes = offsetsMs.allSatisfy { $0 >= 0 } && zip(offsetsMs, offsetsMs.dropFirst()).allSatisfy { $0 <= $1 }
        let synced = timeSynced && validTimes && (text.count <= 1 || offsetsMs.contains { $0 > 0 })
        let times = synced ? offsetsMs : Array(repeating: Int64(0), count: text.count)
        let lines = zip(text, times).map { text, time -> [String: Any] in
            // Native Line's Codable implementation requires Int64 startTime,
            // text and syllables. Reflection metadata omits startTime in 9.2.0.
            ["startTime": time, "text": text, "syllables": [Any]()]
        }
        return (synced ? lineSynced : unsynced, lines, times)
    }
}
