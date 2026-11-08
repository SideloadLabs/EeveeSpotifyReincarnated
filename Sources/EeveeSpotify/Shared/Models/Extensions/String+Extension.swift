import Foundation 
import UIKit
import NaturalLanguage

extension String {
    static func ~= (lhs: String, rhs: String) -> Bool {
        lhs.firstMatch(rhs) != nil
    }
    
    var localized: String {
        BundleHelper.shared.localizedString(self)
    }
    
    var uiKitLocalized: String {
        let bundle = Bundle(for: UIApplication.self)
        return bundle.localizedString(forKey: self, value: nil, table: nil)
    }
    
    func localizeWithFormat(_ arguments: CVarArg...) -> String {
        String(format: self.localized, arguments: arguments)
    }

    var range: NSRange { 
        NSRange(self.startIndex..., in: self) 
    }

    var strippedTrackTitle: String {
        String(
            self
            .removeMatches("\\(.*\\)")
            .removeMatches("- .*")
            .trimmingCharacters(in: .whitespaces)
        )
    }

    var isHex: Bool {
        self ~= "^[a-f0-9]+$"
    }

    var lyricsNoteIfEmpty: String {
        self.isEmpty ? "♪" : self
    }

    var isRTL: Bool {
        for scalar in unicodeScalars {
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
                return true
            case 0x0041...0x005A, 0x0061...0x007A,  // Basic Latin
                 0x00C0...0x00D6, 0x00D8...0x00F6, 0x00F8...0x00FF, // Latin-1 Supplement
                 0x0100...0x024F,  // Latin Extended-A & B
                 0x0370...0x03FF,  // Greek
                 0x0400...0x04FF:  // Cyrillic
                return false
            default:
                continue
            }
        }
        return false
    }

    func containsInsensitive<S: StringProtocol>(_ s: S) -> Bool {
        self.range(of: s, options: .caseInsensitive) != nil
    }

    func firstMatch(_ pattern: String) -> NSTextCheckingResult? {
        try! NSRegularExpression(pattern: pattern)
            .firstMatch(in: self, range: self.range)
    }

    func removeMatches(_ pattern: String) -> String {
        try! NSRegularExpression(pattern: pattern)
            .stringByReplacingMatches(
                in: self, 
                range: self.range,
                withTemplate: ""
            )
    }
    
    var isCanBeRomanizedLanguage: Bool {
        ["ja", "ko", "z1"].contains(self) || self.contains("zh")
    }
    
    var hexadecimal: Data? {
        var data = Data(capacity: count / 2)
        
        let regex = try! NSRegularExpression(pattern: "[0-9a-f]{1,2}", options: .caseInsensitive)
        regex.enumerateMatches(in: self, range: NSRange(startIndex..., in: self)) { match, _, _ in
            let byteString = (self as NSString).substring(with: match!.range)
            let num = UInt8(byteString, radix: 16)!
            data.append(num)
        }
        
        guard data.count > 0 else { return nil }
        
        return data
    }
}
