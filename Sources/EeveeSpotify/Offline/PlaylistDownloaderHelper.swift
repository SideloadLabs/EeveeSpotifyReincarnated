import Foundation
import ObjectiveC.runtime
import UIKit

public final class PlaylistDownloaderHelper {
    private static let api = URLSession(configuration: .ephemeral,
                                        delegate: OfflineHTTPSRedirects(allowedHost: "api.spotify.com"), delegateQueue: nil)
    private static let web = URLSession(configuration: .ephemeral,
                                        delegate: OfflineHTTPSRedirects(allowedHost: "open.spotify.com"), delegateQueue: nil)

    @MainActor
    static func promptForCollectionLink(from presenter: UIViewController? = nil) {
        let title = "offline_collection_by_link".localized
        let alert = UIAlertController(title: title, message: "offline_collection_link_hint".localized, preferredStyle: .alert)
        alert.addTextField {
            $0.placeholder = "https://open.spotify.com/…"
            $0.accessibilityLabel = title
            $0.keyboardType = .URL
            $0.autocapitalizationType = .none
            $0.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "offline_cancel".localized, style: .cancel))
        alert.addAction(UIAlertAction(title: "offline_download".localized, style: .default) { [weak alert, weak presenter] _ in
            guard let text = alert?.textFields?.first?.text, let uri = OfflineSpotifyIdentifier.collectionLink(text) else {
                OfflineDownloadPillHUD.shared.completeError(title: title, errorMessage: "offline_collection_bad_link".localized)
                return
            }
            if let presenter {
                DispatchQueue.main.async { presenter.dismiss(animated: true) }
            }
            fetchAndDownload(uri: uri, name: "")
        })
        OfflinePresentationHelper.safePresent(alert, from: presenter)
    }

    @MainActor
    static func fetchAndDownload(uri: URL, name: String, local: OfflineSpotifyCollection.Result? = nil,
                                 album: OfflineSpotifyCollection.AlbumHint? = nil) {
        let albumID = extractSpotifyId(from: uri.absoluteString, type: "album")
        let playlistID = extractSpotifyId(from: uri.absoluteString, type: "playlist")
        let kind: OfflineSpotifyCollection.Kind = albumID.isEmpty ? .playlist : .album
        let id = kind == .album ? albumID : playlistID
        guard !id.isEmpty else {
            OfflineDownloadPillHUD.shared.completeError(title: name, errorMessage: "offline_error_collection_id".localized)
            return
        }
        let label = name.isEmpty ? "offline_collection".localized : name
        OfflineDownloadPillHUD.shared.show(title: label, initialStatus: "offline_read_collection".localized)
        Task {
            do {
                let result = try await Self.fetch(id: id, kind: kind, name: name, token: spotifyAccessToken, local: local, album: album)
                guard !result.tracks.isEmpty else { throw OfflinePlayerError.incompleteCollection }
                OfflineDownloadManager.shared.downloadPlaylist(name: result.name ?? label, tracks: result.tracks,
                                                               unavailable: result.unavailable)
            } catch {
                EeveeLog.write("[Offline] Spotify collection metadata unavailable")
                OfflineDownloadPillHUD.shared.completeError(title: label,
                    errorMessage: OfflinePlayerError.incompleteCollection.localizedDescription)
            }
        }
    }

    @MainActor
    static func downloadVisibleCollection(uri: URL, matching title: String,
                                          local: OfflineSpotifyCollection.Result? = nil,
                                          album: OfflineSpotifyCollection.AlbumHint? = nil) async -> Bool {
        let value = uri.absoluteString
        let kind: OfflineSpotifyCollection.Kind = extractSpotifyId(from: value, type: "album").isEmpty ? .playlist : .album
        let id = extractSpotifyId(from: value, type: kind.rawValue)
        guard !id.isEmpty, let result = try? await fetch(id: id, kind: kind, name: title, token: spotifyAccessToken,
                                                        matchingTitle: title, local: local, album: album),
              !result.tracks.isEmpty else { return false }
        OfflineDownloadManager.shared.downloadPlaylist(name: title, tracks: result.tracks, unavailable: result.unavailable)
        return true
    }

    @MainActor
    static func downloadRecentCollection(uris: [URL], matching title: String) async -> Bool {
        await withTaskGroup(of: OfflineSpotifyCollection.Result?.self) { group in
            let token = spotifyAccessToken
            for uri in uris {
                group.addTask {
                    let value = uri.absoluteString
                    let kind: OfflineSpotifyCollection.Kind = value.hasPrefix("spotify:album:") ? .album : .playlist
                    let id = extractSpotifyId(from: value, type: kind.rawValue)
                    guard !id.isEmpty else { return nil }
                    return try? await fetch(id: id, kind: kind, name: title, token: token, matchingTitle: title)
                }
            }
            var match: OfflineSpotifyCollection.Result?
            for await result in group {
                guard let result, !result.tracks.isEmpty else { continue }
                guard match == nil else {
                    group.cancelAll()
                    return false
                }
                match = result
            }
            guard let match else { return false }
            OfflineDownloadManager.shared.downloadPlaylist(name: title, tracks: match.tracks, unavailable: match.unavailable)
            return true
        }
    }

    @MainActor
    static func downloadCollectionByTitle(_ title: String, kind type: String) async -> Bool {
        guard let token = spotifyAccessToken, !token.isEmpty,
              let kind = OfflineSpotifyCollection.Kind(rawValue: type),
              var search = URLComponents(string: "https://api.spotify.com/v1/search") else { return false }
        search.queryItems = [URLQueryItem(name: "q", value: title), URLQueryItem(name: "type", value: type),
                             URLQueryItem(name: "limit", value: "10")]
        guard let url = search.url,
              let response = try? await json(url, token, timeout: 5),
              let results = response["\(type)s"] as? OfflineSpotifyCollection.JSONObject,
              let items = results["items"] as? [Any] else { return false }
        let name = OfflineRecordingMatch.normalized(title)
        let ids = Set(items.compactMap { item -> String? in
            guard let item = item as? OfflineSpotifyCollection.JSONObject,
                  let title = item["name"] as? String, OfflineRecordingMatch.normalized(title) == name,
                  let id = item["id"] as? String,
                  extractSpotifyId(from: "spotify:\(type):\(id)", type: type) == id else { return nil }
            return id
        })
        guard ids.count == 1, let id = ids.first,
              let result = try? await fetch(id: id, kind: kind, name: title, token: token, matchingTitle: title),
              !result.tracks.isEmpty else { return false }
        OfflineDownloadManager.shared.downloadPlaylist(name: title, tracks: result.tracks, unavailable: result.unavailable)
        return true
    }

    static func spotifyTrack(id: String) async -> QueuedTrackItem? {
        guard extractSpotifyId(from: "spotify:track:\(id)", type: "track") == id,
              let apiURL = URL(string: "https://api.spotify.com/v1/tracks/\(id)"),
              let embedURL = URL(string: "https://open.spotify.com/embed/track/\(id)"),
              let pageURL = URL(string: "https://open.spotify.com/track/\(id)") else { return nil }
        return await withTaskGroup(of: QueuedTrackItem?.self) { group in
            if let token = spotifyAccessToken {
                group.addTask {
                    guard let data = try? await json(apiURL, token, timeout: 5),
                          let track = OfflineSpotifyCollection.track(data), track.id == id else { return nil }
                    return track
                }
            }
            for url in [embedURL, pageURL] {
                group.addTask {
                    guard let data = try? await request(url, token: nil, session: web, timeout: 5),
                          let html = String(data: data, encoding: .utf8) else { return nil }
                    return url == embedURL ? OfflineSpotifyCollection.embeddedTrack(html, id: id)
                        : OfflineSpotifyCollection.publicTrack(html, id: id)
                }
            }
            for await result in group {
                if let track = result, track.duration != nil {
                    group.cancelAll()
                    return track
                }
            }
            return nil
        }
    }

    static func fetch(id: String, kind: OfflineSpotifyCollection.Kind, name: String,
                      token: String?, matchingTitle: String? = nil,
                      local: OfflineSpotifyCollection.Result? = nil,
                      album: OfflineSpotifyCollection.AlbumHint? = nil) async throws -> OfflineSpotifyCollection.Result {
        if let local, !local.tracks.isEmpty, local.unavailable == 0 {
            EeveeLog.write("[Offline] Read playlist tracks from the open page")
            return local
        }
        let album = album.flatMap { album in
            matchingTitle.map({ OfflineRecordingMatch.normalized($0) == OfflineRecordingMatch.normalized(album.title) }) ?? true
                ? album : nil
        }
        let native = album?.loadedTracks
        if let token, !token.isEmpty,
           await verifiedTitle(matchingTitle, id: id, kind: kind, token: token),
           let result = try? await OfflineSpotifyCollection.load(id: id, kind: kind, name: name, token: token, fetch: { try await json($0, $1) }),
           !result.tracks.isEmpty {
            return preferredPlaylist(local: local, remote: result) ?? result
        }
        do {
            let count = local.map { $0.tracks.count + $0.unavailable }
            let result = try await publicCollection(id: id, kind: kind, name: name, matchingTitle: matchingTitle,
                                                    knownCount: count)
            return preferredPlaylist(local: local, remote: result) ?? result
        } catch {
            try Task.checkCancellation()
            if let partial = preferredPlaylist(local: local, remote: nil) { return partial }
            guard kind == .album else { throw error }
            if let album {
                EeveeLog.write("[Offline] Album metadata: \(album.trackIDs.count) native track IDs, \(album.visibleTracks.count) visible rows, release date \(album.releaseDate != nil), explicit badge \(album.hasExplicitTrack)")
                async let apple = try? FreeAudioSourceResolver.shared.appleAlbum(album)
                if let result = try? await FreeAudioSourceResolver.shared.catalogAlbum(album) {
                    EeveeLog.write("[Offline] Matched album through Deezer metadata")
                    return result
                }
                if let result = await apple {
                    EeveeLog.write("[Offline] Matched album through Apple Music metadata")
                    return result
                }
                try Task.checkCancellation()
                if let native {
                    EeveeLog.write("[Offline] Using \(native.tracks.count) loaded album tracks; \(native.unavailable) unavailable")
                    return native
                }
            } else {
                EeveeLog.write("[Offline] Open album metadata unavailable")
            }
            throw error
        }
    }

    private static func preferredPlaylist(local: OfflineSpotifyCollection.Result?,
                                          remote: OfflineSpotifyCollection.Result?) -> OfflineSpotifyCollection.Result? {
        guard let local, local.tracks.count > (remote?.tracks.count ?? 0) else { return nil }
        EeveeLog.write("[Offline] Using \(local.tracks.count) loaded playlist tracks; \(local.unavailable) unavailable")
        return local
    }

    private static func verifiedTitle(_ title: String?, id: String, kind: OfflineSpotifyCollection.Kind,
                                      token: String) async -> Bool {
        guard let title else { return true }
        let route = kind == .album ? "albums" : "playlists"
        guard let url = URL(string: "https://api.spotify.com/v1/\(route)/\(id)"),
              let entity = try? await json(url, token, timeout: 5),
              entity["id"] as? String == id, let name = entity["name"] as? String else { return false }
        return OfflineRecordingMatch.normalized(name) == OfflineRecordingMatch.normalized(title)
    }

    private static func publicCollection(id: String, kind: OfflineSpotifyCollection.Kind, name: String,
                                         matchingTitle: String? = nil, knownCount: Int? = nil) async throws -> OfflineSpotifyCollection.Result {
        var expectedCount = knownCount
        var best: OfflineSpotifyCollection.Result?
        for prefix in ["", "embed/"] {
            guard let url = URL(string: "https://open.spotify.com/\(prefix)\(kind.rawValue)/\(id)"),
                  let data = try? await request(url, token: nil, session: web),
                  let html = String(data: data, encoding: .utf8) else { continue }
            if prefix.isEmpty {
                expectedCount = OfflineSpotifyCollection.publicCount(html, id: id, kind: kind) ?? expectedCount
            }
            if let result = try? OfflineSpotifyCollection.publicPage(html, id: id, kind: kind, name: name,
                                                                     expectedCount: expectedCount, matchingTitle: matchingTitle,
                                                                     allowPartial: true),
               !result.tracks.isEmpty {
                if result.unavailable == 0 { return result }
                if result.tracks.count > (best?.tracks.count ?? 0) { best = result }
            } else {
                EeveeLog.write("[Offline] Spotify \(prefix.isEmpty ? "page" : "embed") has no readable \(kind.rawValue) track list")
            }
        }
        if let best { return best }
        throw OfflinePlayerError.incompleteCollection
    }

    private static func json(_ url: URL, _ token: String?, timeout: TimeInterval = 8) async throws -> OfflineSpotifyCollection.JSONObject {
        let data = try await request(url, token: token, session: api, timeout: timeout)
        guard let json = try JSONSerialization.jsonObject(with: data) as? OfflineSpotifyCollection.JSONObject else {
            throw OfflinePlayerError.incompleteCollection
        }
        return json
    }

    private static func request(_ url: URL, token: String?, session: URLSession, timeout: TimeInterval = 8) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if url.host == "open.spotify.com" {
            request.setValue("text/html", forHTTPHeaderField: "Accept")
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                             forHTTPHeaderField: "User-Agent")
        }
        guard #available(iOS 15.0, *) else { throw URLError(.unsupportedURL) }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            if error.code != .cancelled {
                EeveeLog.write("[Offline] Spotify metadata network error \(error.code.rawValue) at \(url.host ?? "unknown host")")
            }
            throw error
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count < 8_000_000 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let location = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location")
            let redirectHost = location.flatMap { URL(string: $0, relativeTo: url)?.host }
            let destination = redirectHost.map { " → \($0)" } ?? ""
            EeveeLog.write("[Offline] Spotify metadata HTTP \(status) at \(url.host ?? "unknown host")\(destination)")
            throw URLError(.badServerResponse)
        }
        return data
    }

    public static func stringFromEncoreObject(_ item: Any) -> String {
        var seen = Set<ObjectIdentifier>()
        func unwrap(_ value: Any, depth: Int) -> String {
            if let string = value as? String { return string }
            if let attributed = value as? NSAttributedString { return attributed.string }
            guard depth > 0, let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return "" }
            for key in ["string", "text", "attributedString", "underlyingString", "rawString"] {
                if let nested = offlineObjectProperty(object, key) {
                    let string = unwrap(nested, depth: depth - 1)
                    if !string.isEmpty { return string }
                }
            }
            return ""
        }
        return unwrap(item, depth: 3)
    }
}
