import Foundation

func check(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError(message) }
}
func pump(until condition: () -> Bool, _ message: String) {
    let deadline = Date().addingTimeInterval(5)
    while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    check(condition(), message)
}
/// Removal events are applied together on the next main-queue turn.
func drainMain() { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }

// Deliberately slow storage: a settings refresh must stay responsive even while
// another queue is stuck reading a cold library. Compile the real downloader.
struct LyricsOptions: Equatable, Codable { var value = 0; var downloadOptions: Self { self } }
struct CheckpointFixture: Encodable {
    let source: Int
    let options: LyricsOptions
    let ids: [String]
    let recheckCatalog: Bool
    var rateLimitRetryIds: [String] = []
}
enum LyricsSource: Int {
    case spicy = 5, genius = 0, petit = 3
    var isReplacingLyrics: Bool { true }
    var description: String { "test" }
}
extension UserDefaults {
    static let container = UserDefaults(suiteName: "OfflineLyricsDownloaderTests-\(UUID())")!
    static var lyricsSource = LyricsSource.spicy
    static var lyricsOptions = LyricsOptions()
    static var offlineLyricsEnabled = true
}
extension Notification.Name {
    static let eeveeOfflineLyricsFilesChanged = Notification.Name("EeveeOfflineLyricsFilesChanged")
}
final class OfflineLyricsStore {
    static let shared = OfflineLyricsStore()
    struct Revision: Equatable { let epoch: Int }
    struct Entry { let data: Data }
    struct Summary { let tracks: Int; let bytes: Int }
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private var firstRead = true // statistics queue only
    func summary() -> Summary {
        check(!Thread.isMainThread, "Settings scanned the store on the main thread")
        if firstRead { firstRead = false; entered.signal(); release.wait() }
        return Summary(tracks: 7, bytes: 1234)
    }
    func missingTrackIds(_ ids: [String], source: Int, options: LyricsOptions) -> [String] {
        check(!Thread.isMainThread, "Library preparation scanned files on the main thread")
        statisticsLock.lock()
        queriedIds = Set(ids)
        statisticsLock.unlock()
        return source == LyricsSource.genius.rawValue ? [] : ids.filter { !alreadySaved.contains($0) }
    }
    private let statisticsLock = NSLock()
    private var queriedIds = Set<String>()
    var lastQueriedIds: Set<String> {
        statisticsLock.lock(); defer { statisticsLock.unlock() }
        return queriedIds
    }
    var alreadySaved = Set<String>()
    var saved: [String] = []
    var blockSaved = false
    let savedEntered = DispatchSemaphore(value: 0), savedRelease = DispatchSemaphore(value: 0)
    var suppressed = Set<String>()
    var removedDownloads = Set<String>()
    func savedTrackIds() -> [String] {
        if blockSaved { blockSaved = false; savedEntered.signal(); savedRelease.wait() }
        return saved
    }
    func automaticallyRetryableTrackIds(_ ids: [String]) -> [String] {
        ids.filter { !suppressed.contains($0) && !removedDownloads.contains($0) }
    }
    func downloadsSeen(trackIds: [String]) throws { removedDownloads.subtract(trackIds) }
    func revision(trackId: String) -> Revision { Revision(epoch: 0) }
    func isCurrent(_ revision: Revision, trackId: String) -> Bool { true }
    func entry(trackId: String, source: Int, options: LyricsOptions) -> Entry? { nil }
    func remember(context: String, trackIds: [String]) throws {}
    func remember(contexts: [String: [String]]) throws {}
    func tracks(in context: String) -> [String] { [] }
    func allowDownloads(trackIds: [String]) throws { suppressed.subtract(trackIds); removedDownloads.subtract(trackIds) }
    func invalidatePendingWrites() {}
    var removeCalls = 0
    var removeSizes: [Int] = []
    func remove(trackIds: [String]) throws { removeCalls += 1; removeSizes.append(trackIds.count); removedDownloads.formUnion(trackIds) }
    func removeAll(additionallySuppressing: [String]) throws { suppressed.formUnion(additionallySuppressing) }
}
final class KaraokeLyricsStore {
    static let shared = KaraokeLyricsStore()
    func remove(trackId: String) {}
    func clear() {}
}
// The offline custom lyrics hook the downloader calls when the network goes away.
final class KaraokePlaybackTracker {
    static let shared = KaraokePlaybackTracker()
    func playerReportedTrackId() -> String? { nil }
    func isPlaying() -> Bool { false }
}
func publishSavedLyrics(trackId: String) {}
func savedDisplayLyrics(_ entry: OfflineLyricsStore.Entry) -> Lyrics? { nil }
final class NativeOfflineLyrics {
    static let shared = NativeOfflineLyrics()
    static var placeholders: [String] = []
    static func placeholderTrackIdsForRetry() -> [String] { placeholders }
    var forgotten: [String] = []
    var forgetCalls = 0
    func forgetNoLyrics(trackIds: [String]?) { forgetCalls += 1; forgotten += trackIds ?? [] }
    func providerHasNoLyrics(trackId: String) {}
}
struct Lyrics {
    init(serializedBytes: Data) throws {}
    var hasData: Bool { false }
}
enum LyricsError: Error { case noSuchSong, invalidSpicyKey }
enum OfflineLyricsFetchError: Error { case noMetadata, metadataUnavailable }
struct LyricsProviderHTTPError: Error { let status: Int }
private let logLock = NSLock()
private var debugLines: [String] = []
func writeDebugLog(_ message: String) { logLock.lock(); debugLines.append(message); logLock.unlock() }
func logged(_ text: String) -> Int {
    logLock.lock(); defer { logLock.unlock() }
    return debugLines.filter { $0.contains(text) }.count
}
private var libraryReads = 0
private var libraryCallback: (([String]?) -> Void)?
private var libraryCancels = 0
private var observingAudio = false
func EeveePixieObserveDownloadCompletion(_ enabled: Bool) { observingAudio = enabled }
func EeveePixieReadDownloadedTrackURIs(_ completion: @escaping ([String]?) -> Void) -> (() -> Void)? {
    libraryReads += 1
    libraryCallback = completion
    return { libraryCancels += 1 }
}
private let fetchLock = NSLock()
private var fetchedCount = 0
private var attemptsByTrack: [String: Int] = [:]
private var fetchGates: [String: DispatchSemaphore] = [:]
private let disconnectedTrack = "0000000000000000000821"
private let multiStepTrack = "0000000000000000000723"
private let failingTrack = "0000000000000000000901"
private let rateLimitedTwice = "0000000000000000000911"
private let rateLimitedOnce = "0000000000000000000912"
private let rateLimitCompanion = "0000000000000000000913"
private let restoredRateLimitRetry = "0000000000000000000914"
private let definiteMiss = "0000000000000000000951"
private let noTitleTrack = "0000000000000000000952"
private let titleLookupDown = "0000000000000000000953"
private let serverDownTrack = "0000000000000000000954"
private let rateLimitedLaunch = "0000000000000000000955"
private let refusedTrack = "0000000000000000000956"
private let afterRefusalTrack = "0000000000000000000957"
private let followupReached = DispatchSemaphore(value: 0)
private let followupStarted = DispatchSemaphore(value: 0)
var fetched: Int { fetchLock.lock(); defer { fetchLock.unlock() }; return fetchedCount }
func attempts(_ id: String) -> Int { fetchLock.lock(); defer { fetchLock.unlock() }; return attemptsByTrack[id, default: 0] }
func holdFetch(_ id: String) -> DispatchSemaphore {
    fetchLock.lock(); defer { fetchLock.unlock() }
    let gate = DispatchSemaphore(value: 0)
    fetchGates[id] = gate
    return gate
}
@discardableResult
func downloadProviderLyrics(trackId id: String,
    metadata: (title: String, artist: String)?, metadataTimeout: TimeInterval,
    expectedRevision: OfflineLyricsStore.Revision, foreground: LyricsForegroundExecution,
    isCancelled: @escaping () -> Bool) throws -> Lyrics {
    check(metadataTimeout == 10 || metadataTimeout == 3, "Unexpected metadata deadline")
    if id == "0000000000000000000099" {
        check(metadata == nil && metadataTimeout == 10, "The bulk fetch changed metadata behavior")
    }
    fetchLock.lock()
    fetchedCount += 1
    attemptsByTrack[id, default: 0] += 1
    let gate = fetchGates.removeValue(forKey: id)
    fetchLock.unlock()
    if let gate {
        while !isCancelled() && gate.wait(timeout: .now() + 0.01) == .timedOut {}
        if isCancelled() { throw URLError(.cancelled) }
    }
    if id == disconnectedTrack && attempts(id) == 1 { throw URLError(.notConnectedToInternet) }
    if id == failingTrack { throw URLError(.timedOut) }
    if id == noTitleTrack { throw OfflineLyricsFetchError.noMetadata }
    if id == titleLookupDown { throw OfflineLyricsFetchError.metadataUnavailable }
    if id == serverDownTrack { throw LyricsProviderHTTPError(status: 503) }
    if id == refusedTrack || id == afterRefusalTrack { throw LyricsProviderHTTPError(status: 403) }
    if id == rateLimitedTwice || id == restoredRateLimitRetry || id == rateLimitedLaunch
        || (id == rateLimitedOnce && attempts(id) == 1) {
        throw LyricsRequestLimitError()
    }
    if id == rateLimitedOnce || id == rateLimitCompanion { return try Lyrics(serializedBytes: Data()) }
    if id == multiStepTrack {
        followupReached.signal()
        try foreground.whenActive(isCancelled: isCancelled) { followupStarted.signal() }
    }
    throw LyricsError.noSuchSong
}

let downloader = EeveeOfflineLyricsDownloader.shared
downloader.start()
let cold = EeveeOfflineLyricsDownloader.settingsSnapshot()
check(cold["statistics_loading"] as? Bool == true, "Cold statistics claimed to be ready")
var entered = false
pump(until: {
    if !entered { entered = OfflineLyricsStore.shared.entered.wait(timeout: .now()) == .success }
    return entered
}, "Background statistics never started")

EeveeOfflineLyricsDownloader.beginLibraryScan()
EeveeOfflineLyricsDownloader.libraryScanProgress(57, total: 1107)
// Equivalent to many page observers/re-entries while the cold disk read is held.
for _ in 0..<1000 {
    let snapshot = EeveeOfflineLyricsDownloader.settingsSnapshot()
    check(snapshot["scan_active"] as? Bool == true, "Page refresh lost the active scan")
    check(snapshot["scan_completed"] as? Int == 57 && snapshot["scan_total"] as? Int == 1107,
          "Page refresh reset scan progress to 0/0")
}
let rows = (0..<1107).map { ["uri": "spotify:track:" + String(format: "%022d", $0)] }
EeveeOfflineLyricsDownloader.downloadForTracks(rows as NSArray)
check(EeveeOfflineLyricsDownloader.settingsSnapshot()["scan_active"] as? Bool == true,
      "Cold index preparation falsely completed the scan")
EeveeOfflineLyricsDownloader.cancelDownloads()
UserDefaults.lyricsSource = .genius
_ = EeveeOfflineLyricsDownloader.settingsSnapshot()
OfflineLyricsStore.shared.release.signal()
pump(until: { EeveeOfflineLyricsDownloader.settingsSnapshot()["statistics_loading"] as? Bool == false },
     "Statistics did not recover after a provider switch")
let ready = EeveeOfflineLyricsDownloader.settingsSnapshot()
check(ready["tracks"] as? Int == 7 && ready["bytes"] as? Int == 1234, "Statistics were not published")
check(ready["all_saved"] as? Bool == true, "Stale provider results replaced current statistics")
check(ready["scan_active"] as? Bool == false && ready["pending"] as? Int == 0 && fetched == 0,
      "Cancelled library preparation restarted downloads")
UserDefaults.lyricsSource = .spicy
pump(until: { EeveeOfflineLyricsDownloader.settingsSnapshot()["library_missing"] as? Int == rows.count },
     "Initial Missing count did not cover the whole library")
let oneSavedId = String(format: "%022d", 15)
OfflineLyricsStore.shared.alreadySaved.insert(oneSavedId)
NotificationCenter.default.post(name: .eeveeOfflineLyricsFilesChanged, object: nil,
                                userInfo: ["tracks": [oneSavedId, "trackOutsideLibrary"]])
check(EeveeOfflineLyricsDownloader.settingsSnapshot()["statistics_loading"] as? Bool == false,
      "One saved text put the full Missing count back into loading state")
pump(until: { EeveeOfflineLyricsDownloader.settingsSnapshot()["library_missing"] as? Int == rows.count - 1 },
     "The saved text did not decrement Missing")
check(OfflineLyricsStore.shared.lastQueriedIds == [oneSavedId], "One saved text rescanned the full library")
OfflineLyricsStore.shared.alreadySaved.remove(oneSavedId)
NotificationCenter.default.post(name: .eeveeOfflineLyricsFilesChanged, object: nil,
                                userInfo: ["tracks": [oneSavedId]])
pump(until: { EeveeOfflineLyricsDownloader.settingsSnapshot()["library_missing"] as? Int == rows.count },
     "Deleting a saved text did not increment Missing")
check(OfflineLyricsStore.shared.lastQueriedIds == [oneSavedId], "One deleted text rescanned the full library")
EeveeOfflineLyricsDownloader.beginLibraryScan()
EeveeOfflineLyricsDownloader.downloadForTracks([
    ["uri": "spotify:track:0000000000000000000099", "name": "spotify:track:0000000000000000000099",
     "artist_name": "Unknown artist", "metadata_complete": false]
] as NSArray)
pump(until: { fetched == 1 && EeveeOfflineLyricsDownloader.settingsSnapshot()["pending"] as? Int == 0 },
     "An incomplete catalog row never reached the native metadata fallback")
print("Offline lyrics responsive snapshots, retained progress and cancelled preparation passed")

// Keep one job pending so the progress snapshot exposes both finished outcomes.
let absentTrack = "0000000000000000000902"
let heldTrack = "0000000000000000000903"
let progressTracks = [failingTrack, absentTrack, heldTrack]
func checkFailureCounts(refresh: Bool) {
    let gate = holdFetch(heldTrack)
    if refresh {
        downloader.refreshForCurrentSource(downloadedIds: Set(progressTracks))
    } else {
        EeveeOfflineLyricsDownloader.beginLibraryScan()
        EeveeOfflineLyricsDownloader.downloadForTracks(progressTracks.map { ["uri": "spotify:track:\($0)"] } as NSArray)
    }
    func progress() -> [String: Any] { EeveeOfflineLyricsDownloader.settingsSnapshot()["batch"] as? [String: Any] ?? [:] }
    pump(until: { progress()["completed"] as? Int == 2 }, "Two completed lyrics jobs did not update progress")
    let batch = progress()
    check(batch["failed"] as? Int == 1 && batch["not_found"] as? Int == 1,
          "A missing text and a timed-out request shared the same failure count")
    check((batch["kind"] as? String == "refresh") == refresh, "Wrong lyrics progress snapshot")
    gate.signal()
    pump(until: { progress().isEmpty }, "Finished progress remained visible")
}
checkFailureCounts(refresh: true)
checkFailureCounts(refresh: false)

// Provider switch: every track saved with another provider is queued for the new
// one; a definite "not found" is remembered so the next launch does not ask again.
let before = fetched
OfflineLyricsStore.shared.saved = ["0000000000000000000201", "0000000000000000000202"]
downloader.refreshForCurrentSource()
pump(until: { fetched == before + 2 && EeveeOfflineLyricsDownloader.settingsSnapshot()["pending"] as? Int == 0 },
     "Provider refresh did not queue the saved tracks")
RunLoop.current.run(until: Date().addingTimeInterval(0.2))
downloader.refreshForCurrentSource()
RunLoop.current.run(until: Date().addingTimeInterval(0.5))
check(fetched == before + 2, "Provider refresh asked again for tracks the provider does not have")
print("Provider refresh queues saved tracks once and skips definite misses")

// An empty protective native row must not hide a transport failure forever.
// Explicitly deleted lyrics stay deleted, including across the automatic repair.
let missingMarker = "0000000000000000000301", deletedMarker = "0000000000000000000302"
NativeOfflineLyrics.placeholders = [missingMarker, deletedMarker]
OfflineLyricsStore.shared.suppressed.insert(deletedMarker)
let beforeRecovery = fetched
downloader.refreshForCurrentSource()
pump(until: { fetched == beforeRecovery + 1 && EeveeOfflineLyricsDownloader.settingsSnapshot()["pending"] as? Int == 0 },
     "missing native marker was not repaired, or deleted lyrics were requeued")

// A queued statistics read can finish after Cancel. Its old result must not
// restart downloads (or clear persisted deletion protection) on the main queue.
OfflineLyricsStore.shared.saved = ["0000000000000000000401"]
NativeOfflineLyrics.placeholders = []
OfflineLyricsStore.shared.blockSaved = true
downloader.refreshForCurrentSource()
var savedEntered = false
pump(until: {
    if !savedEntered { savedEntered = OfflineLyricsStore.shared.savedEntered.wait(timeout: .now()) == .success }
    return savedEntered
}, "refresh did not reach the blocked storage read")
let beforeCancel = fetched
EeveeOfflineLyricsDownloader.cancelDownloads()
OfflineLyricsStore.shared.savedRelease.signal()
RunLoop.current.run(until: Date().addingTimeInterval(0.3))
check(fetched == beforeCancel && EeveeOfflineLyricsDownloader.settingsSnapshot()["pending"] as? Int == 0,
      "a stale automatic refresh restarted downloads after Cancel")

NativeOfflineLyrics.placeholders = ["0000000000000000000501"]
var cleared = false
EeveeOfflineLyricsDownloader.deleteSavedLyrics { _ in cleared = true }
pump(until: { cleared }, "delete saved lyrics did not finish")
check(OfflineLyricsStore.shared.suppressed.contains("0000000000000000000501"), "Delete saved lyrics omitted a marker without a sidecar")
let suppressedID = "0000000000000000000501"
var suppressedReplies = 0
downloader.lyricsForNativeDownload(trackId: suppressedID) { result in
    if case .failure = result { suppressedReplies += 1 }
}
pump(until: { suppressedReplies == 1 }, "Spotify did not get a reply for a deleted text")
check(attempts(suppressedID) == 0, "Spotify fetched lyrics that the user explicitly deleted")
print("Automatic recovery repairs missing markers, respects deletion and discards refresh results after Cancel")

let audioFinished = Notification.Name("EeveeOfflineAudioTrackDownloaded")
let autoID = "0000000000000000000601"
let deletedAutoID = "0000000000000000000501"
let beforeAudio = fetched
func emitDownload(_ id: String, at time: Date = Date()) {
    NotificationCenter.default.post(name: audioFinished, object: nil,
        userInfo: ["uri": "spotify:track:\(id)", "completed_at": time.timeIntervalSince1970])
}
check(observingAudio, "native completion observer was not enabled for lyrics")
emitDownload(autoID)
emitDownload(autoID)
emitDownload(deletedAutoID)
pump(until: { fetched == beforeAudio + 1 && EeveeOfflineLyricsDownloader.settingsSnapshot()["pending"] as? Int == 0 },
     "a newly discovered track without any lyric row was not queued, or deletion was ignored")
check(libraryReads == 0, "a single-track completion opened the whole catalog")
let staleCompletionTime = Date()
EeveeOfflineLyricsDownloader.cancelDownloads()
emitDownload("0000000000000000000602", at: staleCompletionTime)
OfflineLyricsStore.shared.saved = []
NativeOfflineLyrics.placeholders = []
EeveeOfflineLyricsDownloader.setDownloadsEnabled(false)
check(!observingAudio, "turning lyrics off left the audio observer enabled")
EeveeOfflineLyricsDownloader.setDownloadsEnabled(true)
pump(until: { libraryReads == 1 }, "re-enable did not schedule catchup for existing downloads")
EeveeOfflineLyricsDownloader.cancelDownloads()
libraryCallback?(["spotify:track:0000000000000000000603"])
RunLoop.current.run(until: Date().addingTimeInterval(0.2))
check(libraryCancels == 1 && fetched == beforeAudio + 1, "stale catalog reply enqueued lyrics after Cancel")
print("Audio completion queues one track with no catalog read and respects deletion and Cancel")

let manualFirst = "0000000000000000000701", freshAudio = "0000000000000000000702"
let manualGate = holdFetch(manualFirst)
EeveeOfflineLyricsDownloader.beginLibraryScan()
EeveeOfflineLyricsDownloader.downloadForTracks([["uri": "spotify:track:\(manualFirst)"]] as NSArray)
pump(until: { attempts(manualFirst) == 1 }, "Manual batch never started")
var pluginReplies = 0
downloader.lyricsForNativeDownload(trackId: manualFirst) { result in
    if case .failure(LyricsError.noSuchSong) = result { pluginReplies += 1 }
}
emitDownload(manualFirst)
emitDownload(freshAudio)
// One song loads at a time: the new audio waits in the queue behind the manual fetch.
pump(until: { EeveeOfflineLyricsDownloader.settingsSnapshot()["pending"] as? Int == 2 },
     "New audio could not enqueue a text while a manual batch ran")
check(attempts(freshAudio) == 0, "A second song loaded while one was already loading")
check(attempts(manualFirst) == 1 && pluginReplies == 0, "Spotify's request did not join the manual fetch")
manualGate.signal()
pump(until: { pluginReplies == 1 && attempts(freshAudio) == 1
              && EeveeOfflineLyricsDownloader.settingsSnapshot()["pending"] as? Int == 0 },
     "Manual and Spotify callers did not finish together, or the queued audio never loaded")
check(attempts(manualFirst) == 1, "The same track fetched twice after joining")

let audioFirst = "0000000000000000000711", completedDuringScan = "0000000000000000000712"
let audioGate = holdFetch(audioFirst)
emitDownload(audioFirst)
pump(until: { attempts(audioFirst) == 1 }, "Audio-initiated fetch never started")
EeveeOfflineLyricsDownloader.beginLibraryScan()
emitDownload(completedDuringScan)
EeveeOfflineLyricsDownloader.downloadForTracks([["uri": "spotify:track:\(audioFirst)"]] as NSArray)
pump(until: {
    let snapshot = EeveeOfflineLyricsDownloader.settingsSnapshot()
    // One song loads at a time: the completed track waits behind the held fetch.
    return snapshot["scan_active"] as? Bool == false && snapshot["pending"] as? Int == 2
}, "The scan blocked a new audio completion or failed to start its batch")
check(EeveeOfflineLyricsDownloader.settingsSnapshot()["library_total"] as? Int == 2,
      "The catalog snapshot lost the track completed during the scan")
audioGate.signal()
pump(until: { EeveeOfflineLyricsDownloader.settingsSnapshot()["pending"] as? Int == 0 }, "Joined batch did not complete")
check(attempts(completedDuringScan) == 1, "The track completed during the scan never loaded")
check(attempts(audioFirst) == 1, "Manual scan repeated the audio-initiated fetch")
print("Manual, automatic and Spotify lyrics requests merge in either order")

let inFlight = "0000000000000000000721"
let finishInFlight = holdFetch(inFlight)
EeveeOfflineLyricsDownloader.beginLibraryScan()
EeveeOfflineLyricsDownloader.downloadForTracks([["uri": "spotify:track:\(inFlight)"]] as NSArray)
pump(until: { attempts(inFlight) == 1 }, "The test fetch did not start")
downloader.foreground.didEnterBackground()
let arrivedWhileInactive = "0000000000000000000722"
emitDownload(arrivedWhileInactive)
pump(until: { EeveeOfflineLyricsDownloader.settingsSnapshot()["pending"] as? Int == 2 },
     "An audio completion while inactive did not preserve its lyrics job")
check(attempts(inFlight) == 1 && attempts(arrivedWhileInactive) == 0,
      "Lyrics started a provider request while Spotify was inactive")
var pausedNativeReplied = false
downloader.lyricsForNativeDownload(trackId: inFlight) { result in
    if case .failure(let error) = result { pausedNativeReplied = (error as? URLError)?.code == .timedOut }
}
pump(until: { pausedNativeReplied }, "A paused lyrics queue blocked Spotify's offline request")
let checkpointKey = "PixieLyricsPendingQueue"
let pendingCheckpoint = UserDefaults.container.data(forKey: checkpointKey)
check(pendingCheckpoint != nil, "Entering the background did not checkpoint unfinished texts")
let paused = EeveeOfflineLyricsDownloader.settingsSnapshot()
check((paused["batch"] as? [String: Any])?["completed"] as? Int == 0 && paused["pending"] as? Int == 2,
      "Paused work was lost or counted as completed")
finishInFlight.signal()
pump(until: { EeveeOfflineLyricsDownloader.settingsSnapshot()["pending"] as? Int == 1 },
     "A started request was not allowed to finish during inactivity")
check(attempts(arrivedWhileInactive) == 0, "Finishing a running request started new work while inactive")
downloader.foreground.didBecomeActive()
pump(until: { EeveeOfflineLyricsDownloader.settingsSnapshot()["pending"] as? Int == 0 }, "Foreground did not resume lyrics")
check(UserDefaults.container.data(forKey: checkpointKey) == nil, "Finishing the queue left an obsolete checkpoint")
check(attempts(inFlight) == 1 && attempts(arrivedWhileInactive) == 1,
      "Returning restarted an already completed request or duplicated the queued audio text")

// Minimized while Spotify plays: iOS keeps it running, so the queue keeps going.
let whilePlaying = "0000000000000000000799"
downloader.foreground.isPlaying = { true }
downloader.foreground.didEnterBackground()
emitDownload(whilePlaying)
pump(until: { attempts(whilePlaying) == 1 && EeveeOfflineLyricsDownloader.settingsSnapshot()["pending"] as? Int == 0 },
     "Lyrics paused while Spotify kept playing in the background")
downloader.foreground.isPlaying = { false }
downloader.foreground.didBecomeActive()
print("Minimized lyrics pause without playback and continue while Spotify plays")

let finishFirstStep = holdFetch(multiStepTrack)
emitDownload(multiStepTrack)
pump(until: { attempts(multiStepTrack) == 1 }, "The first provider step did not start")
downloader.foreground.didEnterBackground()
finishFirstStep.signal()
var reachedFollowup = false
pump(until: {
    if !reachedFollowup { reachedFollowup = followupReached.wait(timeout: .now()) == .success }
    return reachedFollowup
}, "A running step was cancelled instead of reaching the following request")
check(followupStarted.wait(timeout: .now()) == .timedOut, "A fresh provider request started while inactive")
downloader.foreground.didBecomeActive()
pump(until: { EeveeOfflineLyricsDownloader.settingsSnapshot()["pending"] as? Int == 0 },
     "The follow-up request did not continue automatically")
check(followupStarted.wait(timeout: .now()) == .success && attempts(multiStepTrack) == 1,
      "Returning to the foreground reissued the first provider step")
print("Running requests finish normally and deferred requests resume on activation")

let refreshOne = "0000000000000000000731", refreshTwo = "0000000000000000000732"
let firstRefreshFetch = holdFetch(refreshOne), secondRefreshFetch = holdFetch(refreshTwo)
OfflineLyricsStore.shared.saved = [refreshOne, refreshTwo]
downloader.refreshForCurrentSource(userInitiated: true)
func visibleBatch() -> [String: Any] {
    EeveeOfflineLyricsDownloader.settingsSnapshot()["batch"] as? [String: Any] ?? [:]
}
// One song loads at a time: the second waits until the first completes.
pump(until: { attempts(refreshOne) + attempts(refreshTwo) == 1 }, "Provider refresh did not start")
check(visibleBatch()["kind"] as? String == "refresh" && visibleBatch()["total"] as? Int == 2,
      "Automatic refresh did not publish its own visible progress")
let refreshFirstGate = attempts(refreshOne) == 1 ? firstRefreshFetch : secondRefreshFetch
let refreshSecondGate = attempts(refreshOne) == 1 ? secondRefreshFetch : firstRefreshFetch
refreshFirstGate.signal()
pump(until: { visibleBatch()["completed"] as? Int == 1 && attempts(refreshOne) == 1 && attempts(refreshTwo) == 1 },
     "Refresh progress failed to count a completed job, or the next job never started")
refreshSecondGate.signal()
pump(until: { visibleBatch().isEmpty }, "Completed refresh left an active progress panel")
print("Automatic provider refresh reports progress and clears its panel on completion")

let switchedTrack = "0000000000000000000733"
let oldProviderFetch = holdFetch(switchedTrack)
emitDownload(switchedTrack)
pump(until: { attempts(switchedTrack) == 1 }, "Old provider fetch never started")
OfflineLyricsStore.shared.saved = []
UserDefaults.lyricsSource = .petit
downloader.refreshForCurrentSource(userInitiated: true)
pump(until: {
    attempts(switchedTrack) == 2 && EeveeOfflineLyricsDownloader.settingsSnapshot()["pending"] as? Int == 0
}, "Switching provider did not cancel the old request and refresh a downloaded track without tapping Missing")
oldProviderFetch.signal()
print("Switching provider cancels old requests and automatically queues downloads for the new source")

// The first -1009 must keep the manual job alive, including its progress.
let disconnectGate = holdFetch(disconnectedTrack)
EeveeOfflineLyricsDownloader.beginLibraryScan()
EeveeOfflineLyricsDownloader.downloadForTracks([["uri": "spotify:track:\(disconnectedTrack)"]] as NSArray)
pump(until: { attempts(disconnectedTrack) == 1 }, "offline test did not start")
var joinedReplies = 0
downloader.lyricsForNativeDownload(trackId: disconnectedTrack) { result in
    if case .failure(let error) = result, (error as? URLError)?.code == .notConnectedToInternet { joinedReplies += 1 }
}
DispatchQueue.main.async { disconnectGate.signal() }
pump(until: { downloader.foreground.networkUnavailable && joinedReplies == 1 }, "offline error was not shared with the queue")
downloader.foreground.setNetworkAvailable(false)
let nextOffline = "0000000000000000000822"
emitDownload(nextOffline)
var offlineReplies = 0
downloader.lyricsForNativeDownload(trackId: nextOffline) { result in
    if case .failure(let error) = result, (error as? URLError)?.code == .notConnectedToInternet { offlineReplies += 1 }
}
pump(until: { offlineReplies == 1 && EeveeOfflineLyricsDownloader.settingsSnapshot()["pending"] as? Int == 2 },
     "the native callback or one of the two offline jobs was lost")
check(visibleBatch()["completed"] as? Int == 0 && attempts(nextOffline) == 0, "offline tracks were consumed")
downloader.foreground.didEnterBackground()
downloader.foreground.setNetworkAvailable(true)
RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
check(attempts(disconnectedTrack) == 1 && attempts(nextOffline) == 0, "reconnection bypassed foreground admission")
downloader.foreground.didBecomeActive()
pump(until: { EeveeOfflineLyricsDownloader.settingsSnapshot()["pending"] as? Int == 0 },
     "queued lyrics did not resume after reconnecting")
check(attempts(disconnectedTrack) == 2 && attempts(nextOffline) == 1 && offlineReplies == 1 && joinedReplies == 1,
      "the resumed queue duplicated a callback or a download")
print("Offline failure preserves progress, replies once and resumes the same jobs on reconnect")

// A 429 must release its worker slot and wait until all first attempts finish.
let firstAttemptGate = holdFetch(rateLimitCompanion)
EeveeOfflineLyricsDownloader.beginLibraryScan()
EeveeOfflineLyricsDownloader.downloadForTracks([rateLimitedTwice, rateLimitedOnce, rateLimitCompanion].map {
    ["uri": "spotify:track:\($0)"]
} as NSArray)
pump(until: { [rateLimitedTwice, rateLimitedOnce, rateLimitCompanion].allSatisfy { attempts($0) == 1 } },
     "429 jobs monopolized the queue")
var rateLimitedNativeReplies = 0
downloader.lyricsForNativeDownload(trackId: rateLimitedOnce) { result in
    if case .failure(let error) = result, error is LyricsRequestLimitError { rateLimitedNativeReplies += 1 }
}
pump(until: { rateLimitedNativeReplies == 1 }, "Spotify's joined callback waited behind the retry queue")
check(visibleBatch()["completed"] as? Int == 0 && attempts(rateLimitedOnce) == 1 && attempts(rateLimitedTwice) == 1,
      "A 429 job retried or counted as complete before the ordinary job finished")
// The two retries may run in either order; the batch's final counts are logged when it closes.
let rateLimitSummary = "Missing completed 3/3: saved=2 skipped=0 not_found=0 failed=1 cancelled=0"
let rateLimitSummariesBefore = logged(rateLimitSummary)
firstAttemptGate.signal()
pump(until: { visibleBatch().isEmpty }, "The queue did not run its two deferred retries")
check(logged(rateLimitSummary) == rateLimitSummariesBefore + 1 && attempts(rateLimitedTwice) == 2,
      "A second 429 was retried again or misclassified")
check(attempts(rateLimitedOnce) == 2 && rateLimitedNativeReplies == 1, "A recovered job or native callback ran more than once")
print("Rate-limited tracks wait for the queue to finish, retry once and preserve progress")

let cancelRateLimitGate = holdFetch(rateLimitCompanion)
EeveeOfflineLyricsDownloader.beginLibraryScan()
EeveeOfflineLyricsDownloader.downloadForTracks([rateLimitedTwice, rateLimitCompanion].map {
    ["uri": "spotify:track:\($0)"]
} as NSArray)
pump(until: { attempts(rateLimitedTwice) == 3 && attempts(rateLimitCompanion) == 2 }, "Cancellation fixture did not start")
EeveeOfflineLyricsDownloader.cancelDownloads()
cancelRateLimitGate.signal()
RunLoop.current.run(until: Date().addingTimeInterval(0.1))
check(attempts(rateLimitedTwice) == 3 && visibleBatch().isEmpty, "Cancel left a deferred 429 retry running")

// A scan can finish after removal, re-download and a late album membership reply.
let rediscovered = "0000000000000000000831"
let removedOnly = "0000000000000000000832"
EeveeOfflineLyricsDownloader.setDownloadsEnabled(false)
EeveeOfflineLyricsDownloader.setDownloadsEnabled(true)
let readCountBeforeScan = libraryReads
pump(until: { libraryReads == readCountBeforeScan + 1 }, "Initial catalog scan did not start")
let removal = Notification.Name("EeveeOfflineLyricsRemoved")
let album = "spotify:album:0000000000000000000001"
let uri = "spotify:track:\(rediscovered)"
NotificationCenter.default.post(name: removal, object: nil, userInfo: [
    "context": album, "token": "album-removal", "phase": "begin", "tracks": [uri]
])
emitDownload(rediscovered)
emitDownload(removedOnly)
NotificationCenter.default.post(name: removal, object: nil, userInfo: [
    "context": "spotify:track:\(removedOnly)", "token": "track-removal", "phase": "begin"
])
drainMain()
check(NativeOfflineLyrics.shared.forgotten.contains(removedOnly), "A per-track removal was not applied")
let forgottenBeforeLateReply = NativeOfflineLyrics.shared.forgotten.count
NotificationCenter.default.post(name: removal, object: nil, userInfo: [
    "context": album, "token": "album-removal", "phase": "resolved", "tracks": [uri]
])
drainMain()
check(NativeOfflineLyrics.shared.forgotten.count == forgottenBeforeLateReply,
      "Late album removal deleted lyrics after a newer download")
libraryCallback?([])
check(EeveeOfflineLyricsDownloader.settingsSnapshot()["library_total"] as? Int == 1,
      "Stale catalog lost the re-downloaded track or revived the removed one")
pump(until: { attempts(rediscovered) == 1 && EeveeOfflineLyricsDownloader.settingsSnapshot()["pending"] as? Int == 0 },
     "New download did not finish after removal and catalog reconciliation")
print("Catalog and delayed removal callbacks respect later per-track events")

let checkpointTrack = "0000000000000000000741", deletedBeforeRelaunch = "0000000000000000000742"
let savedBeforeRelaunch = "0000000000000000000743"
OfflineLyricsStore.shared.suppressed.insert(deletedBeforeRelaunch)
OfflineLyricsStore.shared.alreadySaved.insert(savedBeforeRelaunch)
let interruptedQueue = CheckpointFixture(source: UserDefaults.lyricsSource.rawValue, options: UserDefaults.lyricsOptions,
    ids: [checkpointTrack, deletedBeforeRelaunch, savedBeforeRelaunch, restoredRateLimitRetry],
    recheckCatalog: false, rateLimitRetryIds: [restoredRateLimitRetry])
UserDefaults.container.set(try PropertyListEncoder().encode(interruptedQueue), forKey: checkpointKey)
let coldDownloader = EeveeOfflineLyricsDownloader()
coldDownloader.foreground.didEnterBackground()
coldDownloader.start()
RunLoop.current.run(until: Date().addingTimeInterval(0.2))
check(attempts(checkpointTrack) == 0 && UserDefaults.container.data(forKey: checkpointKey) != nil,
      "A cold background launch started or lost the saved queue")
let readsBeforeColdLaunch = libraryReads
coldDownloader.foreground.didBecomeActive()
// The launch waits for Pixie and Spotify's offline service, then checks once.
let launchDeadline = Date().addingTimeInterval(8)
while libraryReads == readsBeforeColdLaunch && Date() < launchDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
check(libraryReads == readsBeforeColdLaunch + 1 && attempts(checkpointTrack) == 0,
      "The launch did not run exactly one library check before resuming the queue")
check(UserDefaults.container.data(forKey: checkpointKey) != nil, "The interrupted queue was dropped before the launch check")
libraryCallback?([])
pump(until: { attempts(checkpointTrack) == 1 && UserDefaults.container.data(forKey: checkpointKey) == nil },
     "Opening the app did not automatically resume and finish its checkpoint")
check(libraryReads == readsBeforeColdLaunch + 1, "The launch scanned the library more than once")
check(attempts(checkpointTrack) == 1 && attempts(deletedBeforeRelaunch) == 0 && attempts(savedBeforeRelaunch) == 0
      && attempts(restoredRateLimitRetry) == 1, "Checkpoint recovery restored an ineligible job or reset its 429 retry count")
check(UserDefaults.container.data(forKey: checkpointKey) == nil, "A completed cold task still had a checkpoint")
print("A cold launch restores only missing, eligible work and clears the persisted queue")

// Every launch reads the downloaded library. Known results must not be asked again:
// a definite miss for good, a temporary failure (after one end-of-queue 429 retry)
// only the next day, a rejected key once for the whole provider.
let outcomes = LyricsNotFoundStore.shared
let launchSource = UserDefaults.lyricsSource.rawValue
let launchTracks = [definiteMiss, noTitleTrack, titleLookupDown, serverDownTrack, rateLimitedLaunch]
func launch(_ ids: [String]) {
    downloader.refreshForCurrentSource(downloadedIds: Set(ids), reason: "downloaded library refresh")
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    pump(until: { EeveeOfflineLyricsDownloader.settingsSnapshot()["pending"] as? Int == 0 }, "Launch refresh did not finish")
}
func launchAttempts() -> [Int] { launchTracks.map(attempts) }
let yesterday = Date().addingTimeInterval(-LyricsNotFoundStore.retryDelay - 1)
launch(launchTracks)
check(launchAttempts() == [1, 1, 1, 1, 2], "The first launch did not ask once, with one 429 retry at the end of the queue")
check(outcomes.entries(source: launchSource).isSuperset(of: [definiteMiss, noTitleTrack]),
      "A provider miss or a definite missing title was not remembered")
let deferred = outcomes.waiting(source: launchSource)
check(deferred.isSuperset(of: [titleLookupDown, serverDownTrack, rateLimitedLaunch])
          && deferred.isDisjoint(with: [definiteMiss, noTitleTrack]),
      "Temporary failures were not deferred to the next day, or a definite result was deferred")
launch(launchTracks)
launch(launchTracks)
check(launchAttempts() == [1, 1, 1, 1, 2], "A later launch asked again for a known result")
check(logged("downloaded library refresh: skipped 5 tracks with a known result") == 2,
      "Repeated launches did not log the skipped known results")
for id in [titleLookupDown, serverDownTrack, rateLimitedLaunch] { outcomes.retryLater(id, source: launchSource, now: yesterday) }
launch(launchTracks)
check(launchAttempts() == [1, 1, 2, 2, 4], "The next day did not retry exactly the temporary failures")
NotificationCenter.default.post(name: removal, object: nil, userInfo: [
    "context": "spotify:track:\(definiteMiss)", "token": "forget-removed", "phase": "begin"
])
drainMain()
check(!outcomes.entries(source: launchSource).contains(definiteMiss), "A removed download kept its remembered result")
print("Launches skip known lyrics results and retry temporary failures only the next day")

launch([refusedTrack])
check(attempts(refusedTrack) == 1 && outcomes.refusal(source: launchSource) != nil
      && !outcomes.waiting(source: launchSource).contains(refusedTrack)
      && !outcomes.entries(source: launchSource).contains(refusedTrack),
      "A rejected key was recorded against the track instead of the provider")
launch([afterRefusalTrack])
check(attempts(afterRefusalTrack) == 0 && logged("rejected access") == 1,
      "An automatic download asked a provider that rejected access today")
outcomes.providerRefused(source: launchSource, now: yesterday)
launch([afterRefusalTrack])
check(attempts(afterRefusalTrack) == 1, "The provider was not asked again the next day")
print("A rejected provider key pauses automatic lyrics downloads until the next day")

// Pixie posts one removal per selected track. The burst must write the store, SQLite
// projection and settings once instead of once per track, and still remove every track.
// A cold launch above left a second downloader observing, so count calls per removal first.
func postRemoval(_ id: String, token: String) {
    NotificationCenter.default.post(name: removal, object: nil, userInfo: [
        "context": "spotify:track:\(id)", "token": token, "phase": "begin", "tracks": ["spotify:track:\(id)"]
    ])
}
var callsBefore = OfflineLyricsStore.shared.removeCalls
postRemoval(String(format: "%022d", 9_099_999), token: "calibrate")
drainMain()
let callsPerRemoval = OfflineLyricsStore.shared.removeCalls - callsBefore
check(callsPerRemoval >= 1, "A single removal was not applied")
let massRemoved = (0..<300).map { String(format: "%022d", 9_100_000 + $0) }
callsBefore = OfflineLyricsStore.shared.removeCalls
let forgetCallsBefore = NativeOfflineLyrics.shared.forgetCalls
for id in massRemoved { postRemoval(id, token: "mass-\(id)") }
check(OfflineLyricsStore.shared.removeCalls == callsBefore, "A mass removal wrote the store once per track")
drainMain()
check(OfflineLyricsStore.shared.removeCalls == callsBefore + callsPerRemoval
      && NativeOfflineLyrics.shared.forgetCalls == forgetCallsBefore + callsPerRemoval
      && OfflineLyricsStore.shared.removeSizes.suffix(callsPerRemoval).allSatisfy { $0 == massRemoved.count },
      "A mass removal was not applied as one batch")
check(Set(massRemoved).isSubset(of: OfflineLyricsStore.shared.removedDownloads)
      && Set(massRemoved).isSubset(of: Set(NativeOfflineLyrics.shared.forgotten)),
      "A mass removal lost some of its tracks")
// A download that follows the burst sees it applied first and keeps its own request.
let massRedownload = massRemoved[0]
NotificationCenter.default.post(name: removal, object: nil, userInfo: [
    "context": "spotify:track:\(massRedownload)", "token": "mass-again", "phase": "begin"
])
callsBefore = OfflineLyricsStore.shared.removeCalls
emitDownload(massRedownload, at: Date().addingTimeInterval(1))
check(OfflineLyricsStore.shared.removeCalls == callsBefore + callsPerRemoval,
      "A download event did not apply the earlier removal first")
drainMain()
check(OfflineLyricsStore.shared.removeCalls == callsBefore + callsPerRemoval,
      "An already applied removal ran again")
print("A mass removal is applied once and before later download events")
