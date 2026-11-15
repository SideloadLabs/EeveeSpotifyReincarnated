import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public func extractSpotifyId(from uriStr: String, type: String = "") -> String {
    let value = uriStr.removingPercentEncoding ?? uriStr
    let kinds = type.isEmpty ? ["track", "playlist", "album"] : [type]
    for kind in kinds {
        let parts = value.split(separator: ":")
        if parts.count == 3, parts[0] == "spotify", parts[1] == kind,
           let id = parts[2].split(separator: "?").first, isSpotifyID(id) { return String(id) }
        if kind == "playlist", parts.count == 5, parts[0] == "spotify", parts[1] == "user", parts[3] == "playlist",
           let id = parts[4].split(separator: "?").first, isSpotifyID(id) { return String(id) }
        if let url = URL(string: value), url.scheme == "https", url.host == "open.spotify.com",
           url.pathComponents.count >= 3,
           url.pathComponents.dropLast().last == kind, let id = url.pathComponents.last,
           isSpotifyID(Substring(id)) { return id }
    }
    return ""
}

private func isSpotifyID(_ id: Substring) -> Bool {
    id.utf8.count == 22 && id.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }
}

enum OfflineSpotifyIdentifier {
    private static let collectionKinds = [
        "плейлист": "playlist", "playlist": "playlist",
        "открытый плейлист": "playlist", "закрытый плейлист": "playlist", "приватный плейлист": "playlist",
        "совместный плейлист": "playlist", "public playlist": "playlist", "private playlist": "playlist",
        "collaborative playlist": "playlist",
        "альбом": "album", "сингл": "album", "мини-альбом": "album", "мини‑альбом": "album", "сборник": "album",
        "album": "album", "single": "album", "ep": "album", "compilation": "album"
    ]
    private static let menuSeparators = CharacterSet(charactersIn: "•·\n")

    static func collectionLink(_ input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        for kind in ["playlist", "album"] {
            let id = extractSpotifyId(from: text, type: kind)
            if !id.isEmpty { return URL(string: "spotify:\(kind):\(id)") }
        }
        return nil
    }

    static func collectionLinks(from request: URLRequest?) -> [URL] {
        guard let url = request?.url, url.scheme == "https", let host = url.host,
              host == "spotify.com" || host.hasSuffix(".spotify.com") else { return [] }
        let parts = url.pathComponents
        if let playlist = parts.firstIndex(of: "playlist"), parts.dropFirst(playlist + 1).first == "v2",
           let id = parts.dropFirst(playlist + 2).last, isSpotifyID(id[...]) {
            return [URL(string: "spotify:playlist:\(id)")!]
        }
        if parts.starts(with: ["/", "playlist-permission", "v1", "album"]), parts.count == 5 {
            let id = parts[4]
            if isSpotifyID(id[...]) { return [URL(string: "spotify:album:\(id)")!] }
        }
        guard parts.contains("extended-metadata"), let body = request?.httpBody,
              body.count <= 256 * 1024 else { return [] }
        let text = String(decoding: body, as: UTF8.self)
        let matches = collectionURIRegex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        return matches.prefix(24).compactMap { match in
            Range(match.range, in: text).flatMap { collectionLink(String(text[$0])) }
        }
    }

    private static let collectionURIRegex = try! NSRegularExpression(
        pattern: #"spotify:(?:album|playlist):[A-Za-z0-9]{22}(?![A-Za-z0-9])"#
    )

    static func isMenuText(_ text: String) -> Bool {
        let value = cleanHtmlEntities(text).lowercased()
        return !value.isEmpty && value != "показать код spotify" && value != "show spotify code"
    }

    static func menuFields(_ values: [String]) -> (title: String, subtitle: String) {
        let lines = values.flatMap { $0.split(whereSeparator: \.isNewline) }
            .map { cleanHtmlEntities(String($0)) }.filter(isMenuText)
        guard let title = lines.first else { return ("", "") }
        if let combined = splitCollectionTitle(title) { return combined }
        if let subtitle = lines.indices.dropFirst().first(where: {
            lines[$0].rangeOfCharacter(from: menuSeparators) != nil || menuCollectionKind(lines[$0]) != nil
        }) {
            return (lines[..<subtitle].joined(separator: " "), lines[subtitle])
        }
        return (title, lines.count == 2 ? lines[1] : "")
    }

    static func menuArtist(_ subtitle: String) -> String? {
        guard menuCollectionKind(subtitle) == nil else { return nil }
        let artist = cleanHtmlEntities(subtitle.components(separatedBy: menuSeparators).first ?? "")
        return isMenuText(artist) ? artist : nil
    }

    static func menuCollectionKind(_ subtitle: String) -> String? {
        let prefix = subtitle.components(separatedBy: menuSeparators).first ?? ""
        return collectionLabelKind(prefix)
    }

    private static func collectionLabelKind(_ label: String) -> String? {
        let text = cleanHtmlEntities(label).lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if text.range(of: #"^[0-9][0-9., ]* (?:сохранение|сохранения|сохранений|saves?)$"#,
                      options: .regularExpression) != nil { return "playlist" }
        return collectionKinds[text]
    }

    static func splitCollectionTitle(_ value: String) -> (title: String, subtitle: String)? {
        var remainder = value[...]
        while let separator = remainder.rangeOfCharacter(from: menuSeparators) {
            remainder = value[separator.upperBound...]
            let end = remainder.rangeOfCharacter(from: menuSeparators)?.lowerBound ?? value.endIndex
            let label = cleanHtmlEntities(String(value[separator.upperBound..<end]))
            let title = cleanHtmlEntities(String(value[..<separator.lowerBound]))
            if !title.isEmpty, collectionLabelKind(label) != nil { return (title, label) }
        }
        return nil
    }
}
