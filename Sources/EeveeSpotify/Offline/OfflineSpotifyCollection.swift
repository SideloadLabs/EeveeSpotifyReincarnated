import Foundation

enum OfflineSpotifyCollection {
    typealias JSONObject = [String: Any]

    enum Kind: String { case album, playlist }

    struct Result {
        let tracks: [QueuedTrackItem]
        let unavailable: Int
        let name: String?

        init(tracks: [QueuedTrackItem], unavailable: Int, name: String? = nil) {
            self.tracks = tracks
            self.unavailable = unavailable
            self.name = name
        }
    }

    struct AlbumHint: Sendable {
        let title: String
        let artist: String
        let trackIDs: [String]
        var releaseDate: String? = nil
        var visibleTracks: [QueuedTrackItem] = []
        var hasExplicitTrack = false
        var hasTrackOrder = false

        var loadedTracks: Result? {
            guard hasTrackOrder else { return nil }
            let visible = Dictionary(visibleTracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let loaded = trackIDs.compactMap { visible[$0] }
            guard !loaded.isEmpty else { return nil }
            return Result(tracks: loaded, unavailable: trackIDs.count - loaded.count, name: title)
        }
    }

    static func catalogAlbumIDs(_ data: Data, matching hint: AlbumHint) -> Set<Int> {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? JSONObject,
              let albums = json["data"] as? [JSONObject] else { return [] }
        return Set(albums.compactMap { album -> Int? in
            guard matchesCatalogAlbum(album, hint: hint), let id = album["id"] as? Int, id > 0 else { return nil }
            return id
        })
    }

    static func catalogAlbum(_ data: Data, id: Int, matching hint: AlbumHint, checkDate: Bool = false) throws -> Result {
        guard let album = try JSONSerialization.jsonObject(with: data) as? JSONObject,
              album["id"] as? Int == id, matchesCatalogAlbum(album, hint: hint),
              !checkDate || (hint.releaseDate != nil && album["release_date"] as? String == hint.releaseDate),
              !hint.hasExplicitTrack || album["explicit_lyrics"] as? Bool == true,
              let expected = album["nb_tracks"] as? Int, expected > 0,
              let list = (album["tracks"] as? JSONObject)?["data"] as? [JSONObject],
              list.count == expected else { throw OfflinePlayerError.incompleteCollection }
        var seen = Set<Int>()
        let tracks = list.compactMap { row -> QueuedTrackItem? in
            guard let id = row["id"] as? Int, id > 0, seen.insert(id).inserted,
                  let title = row["title"] as? String, !title.isEmpty,
                  let artist = (row["artist"] as? JSONObject)?["name"] as? String, !artist.isEmpty,
                  let duration = row["duration"] as? Double, duration > 0 else { return nil }
            return QueuedTrackItem(id: "track-deezer-\(id)", title: title, artist: artist, album: hint.title, duration: duration)
        }
        guard !tracks.isEmpty, matchesVisibleTracks(tracks, hint: hint) else { throw OfflinePlayerError.incompleteCollection }
        return Result(tracks: tracks, unavailable: expected - tracks.count, name: hint.title)
    }

    private static func matchesCatalogAlbum(_ album: JSONObject, hint: AlbumHint) -> Bool {
        guard let title = album["title"] as? String,
              let artist = (album["artist"] as? JSONObject)?["name"] as? String else { return false }
        return OfflineRecordingMatch.normalized(title) == OfflineRecordingMatch.normalized(hint.title)
            && OfflineRecordingMatch.normalized(artist) == OfflineRecordingMatch.normalized(hint.artist)
            && (album["nb_tracks"] as? Int ?? 0) >= hint.trackIDs.count
    }

    private static func matchesVisibleTracks(_ tracks: [QueuedTrackItem], hint: AlbumHint) -> Bool {
        hint.visibleTracks.allSatisfy { visible in
            tracks.contains { candidate in
                let title = OfflineRecordingMatch.titleWithoutCredits(visible.title)
                let expected = OfflineRecordingMatch.titleWithoutCredits(candidate.title)
                return OfflineRecordingMatch.normalized(title) == OfflineRecordingMatch.normalized(expected)
                    || (candidate.id.hasPrefix("track-apple-") && OfflineRecordingMatch.matchesCensored(title, expected: expected))
            }
        }
    }

    static func appleAlbumURLs(_ html: String, matching hint: AlbumHint) -> [URL] {
        let name = OfflineRecordingMatch.normalized(hint.title)
        var seen = Set<URL>()
        return appleSections(html).flatMap { $0["items"] as? [JSONObject] ?? [] }.compactMap { item in
            let title = item["title"] as? String ?? (item["titleLinks"] as? [JSONObject])?.first?["title"] as? String
            guard title.map(OfflineRecordingMatch.normalized) == name,
                  let descriptor = item["contentDescriptor"] as? JSONObject,
                  descriptor["kind"] as? String == "album",
                  let value = descriptor["url"] as? String, let url = URL(string: value),
                  appleAlbumID(url) != nil, seen.insert(url).inserted else { return nil }
            return url
        }
    }

    static func appleAlbum(_ html: String, url: URL, matching hint: AlbumHint) -> Result? {
        guard let id = appleAlbumID(url),
              let schema = scriptJSON(in: html, attribute: #"type="application/ld+json""#),
              schema["@type"] as? String == "MusicAlbum",
              let canonical = (schema["url"] as? String).flatMap(URL.init(string:)), appleAlbumID(canonical) == id,
              let title = schema["name"] as? String,
              OfflineRecordingMatch.normalized(title) == OfflineRecordingMatch.normalized(hint.title),
              let artists = schema["byArtist"] as? [JSONObject],
              artists.contains(where: {
                  ($0["name"] as? String).map(OfflineRecordingMatch.normalized) == OfflineRecordingMatch.normalized(hint.artist)
              }),
              hint.releaseDate == nil || schema["datePublished"] as? String == hint.releaseDate else { return nil }
        let sections = appleSections(html)
        guard let header = (sections.first { ($0["id"] as? String)?.hasPrefix("album-detail-header-section - ") == true }?["items"]
                            as? [JSONObject])?.first,
              let expected = header["trackCount"] as? Int, expected > 0, expected >= hint.trackIDs.count,
              !hint.hasExplicitTrack || header["showExplicitBadge"] as? Bool == true else { return nil }
        let rows = sections.filter { section in
            let container = section["containerContentDescriptor"] as? JSONObject
            let album = (container?["identifiers"] as? JSONObject)?["storeAdamID"] as? String
            return section["itemKind"] as? String == "trackLockup" && album == id
        }.flatMap { $0["items"] as? [JSONObject] ?? [] }
        guard rows.count == expected else { return nil }
        let tracks = rows.compactMap { row -> QueuedTrackItem? in
            let descriptor = row["contentDescriptor"] as? JSONObject
            let trackID = (descriptor?["identifiers"] as? JSONObject)?["storeAdamID"] as? String
            guard let trackID, Int(trackID).map({ $0 > 0 }) == true,
                  let name = row["title"] as? String, !name.isEmpty,
                  let artist = row["artistName"] as? String, !artist.isEmpty,
                  let milliseconds = row["duration"] as? Double, milliseconds.isFinite, milliseconds > 0 else { return nil }
            let original = hint.visibleTracks.first {
                OfflineRecordingMatch.matchesCensored($0.title, expected: name)
            }?.title
            return QueuedTrackItem(id: "track-apple-\(trackID)", title: original ?? name, artist: artist,
                                   album: hint.title, duration: milliseconds / 1000)
        }
        guard !tracks.isEmpty, matchesVisibleTracks(tracks, hint: hint) else { return nil }
        return Result(tracks: tracks, unavailable: expected - tracks.count, name: hint.title)
    }

    private static func appleAlbumID(_ url: URL) -> String? {
        let path = url.pathComponents
        guard url.scheme == "https", url.host == "music.apple.com", url.user == nil, url.password == nil,
              url.port == nil, url.query == nil, url.fragment == nil, path.count == 5, path[2] == "album",
              let id = path.last, Int(id).map({ $0 > 0 }) == true else { return nil }
        return id
    }

    private static func appleSections(_ html: String) -> [JSONObject] {
        let pages = scriptJSON(in: html, attribute: #"id="serialized-server-data""#)?["data"] as? [JSONObject]
        return (pages?.first?["data"] as? JSONObject)?["sections"] as? [JSONObject] ?? []
    }

    private static func scriptJSON(in html: String, attribute: String) -> JSONObject? {
        guard let start = html.range(of: attribute),
              let open = html[start.upperBound...].firstIndex(of: ">"),
              let close = html.range(of: "</script>", range: open..<html.endIndex) else { return nil }
        let data = Data(html[html.index(after: open)..<close.lowerBound].utf8)
        return try? JSONSerialization.jsonObject(with: data) as? JSONObject
    }

    static func load(id: String, kind: Kind, name: String, token: String?,
                     fetch: (URL, String?) async throws -> JSONObject) async throws -> Result {
        let paths = kind == .playlist ? ["playlists/\(id)/items", "playlists/\(id)/tracks"] : ["albums/\(id)/tracks"]
        var lastError: Error = OfflinePlayerError.incompleteCollection
        for path in paths {
            var page = URL(string: "https://api.spotify.com/v1/\(path)?limit=50")
            var visited = Set<URL>()
            var tracks: [QueuedTrackItem] = []
            var received = 0
            var total: Int?
            do {
                while let url = page {
                    guard url.scheme == "https", url.host == "api.spotify.com", url.port == nil,
                          url.user == nil, url.path == "/v1/\(path)",
                          visited.count < 300, visited.insert(url).inserted else {
                        throw OfflinePlayerError.incompleteCollection
                    }
                    let json = try await fetch(url, token)
                    guard let entries = json["items"] as? [Any],
                          let expected = json["total"] as? Int, expected >= 0,
                          total == nil || total == expected else { throw OfflinePlayerError.incompleteCollection }
                    total = expected
                    received += entries.count
                    tracks += entries.compactMap { entry in
                        guard let object = entry as? JSONObject, object["is_local"] as? Bool != true else { return nil }
                        let data = kind == .album ? object : (object["item"] ?? object["track"]) as? JSONObject
                        return data.flatMap { track($0, album: kind == .album ? name : nil) }
                    }
                    if let next = json["next"] as? String {
                        guard let url = URL(string: next), !entries.isEmpty else { throw OfflinePlayerError.incompleteCollection }
                        page = url
                    } else {
                        guard json["next"] is NSNull else { throw OfflinePlayerError.incompleteCollection }
                        page = nil
                    }
                }
                guard let total, total == received else { throw OfflinePlayerError.incompleteCollection }
                return Result(tracks: tracks, unavailable: total - tracks.count)
            } catch {
                try Task.checkCancellation()
                lastError = error
            }
        }
        throw lastError
    }

    static func track(_ data: JSONObject, album: String? = nil) -> QueuedTrackItem? {
        let id = (data["id"] as? String) ?? extractSpotifyId(from: data["uri"] as? String ?? "", type: "track")
        let publicArtists = ["firstArtist", "otherArtists"].flatMap {
            (data[$0] as? JSONObject)?["items"] as? [JSONObject] ?? []
        }
        let artistData = (data["artists"] as? JSONObject)?["items"] as? [JSONObject]
            ?? data["artists"] as? [JSONObject] ?? publicArtists
        let artist = artistData.compactMap { entry in
            (entry["profile"] as? JSONObject)?["name"] as? String ?? entry["name"] as? String
        }.filter { !$0.isEmpty }.joined(separator: ", ")
        let albumData = data["album"] as? JSONObject ?? data["albumOfTrack"] as? JSONObject
        let durationValue = data["duration_ms"] ?? (data["duration"] as? JSONObject)?["totalMilliseconds"]
        let milliseconds = (durationValue as? NSNumber)?.doubleValue
        guard data["is_local"] as? Bool != true, (data["type"] as? String ?? "track") == "track",
              OfflineLibraryStore.validID(id), id.count == 22,
              let title = data["name"] as? String, !title.isEmpty, !artist.isEmpty else { return nil }
        let artwork = (albumData?["images"] as? [JSONObject])?.last?["url"] as? String
            ?? ((albumData?["coverArt"] as? JSONObject)?["sources"] as? [JSONObject])?.last?["url"] as? String
        return QueuedTrackItem(id: id, title: title, artist: artist, album: albumData?["name"] as? String ?? album,
                               duration: milliseconds.flatMap { $0 > 0 ? $0 / 1000 : nil },
                               artwork: artwork.flatMap { URL(string: $0) })
    }

    static func embeddedTrack(_ html: String, id: String) -> QueuedTrackItem? {
        guard let start = html.range(of: #"id="__NEXT_DATA__""#),
              let open = html[start.upperBound...].firstIndex(of: ">"),
              let close = html.range(of: "</script>", range: open..<html.endIndex),
              let json = try? JSONSerialization.jsonObject(with: Data(html[html.index(after: open)..<close.lowerBound].utf8)) as? JSONObject,
              let props = (json["props"] as? JSONObject)?["pageProps"] as? JSONObject,
              let state = (props["state"] as? JSONObject)?["data"] as? JSONObject,
              var entity = state["entity"] as? JSONObject,
              entity["uri"] as? String == "spotify:track:\(id)", entity["type"] as? String == "track",
              let duration = entity["duration"] as? NSNumber else { return nil }
        entity["id"] = id
        entity["duration_ms"] = duration
        return track(entity)
    }

    static func publicTrack(_ html: String, id: String) -> QueuedTrackItem? {
        guard let entity = publicEntity(html, uri: "spotify:track:\(id)"),
              entity["uri"] as? String == "spotify:track:\(id)",
              let track = track(entity), track.id == id else { return nil }
        return track
    }

    static func publicCount(_ html: String, id: String, kind: Kind) -> Int? {
        guard let entity = publicEntity(html, uri: "spotify:\(kind.rawValue):\(id)"),
              let container = (entity["tracksV2"] ?? entity["tracks"] ?? entity["content"]) as? JSONObject
        else { return nil }
        return (container["totalCount"] ?? container["total"] ?? entity["totalTracks"]) as? Int
    }

    private static func publicEntity(_ html: String, uri: String) -> JSONObject? {
        guard let start = html.range(of: #"id="initialState" type="text/plain">"#),
              let end = html.range(of: "</script>", range: start.upperBound..<html.endIndex),
              let data = Data(base64Encoded: String(html[start.upperBound..<end.lowerBound])),
              let json = try? JSONSerialization.jsonObject(with: data) as? JSONObject,
              let entities = (json["entities"] as? JSONObject)?["items"] as? JSONObject
        else { return nil }
        return entities[uri] as? JSONObject
    }

    static func publicPage(_ html: String, id: String, kind: Kind, name: String,
                           expectedCount: Int? = nil, matchingTitle: String? = nil, allowPartial: Bool = false) throws -> Result {
        func matchesTitle(_ entity: JSONObject) -> Bool {
            guard let matchingTitle else { return true }
            guard let name = entity["name"] as? String, !name.isEmpty else { return false }
            return OfflineRecordingMatch.normalized(name) == OfflineRecordingMatch.normalized(matchingTitle)
        }
        for script in html.components(separatedBy: "<script").dropFirst() {
            guard let close = script.range(of: "</script>"), let open = script[..<close.lowerBound].firstIndex(of: ">")
            else { continue }
            let content = script[script.index(after: open)..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            let data = content.hasPrefix("ey") ? Data(base64Encoded: content) : content.data(using: .utf8)
            guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? JSONObject else { continue }
            let entityURI = "spotify:\(kind.rawValue):\(id)"
            if let entities = (json["entities"] as? JSONObject)?["items"] as? JSONObject {
                for (key, value) in entities {
                    guard let entity = value as? JSONObject,
                          key == entityURI || entity["uri"] as? String == entityURI || entity["id"] as? String == id,
                          matchesTitle(entity),
                          let container = (entity["tracksV2"] ?? entity["tracks"] ?? entity["content"]) as? JSONObject,
                          let items = container["items"] as? [JSONObject],
                          let total = (container["totalCount"] ?? container["total"] ?? entity["totalTracks"]) as? Int,
                          total >= items.count, total == items.count || allowPartial else { continue }
                    let tracks = items.compactMap { item -> QueuedTrackItem? in
                        let data = (item["itemV2"] as? JSONObject)?["data"] as? JSONObject
                            ?? item["track"] as? JSONObject ?? item
                        return track(data, album: kind == .album ? entity["name"] as? String ?? name : nil)
                    }
                    return Result(tracks: tracks, unavailable: total - tracks.count, name: entity["name"] as? String)
                }
            }
            let props = (json["props"] as? JSONObject)?["pageProps"] as? JSONObject
            let state = (props?["state"] as? JSONObject)?["data"] as? JSONObject
            if let entity = state?["entity"] as? JSONObject,
               entity["uri"] as? String == entityURI || entity["id"] as? String == id,
               matchesTitle(entity),
               let list = entity["trackList"] as? [JSONObject],
               let total = (entity["totalTracks"] ?? entity["totalTrackCount"]) as? Int ?? expectedCount
                   ?? ((kind == .album || allowPartial) && list.count < 100 ? list.count : nil),
               total >= list.count, total == list.count || allowPartial {
                let tracks = list.compactMap { entry -> QueuedTrackItem? in
                    let id = extractSpotifyId(from: entry["uri"] as? String ?? "", type: "track")
                    guard !id.isEmpty, let title = entry["title"] as? String,
                          !title.isEmpty, let artist = entry["subtitle"] as? String, !artist.isEmpty else { return nil }
                    let milliseconds = entry["duration"] as? Double
                    return QueuedTrackItem(id: id, title: title, artist: artist,
                                           album: kind == .album ? entity["name"] as? String ?? name : nil,
                                           duration: milliseconds.flatMap { $0 > 0 ? $0 / 1000 : nil })
                }
                return Result(tracks: tracks, unavailable: total - tracks.count, name: entity["name"] as? String)
            }
        }
        throw OfflinePlayerError.incompleteCollection
    }
}
