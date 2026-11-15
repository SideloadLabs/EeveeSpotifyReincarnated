import UIKit

@MainActor
public final class OfflineDownloadManager {
    public static let shared = OfflineDownloadManager()

    private struct Job: Codable {
        let track: QueuedTrackItem
        let lossless: Bool
        let collection: String?
        let region: OfflineSearchRegion?
        var unavailable: Int? = nil
    }

    private final class Download: Sendable {
        let file: URL
        let duration: TimeInterval
        let bitrate: UInt32

        init(file: URL, duration: TimeInterval, bitrate: UInt32) {
            self.file = file
            self.duration = duration
            self.bitrate = bitrate
        }

        var preferred: Bool { file.pathExtension == "flac" || (file.pathExtension == "mp3" && bitrate >= 315_000) }

        deinit { try? FileManager.default.removeItem(at: file) }
    }

    private static var queueFile: URL {
        OfflineLibraryStore.storesDirectory.appendingPathComponent("download_queue.json")
    }
    private static let audioSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config, delegate: OfflineHTTPSRedirects(), delegateQueue: nil)
    }()

    private var queue: [Job] = []
    private var task: Task<Void, Never>?
    private var background: UIBackgroundTaskIdentifier = .invalid
    private var observer: NSObjectProtocol?
    private var completed = 0
    private var failed = 0
    private var coverTasks: [String: Task<Void, Never>] = [:]

    private init() {
        if let data = try? Data(contentsOf: Self.queueFile),
           let saved = try? JSONDecoder().decode([Job].self, from: data) {
            queue = saved.filter { job in
                let item = job.track
                return OfflineLibraryStore.validID(item.id) && OfflineSpotifyIdentifier.isMenuText(item.title)
                    && (item.artist.isEmpty || OfflineSpotifyIdentifier.isMenuText(item.artist))
            }
        }
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in Task { @MainActor in OfflineDownloadManager.shared.start() } }
        start()
    }

    public func downloadTrack(id: String, title: String, artist: String, duration: TimeInterval? = nil) {
        let item = QueuedTrackItem(id: id, title: title, artist: artist, duration: duration)
        if OfflineLibraryStore.shared.isDownloaded(id) {
            OfflineDownloadPillHUD.shared.completeSuccess(title: title, message: "offline_already_saved".localized)
            return
        }
        enqueue([item], collection: nil)
    }

    public func downloadPlaylist(name: String, tracks: [QueuedTrackItem], unavailable: Int = 0) {
        enqueue(tracks, collection: name, unavailable: unavailable)
    }

    private func enqueue(_ tracks: [QueuedTrackItem], collection: String?, unavailable: Int = 0) {
        let quality = UserDefaults.offlineQuality
        let lossless = quality == 1
        let region = UserDefaults.offlineRegion
        var queued = Set(queue.map { $0.track.id })
        var jobs = tracks.compactMap { track -> Job? in
            guard OfflineLibraryStore.validID(track.id), OfflineSpotifyIdentifier.isMenuText(track.title),
                  OfflineSpotifyIdentifier.isMenuText(track.artist) || (track.artist.isEmpty && track.id.count == 22),
                  !OfflineLibraryStore.shared.isDownloaded(track.id), queued.insert(track.id).inserted else { return nil }
            return Job(track: track, lossless: lossless, collection: collection, region: region)
        }
        if jobs.isEmpty {
            if task == nil, unavailable > 0 {
                OfflineDownloadPillHUD.shared.completeError(title: collection ?? "offline".localized,
                    errorMessage: String(format: "offline_batch_result".localized, 0, unavailable))
            } else if task == nil {
                OfflineDownloadPillHUD.shared.completeSuccess(
                    title: collection ?? tracks.first?.title ?? "offline".localized, message: "offline_already_saved".localized
                )
            }
            return
        }
        do {
            if unavailable > 0 { jobs[jobs.count - 1].unavailable = unavailable }
            try replaceQueue(queue + jobs)
            start()
        } catch {
            OfflineDownloadPillHUD.shared.completeError(title: collection ?? tracks.first?.title ?? "offline".localized,
                                                        errorMessage: error.localizedDescription)
        }
    }

    public func cancelAll() throws {
        try replaceQueue([])
        task?.cancel()
        completed = 0
        failed = 0
        for coverTask in coverTasks.values { coverTask.cancel() }
        OfflineDownloadPillHUD.shared.dismiss()
    }

    private func replaceQueue(_ jobs: [Job]) throws {
        let folder = Self.queueFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(jobs).write(to: Self.queueFile, options: .atomic)
        queue = jobs
    }

    private func start() {
        guard task == nil, !queue.isEmpty else { return }
        background = UIApplication.shared.beginBackgroundTask(withName: "Offline audio") { [weak self] in
            Task { @MainActor in self?.expireBackgroundTask() }
        }
        task = Task { await processQueue() }
    }

    private func expireBackgroundTask() {
        task?.cancel()
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        if background != .invalid {
            UIApplication.shared.endBackgroundTask(background)
            background = .invalid
        }
    }

    private func processQueue() async {
        defer {
            let wasCancelled = Task.isCancelled
            task = nil
            endBackgroundTask()
            if wasCancelled, UIApplication.shared.applicationState == .active { start() }
        }
        while let job = queue.first, !Task.isCancelled {
            let item = job.track
            let label = job.collection ?? (item.artist.isEmpty ? item.title : "\(item.title) • \(item.artist)")
            var downloadError: Error?
            if !OfflineLibraryStore.shared.isDownloaded(item.id) {
                if completed + failed == 0 {
                    OfflineDownloadPillHUD.shared.show(title: label)
                } else {
                    OfflineDownloadPillHUD.shared.updateProgress(
                        title: label, progress: Double(completed + failed) / Double(completed + failed + queue.count),
                        status: item.title
                    )
                }
                do {
                    let (download, recording) = try await Self.download(item, lossless: job.lossless,
                                                                        region: job.region ?? UserDefaults.offlineRegion)
                    try Task.checkCancellation()
                    let track = OfflineTrack(id: item.id, title: recording.title, artist: recording.artist, album: recording.album,
                                             duration: download.duration, downloadState: .downloaded)
                    _ = try OfflineLibraryStore.shared.save(track, audio: download.file, ext: download.file.pathExtension)
                    if coverTasks[item.id] == nil { fetchCover(recording) }
                } catch {
                    if Task.isCancelled { return }
                    downloadError = error
                }
            }
            do {
                try replaceQueue(Array(queue.dropFirst()))
            } catch {
                OfflineDownloadPillHUD.shared.completeError(title: label, errorMessage: error.localizedDescription)
                return
            }
            if downloadError == nil { completed += 1 } else { failed += 1 }
            failed += job.unavailable ?? 0
            if queue.isEmpty {
                defer {
                    completed = 0
                    failed = 0
                }
                if failed == 0 {
                    OfflineDownloadPillHUD.shared.completeSuccess(title: label)
                } else if let downloadError, job.collection == nil, completed + failed == 1 {
                    OfflineDownloadPillHUD.shared.completeError(title: label, errorMessage: downloadError.localizedDescription)
                } else {
                    OfflineDownloadPillHUD.shared.completeError(
                        title: label, errorMessage: String(format: "offline_batch_result".localized, completed, failed)
                    )
                }
            }
        }
    }

    private func fetchCover(_ item: QueuedTrackItem) {
        coverTasks[item.id] = Task {
            defer { coverTasks[item.id] = nil }
            let resolver = FreeAudioSourceResolver.shared
            var cover = item.artwork
            if cover == nil { cover = await resolver.metadata(for: item)?.cover }
            if let cover, let data = try? await resolver.cover(cover), !Task.isCancelled,
               let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.85) {
                try? OfflineLibraryStore.shared.saveCover(jpeg, id: item.id)
            }
        }
    }

    nonisolated private static func download(
        _ item: QueuedTrackItem, lossless: Bool, region: OfflineSearchRegion
    ) async throws -> (Download, QueuedTrackItem) {
        let preferred = lossless ? [.monochrome] : FreeAudioSourceResolver.Provider.preferred(in: region)
        let providers = lossless ? preferred : FreeAudioSourceResolver.Provider.fast
            + FreeAudioSourceResolver.Provider.reserves
        let resolver = FreeAudioSourceResolver.shared
        let metadata = Task { () -> QueuedTrackItem? in
            if item.duration != nil { return item }
            if let track = await PlaylistDownloaderHelper.spotifyTrack(id: item.id) { return track }
            guard !item.artist.isEmpty else { return nil }
            let catalog = await resolver.metadata(for: item)
            let duration: TimeInterval
            if let catalog {
                duration = catalog.duration
            } else if let confirmed = await resolver.matchingSourceDuration(for: item) {
                duration = confirmed
                EeveeLog.write("[Offline] Matched track duration across audio sources")
            } else {
                if !Task.isCancelled { EeveeLog.write("[Offline] Could not confirm track duration") }
                return nil
            }
            return QueuedTrackItem(id: item.id, title: item.title, artist: item.artist, album: item.album,
                                   duration: duration, artwork: item.artwork ?? catalog?.cover)
        }
        defer { metadata.cancel() }

        return try await withThrowingTaskGroup(of: (Download, QueuedTrackItem)?.self) { group in
            for provider in providers {
                group.addTask {
                    if !lossless && FreeAudioSourceResolver.Provider.reserves.contains(provider) {
                        try await Task.sleep(nanoseconds: preferred.contains(provider) ? 650_000_000 : 1_500_000_000)
                    } else if !preferred.contains(provider) {
                        try await Task.sleep(nanoseconds: 650_000_000)
                    }
                    return try await search(provider, item: item, lossless: lossless, metadata: metadata)
                }
            }
            var remaining = providers.count
            var fallback: (Download, QueuedTrackItem)?
            var lastError: Error = OfflinePlayerError.noSource
            while remaining > 0 {
                do {
                    guard let event = try await group.next(), let result = event else { break }
                    remaining -= 1
                    if result.0.preferred {
                        group.cancelAll()
                        return result
                    }
                    if fallback == nil {
                        group.addTask {
                            try await Task.sleep(nanoseconds: 3_000_000_000)
                            return nil
                        }
                    }
                    if result.0.bitrate > (fallback?.0.bitrate ?? 0) { fallback = result }
                } catch {
                    try Task.checkCancellation()
                    remaining -= 1
                    if let failure = error as? OfflinePlayerError, failure != .noSource { lastError = failure }
                }
            }
            try Task.checkCancellation()
            group.cancelAll()
            if let fallback { return fallback }
            throw lastError
        }
    }

    nonisolated private static func search(
        _ provider: FreeAudioSourceResolver.Provider, item: QueuedTrackItem, lossless: Bool,
        metadata: Task<QueuedTrackItem?, Never>
    ) async throws -> (Download, QueuedTrackItem) {
        let resolver = FreeAudioSourceResolver.shared
        var target = item
        if item.artist.isEmpty || provider.needsDuration {
            guard let track = await metadata.value else { throw OfflinePlayerError.noSource }
            target = track
        }
        var lastError: Error = OfflinePlayerError.noSource
        var queries = Set<String>()
        var attempted = Set<URL>()
        for pass in 0..<2 {
            if pass == 1 {
                guard let track = await metadata.value else { break }
                target = track
            }
            let variants = FreeAudioSourceResolver.searchQueries(target, provider: provider)
            for query in (pass == 0 ? Array(variants.prefix(1)) : variants) where queries.insert(query).inserted {
                try Task.checkCancellation()
                let sources: [OfflineAudioSource]
                do {
                    sources = try await resolver.resolve(provider, item: target, query: query)
                } catch {
                    try Task.checkCancellation()
                    continue
                }
                var fallback: (Download, QueuedTrackItem)?
                for source in sources where attempted.insert(source.url).inserted {
                    try Task.checkCancellation()
                    do {
                        let recording: QueuedTrackItem
                        if target.duration == nil {
                            guard let resolved = await metadata.value, resolved.id == target.id,
                                  let duration = resolved.duration,
                                  OfflineRecordingMatch.duration(source.duration, matches: duration) else { continue }
                            recording = resolved
                        } else {
                            recording = target
                        }
                        let download = try await transfer(source, provider: provider, lossless: lossless,
                                                          expected: recording.duration)
                        if download.preferred { return (download, recording) }
                        if download.bitrate > (fallback?.0.bitrate ?? 0) { fallback = (download, recording) }
                    } catch {
                        try Task.checkCancellation()
                        lastError = error
                    }
                }
                if let fallback { return fallback }
            }
        }
        throw lastError
    }

    nonisolated private static func transfer(_ source: OfflineAudioSource, provider: FreeAudioSourceResolver.Provider,
                                              lossless: Bool, expected: TimeInterval?) async throws -> Download {
        let duration = expected ?? source.duration
        let mayBeLossless = provider == .monochrome
        let bytesPerSecond = mayBeLossless ? 2_000_000.0 : 41_000.0
        let maxBytes = duration * bytesPerSecond + 2_000_000
        var request = URLRequest(url: source.url, timeoutInterval: mayBeLossless ? 16 : 12)
        if source.url.host == "upload.wikimedia.org" {
            request.setValue(FreeAudioSourceResolver.commonsUserAgent, forHTTPHeaderField: "User-Agent")
        }
        if source.url.host == "tracks.monochrome.st" {
            request.setValue("https://monochrome.st/", forHTTPHeaderField: "Referer")
            request.setValue("https://monochrome.st", forHTTPHeaderField: "Origin")
        }
        if provider == .lightAudio { request.setValue("https://web.ligaudio.ru/", forHTTPHeaderField: "Referer") }
        if provider == .rilds { request.setValue("https://rilds.net/", forHTTPHeaderField: "Referer") }
        if let referer = provider.audioReferer { request.setValue(referer, forHTTPHeaderField: "Referer") }
        guard #available(iOS 15.0, *) else { throw URLError(.unsupportedURL) }
        let (temporary, response) = try await audioSession.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let finalURL = http.url, provider.allowsAudioURL(finalURL),
              let bytes = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              bytes > 0, Double(bytes) <= maxBytes else {
            throw OfflinePlayerError.downloadCorrupted
        }
        let ext: String
        if lossless {
            ext = "flac"
        } else {
            let handle = try FileHandle(forReadingFrom: temporary)
            defer { try? handle.close() }
            let header = try handle.read(upToCount: 12) ?? Data()
            if mayBeLossless, header.starts(with: Data("fLaC".utf8)) {
                ext = "flac"
            } else if header.dropFirst(4).prefix(4) == Data("ftyp".utf8) {
                ext = "m4a"
            } else {
                ext = "mp3"
            }
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        try FileManager.default.moveItem(at: temporary, to: file)
        do {
            let flac = ext == "flac"
            let audio = try OfflineAudioFile.inspect(file, lossless: flac, expected: duration, allowLowerQuality: !flac)
            if flac && !lossless {
                defer { try? FileManager.default.removeItem(at: file) }
                let converted = try await OfflineAudioFile.compactCopy(of: file)
                do {
                    let convertedAudio = try OfflineAudioFile.inspect(converted, lossless: false, expected: audio.duration,
                                                                      allowLowerQuality: true)
                    return Download(file: converted, duration: convertedAudio.duration, bitrate: convertedAudio.bitrate)
                } catch {
                    try? FileManager.default.removeItem(at: converted)
                    throw error
                }
            }
            return Download(file: file, duration: audio.duration, bitrate: audio.bitrate)
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }
}
