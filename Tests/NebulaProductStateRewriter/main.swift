import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAIL: \(message)") }
}

private func varint(_ value: UInt64) -> Data {
    var out = Data()
    var remaining = value
    repeat {
        var byte = UInt8(remaining & 0x7F)
        remaining >>= 7
        if remaining != 0 { byte |= 0x80 }
        out.append(byte)
    } while remaining != 0
    return out
}

private func tag(_ number: UInt64, _ wireType: UInt64) -> Data {
    varint(number << 3 | wireType)
}

private func stringField(_ number: UInt64, _ value: String) -> Data {
    let payload = Data(value.utf8)
    return tag(number, 2) + varint(UInt64(payload.count)) + payload
}

private func varintField(_ number: UInt64, _ value: UInt64) -> Data {
    tag(number, 0) + varint(value)
}

private func messageField(_ number: UInt64, _ payload: Data) -> Data {
    tag(number, 2) + varint(UInt64(payload.count)) + payload
}

private func fieldValues(_ data: Data) -> [String] {
    var out: [String] = []
    var index = data.startIndex

    func readVarint() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < data.endIndex {
            let byte = data[index]
            result |= UInt64(byte & 0x7F) << shift
            index = data.index(after: index)
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }

    while index < data.endIndex {
        guard let tagValue = readVarint() else { break }
        switch tagValue & 0x07 {
        case 0:
            if let value = readVarint() { out.append(String(value)) }
        case 2:
            guard let length = readVarint(),
                  data.distance(from: index, to: data.endIndex) >= Int(length) else { return out }
            let end = data.index(index, offsetBy: Int(length))
            let raw = Data(data[index..<end])
            index = end
            if let text = String(data: raw, encoding: .utf8), !text.isEmpty {
                out.append(text)
            }
            out.append(contentsOf: fieldValues(raw))
        case 1:
            guard data.distance(from: index, to: data.endIndex) >= 8 else { return out }
            index = data.index(index, offsetBy: 8)
        case 5:
            guard data.distance(from: index, to: data.endIndex) >= 4 else { return out }
            index = data.index(index, offsetBy: 4)
        default:
            return out
        }
    }

    return out
}

// A plain string attribute is forced to its Premium value.
let plainAttributes = messageField(1, stringField(1, "ads") + stringField(2, "1"))
    + messageField(1, stringField(1, "type") + stringField(2, "free"))

guard let plainRewritten = NebulaProductStateRewriter.rewrite(plainAttributes) else {
    fatalError("FAIL: plain attributes must be rewritten")
}
let plainValues = fieldValues(plainRewritten)
require(plainValues.contains("premium"), "type must become premium, got \(plainValues)")
require(!plainValues.contains("free"), "free must not survive, got \(plainValues)")
require(plainValues.contains("ads"), "ads key must be preserved, got \(plainValues)")

// A value wrapped in a single-field oneof submessage is rewritten in place.
let wrapped = messageField(1, stringField(1, "player-license") + messageField(2, stringField(3, "free")))
guard let wrappedRewritten = NebulaProductStateRewriter.rewrite(wrapped) else {
    fatalError("FAIL: wrapped attribute must be rewritten")
}
require(fieldValues(wrappedRewritten).contains("premium"), "wrapped value must become premium")

// A boolean carried as a varint takes the numeric form of the forced value.
let numeric = messageField(1, stringField(1, "on-demand") + varintField(2, 0))
guard let numericRewritten = NebulaProductStateRewriter.rewrite(numeric) else {
    fatalError("FAIL: numeric attribute must be rewritten")
}
require(fieldValues(numericRewritten).contains("1"), "on-demand varint must become 1")

// Attributes the tweak does not force are left exactly as they were.
let untouched = messageField(1, stringField(1, "country") + stringField(2, "FR"))
require(NebulaProductStateRewriter.rewrite(untouched) == nil, "unknown keys must not be rewritten")

// Unrelated fields around a rewritten attribute survive the round trip.
let mixed = stringField(7, "keep-me")
    + messageField(1, stringField(1, "ads") + stringField(2, "1"))
    + varintField(9, 4242)
guard let mixedRewritten = NebulaProductStateRewriter.rewrite(mixed) else {
    fatalError("FAIL: mixed payload must be rewritten")
}
let mixedValues = fieldValues(mixedRewritten)
require(mixedValues.contains("keep-me"), "sibling string field must survive, got \(mixedValues)")
require(mixedValues.contains("4242"), "sibling varint field must survive, got \(mixedValues)")

// Payloads that are not protobuf at all are rejected rather than corrupted.
require(NebulaProductStateRewriter.rewrite(Data()) == nil, "empty payload must be rejected")
require(
    NebulaProductStateRewriter.rewrite(Data([0xFF, 0xFF, 0xFF, 0xFF])) == nil,
    "malformed payload must be rejected"
)

print("NebulaProductStateRewriter tests passed")
