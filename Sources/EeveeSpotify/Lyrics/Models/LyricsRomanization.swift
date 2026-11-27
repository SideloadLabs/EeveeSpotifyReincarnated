import Foundation

enum LyricsRomanization {
    private static let maxLineBytes = 16_384

    static func prefersJapaneseReadings<S: Sequence>(_ lines: S) -> Bool where S.Element == String {
        lines.prefix(4096).contains { line in
            guard line.utf8.prefix(maxLineBytes + 1).count <= maxLineBytes else { return false }
            return line.unicodeScalars.contains { scalar in
                switch scalar.value {
                case 0x3041...0x3096, 0x309D...0x309F, 0x30A1...0x30FA,
                     0x30FD...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF6F, 0xFF71...0xFF9D:
                    return true
                default:
                    return false
                }
            }
        }
    }

    static func romanizeLine(_ line: String, japanese: Bool) -> String {
        guard line.utf8.prefix(maxLineBytes + 1).count <= maxLineBytes else { return line }
        guard japanese else { return line.applyingTransform(.toLatin, reverse: false) ?? line }
        let source = line as NSString
        let tokenizer = CFStringTokenizerCreate(nil, line as CFString,
            CFRangeMake(0, source.length), kCFStringTokenizerUnitWord, Locale(identifier: "ja") as CFLocale)
        var result = ""
        var end = 0
        while !CFStringTokenizerAdvanceToNextToken(tokenizer).isEmpty {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            guard range.location >= end, range.length > 0,
                  range.location <= source.length - range.length else { return line }
            result += source.substring(with: NSRange(location: end, length: range.location - end))
            let token = source.substring(with: NSRange(location: range.location, length: range.length))
            let reading = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String
            if let reading = reading, !reading.isEmpty, !token.unicodeScalars.allSatisfy({ $0.isASCII }) {
                result += reading
            } else {
                result += token
            }
            end = range.location + range.length
        }
        return result + source.substring(from: end)
    }
}
