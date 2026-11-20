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

func geniusLyricsUnavailable(_ error: Error) -> Bool {
    if case LyricsError.noSuchSong = error { return true }
    if case OfflineLyricsFetchError.noMetadata = error { return true }
    if case OfflineLyricsFetchError.metadataUnavailable = error { return true }
    return false
}

func isUsableSavedLyrics(_ entry: OfflineLyricsStore.Entry) -> Bool {
    guard let lyrics = try? Lyrics(serializedBytes: entry.data), !lyrics.data.lines.isEmpty else { return false }
    let data = lyrics.data
    // Genius did not identify instrumentals. Old builds generated this placeholder
    // for an empty response and saved it under the selected provider's key.
    guard data.providedBy == "\(LyricsSource.genius.description) (EeveeSpotify)",
          !data.timeSynchronized, data.lines.count == 3,
          data.lines.allSatisfy({ $0.offsetMs == 0 }), data.lines[2].content.isEmpty else { return true }
    return !BundleHelper.instrumentalLyricsPrompts.contains(data.lines.prefix(2).map(\.content))
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
    guard allowOtherProvider else { return nil }
    let others = LyricsSource.allCases.filter { $0 != source && $0.isReplacingLyrics }.map(\.rawValue)
    return store.fallbackEntry(trackId: trackId, sources: others)
}

/// Saved text for a lyrics request that already failed (no network). `offline`:
/// another provider's saved text may stand in until the selected one is saved.
func cachedOfflineLyrics(trackId: String, offline: Bool = false) -> Lyrics? {
    guard let entry = savedOfflineLyricsEntry(trackId: trackId, allowOtherProvider: offline),
          var lyrics = try? Lyrics(serializedBytes: entry.data) else { return nil }
    lyrics.colors = offlineLyricsColors()
    return lyrics
}

private func downloadRepository(_ source: LyricsSource) -> LyricsRepository? {
    switch source {
    case .genius: return GeniusLyricsRepository.shared
    case .lrclib: return LrclibLyricsRepository.shared
    case .petit: return PetitLyricsRepository.shared
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
           let found = try fetchTrackDetails(trackId: trackId, token: token, startRequest: startWhenActive) {
            title = found.title; artist = found.artist
        }
        guard stillWanted() else { throw URLError(.cancelled) }
        // The Web API's nil mixes timeouts with misses; only Spotify's native
        // answer makes a missing title definite.
        guard known() else { throw answered ? OfflineLyricsFetchError.noMetadata : OfflineLyricsFetchError.metadataUnavailable }
    }
    func fetch(_ repository: LyricsRepository) throws -> LyricsDto {
        let query = LyricsSearchQuery(title: title, primaryArtist: artist, spotifyTrackId: trackId)
        return try LyricsDownloadHTTP.perform(isCancelled: { !stillWanted() }, startRequest: startWhenActive) {
            try repository.getLyrics(query, options: options)
        }
    }
    var used = source
    let dto: LyricsDto
    do {
        if needsMetadata { try requireMetadata() }
        guard stillWanted() else { throw URLError(.cancelled) }
        dto = try fetch(repository)
    } catch let primaryError where source == .genius && geniusLyricsUnavailable(primaryError) {
        // SpicyLyrics can look up the same recording by Spotify ID.
        guard stillWanted() else { throw URLError(.cancelled) }
        used = .spicylyrics
        do { dto = try fetch(SpicyLyricsRepository.shared) }
        catch LyricsError.noSuchSong {
            // A missing metadata lookup is retryable even if Spicy had no lyrics.
            throw primaryError
        }
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
        do {
            dto = try fetch(GeniusLyricsRepository.shared)
        } catch {
            if shouldStopProviderFallback(error) { throw error }
            // Both providers must report a genuine miss before the worker may
            // remember it. An invalid primary API key is not a missing song.
            if case LyricsError.noSuchSong = primaryError { throw error }
            throw primaryError
        }
    }
    guard stillWanted() else { throw URLError(.cancelled) }
    let lyrics = Lyrics.with { $0.data = dto.toSpotifyLyricsData(source: used.description) }
    guard try store.save(trackId: trackId, source: source.rawValue, options: options,
                         data: lyrics.serializedData(), revision: revision) else { throw URLError(.cancelled) }
    LyricsNotFoundStore.shared.succeeded(trackId, source: source.rawValue)
    writeDebugLog("[Lyrics] download \(trackId): \(used.description), \(dto.lines.count) lines saved")
    return lyrics
}

/// Lyrics hook entry point. Spotify's offline-lyrics plugin asks for
/// /color-lyrics/v2/download/track/<id> for downloaded tracks that are usually
/// not playing; those are served from the download path so playback state is
/// untouched. Every other request goes to upstream's getLyricsDataForCurrentTrack.
func eeveeLyricsData(_ path: String, originalLyrics: Lyrics? = nil) throws -> Data {
    guard path.contains("/download/track/") else {
        return try getLyricsDataForCurrentTrack(path, originalLyrics: originalLyrics)
    }
    guard let trackId = extractTrackId(from: path), !trackId.isEmpty else { throw LyricsError.noCurrentTrack }
    let execution = EeveeOfflineLyricsDownloader.shared.foreground
    if !execution.isActive || execution.networkUnavailable,
       let cached = cachedOfflineLyrics(trackId: trackId, offline: true) { return try cached.serializedData() }
    // LyricsTaskState makes this call off main. Spotify gets a bounded wait,
    // and the shared fetch can still save a result after that deadline.
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
    return try lyrics.serializedData()
}
