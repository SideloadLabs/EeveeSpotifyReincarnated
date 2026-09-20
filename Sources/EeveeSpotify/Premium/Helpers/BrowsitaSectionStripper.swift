import Foundation

// Strips ad and upsell sections from home/browse/Now Playing feed protobufs.

enum BrowsitaSectionStripper {

    private static let hardAdMarkers: [[UInt8]] = [
        "spotify:ad:", "open.spotify.com/ad/", "ad-formats", "advertisement", "brand-ad",
        "sponsored", "marquee", "promoted", "home-ads", "adsproduct",
        "leavebehind", "leave-behind", "premium-upsell", "premium_upsell",
        "premiumupsell", "referralsupsellcard",
    ].map { Array($0.utf8) }

    // Generic "upsell" metadata is not enough to delete a whole section. It
    // must describe a visible promotional surface too.
    private static let promotionalIntentMarkers: [[UInt8]] = [
        "upsell", "upgrade", "subscribe", "premium", "promo", "promotion",
        "marketing", "offer",
    ].map { Array($0.utf8) }

    private static let promotionalSurfaceMarkers: [[UInt8]] = [
        "banner", "card", "popup", "pop-up", "sheet", "interstitial",
        "promotion", "promo",
    ].map { Array($0.utf8) }

    private static let keepMarkers: [[UInt8]] = [
        "filter", "chip", "pillar", "browse:chips",
    ].map { Array($0.utf8) }

    static var verboseLog: Bool = false

    static func shouldHandle(_ url: URL) -> Bool {
        let p = url.path.lowercased()
        // /casita/v1/feeds is flat tab-chip list, parser would mis-walk it.
        if p.hasSuffix("/casita/v1/feeds") || p.contains("/casita/v1/feeds/") { return false }
        return p.contains("/browsita/") || p.contains("/casita/")
            || p.contains("/scrollsita/")
    }

    static func strip(_ data: Data, url: URL? = nil) -> Data? {
        let path = url?.path ?? "?"

        // Real scrollsita responses (NpvScrollResponse) have never used
        // browsita's outer sections container, and feeding them to the
        // container parser risks silently mis-slicing bytes on unlucky
        // layouts. They get the wire-level surgical pass exclusively.
        if path.lowercased().contains("/scrollsita/") {
            return surgicallyDropRepeatedAdEntries(data, path: path)
        }
        if let stripped = stripContainerLayout(data, path: path) { return stripped }
        // casita/browsita with an unexpected layout: hard-marker-only fallback.
        return surgicallyDropRepeatedAdEntries(data, path: path)
    }

    // browsita/casita layout: outer 0x0a container of repeated 0x0a sections.
    private static func stripContainerLayout(_ data: Data, path: String) -> Data? {
        var cursor = 0
        guard data.count >= 2, data[cursor] == 0x0a else { return bail(path, "no-outer-tag") }
        cursor += 1
        guard let (outerLen, outerLenBytes) = readVarint(data, at: cursor) else { return bail(path, "bad-outer-varint") }
        cursor += outerLenBytes
        let containerStart = cursor
        let containerEnd = cursor + Int(outerLen)
        guard containerEnd <= data.count else { return bail(path, "outer-len-overflow") }

        var newContainer = Data()
        var dropped = 0, kept = 0, idx = 0
        var c = containerStart

        while c < containerEnd {
            guard c < data.count, data[c] == 0x0a else { return bail(path, "section-tag-mismatch idx=\(idx)") }
            let sectionTagStart = c
            c += 1
            guard let (secLen, secLenBytes) = readVarint(data, at: c) else { return bail(path, "bad-section-varint idx=\(idx)") }
            c += secLenBytes
            let contentStart = c
            let contentEnd = c + Int(secLen)
            guard contentEnd <= containerEnd else { return bail(path, "section-len-overflow idx=\(idx)") }

            if let markers = adHits(data, start: contentStart, end: contentEnd) {
                if verboseLog { writeDebugLog("[STRIP] DROP \(path) idx=\(idx) size=\(secLen) hits=\(markers.joined(separator: ","))") }
                dropped += 1
            } else {
                if verboseLog { writeDebugLog("[STRIP] KEEP \(path) idx=\(idx) size=\(secLen)") }
                newContainer.append(data.subdata(in: sectionTagStart..<contentEnd))
                kept += 1
            }
            c = contentEnd
            idx += 1
        }

        guard dropped > 0 else { return nil }

        var result = Data()
        result.append(0x0a)
        result.append(encodeVarint(UInt64(newContainer.count)))
        result.append(newContainer)
        if containerEnd < data.count {
            result.append(data.subdata(in: containerEnd..<data.count))
        }
        writeDebugLog("[STRIP] \(path) dropped=\(dropped) kept=\(kept) \(data.count)->\(result.count)")
        return result
    }

    // MARK: - Generic wire fallback (scrollsita et al.)

    // Walks raw protobuf wire format and only removes bytes carrying an ad
    // verdict (same adHits logic as the section parser):
    //   - members of a *repeated* field group (>=2 same-numbered siblings)
    //     are cut individually, leaving legit siblings byte-identical;
    //   - singleton carriers are recursed into to reach the repeated group;
    //   - a singleton that cannot be walked further takes the parser's
    //     wholesale-drop verdict;
    //   - unparsable bytes and ad-free payloads pass through untouched, so
    //     unknown layouts degrade to a no-op.
    private static func surgicallyDropRepeatedAdEntries(_ data: Data, path: String) -> Data? {
        var dropped = 0
        guard let rebuilt = dropAdFields(in: data, start: 0, end: data.count, depth: 0, dropped: &dropped),
              dropped > 0 else { return nil }
        writeDebugLog("[STRIP] \(path) surgically dropped=\(dropped) \(data.count)->\(rebuilt.count)")
        return rebuilt
    }

    private static func dropAdFields(in data: Data, start: Int, end: Int, depth: Int, dropped: inout Int) -> Data? {
        guard depth < 24, end > start else { return nil }

        var fields: [(number: Int, segment: Range<Int>, value: Range<Int>?, tagLen: Int)] = []
        var c = start
        while c < end {
            guard let (fieldNumber, wireType, tagLen) = readTag(data, at: c, end: end) else { return nil }
            let segmentStart = c
            c += tagLen
            var valueRange: Range<Int>? = nil
            switch wireType {
            case 0:
                guard let (_, n) = readVarint(data, at: c, end: end) else { return nil }
                c += n
            case 1:
                guard c + 8 <= end else { return nil }
                c += 8
            case 5:
                guard c + 4 <= end else { return nil }
                c += 4
            case 2:
                guard let (len, n) = readVarint(data, at: c, end: end),
                      len <= UInt64(end - c - n) else { return nil }
                c += n
                valueRange = c..<(c + Int(len))
                c = valueRange!.upperBound
            default:
                return nil // SGROUP/EGROUP never appear in Spotify's feeds
            }
            fields.append((fieldNumber, segmentStart..<c, valueRange, tagLen))
        }
        guard !fields.isEmpty else { return nil }

        var counts: [Int: Int] = [:]
        for f in fields { counts[f.number, default: 0] += 1 }

        var dropIndices = Set<Int>()
        var replacements: [Int: Data] = [:]
        for (i, f) in fields.enumerated() {
            guard let value = f.value else { continue }
            let hard = hardMarkerHits(data, start: value.lowerBound, end: value.upperBound)
            // Same verdict family as the section parser: hard evidence wins
            // over keep markers; heuristic intent+surface only when no keep
            // guard fires.
            let verdict = !hard.isEmpty
                || adHits(data, start: value.lowerBound, end: value.upperBound) != nil
            guard verdict else { continue }
            if counts[f.number, default: 0] >= 2 {
                dropIndices.insert(i) // repeated member → surgically removable
            } else if let inner = dropAdFields(in: data, start: value.lowerBound, end: value.upperBound,
                                               depth: depth + 1, dropped: &dropped) {
                replacements[i] = inner // singleton carrier → operate on the repeated group inside
            } else if !hard.isEmpty {
                // Singleton leaf with unambiguous hard evidence: same
                // wholesale-drop verdict the section parser gives such content.
                dropIndices.insert(i)
            }
            // Heuristic-only singletons stay: intent+surface markers can
            // combine across sibling sections inside a carrier and must not
            // trigger a wholesale drop.
        }
        guard !dropIndices.isEmpty || !replacements.isEmpty else { return nil }

        var out = Data()
        for (i, f) in fields.enumerated() {
            if dropIndices.contains(i) {
                dropped += 1
            } else if let replacement = replacements[i] {
                // Re-emit the carrier: original tag bytes (excluding the old
                // length varint) + re-encoded length + rebuilt interior.
                out.append(data[f.segment.lowerBound..<(f.segment.lowerBound + f.tagLen)])
                out.append(encodeVarint(UInt64(replacement.count)))
                out.append(replacement)
            } else {
                out.append(data[f.segment])
            }
        }
        return out
    }

    private static func readTag(_ data: Data, at: Int, end: Int) -> (fieldNumber: Int, wireType: Int, length: Int)? {
        guard let (tag, tagLen) = readVarint(data, at: at, end: end) else { return nil }
        let fieldNumber = Int(tag >> 3)
        guard fieldNumber >= 1, fieldNumber <= (1 << 29) - 1 else { return nil }
        return (fieldNumber, Int(tag) & 7, tagLen)
    }

    private static func hardMarkerHits(_ data: Data, start: Int, end: Int) -> [String] {
        guard end > start, end <= data.count else { return [] }
        let slice = data[start..<end]
        return hardAdMarkers.compactMap {
            containsASCIIInsensitive(slice, needle: $0) ? String(decoding: $0, as: UTF8.self) : nil
        }
    }

    private static func adHits(_ data: Data, start: Int, end: Int) -> [String]? {
        guard end > start, end <= data.count else { return nil }
        let slice = data[start..<end]
        let hardHits = hardMarkerHits(data, start: start, end: end)
        if !hardHits.isEmpty { return hardHits }

        for keep in keepMarkers where containsASCIIInsensitive(slice, needle: keep) { return nil }

        let intentHits = promotionalIntentMarkers.compactMap {
            containsASCIIInsensitive(slice, needle: $0) ? String(decoding: $0, as: UTF8.self) : nil
        }
        guard !intentHits.isEmpty else { return nil }

        let surfaceHits = promotionalSurfaceMarkers.compactMap {
            containsASCIIInsensitive(slice, needle: $0) ? String(decoding: $0, as: UTF8.self) : nil
        }
        return surfaceHits.isEmpty ? nil : intentHits + surfaceHits
    }

    private static func bail(_ path: String, _ reason: String) -> Data? {
        if verboseLog { writeDebugLog("[STRIP] bail \(path) reason=\(reason)") }
        return nil
    }

    private static func containsASCIIInsensitive(_ haystack: Data.SubSequence, needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        let last = haystack.endIndex - needle.count
        var i = haystack.startIndex
        while i <= last {
            var match = true
            for k in 0..<needle.count {
                if asciiLower(haystack[i + k]) != asciiLower(needle[k]) {
                    match = false
                    break
                }
            }
            if match { return true }
            i += 1
        }
        return false
    }

    private static func asciiLower(_ byte: UInt8) -> UInt8 {
        (0x41...0x5a).contains(byte) ? byte + 0x20 : byte
    }

    private static func readVarint(_ data: Data, at: Int, end: Int? = nil) -> (UInt64, Int)? {
        let bound = end ?? data.count
        var value: UInt64 = 0
        var shift: UInt64 = 0
        var bytesRead = 0
        var idx = at
        while idx < bound && bytesRead < 10 {
            let b = data[idx]
            value |= UInt64(b & 0x7f) << shift
            shift += 7
            bytesRead += 1
            idx += 1
            if (b & 0x80) == 0 { return (value, bytesRead) }
        }
        return nil
    }

    private static func encodeVarint(_ v: UInt64) -> Data {
        var value = v
        var result = Data()
        while value >= 0x80 {
            result.append(UInt8((value & 0x7f) | 0x80))
            value >>= 7
        }
        result.append(UInt8(value))
        return result
    }
}
