import Foundation

struct KaraokeSyllableDto {
    var text: String
    var startMs: Int
    var endMs: Int
    var isPartOfWord: Bool
}

extension Array where Element == KaraokeSyllableDto {
    // isPartOfWord glues a syllable to the next one, so spacing and grouping follow the previous flag.
    var plainText: String {
        var text = ""
        var previousIsPartOfWord = false
        for syllable in self {
            if !text.isEmpty && !previousIsPartOfWord {
                text += " "
            }
            text += syllable.text
            previousIsPartOfWord = syllable.isPartOfWord
        }
        return text
    }
}

enum KaraokeTextDirection {
    case leftToRight
    case rightToLeft
}

struct KaraokeLineDto {
    var syllables: [KaraokeSyllableDto]
    var startMs: Int
    var endMs: Int

    var plainText: String { syllables.plainText }

    var words: [[KaraokeSyllableDto]] {
        var result: [[KaraokeSyllableDto]] = []
        var current: [KaraokeSyllableDto] = []
        for syllable in syllables {
            if current.isEmpty || current.last?.isPartOfWord == true {
                current.append(syllable)
            } else {
                result.append(current)
                current = [syllable]
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    // Hebrew/Arabic/Syriac/Thaana blocks read RTL, Latin/Cyrillic/Greek LTR; nil for lines with neither ("♪", "(2x)").
    var strongDirection: KaraokeTextDirection? {
        for scalar in plainText.unicodeScalars {
            switch scalar.value {
            case 0x0590...0x05FF,  // Hebrew
                 0x0600...0x06FF,  // Arabic (includes Persian, Urdu, etc.)
                 0x0700...0x074F,  // Syriac
                 0x0750...0x077F,  // Arabic Supplement
                 0x0780...0x07BF,  // Thaana
                 0x0800...0x085F,  // Samaritan & Mandaic
                 0x0870...0x089F,  // Arabic Extended-B
                 0x08A0...0x08FF,  // Arabic Extended-A
                 0xFB1D...0xFB4F,  // Hebrew Presentation Forms
                 0xFB50...0xFDFF,  // Arabic Presentation Forms-A
                 0xFE70...0xFEFF,  // Arabic Presentation Forms-B
                 0x10EC0...0x10EFF: // Arabic Extended-C
                return .rightToLeft
            case 0x0041...0x005A, 0x0061...0x007A,  // Basic Latin
                 0x00C0...0x00D6, 0x00D8...0x00F6, 0x00F8...0x00FF, // Latin-1 Supplement
                 0x0100...0x024F,  // Latin Extended-A & B
                 0x0370...0x03FF,  // Greek
                 0x0400...0x04FF:  // Cyrillic
                return .leftToRight
            default:
                continue
            }
        }
        return nil
    }
}

struct KaraokeLyricsDto {
    var lines: [KaraokeLineDto]

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

    var songWriters: [String]
    var providerCode: String?
    /// Display name for the credits footer. Nil keeps the old behaviour (Spicy Lyrics when `providerCode` is set).
    var providerName: String? = nil
    var uploaderName: String? = nil
    var uploaderUrl: String? = nil
    var makerName: String? = nil
    var makerUrl: String? = nil
}
