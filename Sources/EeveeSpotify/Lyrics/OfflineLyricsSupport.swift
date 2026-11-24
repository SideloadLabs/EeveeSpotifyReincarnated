import Foundation
import SwiftUI

// Lyrics downloads and the offline fallback. CustomLyrics and karaoke retain
// upstream behavior. Repository transport checks are scoped to downloads only:
// online, every lyrics view asks the selected provider exactly as upstream does.
// Saved lyrics are used only when the network request failed or by Spotify's
// own offline repository, which reads the native SQLite projection.

enum OfflineLyricsFetchError: Error, CustomStringConvertible {
    /// Spotify answered without a usable title/artist, so the provider cannot be
    /// searched. A definite outcome for this track, though not "no lyrics".
    case noMetadata
    /// Spotify's track service did not answer; the lookup may succeed later.
    case metadataUnavailable
    case timedOut
    var description: String {
        switch self {
        case .noMetadata: return "no title/artist for this track, provider cannot be searched"
        case .metadataUnavailable: return "track title/artist lookup did not answer; try again later"
        case .timedOut: return "lyrics fetch is still running; not a missing song"
        }
    }
}

private func shouldStopProviderFallback(_ error: Error) -> Bool {
    if error is LyricsRequestLimitError { return true }
    guard let transport = error as? URLError else { return false }
    return transport.code == .cancelled || transport.code == .notConnectedToInternet
}

func isUsableSavedLyrics(_ entry: OfflineLyricsStore.Entry) -> Bool {
    (try? Lyrics(serializedBytes: entry.data))?.hasData == true
}

/// The lyrics a saved file shows, as upstream builds them from the provider's answer: a file
/// without lines (an instrumental) gets upstream's prompts, in the language Eevee shows now.
func savedDisplayLyrics(_ entry: OfflineLyricsStore.Entry) -> Lyrics? {
    (try? Lyrics(serializedBytes: entry.data)).flatMap(savedDisplayLyrics)
}

func savedDisplayLyrics(_ saved: Lyrics) -> Lyrics? {
    guard saved.hasData else { return nil }
    var lyrics = saved
    if lyrics.data.lines.isEmpty {
        let empty = LyricsDto(lines: [], timeSynced: false, romanization: .original, translation: nil)
        lyrics.data.lines = empty.toSpotifyLyricsData(source: "").lines
    }
    return lyrics
}

/// Names a provider's error in a saved file, for the fallback reason upstream's header shows.
private extension LyricsError {
    static let saved: [LyricsError] = [.noCurrentTrack, .trackMismatch, .decodingError, .noSuchSong,
                                       .unknownError, .invalidSource, .invalidSpicyKey]
    var savedName: String {
        switch self {
        case .noCurrentTrack: return "noCurrentTrack"
        case .trackMismatch: return "trackMismatch"
        case .decodingError: return "decodingError"
        case .noSuchSong: return "noSuchSong"
        case .unknownError: return "unknownError"
        case .invalidSource: return "invalidSource"
        case .invalidSpicyKey: return "invalidSpicyKey"
        }
    }
    /// As upstream records a failed provider: its LyricsError, anything else as unknownError.
    init(failure error: Error) { self = error as? LyricsError ?? .unknownError }
}

/// The selected provider's error from upstream's fetch of a song. After a Genius fallback
/// upstream throws Genius's error, while its header names this one. Kept per song, since a
/// prefetch can fetch another song meanwhile; a few songs at most.
final class SelectedProviderFailure {
    static let shared = SelectedProviderFailure()
    private let lock = NSLock()
    private var errors: [(trackId: String, error: LyricsError)] = []

    func record(trackId: String, error: LyricsError?) {
        lock.lock(); defer { lock.unlock() }
        errors.removeAll { $0.trackId == trackId }
        guard let error else { return }
        errors.append((trackId, error))
        if errors.count > 8 { errors.removeFirst() }
    }

    /// The song's recorded error, forgotten: each request for the song records its own.
    @discardableResult
    func take(trackId: String) -> LyricsError? {
        lock.lock(); defer { lock.unlock() }
        guard let index = errors.firstIndex(where: { $0.trackId == trackId }) else { return nil }
        return errors.remove(at: index).error
    }
}

/// What upstream's lyrics header shows for this answer, set as upstream's fetch sets it.
/// `failure`: the online request's error, when a saved text stands in for it.
func applySavedLyricsState(_ entry: OfflineLyricsStore.Entry, failure: Error? = nil) {
    var state = LyricsLoadingState()
    state.wasRomanized = entry.romanized
    state.fallbackError = failure.map(LyricsError.init(failure:))
        ?? LyricsError.saved.first { $0.savedName == entry.fallbackReason }
    state.isEmpty = (try? Lyrics(serializedBytes: entry.data))?.data.lines.isEmpty ?? false
    state.loadedSuccessfully = true
    lyricsState = state
}

/// Colors used whenever there is no server response to take them from.
private func offlineLyricsColors() -> LyricsColors {
    let settings = UserDefaults.lyricsColors
    let color = settings.useStaticColor ? Color(hex: settings.staticColor) : Color.gray
    return LyricsColors.with {
        $0.backgroundColor = color.uInt32
        $0.lineColor = Color.black.uInt32
        $0.activeLineColor = Color.white.uInt32
    }
}

/// The selected provider's saved text, or — offline only — the newest text saved
/// with another provider until the selected one has been downloaded.
func savedOfflineLyricsEntry(trackId: String, allowOtherProvider: Bool) -> OfflineLyricsStore.Entry? {
    let source = UserDefaults.lyricsSource
    guard source.isReplacingLyrics else { return nil }
    let store = OfflineLyricsStore.shared
    if let entry = store.entry(trackId: trackId, source: source.rawValue, options: UserDefaults.lyricsOptions) {
        return entry
    }
    return allowOtherProvider ? otherProviderLyricsEntry(trackId: trackId, source: source) : nil
}

/// The newest text saved with a provider other than `source`.
private func otherProviderLyricsEntry(trackId: String, source: LyricsSource) -> OfflineLyricsStore.Entry? {
    guard source.isReplacingLyrics else { return nil }
    let others = LyricsSource.allCases.filter { $0 != source && $0.isReplacingLyrics }.map(\.rawValue)
    return OfflineLyricsStore.shared.fallbackEntry(trackId: trackId, sources: others)
}

/// Online, the selected provider's saved lyrics answer Spotify as the provider's own answer
/// would: the same colors, and the custom lyrics button gets its saved lyrics too. A file
/// without the button's lyrics (Genius fallback text, or lyrics without timing) is used as
/// well: online, those songs have no button lyrics either.
private func savedSelectedProviderLyrics(trackId: String, originalLyrics: Lyrics?) -> Data? {
    guard let entry = savedOfflineLyricsEntry(trackId: trackId, allowOtherProvider: false),
          var lyrics = savedDisplayLyrics(entry) else { return nil }
    let buttonLyrics = entry.karaoke.flatMap { try? JSONDecoder().decode(KaraokeLyricsDto.self, from: $0) }
    applyLyricsColors(&lyrics, originalLyrics: originalLyrics)
    guard let data = try? lyrics.serializedData() else { return nil }
    // What the provider's fetch does: this request marks the playing song, and the button
    // shows only lyrics this answer brings.
    KaraokePlaybackTracker.shared.updateTrackIdFromLyricsFetch(trackId)
    applySavedLyricsState(entry)
    if let buttonLyrics { KaraokeLyricsStore.shared.set(trackId: trackId, lyrics: buttonLyrics) }
    else { KaraokeLyricsStore.shared.remove(trackId: trackId) }
    writeDebugLog("[Lyrics] \(trackId): saved \(UserDefaults.lyricsSource.description) lyrics, no request")
    return data
}

/// Saved text for a lyrics request that already failed (no network). `offline`:
/// another provider's saved text may stand in until the selected one is saved.
func cachedOfflineLyrics(trackId: String, offline: Bool = false) -> Lyrics? {
    cachedOfflineEntry(trackId: trackId, offline: offline)?.lyrics
}

private func cachedOfflineEntry(trackId: String, offline: Bool) -> (entry: OfflineLyricsStore.Entry, lyrics: Lyrics)? {
    guard let entry = savedOfflineLyricsEntry(trackId: trackId, allowOtherProvider: offline),
          var lyrics = savedDisplayLyrics(entry) else { return nil }
    lyrics.colors = offlineLyricsColors()
    return (entry, lyrics)
}

/// One at a time, in call order: after fast skipping, the playing song's lyrics are applied last.
private let savedLyricsQueue = DispatchQueue(label: "EeveeSpotify.SavedLyrics", qos: .utility)

/// The custom lyrics view and the lyrics header learn a track's lyrics only from a fetch,
/// and offline there is none: Spotify's native view reads its own offline database without
/// asking Eevee. Offline only, when the playing track changes or the network goes away, the
/// header gets the saved text's state and the view the selected provider's saved lyrics.
/// Online the fetch does both, as before.
func publishSavedLyrics(trackId: String) {
    guard EeveeOfflineLyricsDownloader.shared.foreground.isOffline else { return }
    savedLyricsQueue.async {
        // Back online meanwhile: the provider's answer sets both.
        guard EeveeOfflineLyricsDownloader.shared.foreground.isOffline else { return }
        let source = UserDefaults.lyricsSource
        let selected = savedOfflineLyricsEntry(trackId: trackId, allowOtherProvider: false)
        if let entry = selected ?? otherProviderLyricsEntry(trackId: trackId, source: source) {
            applySavedLyricsState(entry)
        } else {
            lyricsState = LyricsLoadingState()
        }
        guard UserDefaults.karaokeOptions.enabled, source.supportsCustomLyricsView,
              KaraokeLyricsStore.shared.lyrics(forTrackId: trackId) == nil,
              let saved = selected?.karaoke,
              let karaoke = try? JSONDecoder().decode(KaraokeLyricsDto.self, from: saved) else { return }
        KaraokeLyricsStore.shared.set(trackId: trackId, lyrics: karaoke)
    }
}

/// What a saved file holds for a provider's answer: its text, romanized as the options say,
/// whether it was (upstream's rule for the header), and the custom view's lyrics.
/// An instrumental is saved without lines: savedDisplayLyrics adds the prompts when shown.
private func offlineEntry(_ dto: LyricsDto, used: LyricsSource, source: LyricsSource, options: LyricsOptions,
                          karaoke: KaraokeLyricsDto?) -> (lyrics: Lyrics, karaoke: Data?, romanized: Bool) {
    var savedDTO = dto
    let romanize = options.romanization && dto.romanization == .canBeRomanized
    savedDTO.lines = dto.lines.map { line in
        let content = romanize ? (line.content.applyingTransform(.toLatin, reverse: false) ?? line.content) : line.content
        return LyricsLineDto(content: content, offsetMs: line.offsetMs.map { Int(Int32(clamping: $0)) })
    }
    if romanize { savedDTO.romanization = .romanized }
    var lyrics = Lyrics.with { $0.data = savedDTO.toSpotifyLyricsData(source: used.description) }
    if dto.lines.isEmpty { lyrics.data.lines = [] }
    // The custom view's lyrics are made as playback makes them: a provider's own (Spicy Lyrics),
    // or upstream's line-synced view of the provider's answer. Only the selected provider's,
    // since the custom view follows it; nothing for a provider or song online has none for.
    let viewLyrics = used == source && source.supportsCustomLyricsView
        ? karaoke ?? KaraokeLyricsDto.lineSynced(from: dto, providerName: used.description) : nil
    return (lyrics, viewLyrics.flatMap { try? JSONEncoder().encode($0) }, savedDTO.romanization == .romanized)
}

/// The selected provider answered while a downloaded song played: save that answer, so the
/// song has the same lyrics offline without waiting for its turn in the download queue.
/// A Genius fallback is not saved here: online it can stand in for a provider that was only
/// busy, and the download queue still asks the provider.
func savePlaybackLyrics(trackId: String, dto: LyricsDto, source: LyricsSource) {
    guard UserDefaults.offlineLyricsEnabled, source == UserDefaults.lyricsSource, source.isReplacingLyrics,
          dto.lines.contains(where: { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return }
    let options = UserDefaults.lyricsOptions.downloadOptions
    // Spicy Lyrics publishes its word timing while parsing this very answer.
    let karaoke = source.supportsCustomLyricsView ? KaraokeLyricsStore.shared.lyrics(forTrackId: trackId) : nil
    DispatchQueue.main.async {
        guard EeveeOfflineLyricsDownloader.shared.isDownloaded(trackId) else { return }
        DispatchQueue.global(qos: .utility).async {
            let store = OfflineLyricsStore.shared
            guard UserDefaults.lyricsSource == source, UserDefaults.lyricsOptions.downloadOptions == options,
                  store.entry(trackId: trackId, source: source.rawValue, options: options) == nil else { return }
            let (lyrics, savedKaraoke, romanized) = offlineEntry(dto, used: source, source: source,
                                                                 options: options, karaoke: karaoke)
            guard let data = try? lyrics.serializedData(),
                  (try? store.save(trackId: trackId, source: source.rawValue, options: options, data: data,
                                   karaoke: savedKaraoke, romanized: romanized)) == true else { return }
            LyricsNotFoundStore.shared.succeeded(trackId, source: source.rawValue)
            writeDebugLog("[Lyrics] \(trackId): saved the playing \(source.description) answer for offline")
        }
    }
}

private let petitDownloadRepository = PetitLyricsRepository()

private func downloadRepository(_ source: LyricsSource) -> LyricsRepository? {
    switch source {
    case .genius: return GeniusLyricsRepository.shared
    case .lrclib: return LrclibLyricsRepository.shared
    case .petit: return petitDownloadRepository
    case .spicylyrics: return SpicyLyricsRepository.shared
    case .notReplaced: return nil
    }
}

/// Fetch and save the selected provider's lyrics for a downloaded (usually not
/// playing) track. Never touches playback state: captured metadata, the karaoke
/// track signal, prefetch and lyricsState stay as upstream left them.
@discardableResult
func downloadProviderLyrics(trackId: String, metadata: (title: String, artist: String)?,
                            metadataTimeout: TimeInterval,
                            expectedRevision: OfflineLyricsStore.Revision? = nil,
                            foreground: LyricsForegroundExecution,
                            isCancelled: @escaping () -> Bool = { false }) throws -> Lyrics {
    let store = OfflineLyricsStore.shared
    let revision = expectedRevision ?? store.revision(trackId: trackId)
    let source = UserDefaults.lyricsSource
    let options = UserDefaults.lyricsOptions.downloadOptions
    func stillWanted() -> Bool {
        !isCancelled() && store.isCurrent(revision, trackId: trackId) && UserDefaults.offlineLyricsEnabled
            && UserDefaults.lyricsSource == source && UserDefaults.lyricsOptions.downloadOptions == options
    }
    guard let repository = downloadRepository(source), stillWanted() else { throw URLError(.cancelled) }
    // URI-only requests (download queue, Spotify's plugin): local catalog first,
    // then Spotify's native track service, then the Web API with the captured token.
    var title = metadata?.title ?? "", artist = metadata?.artist ?? ""
    let needsMetadata = source == .genius || source == .lrclib || source == .petit
    func known() -> Bool { !title.isEmpty && !artist.isEmpty }
    if !known(), let found = EeveeOfflineLyricsDownloader.pixieCatalogMetadata(trackId: trackId) {
        title = found.title; artist = found.artist
    }
    func startWhenActive(_ start: () -> Void) throws {
        try foreground.whenNetworkAvailable(isCancelled: { !stillWanted() }, start)
    }
    func requireMetadata() throws {
        var answered = true
        if !known() {
            let lookup = nativeLyricsMetadata(trackId: trackId, timeout: metadataTimeout, startRequest: startWhenActive)
            if let found = lookup.metadata { title = found.title; artist = found.artist }
            if case .unavailable = lookup { answered = false }
        }
        guard stillWanted() else { throw URLError(.cancelled) }
        if !known(), let token = spotifyAccessToken,
           let found = fetchTrackDetails(trackId: trackId, token: token) {
            title = found.title; artist = found.artist
        }
        guard stillWanted() else { throw URLError(.cancelled) }
        // The Web API's nil mixes timeouts with misses; only Spotify's native
        // answer makes a missing title definite.
        guard known() else { throw answered ? OfflineLyricsFetchError.noMetadata : OfflineLyricsFetchError.metadataUnavailable }
    }
    // The provider's word timing comes back with its text, read before the download context ends.
    func fetch(_ repository: LyricsRepository) throws -> (LyricsDto, KaraokeLyricsDto?) {
        let query = LyricsSearchQuery(title: title, primaryArtist: artist, spotifyTrackId: trackId)
        return try LyricsDownloadHTTP.perform(isCancelled: { !stillWanted() }, startRequest: startWhenActive) {
            let dto = try repository.getLyrics(query, options: options)
            if dto.lines.isEmpty && repository is LrclibLyricsRepository { return (dto, nil) }
            guard dto.lines.contains(where: { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                if repository is GeniusLyricsRepository { throw LyricsError.noSuchSong }
                throw LyricsError.decodingError
            }
            return (dto, LyricsDownloadHTTP.downloadedKaraoke)
        }
    }
    var used = source
    let dto: LyricsDto
    var karaoke: KaraokeLyricsDto?
    var fallbackReason = "none"
    do {
        if needsMetadata { try requireMetadata() }
        guard stillWanted() else { throw URLError(.cancelled) }
        (dto, karaoke) = try fetch(repository)
    } catch {
        // A cooldown/cancellation must not start another provider. Other errors
        // retain the configured Genius fallback, without turning a temporary
        // primary failure into a permanent "no lyrics" marker.
        if shouldStopProviderFallback(error) { throw error }
        guard stillWanted() else { throw URLError(.cancelled) }
        guard source != .genius, options.geniusFallback else { throw error }
        let primaryError = error
        // Spicy can search by ID alone. Genius needs verified track metadata,
        // including when the automatic catalog scan has only returned URIs.
        if !known() {
            if primaryError is OfflineLyricsFetchError { throw primaryError }
            do { try requireMetadata() }
            catch OfflineLyricsFetchError.noMetadata {
                if case LyricsError.noSuchSong = primaryError { throw OfflineLyricsFetchError.noMetadata }
                throw primaryError
            }
        }
        used = .genius
        fallbackReason = LyricsError(failure: primaryError).savedName
        do {
            (dto, _) = try fetch(GeniusLyricsRepository.shared)
        } catch {
            if shouldStopProviderFallback(error) { throw error }
            // Both providers must report a genuine miss before the worker may
            // remember it. An invalid primary API key is not a missing song.
            if case LyricsError.noSuchSong = primaryError { throw error }
            throw primaryError
        }
    }
    guard stillWanted() else { throw URLError(.cancelled) }
    let (lyrics, savedKaraoke, romanized) = offlineEntry(dto, used: used, source: source, options: options, karaoke: karaoke)
    let data = try lyrics.serializedData()
    guard try store.save(trackId: trackId, source: source.rawValue, options: options, data: data, karaoke: savedKaraoke,
                         romanized: romanized, fallbackReason: fallbackReason, revision: revision) else { throw URLError(.cancelled) }
    LyricsNotFoundStore.shared.succeeded(trackId, source: source.rawValue)
    writeDebugLog("[Lyrics] download \(trackId): \(used.description), \(dto.lines.count) lines saved\(savedKaraoke == nil ? "" : " with the custom view's lyrics")")
    // What Spotify's offline plugin gets, as the saved file shows it.
    return savedDisplayLyrics(lyrics) ?? lyrics
}

/// Saved lyrics for a lyrics request that failed in transport (offline).
func savedLyrics(forFailed url: URL, error: Error?) -> Data? {
    guard let error, (error as? URLError)?.code != .cancelled, url.isLyrics,
          let trackId = extractTrackId(from: url.path),
          let saved = cachedOfflineEntry(trackId: trackId, offline: true) else { return nil }
    if !url.path.contains("/download/") {
        KaraokePlaybackTracker.shared.updateTrackIdFromLyricsFetch(trackId)
        applySavedLyricsState(saved.entry)
    }
    return try? saved.lyrics.serializedData()
}

/// Lyrics hook entry point. Spotify's offline-lyrics plugin asks for
/// /color-lyrics/v2/download/track/<id> for downloaded tracks that are usually
/// not playing; those are served from the download path so playback state is
/// untouched. Every other request goes to upstream's getLyricsDataForCurrentTrack.
/// Both of Spotify's delegates, and the response and completion callbacks, ask
/// for the same task: one provider answer per task is shared between them.
func eeveeLyricsData(_ path: String, originalLyrics: Lyrics? = nil, task: URLSessionTask) throws -> Data {
    guard path.contains("/download/track/") else {
        guard let trackId = extractTrackId(from: path) else {
            return try getLyricsDataForCurrentTrack(path, originalLyrics: originalLyrics)
        }
        // 1. The selected provider's saved lyrics, without asking it again.
        if let saved = savedSelectedProviderLyrics(trackId: trackId, originalLyrics: originalLyrics) { return saved }
        // 2. The provider online, as upstream does. An error recorded by an earlier request
        // for this song (another provider, or a fetch that stopped before asking) is not this one's.
        SelectedProviderFailure.shared.take(trackId: trackId)
        do { return try getLyricsDataForCurrentTrack(path, originalLyrics: originalLyrics) }
        catch {
            // 3. Spotify has no lyrics of its own (its card may be one Eevee added for saved
            // lyrics) and the provider has none online: lyrics saved with an earlier provider,
            // as offline. With Spotify's own lyrics, those stay as before.
            guard originalLyrics == nil, (error as? URLError)?.code != .cancelled,
                  let entry = savedOfflineLyricsEntry(trackId: trackId, allowOtherProvider: true),
                  var lyrics = savedDisplayLyrics(entry) else { throw error }
            applyLyricsColors(&lyrics, originalLyrics: nil)
            // Upstream's header names the selected provider's error; after a Genius fallback
            // `error` is Genius's, so take the one upstream's fetch recorded for this song.
            applySavedLyricsState(entry, failure: SelectedProviderFailure.shared.take(trackId: trackId) ?? error)
            writeDebugLog("[Lyrics] \(trackId): provider has no lyrics online (\(error)); saved lyrics are shown")
            return try lyrics.serializedData()
        }
    }
    guard UserDefaults.lyricsSource.isReplacingLyrics, UserDefaults.offlineLyricsEnabled else {
        throw LyricsError.invalidSource
    }
    guard let trackId = extractTrackId(from: path) else { throw LyricsError.noCurrentTrack }
    return try LyricsTaskState.forTask(task).result {
        do { return try pluginDownloadLyrics(trackId: trackId).serializedData() }
        catch {
            // Without lyrics from Spotify or the provider, an empty row keeps the
            // audio download from waiting for lyrics. Not a provider "not found" entry.
            if originalLyrics == nil, (error as? URLError)?.code != .cancelled {
                NativeOfflineLyrics.shared.markNoLyrics(trackId: trackId,
                    reason: "Spotify has no lyrics, external lyrics unavailable: \(error)")
            }
            throw error
        }
    }
}

/// Completion of a successful Spotify `/download/track/` request. The provider
/// fetch for such a (usually not playing) track can take seconds, so it never
/// runs while Spotify's delegate queue waits: every other Spotify response on
/// that queue would stall behind it. `deliver` gets the provider's payload, or
/// Spotify's own body if there is none. Returns false for every other request,
/// which keeps upstream's path unchanged.
func answerLyricsDownloadAsync(_ url: URL, buffer: Data, task: URLSessionTask,
                               deliver: @escaping (Data) -> Void) -> Bool {
    guard url.path.contains("/download/track/") else { return false }
    DispatchQueue.global(qos: .utility).async {
        let originalLyrics = try? Lyrics(serializedBytes: buffer)
        deliver((try? eeveeLyricsData(url.path, originalLyrics: originalLyrics, task: task)) ?? buffer)
    }
    return true
}

private func pluginDownloadLyrics(trackId: String) throws -> Lyrics {
    if let saved = cachedOfflineLyrics(trackId: trackId) { return saved }
    let execution = EeveeOfflineLyricsDownloader.shared.foreground
    if !execution.isActive || execution.networkUnavailable,
       let cached = cachedOfflineLyrics(trackId: trackId, offline: true) { return cached }
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<Lyrics, Error>?
    EeveeOfflineLyricsDownloader.shared.lyricsForNativeDownload(trackId: trackId) { response in
        result = response
        semaphore.signal()
    }
    guard semaphore.wait(timeout: .now() + 12) == .success, let result else {
        writeDebugLog("[Lyrics] plugin download \(trackId): provider took longer than 12 s")
        throw OfflineLyricsFetchError.timedOut
    }
    var lyrics: Lyrics
    do { lyrics = try result.get() }
    catch let transport as URLError where transport.code == .notConnectedToInternet {
        guard let cached = cachedOfflineLyrics(trackId: trackId, offline: true) else { throw transport }
        lyrics = cached
    }
    lyrics.colors = offlineLyricsColors()
    return lyrics
}
