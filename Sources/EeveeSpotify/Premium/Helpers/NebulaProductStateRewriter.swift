import Foundation

// Spotify 9.2 replaced the UCS bootstrap/customize client with "Nebula":
// product state now arrives from spclient `nebula/v1/configuration/attributes`
// as `Nebula_GetAttributesResponse`, which `NebulaProductStateMapper` turns
// into the core's product state. The old `modifyRemoteConfiguration` path never
// runs on 9.2 because no bootstrap/customize response is ever fetched.
//
// The generated Swift types for that response are not exposed to the Objective-C
// runtime and their field numbers are not published, so this rewriter works on
// the wire format directly: it walks the protobuf tree and rewrites the value of
// every submessage that pairs a known product-state key with one. Matching on
// shape rather than field number keeps it working if Spotify renumbers the
// message. A submessage is re-encoded only when something inside it changed, so
// unknown fields survive byte for byte.
enum NebulaProductStateRewriter {

    // Mirrors forcedPremiumString in EeveePremiumForce.x.swift. Kept local so
    // this file compiles standalone for its test suite.
    private static let forcedValues: [String: String] = [
        "type": "premium",
        "catalogue": "premium",
        "product": "premium",
        "name": "Spotify Premium",
        "player-license": "premium",
        "player-license-v2": "premium",
        "financial-product": "pr:premium,tc:0",

        "ads": "0",
        "ab-ad-player-targeting": "0",
        "allow-advertising-id-transmission": "0",
        "restrict-advertising-id-transmission": "1",
        "audio-ad-frequency": "0",
        "video-ad-frequency": "0",
        "ad-formats": "",

        "on-demand": "1",
        "unrestricted": "1",
        "shuffle-eligible": "1",
        "social-connect": "1",
        "tracks-in-collection-enabled": "1",

        "streaming-rules": "",
        "previous-streaming-rules": "",
        "high-bitrate": "1",
        "shuffle": "0",
        "shuffle-mode": "0",
        "pick-and-shuffle": "0",

        // Plan-shaped keys Spotify 9.2 ships in Nebula. A paid account reports
        // no free/mini tier and no trial, which is what keeps the subscribe
        // surfaces (Premium tab, upsell entry points) from being built.
        "nft-disabled": "1",
        "is-mobile-only-tier": "0",
        "premium-mini": "0",
        "premium-only-market-mobile": "0",
        "on-demand-trial": "0",
        "on-demand-trial-in-progress": "0",
        "is-eligible-premium-unboxing": "0",
        "premium-unboxing-auto-open": "0",
        "referrals-entrypoint-eligible": "0",
        "streaming": "1",
        "offline": "1",
    ]

    struct Report {
        let data: Data
        let rewritten: [String]
    }

    /// Returns the rewritten payload, or nil when nothing was changed.
    static func rewrite(_ data: Data) -> Data? {
        rewriteReporting(data)?.data
    }

    /// Same rewrite, plus the attribute keys it touched, so a debug log can
    /// record which product-state keys this Spotify build shipped. Keys only:
    /// the values belong to the account.
    static func rewriteReporting(_ data: Data) -> Report? {
        guard var nodes = parseMessage(data), !nodes.isEmpty else { return nil }
        var rewritten: [String] = []
        guard rewriteMessage(&nodes, &rewritten) else { return nil }
        return Report(data: encodeMessage(nodes), rewritten: rewritten)
    }

    // MARK: - Wire model

    fileprivate enum Value {
        case varint(UInt64)
        case fixed64(Data)
        case fixed32(Data)
        case bytes(raw: Data, children: [Node]?)
    }

    fileprivate struct Node {
        let number: UInt64
        var value: Value
    }

    // MARK: - Rewriting

    private static func rewriteMessage(
        _ nodes: inout [Node],
        _ rewritten: inout [String]
    ) -> Bool {
        var changed = false

        // Depth first: a nested attribute list is rewritten before this level.
        for index in nodes.indices {
            if case .bytes(let raw, var children) = nodes[index].value, children != nil {
                if rewriteMessage(&children!, &rewritten) {
                    nodes[index].value = .bytes(raw: raw, children: children)
                    changed = true
                }
            }
        }

        // An attribute message pairs a key string with its value. Find the key
        // first, then the value field that sits beside it.
        guard let keyIndex = nodes.firstIndex(where: { node in
            guard case .bytes(let raw, _) = node.value,
                  let text = String(data: raw, encoding: .utf8) else { return false }
            return forcedValues[text] != nil
        }) else {
            return changed
        }

        guard case .bytes(let keyRaw, _) = nodes[keyIndex].value,
              let key = String(data: keyRaw, encoding: .utf8),
              let forced = forcedValues[key] else {
            return changed
        }

        for index in nodes.indices where index != keyIndex {
            if setValue(&nodes[index], to: forced) {
                rewritten.append(key)
                changed = true
                break
            }
        }

        return changed
    }

    /// Writes `forced` into one value node, matching however the value is carried:
    /// a plain string, a varint, or a single-field "oneof" wrapper submessage.
    private static func setValue(_ node: inout Node, to forced: String) -> Bool {
        switch node.value {

        case .varint:
            guard let number = numericValue(of: forced) else { return false }
            node.value = .varint(number)
            return true

        case .bytes(let raw, let children):
            if var inner = children, inner.count == 1 {
                if setValue(&inner[0], to: forced) {
                    node.value = .bytes(raw: raw, children: inner)
                    return true
                }
                return false
            }

            guard String(data: raw, encoding: .utf8) != nil else { return false }
            node.value = .bytes(raw: Data(forced.utf8), children: nil)
            return true

        case .fixed64, .fixed32:
            return false
        }
    }

    /// Product-state booleans travel as "0"/"1" strings; a varint field needs the number.
    private static func numericValue(of forced: String) -> UInt64? {
        if let direct = UInt64(forced) { return direct }
        return nil
    }

    // MARK: - Decoding

    fileprivate static func parseMessage(_ data: Data) -> [Node]? {
        var nodes: [Node] = []
        var offset = data.startIndex

        while offset < data.endIndex {
            guard let (tag, afterTag) = readVarint(data, offset) else { return nil }
            let number = tag >> 3
            let wireType = tag & 0x07
            guard number != 0 else { return nil }
            offset = afterTag

            switch wireType {
            case 0:
                guard let (value, next) = readVarint(data, offset) else { return nil }
                nodes.append(Node(number: number, value: .varint(value)))
                offset = next

            case 1:
                guard data.distance(from: offset, to: data.endIndex) >= 8 else { return nil }
                let end = data.index(offset, offsetBy: 8)
                nodes.append(Node(number: number, value: .fixed64(data[offset..<end])))
                offset = end

            case 2:
                guard let (length, afterLength) = readVarint(data, offset),
                      length <= UInt64(data.distance(from: afterLength, to: data.endIndex))
                else { return nil }
                let end = data.index(afterLength, offsetBy: Int(length))
                let raw = Data(data[afterLength..<end])
                // Only treat it as a submessage when it parses cleanly AND
                // re-encodes to the same bytes, so raw payloads stay untouched.
                var children: [Node]? = nil
                if !raw.isEmpty, let parsed = parseMessage(raw), encodeMessage(parsed) == raw {
                    children = parsed
                }
                nodes.append(Node(number: number, value: .bytes(raw: raw, children: children)))
                offset = end

            case 5:
                guard data.distance(from: offset, to: data.endIndex) >= 4 else { return nil }
                let end = data.index(offset, offsetBy: 4)
                nodes.append(Node(number: number, value: .fixed32(data[offset..<end])))
                offset = end

            default:
                return nil
            }
        }

        return nodes
    }

    private static func readVarint(_ data: Data, _ start: Data.Index) -> (UInt64, Data.Index)? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var index = start

        while index < data.endIndex {
            let byte = data[index]
            if shift > 63 { return nil }
            result |= UInt64(byte & 0x7F) << shift
            index = data.index(after: index)
            if byte & 0x80 == 0 { return (result, index) }
            shift += 7
        }

        return nil
    }

    // MARK: - Encoding

    fileprivate static func encodeMessage(_ nodes: [Node]) -> Data {
        var out = Data()

        for node in nodes {
            switch node.value {
            case .varint(let value):
                appendVarint(&out, node.number << 3 | 0)
                appendVarint(&out, value)

            case .fixed64(let value):
                appendVarint(&out, node.number << 3 | 1)
                out.append(value)

            case .bytes(let raw, let children):
                let payload = children.map { encodeMessage($0) } ?? raw
                appendVarint(&out, node.number << 3 | 2)
                appendVarint(&out, UInt64(payload.count))
                out.append(payload)

            case .fixed32(let value):
                appendVarint(&out, node.number << 3 | 5)
                out.append(value)
            }
        }

        return out
    }

    private static func appendVarint(_ data: inout Data, _ value: UInt64) {
        var remaining = value
        repeat {
            var byte = UInt8(remaining & 0x7F)
            remaining >>= 7
            if remaining != 0 { byte |= 0x80 }
            data.append(byte)
        } while remaining != 0
    }
}
