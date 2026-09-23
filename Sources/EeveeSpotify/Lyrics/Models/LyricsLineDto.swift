import Foundation

struct LyricsLineDto {
    var content: String
    var offsetMs: Int?
    /// Lead-vocal syllable timing for Spotify's native rich-sync rendering;
    /// only used when it still spells out `content` exactly.
    var syllables: [KaraokeSyllableDto]? = nil
    var endMs: Int? = nil
}
