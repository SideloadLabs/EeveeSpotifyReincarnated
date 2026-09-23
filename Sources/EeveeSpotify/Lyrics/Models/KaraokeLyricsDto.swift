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
    /// Background vocals (SpicyLyrics' `Background` array — ad-libs,
    /// echoes, backing lines), each group with its own per-syllable timing.
    /// Rendered smaller underneath the lead syllables, like the real
    /// extension's Syllable.ts does. A line can have background vocals and
    /// no lead syllables at all.
    var background: [KaraokeSyllableDto] = []
    /// SpicyLyrics' `OppositeAligned` duet flag — this line is sung by the
    /// second vocalist and sits on the opposite side from the lead lines.
    var oppositeAligned: Bool = false
    /// Synthesized "• • •" line covering an instrumental gap, matching the
    /// real extension's musical-line dots (Syllable.ts). Its `syllables`
    /// are the three dots, each timed to one third of the gap.
    var isInterlude: Bool = false
    /// Line-synced lyrics (the API's Type "Line"): `syllables` holds the
    /// whole line as one entry spanning the line's time, and the view
    /// fills it as one line, like the extension's Line mode.
    var isLineSynced: Bool = false

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

    /// True if this line's text is a right-to-left script (Arabic, Hebrew,
    /// etc.) — checked via the first "strong" directional character found,
    /// the same principle the Unicode Bidi Algorithm itself uses to decide
    /// a paragraph's base direction. Used to flip the karaoke fill
    /// gradient's sweep direction and word layout order for RTL lyrics —
    /// see the environment(\.layoutDirection:) call in KaraokeLineView.
    var isRTL: Bool {
        for scalar in plainText.unicodeScalars {
            switch scalar.value {
            case 0x0590...0x05FF,  // Hebrew
                 0x0600...0x06FF,  // Arabic
                 0x0750...0x077F,  // Arabic Supplement
                 0x08A0...0x08FF,  // Arabic Extended-A
                 0xFB1D...0xFB4F,  // Hebrew presentation forms
                 0xFB50...0xFDFF,  // Arabic presentation forms A
                 0xFE70...0xFEFF:  // Arabic presentation forms B
                return true
            case 0x0041...0x005A, 0x0061...0x007A:  // basic Latin letters
                return false
            default:
                continue
            }
        }
        return false
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
    /// Community-sync credits (developer API `UploadAttribution`), which
    /// its terms require showing and linking next to the lyrics.
    var uploader: KaraokeCreditDto? = nil
    var maker: KaraokeCreditDto? = nil
}

struct KaraokeCreditDto {
    var name: String
    var url: URL?

    static let providerNames: [String: String] = [
        "spicy_lyrics": "Spicy Lyrics",
        "spl": "Spicy Lyrics",
        "apple_music": "Apple Music",
        "aml": "Apple Music",
        "spotify": "Spotify",
        "spt": "Spotify",
    ]

    static func providerLabel(code: String?, displayName: String?) -> String? {
        guard let code = code else { return nil }
        if code == "ext" { return displayName ?? "External Source" }
        return providerNames[code] ?? code
    }
}
