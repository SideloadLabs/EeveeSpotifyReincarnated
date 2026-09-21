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

/// Reading direction of a run of text. Deliberately a type of this
/// model layer's own rather than SwiftUI's LayoutDirection, so the DTOs
/// stay free of any UI-framework import; KaraokeLineView maps it across.
enum KaraokeTextDirection {
    case leftToRight
    case rightToLeft
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

    /// True if this line's text is a right-to-left script (Arabic, Hebrew,
    /// etc.) — checked via the first "strong" directional character found,
    /// the same principle the Unicode Bidi Algorithm itself uses to decide
    /// a paragraph's base direction. Used to flip the karaoke fill
    /// gradient's sweep direction and word layout order for RTL lyrics —
    /// see the environment(\.layoutDirection:) call in KaraokeLineView.
    var isRTL: Bool { strongDirection == .rightToLeft }

    /// Direction of the first *strong* directional character in the line,
    /// or `.none` when the line has no strong character at all — a line
    /// that is only punctuation, digits, ellipses or musical-note glyphs
    /// ("♪", "...", "(2x)") carries no direction of its own. Those lines
    /// are common in Arabic lyrics as instrumental/ad-lib markers, and
    /// treating them as LTR made them visibly jump sides mid-song, so the
    /// view layer feeds them the surrounding song's direction instead
    /// (see KaraokeLyricsDto.isRTL and KaraokeLineView's fallbackIsRTL).
    var strongDirection: KaraokeTextDirection? {
        for scalar in plainText.unicodeScalars {
            switch scalar.value {
            case 0x0590...0x05FF,  // Hebrew
                 0x0600...0x06FF,  // Arabic
                 0x0750...0x077F,  // Arabic Supplement
                 0x08A0...0x08FF,  // Arabic Extended-A
                 0xFB1D...0xFB4F,  // Hebrew presentation forms
                 0xFB50...0xFDFF,  // Arabic presentation forms A
                 0xFE70...0xFEFF:  // Arabic presentation forms B
                return .rightToLeft
            case 0x0041...0x005A, 0x0061...0x007A:  // basic Latin letters
                return .leftToRight
            default:
                continue
            }
        }
        return nil
    }
}

/// Full karaoke-ready lyrics for one track. Only produced when the
/// SpicyLyrics API returns Type=="Syllable" — for Static/Line lyrics,
/// the existing LyricsDto/native-screen path is used instead and this
/// type is simply not constructed.
struct KaraokeLyricsDto {
    var lines: [KaraokeLineDto]

    /// The song's overall reading direction: whichever direction more of
    /// its lines actually declare. Only lines with a strong directional
    /// character vote; lines that have none (instrumental markers, "♪",
    /// bare numbers) are the ones this value exists to serve, so they
    /// can't also decide it. Ties fall to left-to-right.
    var isRTL: Bool {
        var rtl = 0, ltr = 0
        for line in lines {
            switch line.strongDirection {
            case .rightToLeft: rtl += 1
            case .leftToRight: ltr += 1
            case nil: continue
            }
        }
        return rtl > ltr
    }

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
    /// From the API's UploadAttribution block (Uploader / Maker usernames).
    /// Nil when the response carries no attribution.
    var uploaderName: String? = nil
    var uploaderUrl: String? = nil
    var makerName: String? = nil
    var makerUrl: String? = nil
}
