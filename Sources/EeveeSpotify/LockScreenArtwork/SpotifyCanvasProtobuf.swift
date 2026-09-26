import Foundation

enum ProtoValue {
    case varint(UInt64)
    case lengthDelimited(Data)
    case fixed32(UInt32)
    case fixed64(UInt64)
}

enum ProtoWire {
    // MARK: Encoding

    static func varintBytes(_ value: UInt64) -> Data {
        var value = value
        var bytes = [UInt8]()
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while value != 0
        return Data(bytes)
    }

    /// A single length-delimited (wire type 2) field: tag + varint length + payload.
    static func lengthDelimitedField(_ fieldNumber: UInt64, _ payload: Data) -> Data {
        var out = varintBytes((fieldNumber << 3) | 2)
        out.append(varintBytes(UInt64(payload.count)))
        out.append(payload)
        return out
    }

    static func stringField(_ fieldNumber: UInt64, _ value: String) -> Data {
        lengthDelimitedField(fieldNumber, Data(value.utf8))
    }

    // MARK: Decoding

    static func parseFields(_ data: Data) -> [UInt64: [ProtoValue]]? {
        var fields: [UInt64: [ProtoValue]] = [:]
        var index = data.startIndex

        func readVarint() -> UInt64? {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while index < data.endIndex {
                let byte = data[index]
                index = data.index(after: index)
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
                if shift >= 64 { return nil }
            }
            return nil
        }

        while index < data.endIndex {
            guard let tag = readVarint() else { return nil }
            let fieldNumber = tag >> 3
            let wireType = tag & 0x7

            switch wireType {
            case 0: // varint
                guard let value = readVarint() else { return nil }
                fields[fieldNumber, default: []].append(.varint(value))
            case 1: // fixed64
                guard data.distance(from: index, to: data.endIndex) >= 8 else { return nil }
                let end = data.index(index, offsetBy: 8)
                let bytes = [UInt8](data[index..<end])
                index = end
                let value = bytes.withUnsafeBytes { $0.load(as: UInt64.self) }
                fields[fieldNumber, default: []].append(.fixed64(UInt64(littleEndian: value)))
            case 2: // length-delimited
                guard let length = readVarint() else { return nil }
                guard data.distance(from: index, to: data.endIndex) >= Int(length) else { return nil }
                let end = data.index(index, offsetBy: Int(length))
                let payload = Data(data[index..<end])
                index = end
                fields[fieldNumber, default: []].append(.lengthDelimited(payload))
            case 5: // fixed32
                guard data.distance(from: index, to: data.endIndex) >= 4 else { return nil }
                let end = data.index(index, offsetBy: 4)
                let bytes = [UInt8](data[index..<end])
                index = end
                let value = bytes.withUnsafeBytes { $0.load(as: UInt32.self) }
                fields[fieldNumber, default: []].append(.fixed32(UInt32(littleEndian: value)))
            default:
                // Wire types 3/4 (deprecated groups) never appear in canvaz's schema.
                return nil
            }
        }
        return fields
    }

    static func string(_ value: ProtoValue?) -> String? {
        guard case .lengthDelimited(let data)? = value else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func varintValue(_ value: ProtoValue?) -> UInt64? {
        guard case .varint(let v)? = value else { return nil }
        return v
    }
}

/// A track's Canvas — its looping video background — as plain data.
struct SpotifyCanvas {
    let identifier: String
    let address: String
    let isVideo: Bool
}

enum SpotifyCanvazAPI {
    static func requestBody(trackURI: String) -> Data {
        let entity = ProtoWire.stringField(1, trackURI)
        return ProtoWire.lengthDelimitedField(1, entity)
    }

    static func canvas(from body: Data) -> SpotifyCanvas? {
        guard let fields = ProtoWire.parseFields(body),
              case .lengthDelimited(let canvazBytes)? = fields[1]?.first,
              let canvazFields = ProtoWire.parseFields(canvazBytes),
              let address = ProtoWire.string(canvazFields[2]?.first), !address.isEmpty
        else { return nil }

        let identifier = ProtoWire.string(canvazFields[1]?.first)
            ?? ProtoWire.string(canvazFields[3]?.first)
            ?? String(address.hashValue)
        let type = ProtoWire.varintValue(canvazFields[4]?.first) ?? 0
        return SpotifyCanvas(identifier: identifier, address: address, isVideo: (1...3).contains(type))
    }

    static func canvas(fromTrackMetadata metadata: [String: String]) -> SpotifyCanvas? {
        guard let address = metadata["canvas.url"], !address.isEmpty else { return nil }
        let type = metadata["canvas.type"] ?? ""
        let identifier = metadata["canvas.id"] ?? metadata["canvas.fileId"] ?? String(address.hashValue)
        return SpotifyCanvas(identifier: identifier, address: address, isVideo: type.hasPrefix("VIDEO"))
    }
}
