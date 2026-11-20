import Foundation

extension Notification.Name {
    static let eeveeOfflineLyricsFilesChanged = Notification.Name("EeveeOfflineLyricsFilesChanged")
}

/// App-owned sidecar. Audio files and Spotify's databases are never modified here.
final class OfflineLyricsStore {
    static let shared = OfflineLyricsStore(isUsable: isUsableSavedLyrics)

    struct Entry: Codable {
        let version: Int
        let options: LyricsOptions
        let data: Data
        // Files from earlier builds may still carry a "karaoke" key; the decoder ignores it.
    }
    struct Revision: Equatable {
        let epoch: UInt64
        let track: UInt64
    }
    struct Summary {
        let tracks: Int
        let files: Int
        let bytes: Int
    }
    private struct FileIndex {
        private var entries: [String: (id: String, bytes: Int)] = [:]
        private var filesByTrack: [String: Int] = [:]
        private var bytes = 0

        var summary: Summary { Summary(tracks: filesByTrack.count, files: entries.count, bytes: bytes) }

        mutating func put(_ name: String, id: String, bytes length: Int) {
            remove(name)
            entries[name] = (id, length)
            filesByTrack[id, default: 0] += 1
            bytes += length
        }

        mutating func remove(_ name: String) {
            guard let old = entries.removeValue(forKey: name) else { return }
            let count = filesByTrack[old.id, default: 1] - 1
            filesByTrack[old.id] = count == 0 ? nil : count
            bytes -= old.bytes
        }
    }

    private let directory: URL
    private let isUsable: (Entry) -> Bool
    private let lock = NSLock()
    private var epoch: UInt64 = 0
    private var revisions: [String: UInt64] = [:]
    private var contexts: [String: Set<String>]?
    private var suppressed: Set<String>?
    private var fileIndex: FileIndex?
    private var optionIndex: [String: LyricsOptions] = [:]
    private var missingFiles = Set<String>()

    private func changed(_ ids: [String]? = nil) {
        // Observers may read the store, so dispatch after releasing its lock.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .eeveeOfflineLyricsFilesChanged, object: nil,
                userInfo: ids.map { ["tracks": $0] })
        }
    }

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("EeveeSpotify/OfflineLyrics", isDirectory: true),
         isUsable: @escaping (Entry) -> Bool = { _ in true }) {
        self.directory = directory
        self.isUsable = isUsable
    }

    private func valid(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        }
    }
    private func url(trackId: String, source: Int) -> URL? {
        guard valid(trackId) else { return nil }
        return directory.appendingPathComponent("\(source)-\(trackId).json", isDirectory: false)
    }
    private func currentRevision(_ id: String) -> Revision { Revision(epoch: epoch, track: revisions[id, default: 0]) }
    func revision(trackId: String) -> Revision {
        lock.lock(); defer { lock.unlock() }
        return currentRevision(trackId)
    }
    func isCurrent(_ revision: Revision, trackId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return currentRevision(trackId) == revision
    }
    /// Cancels old work without deleting previously saved lyrics.
    func invalidatePendingWrites() {
        lock.lock(); defer { lock.unlock() }
        epoch &+= 1
    }

    private func readEntry(_ url: URL) -> Entry? {
        guard let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.version == 1, isUsable(entry) else { return nil }
        return entry
    }

    func entry(trackId: String, source: Int, options: LyricsOptions) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        guard let url = url(trackId: trackId, source: source) else { return nil }
        let key = url.lastPathComponent
        guard let entry = readEntry(url) else {
            optionIndex[key] = nil
            missingFiles.insert(key)
            return nil
        }
        optionIndex[key] = entry.options
        missingFiles.remove(key)
        guard matches(entry.options, options) else { return nil }
        return entry
    }

    /// Newest saved text from one of `sources` (another provider), whatever its
    /// options. Shown offline only until the selected provider's text is saved.
    func fallbackEntry(trackId: String, sources: [Int]) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        var best: (date: Date, entry: Entry)?
        for source in sources {
            guard let url = url(trackId: trackId, source: source),
                  let entry = readEntry(url) else { continue }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if best == nil || date > best!.date { best = (date, entry) }
        }
        return best?.entry
    }

    private func matches(_ saved: LyricsOptions, _ requested: LyricsOptions) -> Bool {
        saved.romanization == requested.romanization && saved.lrclibUrl == requested.lrclibUrl && saved.geniusFallback == requested.geniusFallback
    }
    /// Cache only settings metadata for button state, not another copy of all lyrics.
    /// Subsequent progress updates don't reread/decode the entire song library.
    func missingTrackIds(_ ids: [String], source: Int, options: LyricsOptions) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return ids.filter { id in
            guard valid(id) else { return false }
            // Check the in-memory index before constructing a Foundation URL.
            // URL.appendingPathComponent without a directory hint can lstat even
            // when no lyrics file needs to be read (the build020 watchdog stack).
            let key = "\(source)-\(id).json"
            if let saved = optionIndex[key] { return !matches(saved, options) }
            if missingFiles.contains(key) { return true }
            guard let file = url(trackId: id, source: source) else { return false }
            guard let entry = readEntry(file) else {
                // All app writes clear this cached miss; progress refreshes
                // must not reopen thousands of missing files on the main queue.
                missingFiles.insert(key)
                return true
            }
            optionIndex[key] = entry.options
            return !matches(entry.options, options)
        }
    }

    @discardableResult
    func save(trackId: String, source: Int, options: LyricsOptions, data: Data,
              revision: Revision? = nil) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        loadSuppressed()
        guard let url = url(trackId: trackId, source: source), !suppressed!.contains(trackId),
              revision == nil || currentRevision(trackId) == revision else { return false }
        try prepareDirectory()
        let entry = Entry(version: 1, options: options, data: data)
        let encoded = try JSONEncoder().encode(entry)
        try encoded.write(to: url, options: .atomic)
        fileIndex?.put(url.lastPathComponent, id: trackId, bytes: encoded.count)
        optionIndex[url.lastPathComponent] = options
        missingFiles.remove(url.lastPathComponent)
        changed([trackId])
        return true
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var folder = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
    }
    private func loadSuppressed() {
        guard suppressed == nil else { return }
        let data = try? Data(contentsOf: directory.appendingPathComponent("deleted.json"))
        suppressed = Set((data.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []).filter(valid))
    }
    private func saveSuppressed() throws {
        try prepareDirectory()
        try JSONEncoder().encode((suppressed ?? []).sorted()).write(to: directory.appendingPathComponent("deleted.json"), options: .atomic)
    }
    /// Automatic recovery must not undo Delete saved lyrics, even after relaunch.
    /// Read on the statistics worker alongside missingTrackIds, never on main.
    func automaticallyRetryableTrackIds(_ ids: [String]) -> [String] {
        lock.lock(); defer { lock.unlock() }
        loadSuppressed()
        return ids.filter { valid($0) && !suppressed!.contains($0) }
    }
    /// A real new music download or explicit backfill may save the text again.
    /// Merely reopening a deleted song's online lyrics may not recreate its file.
    func allowDownloads(trackIds: [String]) throws {
        lock.lock(); defer { lock.unlock() }
        loadSuppressed()
        let before = suppressed!
        suppressed!.subtract(trackIds.filter(valid))
        if before != suppressed! { try saveSuppressed() }
    }

    private func loadContexts() {
        guard contexts == nil else { return }
        let data = try? Data(contentsOf: directory.appendingPathComponent("contexts.json"))
        let decoded = data.flatMap { try? JSONDecoder().decode([String: [String]].self, from: $0) } ?? [:]
        contexts = decoded.mapValues { Set($0.filter(valid)) }
    }
    private func saveContexts() throws {
        try prepareDirectory()
        try JSONEncoder().encode((contexts ?? [:]).mapValues { $0.sorted() })
            .write(to: directory.appendingPathComponent("contexts.json"), options: .atomic)
    }
    /// Remember membership while it is available, so deletion works without a network.
    func remember(context: String, trackIds: [String]) throws {
        try remember(contexts: [context: trackIds])
    }

    func remember(contexts memberships: [String: [String]]) throws {
        lock.lock(); defer { lock.unlock() }
        loadContexts()
        var dirty = false
        for (context, trackIds) in memberships where context.hasPrefix("spotify:album:") || context.hasPrefix("spotify:playlist:") {
            let ids = trackIds.filter(valid)
            let previous = contexts?[context]?.count ?? 0
            contexts![context, default: []].formUnion(ids)
            if contexts?[context]?.count != previous { dirty = true }
        }
        if dirty {
            do { try saveContexts() }
            catch { contexts = nil; throw error }
        }
    }
    func tracks(in context: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        loadContexts()
        return Array(contexts?[context] ?? [])
    }
    private func lyricFiles() -> [(url: URL, id: String)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { file in
            guard file.pathExtension == "json", let dash = file.deletingPathExtension().lastPathComponent.firstIndex(of: "-") else { return nil }
            let stem = file.deletingPathExtension().lastPathComponent
            guard Int(stem[..<dash]) != nil else { return nil }
            let id = String(stem[stem.index(after: dash)...])
            return valid(id) ? (file, id) : nil
        }
    }
    func summary() -> Summary {
        lock.lock(); defer { lock.unlock() }
        if fileIndex == nil {
            var index = FileIndex()
            for file in lyricFiles() {
                let bytes = (try? file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                index.put(file.url.lastPathComponent, id: file.id, bytes: bytes)
            }
            fileIndex = index
        }
        return fileIndex!.summary
    }
    func savedTrackIds() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(Set(lyricFiles().map(\.id)))
    }
    func remove(trackIds: [String]) throws {
        lock.lock(); defer { lock.unlock() }
        defer { changed(trackIds) }
        let ids = Set(trackIds.filter(valid))
        // Revisions change even if no file exists: queued/in-flight work must not recreate it.
        for id in ids { revisions[id, default: 0] &+= 1 }
        loadSuppressed()
        suppressed!.formUnion(ids)
        var failure: Error?
        for file in lyricFiles() where ids.contains(file.id) {
            do {
                try FileManager.default.removeItem(at: file.url)
                fileIndex?.remove(file.url.lastPathComponent)
                optionIndex[file.url.lastPathComponent] = nil
                missingFiles.insert(file.url.lastPathComponent)
            } catch { failure = error }
        }
        loadContexts()
        for key in Array(contexts!.keys) {
            contexts![key]?.subtract(ids)
            if contexts![key]?.isEmpty == true { contexts![key] = nil }
        }
        do { try saveContexts(); try saveSuppressed() } catch { failure = error }
        if let failure { throw failure }
    }
    func removeAll(additionallySuppressing trackIds: [String] = []) throws {
        lock.lock(); defer { lock.unlock() }
        defer { changed() }
        loadSuppressed()
        suppressed!.formUnion(lyricFiles().map(\.id))
        suppressed!.formUnion(trackIds.filter(valid))
        epoch &+= 1
        contexts = [:]
        fileIndex = nil
        optionIndex = [:]
        missingFiles = []
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        try saveSuppressed()
    }
}
