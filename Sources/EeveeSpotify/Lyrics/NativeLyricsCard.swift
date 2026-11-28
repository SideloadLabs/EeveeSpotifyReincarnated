import Foundation

/// Spotify 9.2's server lists the cards under the player (/scrollsita/v1/scroll/spotify:track:<id>,
/// a spotify.scrollsita.v1.NpvScrollResponse) and includes the lyrics card only for songs it has
/// lyrics for itself. Older Spotify decided that in the app, where Eevee enabled the card for every
/// song (LyricsErrorHandlingGroup). For a song whose provider lyrics are saved, this adds the card
/// the server sends for its own lyrics, first as the server places it. Spotify then asks for the
/// lyrics, which Eevee already answers with the provider's.
enum NativeLyricsCard {
    private static let pathPrefix = "/scrollsita/v1/scroll/spotify:track:"
    /// The server's lyrics section, the same for every song.
    private static let lyricsSection = "spotify:section:0JQ5DB6s3cssW5Bo6cGq21"
    // NpvScrollResponse.structure = 1, NpvScrollStructure.sections = 1,
    // Section.lyrics = 5 (Lyrics.track_uri = 1), Section.info = 23 (SectionInfo.uri = 1).
    private static let structureField = 1, sectionField = 1, lyricsField = 5, infoField = 23

    static func insert(into response: Data, url: URL) -> Data? {
        guard url.path.hasPrefix(pathPrefix) else { return nil }
        let trackId = String(url.path.dropFirst(pathPrefix.count))
        guard NativeOfflineLyrics.shared.hasProviderLyrics(trackId: trackId),
              let result = adding(trackId: trackId, to: response) else { return nil }
        writeDebugLog("[Lyrics] native lyrics card added for \(trackId)")
        return result
    }

    /// The response with a lyrics card before its other sections. Nil when it already has
    /// one or is not laid out as expected, so the response is left as it is.
    static func adding(trackId: String, to response: Data) -> Data? {
        guard let fields = parse(response),
              fields.filter({ $0.number == structureField }).count == 1,
              let index = fields.firstIndex(where: { $0.number == structureField }),
              let structure = fields[index].bytes,
              let sections = parse(structure) else { return nil }
        for section in sections where section.number == sectionField {
            guard let bytes = section.bytes, let inner = parse(bytes) else { return nil }
            if inner.contains(where: { $0.number == lyricsField }) { return nil }
        }
        let lyrics = field(lyricsField, field(1, Data("spotify:track:\(trackId)".utf8)))
        let info = field(infoField, field(1, Data(lyricsSection.utf8)))
        let card = field(sectionField, lyrics + info)
        var out = Data()
        for (position, entry) in fields.enumerated() {
            out += position == index ? field(structureField, card + structure) : entry.raw
        }
        return out
    }

    private struct Field {
        let number: Int
        let bytes: Data?
        let raw: Data
    }

    private static func parse(_ input: Data) -> [Field]? {
        let data = Data(input)
        var i = 0
        var fields = [Field]()
        while i < data.count {
            let start = i
            guard let key = varint(data, &i), key >> 3 > 0 else { return nil }
            var bytes: Data?
            switch key & 7 {
            case 0: guard varint(data, &i) != nil else { return nil }
            case 1: i += 8
            case 2:
                guard let length = varint(data, &i), length <= UInt64(data.count - i) else { return nil }
                bytes = data.subdata(in: i..<i + Int(length))
                i += Int(length)
            case 5: i += 4
            default: return nil
            }
            guard i <= data.count else { return nil }
            fields.append(Field(number: Int(key >> 3), bytes: bytes, raw: data.subdata(in: start..<i)))
        }
        return fields
    }

    private static func varint(_ data: Data, _ i: inout Int) -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while i < data.count, shift < 64 {
            let byte = data[i]
            i += 1
            value |= UInt64(byte & 0x7f) << shift
            if byte < 0x80 { return value }
            shift += 7
        }
        return nil
    }

    private static func field(_ number: Int, _ bytes: Data) -> Data {
        encode(UInt64(number << 3 | 2)) + encode(UInt64(bytes.count)) + bytes
    }

    private static func encode(_ value: UInt64) -> Data {
        var value = value
        var data = Data()
        while value >= 0x80 {
            data.append(UInt8(value & 0x7f) | 0x80)
            value >>= 7
        }
        data.append(UInt8(value))
        return data
    }
}
