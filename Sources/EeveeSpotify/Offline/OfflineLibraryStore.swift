import Foundation

struct OfflineTrackBadgeIndex {
    private let artistsByTitle: [String: Set<String>]
    private let ids: Set<String>
    private let legacyArtistsByTitle: [String: Set<String>]

    init(tracks: [OfflineTrack]) {
        var artists: [String: Set<String>] = [:]
        var legacyArtists: [String: Set<String>] = [:]
        for track in tracks {
            let title = Self.key(track.title)
            let artist = Self.key(track.artist)
            guard !title.isEmpty, !artist.isEmpty else { continue }
            artists[title, default: []].insert(artist)
            if track.id.hasPrefix("track-") { legacyArtists[title, default: []].insert(artist) }
        }
        artistsByTitle = artists
        legacyArtistsByTitle = legacyArtists
        ids = Set(tracks.map(\.id))
    }

    var isEmpty: Bool { artistsByTitle.isEmpty }

    func hasTitle(_ title: String) -> Bool { artistsByTitle[Self.key(title)] != nil }

    func contains(id: String) -> Bool { ids.contains(id) }

    func contains(title: String, artist: String, legacyOnly: Bool = false) -> Bool {
        let index = legacyOnly ? legacyArtistsByTitle : artistsByTitle
        return index[Self.key(title)]?.contains(Self.key(artist)) == true
    }

    private static func key(_ value: String) -> String {
        cleanHtmlEntities(value).precomposedStringWithCanonicalMapping.lowercased()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

public final class OfflineLibraryStore: NSObject {
    public static let shared = OfflineLibraryStore(directory: storesDirectory)
    public static let directoryName = "Offline"
    static let audioExtensions = ["flac", "mp3", "m4a", "wav", "ogg"]

    public static var storesDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    private let directory: URL
    private let lock = NSLock()
    private var tracks: [OfflineTrack] = []
    private var indexURL: URL { directory.appendingPathComponent("offline_index.json") }

    init(directory: URL) {
        self.directory = directory
        super.init()
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([OfflineTrack].self, from: data) {
            tracks = decoded.filter { Self.validID($0.id) }
        }
    }

    static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 200 && id.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 95, 37].contains($0)
        }
    }

    private func file(for track: OfflineTrack) -> URL? {
        let extensions = track.storedExtension.map { [$0] } ?? Self.audioExtensions
        return extensions.lazy.filter { Self.audioExtensions.contains($0) }
            .map { self.directory.appendingPathComponent("\(track.id).\($0)") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    public func isDownloaded(_ id: String) -> Bool { localFileURL(for: id) != nil }

    public func localFileURL(for id: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        guard let track = tracks.first(where: { $0.id == id && $0.downloadState == .downloaded }) else { return nil }
        return file(for: track)
    }

    public func downloadedTracks() -> [OfflineTrack] {
        lock.lock()
        defer { lock.unlock() }
        return tracks.filter { $0.downloadState == .downloaded && file(for: $0) != nil }
    }

    public func allTracks() -> [OfflineTrack] { downloadedTracks() }

    static let changed = Notification.Name("EeveeOfflineLibraryChanged")

    private func notifyChange() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changed, object: nil) }
    }

    func save(_ track: OfflineTrack, audio: URL, ext: String) throws -> URL {
        guard Self.validID(track.id), Self.audioExtensions.contains(ext) else { throw OfflinePlayerError.downloadCorrupted }
        lock.lock()
        defer { lock.unlock() }
        if let saved = tracks.first(where: { $0.id == track.id && $0.downloadState == .downloaded }),
           let existing = file(for: saved) { return existing }
        try ensureDirectory()
        let destination = directory.appendingPathComponent("\(track.id).\(ext)")
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: audio, to: destination)
        do {
            var saved = track
            saved.storedExtension = ext
            try persist(tracks.filter { $0.id != track.id } + [saved])
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        notifyChange()
        return destination
    }

    func saveCover(_ data: Data, id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard tracks.contains(where: { $0.id == id }), Self.validID(id) else { return }
        try data.write(to: directory.appendingPathComponent("\(id).jpg"), options: .atomic)
        notifyChange()
    }

    public func removeDownloaded(id: String) throws { try remove(ids: [id]) }

    public func clearAll() throws { try remove(ids: nil) }

    private func remove(ids: Set<String>?) throws {
        lock.lock()
        defer { lock.unlock() }
        let deleted = ids ?? Set(tracks.map(\.id))
        defer { notifyChange() }
        for id in deleted where Self.validID(id) {
            for ext in Self.audioExtensions + ["jpg"] {
                let url = directory.appendingPathComponent("\(id).\(ext)")
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
        }
        try persist(tracks.filter { !deleted.contains($0.id) })
    }

    private func ensureDirectory() throws {
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var url = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
    }

    private func persist(_ updated: [OfflineTrack]) throws {
        try ensureDirectory()
        try JSONEncoder().encode(updated).write(to: indexURL, options: .atomic)
        tracks = updated
    }
}
