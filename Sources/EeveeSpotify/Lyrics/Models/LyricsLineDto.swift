import Foundation

struct SyllableDto {
    var startTimeMs: Int64
    var numChars: Int64
}

struct LyricsLineDto {
    var words: String
    var startTimeMs: Int64?
    var syllables: [SyllableDto]?
}
