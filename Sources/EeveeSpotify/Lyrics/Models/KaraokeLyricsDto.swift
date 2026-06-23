import Foundation

/// A single syllable/word-chunk with its own timing, used to drive
/// karaoke-style progressive highlight animation. Mirrors the real
/// SpicyLyrics extension's per-syllable model (Syllable.ts):
/// each syllable knows its own start/end time and whether it glues
/// directly onto the previous syllable (continuing the same word)
/// or starts a new word (needs a preceding space when rendered).
struct KaraokeSyllableDto {
    var text: String
    var startMs: Int
    var endMs: Int
    var isPartOfWord: Bool
}

/// A single lyrics line with full per-syllable timing, for the custom
/// karaoke view. This is intentionally separate from LyricsLineDto
/// (which only carries one offsetMs per line, matching Spotify's native
/// protobuf schema) — that type still feeds Spotify's native lyrics
/// screen for Static/Line lyrics; this type only exists for the
/// custom overlay when real Syllable data is available.
struct KaraokeLineDto {
    var syllables: [KaraokeSyllableDto]
    var startMs: Int
    var endMs: Int

    /// Flattened text, spaced the same way the existing LyricsLineDto
    /// conversion does (space before any syllable that isn't IsPartOfWord).
    var plainText: String {
        var text = ""
        for syllable in syllables {
            if !text.isEmpty && !syllable.isPartOfWord {
                text += " "
            }
            text += syllable.text
        }
        return text
    }
}

/// Full karaoke-ready lyrics for one track. Only produced when the
/// SpicyLyrics API returns Type=="Syllable" — for Static/Line lyrics,
/// the existing LyricsDto/native-screen path is used instead and this
/// type is simply not constructed.
struct KaraokeLyricsDto {
    var lines: [KaraokeLineDto]
}
