import Foundation

enum SponsorBlockFormatters {
    static func time(_ s: Double) -> String {
        let sec = max(0, s)
        let h = Int(sec) / 3600
        let m = (Int(sec) % 3600) / 60
        let secPart = sec.truncatingRemainder(dividingBy: 60)
        if h > 0 { return String(format: "%d:%02d:%05.2f", h, m, secPart) }
        return String(format: "%d:%05.2f", m, secPart)
    }

    static func shortTime(_ s: Double) -> String {
        let sec = max(0, s)
        let m = Int(sec) / 60
        let r = Int(sec) % 60
        return String(format: "%d:%02d", m, r)
    }

    static func categoryName(_ key: String) -> String {
        switch key {
        case "sponsor":          return "Sponsor"
        case "selfpromo":        return "Self-Promo"
        case "interaction":      return "Interaction"
        case "intro":            return "Intro"
        case "outro":            return "Outro"
        case "preview":          return "Preview"
        case "hook":             return "Hook"
        case "filler":           return "Filler"
        case "exclusive_access": return "Exclusive Access"
        default:                 return key
        }
    }

    static func categoryShortName(_ key: String) -> String {
        switch key {
        case "sponsor":          return "sponsor"
        case "selfpromo":        return "self-promo"
        case "interaction":      return "interaction"
        case "intro":            return "intro"
        case "outro":            return "outro"
        case "preview":          return "preview"
        case "hook":             return "hook"
        case "filler":           return "filler"
        case "exclusive_access": return "exclusive access"
        default:                 return key
        }
    }
}
