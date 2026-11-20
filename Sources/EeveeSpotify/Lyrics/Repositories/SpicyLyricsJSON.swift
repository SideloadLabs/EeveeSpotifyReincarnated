import Foundation

enum SpicyLyricsJSON {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([SpicyLyricsJSON])
    case object([String: SpicyLyricsJSON])

    init(_ json: Any) {
        switch json {
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            self = CFGetTypeID(number) == CFBooleanGetTypeID()
                ? .bool(number.boolValue)
                : .number(number.doubleValue)
        case let array as [Any]:
            self = .array(array.map(SpicyLyricsJSON.init))
        case let object as [String: Any]:
            self = .object(object.mapValues(SpicyLyricsJSON.init))
        default:
            self = .null
        }
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var doubleValue: Double? {
        if case .number(let d) = self { return d }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var arrayValue: [SpicyLyricsJSON]? {
        if case .array(let a) = self { return a }
        return nil
    }

    subscript(key: String) -> SpicyLyricsJSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
}
