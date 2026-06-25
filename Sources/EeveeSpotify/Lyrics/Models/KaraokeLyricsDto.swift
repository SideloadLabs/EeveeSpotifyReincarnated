import Foundation

/// A single syllable/word-chunk with its own timing, used to drive
/// karaoke-style progressive highlight animation. Mirrors the real
/// SpicyLyrics extension's per-syllable model (Syllable.ts):
/// each syllable knows its own start/end time and whether the word
/// continues into the *next* syllable. IsPartOfWord is a forward-looking
/// flag — confirmed against the real client's Syllable.ts word-grouping
/// loop, which gates the current syllable's own group-continuation on
/// the *previous* syllable's flag (`lead.IsPartOfWord || (prev?.IsPartOfWord
/// && currentWordGroup)`), and against tools.ts's convertSyllableToStatic,
/// which appends a space *after* a syllable only `if (!syllable.IsPartOfWord)`.
/// Both treat the flag as "no gap follows this syllable" — i.e. it glues
/// onto what comes after it, not what came before. An earlier version of
/// this port read the flag backwards (as "glues onto the previous
/// syllable"), which produced exactly the broken spacing seen in some
/// songs — e.g. "Lo"+"la" (IsPartOfWord true on "Lo") rendering as
/// "Lo la" instead of "Lola", and "was"+"Lo" rendering as "wasLo" instead
/// of "was Lo" — since the old logic checked each syllable's own flag
/// instead of the one before it.
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

    /// Flattened text. A space is inserted before a syllable unless the
    /// *previous* syllable's isPartOfWord flag says it glues forward onto
    /// this one — see the note on KaraokeSyllableDto.isPartOfWord above
    /// for why it's the previous syllable's flag, not this syllable's own.
    var plainText: String {
        var text = ""
        var previousIsPartOfWord = false
        for syllable in syllables {
            if !text.isEmpty && !previousIsPartOfWord {
                text += " "
            }
            text += syllable.text
            previousIsPartOfWord = syllable.isPartOfWord
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
    /// Matches the real extension's Credits/ApplyLyricsCredits.ts
    /// "Written by: ..." footer, sourced from the API's SongWriters array.
    var songWriters: [String]
    /// Raw provider code from the API's "source" field (e.g. "aml", "spt",
    /// "spl", "ldb", "ext") — mapped to a display label the same way
    /// Credits/ApplyLyricsProvider.ts does, kept as the raw code here so
    /// the view layer owns the display-string mapping.
    var providerCode: String?
    /// Only present/used when providerCode == "ext" — the real extension's
    /// ApplyLyricsProvider.ts falls back to a server-supplied display name
    /// for external sources rather than a fixed ProviderMap entry.
    var providerDisplayName: String?
}
