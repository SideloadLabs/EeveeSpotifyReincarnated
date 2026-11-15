import Foundation

struct OfflineAudioSource: Sendable {
    let url: URL
    let duration: TimeInterval
}

enum OfflineRecordingMatch {
    static func normalized(_ value: String) -> String {
        cleanHtmlEntities(value)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "$", with: "s")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func duration(_ actual: TimeInterval, matches expected: TimeInterval) -> Bool {
        actual.isFinite && actual > 0 && expected.isFinite && expected > 0 &&
            abs(actual - expected) <= min(5, max(1, expected * 0.025))
    }

    static func titleWithoutCredits(_ title: String) -> String {
        title.replacingOccurrences(of: #"\s*[\[(](?:feat\.?|ft\.?|featuring)\s+[^)\]]+[)\]]"#,
                                   with: "", options: [.regularExpression, .caseInsensitive])
    }

    static func primaryCredit(_ artist: String) -> String {
        artist.components(separatedBy: ", ").first ?? artist
    }

    static func credits(_ artist: String) -> [String] {
        artist.replacingOccurrences(of: "\u{00a0}", with: " ")
            .replacingOccurrences(of: " & ", with: ", ")
            .components(separatedBy: ", ").filter { !$0.isEmpty }
    }

    static func matches(title: String, artist: String, item: QueuedTrackItem, duration: TimeInterval) -> Bool {
        let expectedTitle = normalized(titleWithoutCredits(item.title))
        let expectedArtist = normalized(item.artist)
        let candidateArtist = normalized(artist)
        guard !expectedTitle.isEmpty, !expectedArtist.isEmpty,
              normalized(titleWithoutCredits(title)) == expectedTitle ||
                (item.id.hasPrefix("track-apple-") && item.duration != nil && matchesCensored(title, expected: item.title)),
              duration.isFinite, duration > 0,
              item.duration.map({ Self.duration(duration, matches: $0) }) ?? true else { return false }
        if candidateArtist == expectedArtist { return true }
        guard item.duration != nil else { return false }
        let actualLatin = normalized(artist.applyingTransform(.toLatin, reverse: false) ?? artist)
        let expectedLatin = normalized(item.artist.applyingTransform(.toLatin, reverse: false) ?? item.artist)
        return !actualLatin.isEmpty && actualLatin == expectedLatin
    }

    static func matchesCensored(_ title: String, expected: String) -> Bool {
        guard let stars = expected.range(of: #"\*{3,}"#, options: .regularExpression) else { return false }
        let prefix = String(expected[..<stars.lowerBound])
        let suffix = String(expected[stars.upperBound...])
        guard prefix.last?.isLetter == true, suffix.first?.isLetter == true, !suffix.contains("*"),
              normalized(prefix + suffix).count >= 6 else { return false }
        let pattern = "^" + NSRegularExpression.escapedPattern(for: normalized(prefix)) + "[\\p{L}]{1,16}"
            + NSRegularExpression.escapedPattern(for: normalized(suffix)) + "$"
        return normalized(title).range(of: pattern, options: .regularExpression) != nil
    }
}

final class OfflineHTTPSRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    private let allowedHost: String?

    init(allowedHost: String? = nil) {
        self.allowedHost = allowedHost
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let url = request.url
        completionHandler(url?.scheme == "https" && (allowedHost == nil || url?.host == allowedHost) ? request : nil)
    }
}

final class FreeAudioSourceResolver: Sendable {
    static let shared = FreeAudioSourceResolver()
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 8
        session = URLSession(configuration: config, delegate: OfflineHTTPSRedirects(), delegateQueue: nil)
    }

    enum Provider: CaseIterable, Sendable {
        case lMusic, hitparad, muzLink, mp3PM, commons, muzofond, mp3party, driveMusic, monochrome, lightAudio, rilds
        case audset, zvu4it, muzrecord, muzdrop, netease

        static let fast: [Self] = [.lMusic, .hitparad, .muzLink, .mp3PM, .commons, .muzofond, .mp3party, .driveMusic]
        static let reserves: [Self] = [.lightAudio, .rilds, .monochrome, .audset, .zvu4it, .muzrecord, .muzdrop, .netease]

        var needsDuration: Bool {
            [.commons, .muzLink, .audset, .zvu4it, .muzrecord, .muzdrop, .netease].contains(self)
        }

        func allowsAudioURL(_ url: URL) -> Bool {
            guard let host = url.host, url.scheme == "https", url.user == nil,
                  url.password == nil, url.port == nil else { return false }
            switch self {
            case .audset: return host == "audset.net" && url.path.hasPrefix("/api/v1/tracks/")
            case .zvu4it:
                return host.hasSuffix(".zvu4it.org") &&
                    (url.path.hasPrefix("/mp3-download/") || url.path.hasPrefix("/download-track/")) &&
                    url.pathExtension.lowercased() == "mp3"
            case .muzrecord:
                return host == "s.muzrecord.com" && url.path.hasPrefix("/mp3/") && url.pathExtension.lowercased() == "mp3"
            case .muzdrop:
                return host == "muzdrop.net" && url.path.hasPrefix("/uploads/") && url.pathExtension.lowercased() == "mp3"
            case .netease: return host.hasSuffix(".music.126.net") && url.pathExtension.lowercased() == "mp3"
            default: return true
            }
        }

        var audioReferer: String? {
            switch self {
            case .zvu4it: return "https://zvu4it.org/"
            case .muzrecord: return "https://muzrecord.com/"
            case .muzdrop: return "https://muzdrop.net/"
            case .netease: return "https://music.163.com/"
            default: return nil
            }
        }

        static func preferred(in region: OfflineSearchRegion) -> [Self] {
            switch region {
            case .automatic: return fast
            case .russia: return [.lMusic, .hitparad, .muzofond, .muzLink, .mp3party, .driveMusic, .audset]
            case .europe: return [.lMusic, .hitparad, .muzLink, .mp3PM, .commons, .zvu4it]
            }
        }
    }

    static func searchQueries(_ item: QueuedTrackItem, provider: Provider? = nil) -> [String] {
        let primary = OfflineRecordingMatch.primaryCredit(item.artist)
        let title = OfflineRecordingMatch.titleWithoutCredits(item.title)
        let base = title.components(separatedBy: " - ").first ?? title
        let unadorned = base.replacingOccurrences(of: #"\s*[\[(][^\])]+[\])]"#, with: "", options: .regularExpression)
        let fullQuery = "\(item.artist) \(item.title)"
        let versionQuery = fullQuery.replacingOccurrences(of: #"[\[\]().+]"#, with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let variants: [String]
        switch provider {
        case .audset, .muzrecord, .muzdrop:
            variants = [title, "\(primary) \(title)"]
        case .zvu4it:
            variants = [fullQuery, title]
        case .netease:
            variants = ["\(primary) \(title)", "\(primary) \(unadorned)".folding(options: .diacriticInsensitive, locale: nil)]
        default:
            variants = [fullQuery, "\(primary) \(title)", title,
                        "\(primary) \(title)".replacingOccurrences(of: "$", with: "s"),
                        "\(primary) \(unadorned)", unadorned]
                + OfflineRecordingMatch.credits(item.artist).dropFirst().prefix(2).map { "\($0) \(title)" }
                + (unadorned == title ? [] : [versionQuery])
        }
        var seen = Set<String>()
        let uncensoredQuery = item.id.hasPrefix("track-apple-") && title.contains("***")
            ? title.replacingOccurrences(of: #"\p{L}+\*{3,}\p{L}+"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces) : ""
        return (variants + (uncensoredQuery.isEmpty ? [] : ["\(primary) \(uncensoredQuery)"]))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    func resolve(_ provider: Provider, item: QueuedTrackItem, query override: String? = nil) async throws -> [OfflineAudioSource] {
        guard !provider.needsDuration || item.duration != nil else { return [] }
        let query = override ?? "\(item.artist) \(item.title)"
        let url: URL
        switch provider {
        case .lMusic:
            url = Self.url("https://lmusic.kz/search", ["q": query])
        case .hitparad:
            url = URL(string: "https://hitparad.fm/tracks/")!.appendingPathComponent(Self.searchWords(query))
        case .muzLink:
            url = Self.url("https://muzlink.net/search", ["q": query])
        case .muzofond:
            let path = Self.searchWords(query)
            url = URL(string: "https://muzofond.fm/music/")!.appendingPathComponent(path)
        case .mp3party:
            url = Self.url("https://mp3party.net/search", ["q": query])
        case .driveMusic:
            url = Self.url("https://ru.drivemusic.me/", ["do": "search", "subaction": "search", "story": query])
        case .lightAudio:
            url = URL(string: "https://web.ligaudio.ru/mp3/")!.appendingPathComponent(query)
        case .rilds:
            let slug = OfflineRecordingMatch.normalized(query.applyingTransform(.toLatin, reverse: false) ?? query)
                .split(separator: " ").joined(separator: "-")
            guard !slug.isEmpty, slug.utf8.count <= 63,
                  slug.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
                  let search = URL(string: "https://\(slug).rilds.net/") else { return [] }
            url = search
        case .mp3PM:
            let ascii = OfflineRecordingMatch.normalized(query.applyingTransform(.toLatin, reverse: false) ?? query)
                .utf8.filter { (97...122).contains($0) || (48...57).contains($0) || $0 == 32 }
            let slug = String(decoding: ascii, as: UTF8.self).split(separator: " ").joined(separator: "-")
            guard !slug.isEmpty, slug.utf8.count <= 61,
                  let search = URL(string: "https://s-\(slug).mp3.pm/") else { return [] }
            url = search
        case .commons:
            let title = item.title.replacingOccurrences(of: "\"", with: " ")
            url = Self.url("https://commons.wikimedia.org/w/api.php", [
                "action": "query", "format": "json", "formatversion": "2", "generator": "search",
                "gsrnamespace": "6", "gsrlimit": "6", "gsrsearch": "intitle:\"\(title)\" filetype:audio",
                "prop": "imageinfo", "iiprop": "url|mime|extmetadata", "iiextmetadatafilter": "Artist|License|ObjectName"
            ])
        case .monochrome:
            url = Self.url("https://tracks.monochrome.st/search/tracks", ["q": query, "limit": "10"])
        case .audset:
            var parts = URLComponents(string: "https://audset.net")!
            parts.percentEncodedPath = "/search/" + (query.lowercased().addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
            guard let search = parts.url else { return [] }
            url = search
        case .zvu4it:
            url = URL(string: "https://zvu4it.org/tracks/")!.appendingPathComponent(query)
        case .muzrecord, .muzdrop:
            let host = provider == .muzrecord ? "muzrecord.com" : "muzdrop.net"
            url = Self.url("https://\(host)/index.php", ["do": "search", "subaction": "search", "story": query])
        case .netease:
            return try await neteaseSources(item, query: query)
        }
        let data = try await request(url)
        if provider == .monochrome { return Self.monochromeSources(data, item: item) }
        if provider == .commons { return Self.commonsSources(data, item: item) }
        guard let html = String(data: data, encoding: .utf8) else { return [] }
        return Self.mp3Sources(html, provider: provider, item: item)
    }

    static func mp3Sources(_ html: String, provider: Provider, item: QueuedTrackItem) -> [OfflineAudioSource] {
        guard !provider.needsDuration || item.duration != nil else { return [] }
        let candidates: [(String, String, String, TimeInterval)]
        var declaredBitrates: [String: Int] = [:]
        switch provider {
        case .lMusic:
            let rows = matches(#"(<div class="c-card-mp3\b[^>]*\bdata-artist_name="[^"]+"[^>]*>.*?class="c-card-mp3__duration[^"]*"[^>]*>\s*\d+:\d{2}\s*</div>)"#, html)
            candidates = rows.compactMap { row in
                let entry = row[0]
                guard let artist = matches(#"data-artist_name="([^"]+)""#, entry).first?.first,
                      let title = matches(#"data-song_name="([^"]+)""#, entry).first?.first,
                      let id = matches(#"data-download_url="/api/download/(\d+)""#, entry).first?.first,
                      let time = matches(#"class="c-card-mp3__duration[^"]*"[^>]*>\s*(\d+):(\d{2})\s*</div>"#, entry).first
                else { return nil }
                return (artist, title, "https://lmusic.kz/api/download/\(id)", seconds(time[0], time[1]))
            }
        case .hitparad:
            let scripts = matches(#"self\.__next_f\.push\(\[1,("(?:[^"\\]|\\.)*")\]\)"#, html)
            let pattern = #""artist":("(?:[^"\\]|\\.)*"),"title":("(?:[^"\\]|\\.)*"),"version":("(?:[^"\\]|\\.)*"),"duration":(\d+),"bitrate":(\d+),"size":\d+,"play":("(?:[^"\\]|\\.)*")"#
            candidates = scripts.compactMap { jsonString($0[0]) }.flatMap { matches(pattern, $0) }.compactMap { fields in
                guard let artist = jsonString(fields[0]), let title = jsonString(fields[1]),
                      let version = jsonString(fields[2]), let bitrate = Int(fields[4]), (120...325).contains(bitrate),
                      let url = jsonString(fields[5]),
                      let host = URL(string: url)?.host, host.hasSuffix(".hitparad.fm") else { return nil }
                declaredBitrates[url] = bitrate
                let name = version.isEmpty || OfflineRecordingMatch.normalized(title)
                    .hasSuffix(OfflineRecordingMatch.normalized(version)) ? title : "\(title) (\(version))"
                return (artist, name, url, Double(fields[3]) ?? 0)
            }
        case .muzLink:
            guard let duration = item.duration else { return [] }
            let rows = matches(#"onclick="gpPlay\(\[([^\]]*)\],\s*'([^']*)',\s*'([^']*)'"#, html)
            candidates = rows.flatMap { row in
                matches(#"'(/dl/[A-Za-z0-9_-]+\?stream=1)'"#, row[0]).map {
                    (row[2], row[1], "https://muzlink.net\($0[0])", duration)
                }
            }
        case .muzofond:
            let pattern = #"<li class="item"[^>]*data-duration="(\d+)"[^>]*>.*?<li class="play"[^>]*data-url="([^"]+)".*?<span class="artist">(.*?)</span>.*?<span class="track">(.*?)</span>"#
            candidates = matches(pattern, html).map { ($0[2], $0[3], $0[1], Double($0[0]) ?? 0) }
        case .mp3party:
            let pattern = #"data-js-artist-name="([^"]+)"[^>]*data-js-song-title="([^"]+)"[^>]*data-js-url="([^"]+)".*?<div class="track__info-item">\s*(\d+):(\d{2})\s*</div>"#
            candidates = matches(pattern, html).map { ($0[0], $0[1], $0[2], seconds($0[3], $0[4])) }
        case .driveMusic:
            candidates = html.components(separatedBy: #"class="music-popular-wrapper""#).dropFirst().compactMap { block in
                guard let url = matches(#"data-url="([^"]+)""#, block).first?.first,
                      let title = matches(#"class="popular-play-author">([^<]+)</a>"#, block).first?.first,
                      let artist = matches(#"popular-play-composition.*?<a[^>]*>([^<]+)</a>"#, block).first?.first,
                      let time = matches(#"class="popular-download-number">\s*(\d+):(\d{2})\s*</div>"#, block).first
                else { return nil }
                return (artist, title, url, seconds(time[0], time[1]))
            }
        case .mp3PM:
            let rows = matches(#"(<li\b[^>]*class="cplayer-sound-item\b[^"]*"[^>]*>.*?</li>)"#, html)
            candidates = rows.compactMap { row in
                let entry = row[0]
                guard let rawURL = matches(#"data-sound-url="([^"]+)""#, entry).first?.first,
                      let url = URL(string: cleanHtmlEntities(rawURL)), let host = url.host,
                      host.hasSuffix(".mp3.pm"), url.path.hasPrefix("/listen/"), url.pathExtension.lowercased() == "mp3",
                      let artist = matches(#"class="cplayer-data-sound-author"[^>]*>(.*?)</i>"#, entry).first?.first,
                      let title = matches(#"class="cplayer-data-sound-title"[^>]*>(.*?)</b>"#, entry).first?.first,
                      let time = matches(#"class="cplayer-data-sound-time"[^>]*>\s*(\d+):(\d{2})\s*</em>"#, entry).first
                else { return nil }
                return (artist, title, rawURL, seconds(time[0], time[1]))
            }
        case .commons, .monochrome, .netease:
            return []
        case .lightAudio:
            let pattern = #"<span class="title" itemprop="name">(.*?)</span>.*?<span class="autor" itemprop="byArtist">(.*?)</span>.*?<span class="d">\s*(\d+):(\d+)\s*</span>.*?<a class="down"[^>]*href="(//storage[0-9]+\.lightaudio\.ru/dm/[^"]+)""#
            candidates = matches(pattern, html).map { ($0[1], $0[0], "https:" + $0[4], seconds($0[2], $0[3])) }
        case .rilds:
            candidates = html.components(separatedBy: #"class="playlist-btn""#).dropFirst().compactMap { row in
                guard let credit = matches(#"class="playlist-down" title="Download ([^"]+)""#, row).first?.first,
                      let separator = credit.range(of: " - "),
                      let time = matches(#"class="playlist-duration">\s*(\d+):(\d+)"#, row).first,
                      let audio = matches(#"data-url="(https://fine\.sunproxy\.net/file/[^"]+\.mp3)""#, row).first?.first
                else { return nil }
                return (String(credit[..<separator.lowerBound]), String(credit[separator.upperBound...]),
                        audio, seconds(time[0], time[1]))
            }
        case .audset:
            let pattern = #"<a href="/track/(\d{1,12})" class="track-title">(.*?)</a>\s*<span class="artist-credits[^"]*"[^>]*>(.*?)</span>\s*(?:<!---->)?\s*</div>\s*<span class="track-duration">(\d+):(\d{2})</span>"#
            candidates = matches(pattern, html).map { row in
                let artists = matches(#"<a href="/artist/\d+"[^>]*>(.*?)</a>"#, row[2]).map { $0[0] }.joined(separator: ", ")
                return (artists, row[1], "https://audset.net/api/v1/tracks/\(row[0])/download", seconds(row[3], row[4]))
            }
        case .zvu4it:
            candidates = html.components(separatedBy: #"<div class="f-table">"#).dropFirst().compactMap { row in
                guard let artist = matches(#"class="artist-name"[^>]*>(.*?)</div>"#, row).first?.first,
                      let title = matches(#"class="track-name"[^>]*>(.*?)</div>"#, row).first?.first,
                      let time = matches(#"class="time-text"[^>]*>\s*(\d+):(\d{2})\s*</div>"#, row).first,
                      let audio = matches(#"class="mp3"\s+href="((?:https:)?//[^"]+)""#, row).first?.first else { return nil }
                return (artist, title, audio.hasPrefix("//") ? "https:" + audio : audio, seconds(time[0], time[1]))
            }
        case .muzrecord, .muzdrop:
            candidates = html.components(separatedBy: #"data-track=""#).dropFirst().compactMap { row in
                guard let end = row.firstIndex(of: ">"), let quote = row.firstIndex(of: "\""), quote < end,
                      let artist = matches(#"data-artist="([^"]+)""#, String(row[..<end])).first?.first,
                      let time = matches(#"class="track-time">\s*(\d+):(\d{2})\s*</div>"#, row).first else { return nil }
                let audio = String(row[..<quote])
                let title = matches(#"data-title="([^"]+)""#, String(row[..<end])).first?.first
                if let title { return (artist, title, audio, seconds(time[0], time[1])) }
                guard provider == .muzdrop, let separator = artist.range(of: " - ") else { return nil }
                let name = String(artist[separator.upperBound...])
                    .replacingOccurrences(of: #"\s*(?:\(полная версия\)|полная версия)\s*$"#, with: "",
                                          options: [.regularExpression, .caseInsensitive])
                return (String(artist[..<separator.lowerBound]), name, audio, seconds(time[0], time[1]))
            }
        }

        let sources = candidates.compactMap { artist, title, rawURL, duration -> OfflineAudioSource? in
            let artistName = text(artist)
            let credits = OfflineRecordingMatch.credits(artistName)
            let targets = [item.artist] + OfflineRecordingMatch.credits(item.artist)
            guard ([artistName] + credits).contains(where: { credit in
                targets.contains { target in
                    let recording = QueuedTrackItem(id: item.id, title: item.title, artist: target, duration: item.duration)
                    return OfflineRecordingMatch.matches(title: text(title), artist: credit, item: recording, duration: duration)
                }
            }), let url = URL(string: cleanHtmlEntities(rawURL)), provider.allowsAudioURL(url),
                  url.pathExtension.lowercased() != "flac" else { return nil }
            return OfflineAudioSource(url: url, duration: duration)
        }
        if provider == .muzLink { return Array(sources.prefix(5)) }
        let expected = item.duration
        let ordered = sources.sorted { left, right in
            let leftBitrate = declaredBitrates[left.url.absoluteString] ?? 0
            let rightBitrate = declaredBitrates[right.url.absoluteString] ?? 0
            if leftBitrate != rightBitrate { return leftBitrate > rightBitrate }
            return expected.map { abs(left.duration - $0) < abs(right.duration - $0) } ?? false
        }
        var seen = Set<URL>()
        return Array(ordered.filter { seen.insert($0.url).inserted }.prefix(3))
    }

    private func neteaseSources(_ item: QueuedTrackItem, query: String) async throws -> [OfflineAudioSource] {
        let endpoint = "https://music-api.gdstudio.xyz/api.php"
        let search = try await request(Self.url(endpoint, [
            "types": "search", "source": "netease", "name": query, "count": "6", "pages": "1"
        ]))
        guard let rows = try JSONSerialization.jsonObject(with: search) as? [[String: Any]] else { return [] }
        let ids = rows.compactMap { row -> String? in
            guard let id = row["id"] as? String, (1...14).contains(id.utf8.count),
                  id.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return id
        }
        guard !ids.isEmpty else { return [] }
        let detail = try await request(Self.url("https://music.163.com/api/song/detail/", ["ids": "[\(ids.joined(separator: ","))]"]))
        var sources: [OfflineAudioSource] = []
        for (id, duration) in try Self.neteaseTracks(detail, item: item, ids: Set(ids)).prefix(2) {
            for quality in ["320", "192"] {
                let lookup = Self.url(endpoint, ["types": "url", "source": "netease", "id": id, "br": quality])
                try Task.checkCancellation()
                guard let data = try? await request(lookup), let url = try? Self.neteaseAudioURL(data) else { continue }
                if !sources.contains(where: { $0.url == url }) { sources.append(.init(url: url, duration: duration)) }
                break
            }
        }
        return sources
    }

    static func neteaseTracks(_ data: Data, item: QueuedTrackItem, ids: Set<String>) throws -> [(String, TimeInterval)] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let songs = json["songs"] as? [[String: Any]] else { return [] }
        return songs.compactMap { track in
            guard let id = track["id"] as? Int64, ids.contains(String(id)),
                  let title = track["name"] as? String, let ms = track["duration"] as? Double,
                  let artists = track["artists"] as? [[String: Any]] else { return nil }
            let duration = ms / 1000
            let credits = artists.compactMap { $0["name"] as? String }.joined(separator: ", ")
            guard OfflineRecordingMatch.matches(title: title, artist: credits, item: item, duration: duration) else { return nil }
            return (String(id), duration)
        }
    }

    static func neteaseAudioURL(_ data: Data) throws -> URL? {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let bitrate = json["br"] as? Int, (120...325).contains(bitrate),
              let raw = json["url"] as? String, let url = URL(string: raw),
              Provider.netease.allowsAudioURL(url) else { return nil }
        return url
    }

    static let commonsUserAgent = "EeveeSpotifyOffline/1.0 (https://github.com/SideloadLabs/EeveeSpotifyReincarnated)"

    static func commonsSources(_ data: Data, item: QueuedTrackItem) -> [OfflineAudioSource] {
        guard let duration = item.duration,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = json["query"] as? [String: Any], let pages = query["pages"] as? [[String: Any]] else { return [] }
        return pages.compactMap { page in
            guard let info = (page["imageinfo"] as? [[String: Any]])?.first,
                  info["mime"] as? String == "audio/mpeg",
                  let fields = info["extmetadata"] as? [String: [String: String]],
                  let license = fields["License"]?["value"],
                  license.range(of: #"^(?:cc-by(?:-sa)?-[1-4]\.[05]|cc-zero|pd)$"#, options: .regularExpression) != nil,
                  let title = fields["ObjectName"]?["value"], let artist = fields["Artist"]?["value"],
                  let rawURL = info["url"] as? String, let url = URL(string: rawURL),
                  url.scheme == "https", url.host == "upload.wikimedia.org",
                  url.path.hasPrefix("/wikipedia/commons/"), url.pathExtension.lowercased() == "mp3" else { return nil }
            let name = text(title).replacingOccurrences(of: #"\s*\(ISRC [A-Z0-9]{12}\)$"#, with: "", options: .regularExpression)
            guard OfflineRecordingMatch.matches(title: name, artist: text(artist), item: item, duration: duration) else { return nil }
            return OfflineAudioSource(url: url, duration: duration)
        }
    }

    private static func searchWords(_ query: String) -> String {
        query.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ").lowercased()
    }

    private static func jsonString(_ value: String) -> String? {
        try? JSONDecoder().decode(String.self, from: Data(value.utf8))
    }

    private static func text(_ html: String) -> String {
        cleanHtmlEntities(html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
    }

    private static func monochromeSources(_ data: Data, item: QueuedTrackItem) -> [OfflineAudioSource] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tracks = json["tracks"] as? [[String: Any]] else { return [] }
        let matches = tracks.compactMap { track -> (OfflineAudioSource, Bool)? in
            guard track["playable"] as? Bool != false, let title = track["title"] as? String,
                  let artists = track["artistNames"] as? [String], !artists.isEmpty,
                  let id = track["trackId"] as? String ?? track["id"] as? String,
                  OfflineLibraryStore.validID(id),
                  let milliseconds = track["duration"] as? Double,
                  artists.contains(where: { artist in
                      ([item.artist] + OfflineRecordingMatch.credits(item.artist)).contains { credit in
                          let target = QueuedTrackItem(id: item.id, title: item.title, artist: credit, duration: item.duration)
                          return OfflineRecordingMatch.matches(title: title, artist: artist, item: target, duration: milliseconds / 1000)
                      }
                  })
            else { return nil }
            let url = URL(string: "https://tracks.monochrome.st/track/")!.appendingPathComponent(id)
            return (OfflineAudioSource(url: url, duration: milliseconds / 1000), artists.count == 1)
        }
        return (matches.filter { $0.1 } + matches.filter { !$0.1 }).map { $0.0 }
    }

    func catalogAlbum(_ hint: OfflineSpotifyCollection.AlbumHint) async throws -> OfflineSpotifyCollection.Result {
        let search = Self.url("https://api.deezer.com/search/album", ["q": hint.title, "limit": "15"])
        let data = try await request(search)
        let ids = OfflineSpotifyCollection.catalogAlbumIDs(data, matching: hint)
        guard !ids.isEmpty, ids.count <= 6 else {
            throw OfflinePlayerError.incompleteCollection
        }
        return try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            for id in ids {
                group.addTask {
                    let url = URL(string: "https://api.deezer.com/album/\(id)")!
                    return (id, try await self.request(url))
                }
            }
            var candidates: [(Int, Data)] = []
            for try await response in group {
                candidates.append(response)
            }
            for checkDate in [true, false] {
                let matches = candidates.compactMap { id, data in
                    try? OfflineSpotifyCollection.catalogAlbum(data, id: id, matching: hint, checkDate: checkDate)
                }
                if matches.count == 1, let match = matches.first { return match }
            }
            throw OfflinePlayerError.incompleteCollection
        }
    }

    func appleAlbum(_ hint: OfflineSpotifyCollection.AlbumHint) async throws -> OfflineSpotifyCollection.Result {
        let search = Self.url("https://music.apple.com/us/search", ["term": "\(hint.artist) \(hint.title)"])
        let html = String(decoding: try await request(search), as: UTF8.self)
        let urls = OfflineSpotifyCollection.appleAlbumURLs(html, matching: hint)
        guard !urls.isEmpty, urls.count <= 4 else { throw OfflinePlayerError.incompleteCollection }
        var matches: [OfflineSpotifyCollection.Result] = []
        for url in urls {
            let album = String(decoding: try await request(url), as: UTF8.self)
            if let result = OfflineSpotifyCollection.appleAlbum(album, url: url, matching: hint) {
                matches.append(result)
            }
        }
        guard matches.count == 1, let result = matches.first else { throw OfflinePlayerError.incompleteCollection }
        return result
    }

    struct Metadata: Sendable {
        let duration: TimeInterval
        let cover: URL?
    }

    func metadata(for item: QueuedTrackItem) async -> Metadata? {
        let query = "\(OfflineRecordingMatch.primaryCredit(item.artist)) \(OfflineRecordingMatch.titleWithoutCredits(item.title))"
        let apple = Self.url("https://itunes.apple.com/search", ["term": query, "entity": "song", "limit": "12"])
        let deezer = Self.url("https://api.deezer.com/search", ["q": query, "limit": "12"])
        return await withTaskGroup(of: Metadata?.self) { group in
            for url in [apple, deezer] {
                group.addTask {
                    guard let data = try? await self.request(url) else { return nil }
                    return Self.catalogMetadata(data, item: item, deezer: url == deezer)
                }
            }
            for await result in group {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }
    }

    func matchingSourceDuration(for item: QueuedTrackItem) async -> TimeInterval? {
        await withTaskGroup(of: [TimeInterval].self) { group in
            for provider in [Provider.lMusic, .hitparad, .monochrome] {
                group.addTask { (try? await self.resolve(provider, item: item))?.map(\.duration) ?? [] }
            }
            var durations: [[TimeInterval]] = []
            for await result in group { durations.append(result) }
            return Self.agreedDuration(durations)
        }
    }

    static func agreedDuration(_ reports: [[TimeInterval]]) -> TimeInterval? {
        let fullTracks = reports.map { $0.filter { $0 >= 60 && $0.isFinite } }
        let corroborated = fullTracks.flatMap { $0 }.filter { candidate in
            fullTracks.filter { $0.contains { OfflineRecordingMatch.duration($0, matches: candidate) } }.count >= 2
        }.sorted()
        guard let first = corroborated.first, let last = corroborated.last,
              OfflineRecordingMatch.duration(last, matches: first) else { return nil }
        return corroborated[corroborated.count / 2]
    }

    static func catalogMetadata(_ data: Data, item: QueuedTrackItem, deezer: Bool) -> Metadata? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json[deezer ? "data" : "results"] as? [[String: Any]] else { return nil }
        let expectedArtist = OfflineRecordingMatch.primaryCredit(item.artist)
        for track in results {
            let title = track[deezer ? "title" : "trackName"] as? String
            let artist = deezer ? (track["artist"] as? [String: Any])?["name"] as? String : track["artistName"] as? String
            let artwork = deezer ? (track["album"] as? [String: Any])?["cover_medium"] as? String : track["artworkUrl100"] as? String
            guard let title, let artist,
                  let value = track[deezer ? "duration" : "trackTimeMillis"] as? Double else { continue }
            let duration = deezer ? value : value / 1000
            let exactTarget = QueuedTrackItem(id: item.id, title: item.title, artist: expectedArtist)
            let credits = artist.replacingOccurrences(of: " & ", with: ", ").components(separatedBy: ", ")
            guard ([artist] + credits).contains(where: {
                OfflineRecordingMatch.matches(title: title, artist: $0, item: exactTarget, duration: duration)
            }) else { continue }
            return Metadata(duration: duration, cover: artwork.flatMap { URL(string: $0) })
        }
        return nil
    }

    func cover(_ url: URL) async throws -> Data {
        try await request(url, maxBytes: 2_000_000)
    }

    private func request(_ url: URL, maxBytes: Int = 3_000_000) async throws -> Data {
        guard url.scheme == "https" else { throw URLError(.unsupportedURL) }
        var request = URLRequest(url: url)
        let agent = url.host == "commons.wikimedia.org" ? Self.commonsUserAgent :
            "Mozilla/5.0 (iPhone; CPU iPhone OS 16_1 like Mac OS X) AppleWebKit/605.1.15"
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        if url.host == "music-api.gdstudio.xyz" {
            request.setValue("https://music-api.gdstudio.xyz/", forHTTPHeaderField: "Referer")
        } else if url.host == "tracks.monochrome.st" {
            request.setValue("https://monochrome.st/", forHTTPHeaderField: "Referer")
            request.setValue("https://monochrome.st", forHTTPHeaderField: "Origin")
        }
        guard #available(iOS 15.0, *) else { throw URLError(.unsupportedURL) }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            Self.logCatalogFailure(host: url.host, code: error.code.rawValue)
            throw error
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= maxBytes else {
            Self.logCatalogFailure(host: url.host, code: (response as? HTTPURLResponse)?.statusCode ?? 0)
            throw URLError(.badServerResponse)
        }
        return data
    }

    private static func logCatalogFailure(host: String?, code: Int) {
        #if os(iOS)
        if let host, ["api.deezer.com", "itunes.apple.com", "music.apple.com"].contains(host), code != URLError.cancelled.rawValue {
            EeveeLog.write("[Offline] Catalog metadata failure \(code) at \(host)")
        }
        #endif
    }

    private static func url(_ base: String, _ query: [String: String]) -> URL {
        var parts = URLComponents(string: base)!
        parts.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return parts.url!
    }

    private static func seconds(_ minutes: String, _ seconds: String) -> TimeInterval {
        (Double(minutes) ?? 0) * 60 + (Double(seconds) ?? 0)
    }

    private static func matches(_ pattern: String, _ input: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return [] }
        let text = input as NSString
        return regex.matches(in: input, range: NSRange(location: 0, length: text.length)).map { match in
            (1..<match.numberOfRanges).map { text.substring(with: match.range(at: $0)) }
        }
    }
}
