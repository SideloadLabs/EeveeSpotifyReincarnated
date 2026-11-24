import Foundation
#if canImport(EeveeSpotifyC)
import EeveeSpotifyC
#endif

@objc(EeveeOfflineLyricsDownloader)
final class EeveeOfflineLyricsDownloader: NSObject {
    static let shared = EeveeOfflineLyricsDownloader()
    private let worker: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "EeveeSpotify.OfflineLyrics"
        // One song at a time: providers rate-limit per client, and playback shares that limit.
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()
    private final class Job {
        let id: String
        let revision: OfflineLyricsStore.Revision
        let source: LyricsSource
        let options: LyricsOptions
        let row: [String: String]
        var callbacks: [(JobStatus) -> Void] = []
        var nativeCallbacks: [(Result<Lyrics, Error>) -> Void] = []
        var refresh: RefreshProgress?
        var operation: Operation?
        var priority: Operation.QueuePriority
        var isRateLimitRetry = false
        let metadataTimeout: TimeInterval
        let queuedAt = Date()

        var key: String { Self.key(source: source, id: id) }
        static func key(source: LyricsSource, id: String) -> String { "\(source.rawValue):\(id)" }

        init(id: String, revision: OfflineLyricsStore.Revision, source: LyricsSource, options: LyricsOptions,
             row: [String: String], priority: Operation.QueuePriority, metadataTimeout: TimeInterval) {
            self.id = id
            self.revision = revision
            self.source = source
            self.options = options
            self.row = row
            self.priority = priority
            self.metadataTimeout = metadataTimeout
        }

        var isWanted: Bool {
            UserDefaults.offlineLyricsEnabled && UserDefaults.lyricsSource == source && UserDefaults.lyricsOptions.downloadOptions == options
                && OfflineLyricsStore.shared.isCurrent(revision, trackId: id)
        }
    }
    private enum Outcome {
        case saved(Lyrics), skipped(Lyrics), failed(Error), cancelled
    }
    /// The provider rejected access after this job was queued; it is not asked again.
    private struct ProviderRefusedError: Error, CustomStringConvertible {
        var description: String { "lyrics provider rejected access; not asked again until tomorrow" }
    }
    /// How a job ended. The raw values are the progress keys Pixie's settings page reads.
    private enum JobStatus: String, CaseIterable {
        case saved, skipped, notFound = "not_found", failed, cancelled
    }
    /// Visible progress of a batch: Missing (the library button) or a provider refresh.
    private struct Progress {
        let isRefresh: Bool
        var total: Int
        var completed = 0
        var counts: [JobStatus: Int] = [:]

        var isDone: Bool { completed >= total }
        mutating func count(_ status: JobStatus) {
            completed += 1
            counts[status, default: 0] += 1
        }
        var snapshot: [String: Any] {
            var result: [String: Any] = ["active": true, "completed": completed, "total": total]
            for status in JobStatus.allCases { result[status.rawValue] = counts[status, default: 0] }
            if isRefresh { result["kind"] = "refresh" }
            return result
        }
        var summary: String {
            JobStatus.allCases.map { "\($0.rawValue)=\(counts[$0, default: 0])" }.joined(separator: " ")
        }
    }
    /// A provider refresh's progress, shared by its jobs.
    private final class RefreshProgress {
        let source: LyricsSource
        let options: LyricsOptions
        var progress = Progress(isRefresh: true, total: 0)

        init(source: LyricsSource, options: LyricsOptions) { self.source = source; self.options = options }
    }
    let foreground = LyricsForegroundExecution()
    private var observers: [NSObjectProtocol] = []
    // Main-queue state. One track loads at a time; every host is still rate-limited.
    private var pending: [String: Job] = [:]
    private var rateLimitedJobs: [String: Job] = [:]
    private var removalTokens: [String: String] = [:]
    private var removalStarted: [String: Date] = [:]
    private var requestedAt: [String: Date] = [:]
    private var removedAt: [String: Date] = [:]
    /// Removed tracks whose saving, cancelling and refresh run once for the whole burst.
    private var removalBatch: Set<String> = []
    private var removalFlushScheduled = false
    private var clearedAt = Date.distantPast
    private static func loadKnownLibrary() -> Set<String>? {
        let defaults = UserDefaults.container
        if defaults.bool(forKey: "PixieLyricsCatalogDirty") { return nil }
        if let ids = defaults.stringArray(forKey: "PixieLyricsKnownDownloadIds") { return Set(ids) }
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pixie/offline-catalog.plist")
        guard let data = try? Data(contentsOf: url),
              let file = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              file["version"] as? Int == 1, let rows = file["rows"] as? [[String: Any]] else { return nil }
        return Set(rows.compactMap { ($0["uri"] as? String).flatMap(trackId) })
    }
    private var knownLibraryWriteScheduled = false
    /// The whole list is written at most once a second (every completed track changes it)
    /// and when Spotify leaves the screen. A launch reads Spotify's library again anyway.
    private func persistKnownLibrary() {
        guard !knownLibraryWriteScheduled else { return }
        knownLibraryWriteScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.writeKnownLibrary() }
    }
    private func writeKnownLibrary() {
        guard knownLibraryWriteScheduled else { return }
        knownLibraryWriteScheduled = false
        UserDefaults.container.set(knownDownloadedIds == nil, forKey: "PixieLyricsCatalogDirty")
        if let ids = knownDownloadedIds { UserDefaults.container.set(Array(ids), forKey: "PixieLyricsKnownDownloadIds") }
        else { UserDefaults.container.removeObject(forKey: "PixieLyricsKnownDownloadIds") }
    }
    private var knownDownloadedIds: Set<String>? = EeveeOfflineLyricsDownloader.loadKnownLibrary()
    private var scanningLibrary = false
    private var scanCompleted = 0
    private var scanTotal = 0
    private var batchID: UUID?
    /// The Missing button's batch, while it runs.
    private var batch: Progress?
    private var refreshProgress: RefreshProgress?
    private var refreshGeneration: UInt64 = 0
    private var explicitRefresh: UUID?
    private struct QueueCheckpoint: Codable, Equatable {
        let source: Int
        let options: LyricsOptions
        let ids: [String]
        let recheckCatalog: Bool
        let rateLimitRetryIds: [String]
    }
    private static let checkpointKey = "PixieLyricsPendingQueue"
    private var lastCheckpoint: QueueCheckpoint?
    private var restoringCheckpoint = false
    private var checkpointWriteScheduled = false
    private var didRestoreAtLaunch = false
    private var launchCheckpoint: QueueCheckpoint?
    private var readLibraryOnNextForeground = false
    private var cancelledAt = Date.distantPast
    private var scheduledLibraryRead: DispatchWorkItem?
    private var cancelLibraryRead: (() -> Void)?
    private var completedDuringLibraryRead = Set<String>()
    private var manualScanStarted: Date?
    private var completedDuringManualScan = Set<String>()
    private let statisticsQueue = DispatchQueue(label: "EeveeSpotify.OfflineLyrics.statistics", qos: .utility)
    private struct StatisticsInput: Equatable {
        let ids: Set<String>?
        let source: LyricsSource
        let options: LyricsOptions
    }
    // Main-queue cache. A synchronous UIKit snapshot must never scan files or wait
    // for the store's disk-I/O lock. In build020 that killed the app on re-entry.
    private var statisticsInput: StatisticsInput?
    private var statisticsRevision: UInt64 = 0
    private var statisticsNeedsFullRefresh = true
    private var statisticsChangedIds = Set<String>()
    private var statisticsScheduled = false
    private var statisticsRunning = false
    private var statisticsReady = false
    private var savedTracks = 0
    private var savedBytes = 0
    private var missingIds = Set<String>()

    func start() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.start() }
            return
        }
        guard observers.isEmpty else { return }
        foreground.enteredBackground = { [weak self] in
            self?.flushCheckpoint()
            self?.writeKnownLibrary()
        }
        foreground.hasWork = { [weak self] in self?.hasLyricsWork ?? false }
        foreground.isPlaying = { KaraokePlaybackTracker.shared.isPlaying() }
        foreground.backgroundTimeEnded = { [weak self] playing in
            guard let self, self.hasLyricsWork else { return }
            writeDebugLog(playing ? "[Lyrics] minimized time ended; Spotify is playing, lyrics continue"
                                  : "[Lyrics] minimized time ended; lyrics wait for Spotify")
        }
        foreground.activityChanged = { [weak self] active in
            guard let self else { return }
            self.worker.isSuspended = !active
            if active {
                self.resumeForegroundWork()
            } else {
                self.flushCheckpoint()
            }
            if self.hasLyricsWork {
                writeDebugLog(active ? "[Lyrics] foreground queue resumed" : "[Lyrics] app inactive; new requests deferred")
            }
        }
        foreground.networkLost = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.foreground.networkUnavailable else { return }
                // The song already playing gets its saved lyrics too, also when Spotify starts offline.
                if let trackId = KaraokePlaybackTracker.shared.playerReportedTrackId() {
                    publishSavedLyrics(trackId: trackId)
                }
                // Spotify can finish its request while our persisted queue waits for the network.
                for job in Array(self.pending.values) {
                    let callbacks = job.nativeCallbacks
                    job.nativeCallbacks.removeAll()
                    for callback in callbacks { callback(.failure(URLError(.notConnectedToInternet))) }
                }
            }
        }
        foreground.observe()
        worker.isSuspended = !foreground.isActive
        observers.append(NotificationCenter.default.addObserver(
            forName: Notification.Name("EeveeOfflineLyricsRequested"), object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let tracks = note.userInfo?["tracks"] as? [String] else { return }
            self.flushRemovals()
            let context = note.userInfo?["context"] as? String ?? ""
            let issued = (note.userInfo?["requested_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } ?? Date.distantPast
            // Native album/playlist membership may arrive after the user deleted
            // the download. The original request time, not the callback time,
            // decides whether that event may start a new lyrics download.
            guard issued >= self.clearedAt, issued >= self.cancelledAt, issued >= (self.removalStarted[context] ?? .distantPast),
                  UserDefaults.offlineLyricsEnabled else { return }
            let current = tracks.filter { uri in
                guard let id = Self.trackId(uri) else { return false }
                return issued >= (self.removedAt[id] ?? .distantPast)
            }
            self.removalTokens[context] = nil
            let ids = current.compactMap(Self.trackId)
            for id in ids { self.requestedAt[id] = max(issued, self.requestedAt[id] ?? .distantPast) }
            // Requested is not downloaded yet: the library count grows on each audio completion.
            self.statisticsQueue.async {
                do { try OfflineLyricsStore.shared.remember(context: context, trackIds: ids) }
                catch { writeDebugLog("[Lyrics] could not save download membership: \(error)") }
            }
            self.enqueue(current.map { ["uri": $0] })
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: Notification.Name("EeveeOfflineLyricsRemoved"), object: nil, queue: .main
        ) { [weak self] note in self?.removed(note.userInfo ?? [:]) })
        observers.append(NotificationCenter.default.addObserver(
            forName: Notification.Name("EeveeOfflineAudioTrackDownloaded"), object: nil, queue: .main
        ) { [weak self] note in
            guard let uri = note.userInfo?["uri"] as? String, let id = Self.trackId(uri),
                  let time = note.userInfo?["completed_at"] as? NSNumber else { return }
            self?.audioTrackDownloaded(id, at: Date(timeIntervalSince1970: time.doubleValue))
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .eeveeOfflineLyricsFilesChanged, object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let ids = note.userInfo?["tracks"] as? [String]
            if let ids { self.statisticsChangedIds.formUnion(ids) }
            self.refreshStatisticsIfNeeded(invalidate: ids == nil)
        })
        EeveePixieObserveDownloadCompletion(UserDefaults.offlineLyricsEnabled)
        if foreground.isActive { resumeForegroundWork() }
    }

    private var hasLyricsWork: Bool {
        restoringCheckpoint || scanningLibrary || explicitRefresh != nil || !pending.isEmpty
    }

    private func resumeForegroundWork() {
        if !didRestoreAtLaunch {
            didRestoreAtLaunch = true
            launchCheckpoint = loadCheckpoint()
            restoringCheckpoint = launchCheckpoint != nil
            // One launch check, once Pixie and Spotify's offline service are up. It
            // covers the downloaded library, saved texts, markers and the interrupted
            // queue, so nothing else rescans at launch.
            scheduleInitialLibraryRead(delay: 5)
        }
        if readLibraryOnNextForeground {
            readLibraryOnNextForeground = false
            scheduleInitialLibraryRead()
        }
    }

    /// The queue interrupted by the last exit, if it still matches the settings.
    private func loadCheckpoint() -> QueueCheckpoint? {
        let defaults = UserDefaults.container
        guard let data = defaults.data(forKey: Self.checkpointKey) else { return nil }
        guard let checkpoint = try? PropertyListDecoder().decode(QueueCheckpoint.self, from: data),
              UserDefaults.offlineLyricsEnabled, checkpoint.source == UserDefaults.lyricsSource.rawValue,
              checkpoint.options.downloadOptions == UserDefaults.lyricsOptions.downloadOptions else {
            defaults.removeObject(forKey: Self.checkpointKey)
            return nil
        }
        lastCheckpoint = checkpoint
        return checkpoint
    }

    private func finishRestore() {
        launchCheckpoint = nil
        guard restoringCheckpoint else { return }
        restoringCheckpoint = false
        changed()
    }

    private func flushCheckpoint() {
        checkpointWriteScheduled = false
        guard didRestoreAtLaunch else { return }
        if !restoringCheckpoint {
            let source = UserDefaults.lyricsSource
            let options = UserDefaults.lyricsOptions.downloadOptions
            let jobs = pending.values.filter { $0.source == source && $0.options == options }
            let ids = jobs.map(\.id).sorted()
            let retries = jobs.filter(\.isRateLimitRetry).map(\.id).sorted()
            let scanning = scanningLibrary || explicitRefresh != nil
            let checkpoint = UserDefaults.offlineLyricsEnabled && source.isReplacingLyrics && (scanning || !ids.isEmpty)
                ? QueueCheckpoint(source: source.rawValue, options: options, ids: ids, recheckCatalog: scanning,
                                  rateLimitRetryIds: retries) : nil
            if checkpoint != lastCheckpoint {
                let defaults = UserDefaults.container
                if let checkpoint, let data = try? PropertyListEncoder().encode(checkpoint) {
                    defaults.set(data, forKey: Self.checkpointKey)
                } else {
                    defaults.removeObject(forKey: Self.checkpointKey)
                }
                lastCheckpoint = checkpoint
            }
        }
    }

    private func audioTrackDownloaded(_ id: String, at time: Date) {
        flushRemovals()
        guard UserDefaults.offlineLyricsEnabled, time >= cancelledAt,
              time >= (removedAt[id] ?? .distantPast) else { return }
        requestedAt[id] = max(time, requestedAt[id] ?? .distantPast)
        if cancelLibraryRead != nil { completedDuringLibraryRead.insert(id) }
        if scanningLibrary { completedDuringManualScan.insert(id) }
        let previousIds = knownDownloadedIds
        if knownDownloadedIds?.insert(id).inserted == true {
            if let input = statisticsInput, input.ids == previousIds {
                statisticsInput = StatisticsInput(ids: knownDownloadedIds, source: input.source, options: input.options)
                statisticsChangedIds.insert(id)
            }
            persistKnownLibrary()
            changed()
        }
        refreshForCurrentSource(downloadedIds: [id], observedAt: time, reason: "audio track completed",
                                priority: .high, showsProgress: false, seenDownloaded: [id])
    }

    /// A launch or re-enable covers tracks already on disk, saved texts, markers and
    /// interrupted jobs in one pass. Audio completion events take the single-ID path.
    private func scheduleInitialLibraryRead(delay: TimeInterval = 0.8) {
        guard UserDefaults.offlineLyricsEnabled, UserDefaults.lyricsSource.isReplacingLyrics, !scanningLibrary else {
            finishRestore(); return
        }
        guard cancelLibraryRead == nil, scheduledLibraryRead == nil else { return }
        let generation = refreshGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.refreshGeneration == generation else { return }
            self.scheduledLibraryRead = nil
            guard self.foreground.isActive else {
                self.readLibraryOnNextForeground = true
                return
            }
            guard UserDefaults.offlineLyricsEnabled, UserDefaults.lyricsSource.isReplacingLyrics, !self.scanningLibrary else {
                self.finishRestore(); return
            }
            // Pixie can load after the lyrics downloader.
            EeveePixieObserveDownloadCompletion(true)
            let started = Date()
            self.cancelLibraryRead = EeveePixieReadDownloadedTrackURIs { [weak self] tracks in
                guard let self, self.refreshGeneration == generation else { return }
                self.cancelLibraryRead = nil
                let completed = self.completedDuringLibraryRead
                self.completedDuringLibraryRead.removeAll()
                let checkpoint = self.launchCheckpoint
                guard !self.scanningLibrary else { self.finishRestore(); return }
                var downloaded = completed
                if let tracks {
                    downloaded.formUnion(Set(tracks.compactMap(Self.trackId))
                        .filter { (self.removedAt[$0] ?? .distantPast) <= started })
                    if downloaded != self.knownDownloadedIds {
                        self.knownDownloadedIds = downloaded
                        self.persistKnownLibrary()
                        self.changed()
                    }
                }
                self.refreshForCurrentSource(downloadedIds: downloaded.union(checkpoint?.ids ?? []), observedAt: started,
                                             reason: "launch check", includeStored: true, seenDownloaded: downloaded,
                                             rateLimitRetryIds: Set(checkpoint?.rateLimitRetryIds ?? [])) { [weak self] in
                    self?.finishRestore()
                }
            }
        }
        scheduledLibraryRead = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Remembers a final failure so the automatic refresh does not repeat it on
    /// every launch: a definite miss for good, anything temporary until tomorrow,
    /// a rejected key once for the provider. A library download still asks again.
    private static func rememberFailure(_ error: Error, job: Job) {
        let store = LyricsNotFoundStore.shared
        let source = job.source.rawValue
        if case LyricsError.noSuchSong = error {
            store.record(job.id, source: source)
            NativeOfflineLyrics.shared.providerHasNoLyrics(trackId: job.id)
        } else if case OfflineLyricsFetchError.noMetadata = error {
            store.record(job.id, source: source)
        } else if error is ProviderRefusedError {
            return
        } else if case LyricsError.invalidSpicyKey = error {
            store.providerRefused(source: source)
        } else if let http = error as? LyricsProviderHTTPError, http.status == 401 || http.status == 403 {
            store.providerRefused(source: source)
        } else {
            store.retryLater(job.id, source: source)
        }
    }

    /// After a provider switch (and at launch), queue the selected provider's text for
    /// every track saved with another provider, in library order. Old texts are not
    /// deleted: offline they stand in until each replacement is saved.
    func refreshForCurrentSource(downloadedIds: Set<String>? = nil, observedAt: Date = Date(),
                                 reason: String = "provider refresh", priority: Operation.QueuePriority = .normal,
                                 userInitiated: Bool = false, showsProgress: Bool = true,
                                 includeStored: Bool = false, seenDownloaded: Set<String> = [],
                                 rateLimitRetryIds: Set<String> = [], completion: (() -> Void)? = nil) {
        let source = UserDefaults.lyricsSource
        let options = UserDefaults.lyricsOptions.downloadOptions
        if userInitiated { cancelPending() }
        guard source.isReplacingLyrics, UserDefaults.offlineLyricsEnabled else { completion?(); return }
        let generation = refreshGeneration
        let refresh = userInitiated ? UUID() : nil
        if let refresh {
            explicitRefresh = refresh
            restoringCheckpoint = false
            changed()
            // The restart prompt can terminate this process before the scan returns.
            flushCheckpoint()
        }
        let outcomes = LyricsNotFoundStore.shared
        // Automatic work never repeats a known outcome. An explicit refresh (the
        // user changed the provider or its options) still skips definite misses.
        if !userInitiated, let refused = outcomes.refusal(source: source.rawValue) {
            writeDebugLog("[Lyrics] \(reason): \(source.description) rejected access at \(refused); automatic downloads wait until tomorrow")
            completion?()
            return
        }
        let notFound = outcomes.entries(source: source.rawValue)
        let waiting = userInitiated ? [] : outcomes.waiting(source: source.rawValue)
        let checkStored = includeStored || downloadedIds == nil
        let candidatesFromLibrary = downloadedIds ?? (userInitiated ? knownDownloadedIds ?? [] : [])
        if userInitiated && knownDownloadedIds == nil { scheduleInitialLibraryRead() }
        let placeholders = checkStored ? NativeOfflineLyrics.placeholderTrackIdsForRetry() : []
        statisticsQueue.async {
            let store = OfflineLyricsStore.shared
            // Spotify reports these downloaded: a removed download that came back may get lyrics again.
            if !seenDownloaded.isEmpty {
                do { try store.downloadsSeen(trackIds: Array(seenDownloaded)) }
                catch { writeDebugLog("[Lyrics] could not record downloaded tracks: \(error)") }
            }
            let candidates = candidatesFromLibrary.union(checkStored ? Set(store.savedTrackIds()).union(placeholders) : [])
            let retryable = store.automaticallyRetryableTrackIds(Array(candidates))
            let lacking = store.missingTrackIds(retryable, source: source.rawValue, options: options)
            let missing = lacking.filter { !notFound.contains($0) && !waiting.contains($0) }
            let known = lacking.count - missing.count
            if known > 0 {
                writeDebugLog("[Lyrics] \(reason): skipped \(known) tracks with a known result (no lyrics, or retry tomorrow)")
            }
            let order = missing.count > 1 ? Self.pixieCatalogOrder() : [:]
            let sorted = missing.sorted { (order[$0] ?? Int.max, $0) < (order[$1] ?? Int.max, $1) }
            DispatchQueue.main.async {
                defer {
                    completion?()
                    if let refresh, self.explicitRefresh == refresh {
                        self.explicitRefresh = nil
                        self.changed()
                    }
                }
                guard self.refreshGeneration == generation, !sorted.isEmpty, UserDefaults.offlineLyricsEnabled,
                      UserDefaults.lyricsSource == source, UserDefaults.lyricsOptions.downloadOptions == options else { return }
                let current = sorted.filter { (self.removedAt[$0] ?? .distantPast) <= observedAt }
                guard !current.isEmpty else { return }
                writeDebugLog("[Lyrics] \(reason): \(current.count) tracks lack \(source.description) lyrics")
                self.enqueue(current.map { ["uri": "spotify:track:\($0)"] }, allowPreviouslyDeleted: false,
                             priority: priority, tracksRefresh: showsProgress, rateLimitRetryIds: rateLimitRetryIds)
            }
        }
    }

    private static let catalogLock = NSLock()
    private static var catalogCache: (modified: Date, rows: [String: (title: String, artist: String)], order: [String: Int])?
    /// Position of each track in Pixie's offline catalog (library order).
    static func pixieCatalogOrder() -> [String: Int] {
        _ = pixieCatalogMetadata(trackId: "")
        catalogLock.lock(); defer { catalogLock.unlock() }
        return catalogCache?.order ?? [:]
    }
    /// Name and artist from Pixie's offline catalog (Library/Application Support/Pixie/offline-catalog.plist).
    static func pixieCatalogMetadata(trackId wanted: String) -> (title: String, artist: String)? {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pixie/offline-catalog.plist")
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        else { return nil }
        catalogLock.lock(); defer { catalogLock.unlock() }
        if catalogCache?.modified != modified {
            var rows: [String: (title: String, artist: String)] = [:]
            var order: [String: Int] = [:]
            if let data = try? Data(contentsOf: url),
               let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               let list = root["rows"] as? [[String: Any]] {
                for row in list {
                    if let id = (row["uri"] as? String).flatMap(Self.trackId), order[id] == nil { order[id] = order.count }
                    guard row["metadata_complete"] as? Bool != false,
                          let uri = row["uri"] as? String, let id = Self.trackId(uri),
                          let title = row["name"] as? String, let artist = row["artist_name"] as? String,
                          !title.isEmpty, !artist.isEmpty else { continue }
                    rows[id] = (title, artist)
                }
            }
            catalogCache = (modified, rows, order)
        }
        return catalogCache?.rows[wanted]
    }

    private static func trackId(_ uri: String) -> String? {
        guard uri.hasPrefix("spotify:track:") else { return nil }
        let id = String(uri.dropFirst(14))
        guard id.count == 22, id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else { return nil }
        return id
    }
    /// Whether Spotify has the track downloaded, as far as the library read knows (main thread).
    func isDownloaded(_ trackId: String) -> Bool {
        knownDownloadedIds?.contains(trackId) == true
    }
    private func changed() {
        if !hasLyricsWork { foreground.workFinished() }
        if !hasLyricsWork || !foreground.isActive {
            flushCheckpoint()
        } else if !checkpointWriteScheduled {
            checkpointWriteScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(750)) { [weak self] in
                if self?.checkpointWriteScheduled == true { self?.flushCheckpoint() }
            }
        }
        refreshStatisticsIfNeeded()
        NotificationCenter.default.post(name: Notification.Name("EeveeOfflineLyricsSettingsChanged"), object: nil)
    }
    private func refreshStatisticsIfNeeded(invalidate: Bool = false) {
        let input = StatisticsInput(ids: knownDownloadedIds, source: UserDefaults.lyricsSource, options: UserDefaults.lyricsOptions.downloadOptions)
        if invalidate || input != statisticsInput {
            statisticsInput = input
            statisticsRevision &+= 1
            statisticsNeedsFullRefresh = true
            statisticsReady = false
        }
        guard statisticsNeedsFullRefresh || !statisticsChangedIds.isEmpty else { return }
        guard !statisticsScheduled, !statisticsRunning else { return }
        statisticsScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150)) {
            self.statisticsScheduled = false
            guard let input = self.statisticsInput else { return }
            self.statisticsRunning = true
            let revision = self.statisticsRevision
            let full = self.statisticsNeedsFullRefresh
            let ids = input.ids ?? []
            let candidates = full ? ids : ids.intersection(self.statisticsChangedIds)
            self.statisticsNeedsFullRefresh = false
            self.statisticsChangedIds.removeAll()
            self.statisticsQueue.async {
                let summary = OfflineLyricsStore.shared.summary()
                let missing = OfflineLyricsStore.shared.missingTrackIds(Array(candidates),
                    source: input.source.rawValue, options: input.options)
                DispatchQueue.main.async {
                    self.statisticsRunning = false
                    guard revision == self.statisticsRevision,
                          input.source == UserDefaults.lyricsSource, input.options == UserDefaults.lyricsOptions.downloadOptions else {
                        self.refreshStatisticsIfNeeded()
                        return
                    }
                    self.savedTracks = summary.tracks
                    self.savedBytes = summary.bytes
                    if full { self.missingIds = Set(missing) }
                    else {
                        self.missingIds.subtract(candidates)
                        self.missingIds.formUnion(missing)
                    }
                    self.statisticsReady = true
                    NotificationCenter.default.post(name: Notification.Name("EeveeOfflineLyricsSettingsChanged"), object: nil)
                    self.refreshStatisticsIfNeeded()
                }
            }
        }
    }
    private func enqueue(_ rows: [[String: String]], allowPreviouslyDeleted: Bool = true,
                         priority: Operation.QueuePriority = .normal, tracksRefresh: Bool = false,
                         rateLimitRetryIds: Set<String> = [],
                         completion: ((JobStatus) -> Void)? = nil) {
        flushRemovals()
        defer { scheduleRateLimitRetriesIfReady(); changed() }
        let source = UserDefaults.lyricsSource
        let options = UserDefaults.lyricsOptions.downloadOptions
        guard source.isReplacingLyrics, UserDefaults.offlineLyricsEnabled else {
            for _ in rows { completion?(.cancelled) }
            return
        }
        let ids = rows.compactMap { $0["uri"].flatMap(Self.trackId) }
        do { if allowPreviouslyDeleted { try OfflineLyricsStore.shared.allowDownloads(trackIds: ids) } }
        catch {
            writeDebugLog("[Lyrics] could not prepare redownload: \(error)")
            for _ in rows { completion?(.failed) }
            return
        }
        for row in rows {
            guard let uri = row["uri"], let id = Self.trackId(uri) else {
                completion?(.failed)
                continue
            }
            submit(id: id, row: row, source: source, options: options, priority: priority,
                   metadataTimeout: 10, tracksRefresh: tracksRefresh, isRateLimitRetry: rateLimitRetryIds.contains(id),
                   completion: completion)
        }
    }

    /// Spotify's offline-lyrics HTTP request joins a queued or running fetch
    /// for the same track. Its caller still has a bounded wait for the reply.
    func lyricsForNativeDownload(trackId id: String, completion: @escaping (Result<Lyrics, Error>) -> Void) {
        DispatchQueue.main.async {
            let source = UserDefaults.lyricsSource
            guard Self.trackId("spotify:track:\(id)") != nil, source.isReplacingLyrics, UserDefaults.offlineLyricsEnabled else {
                completion(.failure(URLError(.cancelled)))
                return
            }
            guard self.foreground.isActive else {
                completion(.failure(URLError(.timedOut)))
                return
            }
            guard !self.foreground.networkUnavailable else {
                completion(.failure(URLError(.notConnectedToInternet)))
                return
            }
            self.submit(id: id, row: [:], source: source, options: UserDefaults.lyricsOptions.downloadOptions,
                        priority: .veryHigh, metadataTimeout: 3, nativeCompletion: completion)
            self.changed()
        }
    }

    private func submit(id: String, row: [String: String], source: LyricsSource, options: LyricsOptions,
                        priority: Operation.QueuePriority, metadataTimeout: TimeInterval, tracksRefresh: Bool = false,
                        isRateLimitRetry: Bool = false,
                        completion: ((JobStatus) -> Void)? = nil, nativeCompletion: ((Result<Lyrics, Error>) -> Void)? = nil) {
        let revision = OfflineLyricsStore.shared.revision(trackId: id)
        let key = Job.key(source: source, id: id)
        let previous = pending[key]
        if let job = previous, job.revision == revision, job.options == options {
            if tracksRefresh { trackRefresh(job) }
            if let completion { job.callbacks.append(completion) }
            if let nativeCompletion {
                if rateLimitedJobs[key] != nil { nativeCompletion(.failure(LyricsRequestLimitError())) }
                else { job.nativeCallbacks.append(nativeCompletion) }
            }
            if priority.rawValue > job.priority.rawValue {
                job.priority = priority
                job.operation?.queuePriority = priority
            }
            return
        }
        let job = Job(id: id, revision: revision, source: source, options: options,
                      row: row, priority: priority, metadataTimeout: metadataTimeout)
        if let completion { job.callbacks.append(completion) }
        if let nativeCompletion { job.nativeCallbacks.append(nativeCompletion) }
        pending[key] = job
        if tracksRefresh { trackRefresh(job) }
        if let previous {
            rateLimitedJobs[key] = nil
            previous.operation?.cancel()
            foreground.recheckWaitingRequests()
            previous.operation = nil
            deliver(.cancelled, to: previous)
        }
        job.isRateLimitRetry = isRateLimitRetry
        if isRateLimitRetry { rateLimitedJobs[key] = job }
        else { schedule(job, key: key) }
    }

    private func trackRefresh(_ job: Job) {
        if refreshProgress?.source != job.source || refreshProgress?.options != job.options {
            refreshProgress = RefreshProgress(source: job.source, options: job.options)
        }
        guard let group = refreshProgress, job.refresh !== group else { return }
        job.refresh = group
        group.progress.total += 1
    }

    private func schedule(_ job: Job, key: String) {
        let operation = BlockOperation {
            let outcome = self.fetch(job)
            DispatchQueue.main.async {
                guard self.pending[key] === job else { return }
                job.operation = nil
                self.finishAttempt(outcome, job: job)
            }
        }
        operation.queuePriority = job.priority
        job.operation = operation
        worker.addOperation(operation)
    }

    private func finishAttempt(_ outcome: Outcome, job: Job) {
        if case .failed(let error as LyricsRequestLimitError) = outcome, !job.isRateLimitRetry {
            job.isRateLimitRetry = true
            rateLimitedJobs[job.key] = job
            let callbacks = job.nativeCallbacks
            job.nativeCallbacks.removeAll()
            for callback in callbacks { callback(.failure(error)) }
            writeDebugLog("[Lyrics] HTTP 429 for \(job.id); retrying at the end of the queue")
        } else {
            if case .failed(let error) = outcome {
                if error is LyricsRequestLimitError {
                    writeDebugLog("[Lyrics] offline lyrics unavailable for \(job.id): HTTP 429 on retry; next try tomorrow")
                }
                Self.rememberFailure(error, job: job)
            }
            pending[job.key] = nil
            deliver(outcome, to: job)
        }
        scheduleRateLimitRetriesIfReady()
        changed()
    }

    private func scheduleRateLimitRetriesIfReady() {
        // Deferred jobs stay pending for progress, merging and cancellation.
        guard !scanningLibrary, !rateLimitedJobs.isEmpty, rateLimitedJobs.count == pending.count else { return }
        let retries = rateLimitedJobs
        rateLimitedJobs.removeAll()
        for (key, job) in retries { schedule(job, key: key) }
    }

    private func fetch(_ job: Job) -> Outcome {
        let store = OfflineLyricsStore.shared
        let id = job.id
        func cancelled() -> Bool { !job.isWanted }
        do { try foreground.whenActive(isCancelled: cancelled) }
        catch { return .cancelled }
        guard !store.automaticallyRetryableTrackIds([id]).isEmpty else { return .cancelled }
        if let entry = store.entry(trackId: id, source: job.source.rawValue, options: job.options),
           let cached = savedDisplayLyrics(entry) {
            LyricsNotFoundStore.shared.succeeded(id, source: job.source.rawValue)
            return .skipped(cached)
        }
        let title = job.row["name"] ?? ""
        let artist = job.row["artist_name"] ?? ""
        // The provider resolves missing metadata through the same catalog and native service.
        let metadata = title.isEmpty || artist.isEmpty ? nil : (title: title, artist: artist)
        while true {
            if cancelled() { return .cancelled }
            // One rejection covers every job queued before it: do not ask again.
            if let refused = LyricsNotFoundStore.shared.refusal(source: job.source.rawValue), refused >= job.queuedAt {
                return .failed(ProviderRefusedError())
            }
            do {
                try foreground.whenNetworkAvailable(isCancelled: cancelled)
                let lyrics = try downloadProviderLyrics(trackId: id, metadata: metadata,
                    metadataTimeout: job.metadataTimeout, expectedRevision: job.revision,
                    foreground: foreground, isCancelled: cancelled)
                guard job.isWanted else { return .cancelled }
                writeDebugLog("[Lyrics] offline lyrics ready for \(id)")
                return .saved(lyrics)
            } catch {
                if cancelled() { return .cancelled }
                if (error as? URLError)?.code == .cancelled { return .cancelled }
                if (error as? URLError)?.code == .notConnectedToInternet {
                    foreground.connectionFailed()
                    continue
                }
                // A 429 is logged where its retry is decided (finishAttempt).
                if !(error is LyricsRequestLimitError) {
                    writeDebugLog("[Lyrics] offline lyrics unavailable for \(id): \(error)")
                }
                return .failed(error)
            }
        }
    }

    private func deliver(_ outcome: Outcome, to job: Job) {
        let status: JobStatus
        let result: Result<Lyrics, Error>
        switch outcome {
        case .saved(let lyrics): (status, result) = (.saved, .success(lyrics))
        case .skipped(let lyrics): (status, result) = (.skipped, .success(lyrics))
        case .failed(let error):
            if case LyricsError.noSuchSong = error { status = .notFound }
            else { status = .failed }
            result = .failure(error)
        case .cancelled: (status, result) = (.cancelled, .failure(URLError(.cancelled)))
        }
        if let group = job.refresh, group === refreshProgress {
            group.progress.count(status)
            if group.progress.isDone { refreshProgress = nil }
        }
        for callback in job.callbacks { callback(status) }
        for callback in job.nativeCallbacks { callback(result) }
    }

    private func cancelPending() {
        refreshGeneration &+= 1
        explicitRefresh = nil
        restoringCheckpoint = false
        cancelledAt = Date()
        launchCheckpoint = nil
        readLibraryOnNextForeground = false
        scheduledLibraryRead?.cancel()
        scheduledLibraryRead = nil
        cancelLibraryRead?()
        cancelLibraryRead = nil
        completedDuringLibraryRead.removeAll()
        OfflineLyricsStore.shared.invalidatePendingWrites()
        foreground.recheckWaitingRequests()
        worker.cancelAllOperations()
        let cancelled = Array(pending.values)
        pending.removeAll()
        rateLimitedJobs.removeAll()
        batchID = nil
        batch = nil
        refreshProgress = nil
        scanningLibrary = false
        manualScanStarted = nil
        completedDuringManualScan.removeAll()
        flushCheckpoint()
        for job in cancelled {
            job.operation = nil
            deliver(.cancelled, to: job)
        }
        changed()
    }
    private func removed(_ event: [AnyHashable: Any]) {
        if event["all"] as? Bool == true {
            flushRemovals()
            Self.deleteSavedLyrics { error in if let error { writeDebugLog("[Lyrics] failed to clear offline lyrics: \(error)") } }
            NativeOfflineLyrics.shared.forgetNoLyrics(trackIds: nil)
            LyricsNotFoundStore.shared.forget(nil)
            return
        }
        let context = event["context"] as? String ?? ""
        let token = event["token"] as? String ?? ""
        let phase = event["phase"] as? String ?? "begin"
        if phase == "begin" { removalTokens[context] = token; removalStarted[context] = Date() }
        else if removalTokens[context] != token { return }
        var ids = (event["tracks"] as? [String] ?? []).compactMap(Self.trackId)
        if let id = Self.trackId(context) { ids.append(id) }
        ids.append(contentsOf: OfflineLyricsStore.shared.tracks(in: context))
        if phase == "resolved", let started = removalStarted[context] {
            ids = ids.filter { (requestedAt[$0] ?? .distantPast) <= started }
        }
        guard !ids.isEmpty else { return }
        let deleted = Date()
        for id in ids { removedAt[id] = deleted }
        completedDuringLibraryRead.subtract(ids)
        completedDuringManualScan.subtract(ids)
        knownDownloadedIds?.subtract(ids)
        // A mass removal posts one event per track. Writing the library, the store files,
        // SQLite and the settings UI once per track made the main thread stutter, so the
        // burst is applied once, before any later download event (see flushRemovals).
        removalBatch.formUnion(ids)
        guard !removalFlushScheduled else { return }
        removalFlushScheduled = true
        DispatchQueue.main.async { [weak self] in self?.flushRemovals() }
    }
    /// Applies removals collected from `removed`. Every path that can start or show
    /// downloads calls it first, so events keep the order in which they arrived.
    private func flushRemovals() {
        removalFlushScheduled = false
        guard !removalBatch.isEmpty else { return }
        let removedIds = removalBatch
        removalBatch.removeAll()
        let ids = Array(removedIds)
        persistKnownLibrary()
        do { try OfflineLyricsStore.shared.remove(trackIds: ids) }
        catch { writeDebugLog("[Lyrics] failed to remove offline lyrics: \(error)") }
        foreground.recheckWaitingRequests()
        for job in pending.values.filter({ removedIds.contains($0.id) }) {
            pending[job.key] = nil
            rateLimitedJobs[job.key] = nil
            job.operation?.cancel()
            job.operation = nil
            deliver(.cancelled, to: job)
        }
        for id in removedIds { KaraokeLyricsStore.shared.remove(trackId: id) }
        NativeOfflineLyrics.shared.forgetNoLyrics(trackIds: ids)
        LyricsNotFoundStore.shared.forget(ids)
        scheduleRateLimitRetriesIfReady()
        changed()
    }

    @objc static func settingsSnapshot() -> NSDictionary {
        let downloader = shared
        downloader.flushRemovals()
        downloader.refreshStatisticsIfNeeded()
        let visibleBatch = downloader.batch?.snapshot ?? downloader.refreshProgress?.progress.snapshot ?? [:]
        return ["library_known": downloader.knownDownloadedIds != nil, "library_total": downloader.knownDownloadedIds?.count ?? 0, "library_missing": downloader.missingIds.count,
                "all_saved": downloader.statisticsReady && downloader.knownDownloadedIds != nil && downloader.missingIds.isEmpty,
                "statistics_loading": !downloader.statisticsReady,
                "scan_active": downloader.scanningLibrary, "scan_completed": downloader.scanCompleted, "scan_total": downloader.scanTotal,
                "enabled": UserDefaults.offlineLyricsEnabled, "available": UserDefaults.lyricsSource.isReplacingLyrics,
                "tracks": downloader.savedTracks, "bytes": downloader.savedBytes, "source": UserDefaults.lyricsSource.description, "pending": downloader.pending.count, "batch": visibleBatch] as NSDictionary
    }
    @objc static func setDownloadsEnabled(_ enabled: Bool) {
        shared.flushRemovals()
        let wasEnabled = UserDefaults.offlineLyricsEnabled
        UserDefaults.offlineLyricsEnabled = enabled
        if enabled != wasEnabled { EeveePixieObserveDownloadCompletion(enabled) }
        if enabled && !wasEnabled { shared.knownDownloadedIds = nil; shared.persistKnownLibrary() }
        if !enabled { shared.cancelPending() }
        shared.changed()
        if enabled && !wasEnabled { shared.scheduleInitialLibraryRead() }
    }
    @objc(deleteSavedLyricsWithCompletion:)
    static func deleteSavedLyrics(completion: @escaping (NSString?) -> Void) {
        shared.flushRemovals()
        let ids = shared.pending.values.map(\.id) + NativeOfflineLyrics.placeholderTrackIdsForRetry()
        shared.clearedAt = Date()
        shared.cancelPending()
        DispatchQueue.global(qos: .utility).async {
            var failure: NSString?
            do { try OfflineLyricsStore.shared.removeAll(additionallySuppressing: ids) }
            catch { failure = error.localizedDescription as NSString }
            let error = failure
            DispatchQueue.main.async {
                KaraokeLyricsStore.shared.clear()
                shared.changed()
                completion(error)
            }
        }
    }
    @objc static func cancelDownloads() { shared.cancelPending() }

    @objc static func beginLibraryScan() {
        shared.scanningLibrary = true
        shared.manualScanStarted = Date()
        shared.completedDuringManualScan.removeAll()
        shared.scanCompleted = 0
        shared.scanTotal = 0
        shared.changed()
    }
    @objc(libraryScanProgress:total:)
    static func libraryScanProgress(_ completed: Int, total: Int) {
        guard shared.scanningLibrary else { return }
        shared.scanCompleted = completed
        shared.scanTotal = total
        shared.changed()
    }
    @objc static func endLibraryScan() {
        if shared.scanningLibrary {
            shared.batchID = nil
            shared.manualScanStarted = nil
            shared.completedDuringManualScan.removeAll()
        }
        shared.scanningLibrary = false
        shared.scheduleRateLimitRetriesIfReady()
        shared.changed()
    }

    @objc static func downloadForTracks(_ input: NSArray) {
        guard shared.scanningLibrary else { return }
        guard UserDefaults.offlineLyricsEnabled, UserDefaults.lyricsSource.isReplacingLyrics, shared.batchID == nil else {
            endLibraryScan(); return
        }
        let started = shared.manualScanStarted ?? Date()
        let rows = (input as? [[String: Any]] ?? []).compactMap { row -> [String: String]? in
            guard let uri = row["uri"] as? String, let id = trackId(uri),
                  (shared.removedAt[id] ?? .distantPast) <= started || shared.completedDuringManualScan.contains(id) else { return nil }
            var strings = row.compactMapValues { $0 as? String }
            if row["metadata_complete"] as? Bool == false {
                strings["name"] = nil; strings["artist_name"] = nil
            }
            return strings
        }
        var seen = Set<String>()
        let unique = rows.filter { seen.insert($0["uri"]!).inserted }
        let ids = Set(unique.compactMap { $0["uri"].flatMap(trackId) })
        shared.knownDownloadedIds = ids.union(shared.completedDuringManualScan)
        shared.persistKnownLibrary()
        let token = UUID()
        shared.batchID = token
        let source = UserDefaults.lyricsSource
        let options = UserDefaults.lyricsOptions.downloadOptions
        shared.changed()
        // The catalog callback runs on main. Preparing a cold sidecar index for
        // thousands of tracks must finish in the worker, without blocking UIKit.
        shared.statisticsQueue.async {
            let missing = Set(OfflineLyricsStore.shared.missingTrackIds(Array(ids), source: source.rawValue, options: options))
            let needed = unique.filter { row in row["uri"].flatMap(trackId).map(missing.contains) ?? false }
            DispatchQueue.main.async {
                guard shared.batchID == token, shared.scanningLibrary else { return }
                let valid = ids.filter { (shared.removedAt[$0] ?? .distantPast) <= started || shared.completedDuringManualScan.contains($0) }
                shared.scanningLibrary = false
                shared.manualScanStarted = nil
                shared.completedDuringManualScan.removeAll()
                guard UserDefaults.offlineLyricsEnabled, UserDefaults.lyricsSource == source, UserDefaults.lyricsOptions.downloadOptions == options else {
                    shared.batchID = nil; shared.scheduleRateLimitRetriesIfReady(); shared.changed(); return
                }
                let current = needed.filter { $0["uri"].flatMap(trackId).map(valid.contains) ?? false }
                shared.startBatch(current, catalog: unique, token: token)
            }
        }
    }
    private func startBatch(_ needed: [[String: String]], catalog: [[String: String]], token: UUID) {
        flushRemovals()
        guard !needed.isEmpty else {
            batchID = nil; batch = nil; scheduleRateLimitRetriesIfReady(); changed(); return
        }
        batch = Progress(isRefresh: false, total: needed.count)
        var albums: [String: [String]] = [:]
        for row in catalog {
            if let album = row["album_uri"], let uri = row["uri"], let id = Self.trackId(uri) { albums[album, default: []].append(id) }
        }
        let contexts = albums
        worker.addOperation {
            do { try OfflineLyricsStore.shared.remember(contexts: contexts) }
            catch { writeDebugLog("[Lyrics] could not save album membership: \(error)") }
        }
        enqueue(needed) { status in
            guard self.batchID == token, var progress = self.batch else { return }
            progress.count(status)
            if progress.isDone {
                writeDebugLog("[Lyrics] Missing completed \(progress.completed)/\(progress.total): \(progress.summary)")
                self.batchID = nil
                self.batch = nil
            } else {
                self.batch = progress
            }
        }
    }
}
