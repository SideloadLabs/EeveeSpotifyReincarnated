import Orion
import SwiftUI
import MediaPlayer

struct BaseLyricsGroup: HookGroup { }

struct LegacyLyricsGroup: HookGroup { }
struct ModernLyricsGroup: HookGroup { }
struct V91LyricsGroup: HookGroup { }            // 9.1.x-safe subset
struct LyricsErrorHandlingGroup: HookGroup { }  // not activated on 9.1.x

private let geniusLyricsRepository = GeniusLyricsRepository.shared
private let petitLyricsRepository = PetitLyricsRepository.shared

// Overload for 9.1.6 where we only have track ID from URL
func loadCustomLyrics(_ request: PlaybackRequest) throws -> Lyrics {
    let trackId = request.track

    var source = request.source

    var currentTitle: String? = nil
    var currentArtist: String? = nil
    var hasMetadata = false

    let needsMetadata = source == .genius || source == .lrclib || source == .petit

    // 1. Use cached metadata if it's for the same track
    if let (title, artist) = metadataForPlayback(trackId) {
        currentTitle = title
        currentArtist = artist
        hasMetadata = !title.isEmpty && !artist.isEmpty
    }

    // 2. Try statefulPlayer (most reliable on modern Spotify)
    if !hasMetadata {
        if let player = statefulPlayer,
           let track = player.currentTrack() {
            let currentId = track.URI().spt_trackIdentifier()

            if currentId == trackId {
                currentTitle = track.trackTitle()
                currentArtist = track.artistName()
                hasMetadata = !(currentTitle ?? "").isEmpty && !(currentArtist ?? "").isEmpty
                rememberPlaybackMetadata(trackId, currentTitle, currentArtist)
            }
        }
    }

    // 3. MPNowPlayingInfoCenter — must be read on the main thread.
    // It always describes the playing track, so it must not be used for another track
    // (Spotify also loads lyrics for tracks that aren't playing yet).
    let nowPlayingIsThisTrack = KaraokePlaybackTracker.shared.playerReportedTrackId() == trackId
    if !hasMetadata && nowPlayingIsThisTrack {
        var npTitle: String? = nil
        var npArtist: String? = nil
        if Thread.isMainThread {
            npTitle = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String
            npArtist = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtist] as? String
        } else {
            DispatchQueue.main.sync {
                npTitle = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String
                npArtist = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtist] as? String
            }
        }
        if let title = npTitle, let artist = npArtist, !title.isEmpty, !artist.isEmpty {
            currentTitle = title
            currentArtist = artist
            hasMetadata = true
            rememberPlaybackMetadata(trackId, title, artist)
        }
    }

    // 4. Read verified metadata for this ID, including tracks that aren't playing.
    if !hasMetadata,
       let info = EeveeOfflineLyricsDownloader.pixieCatalogMetadata(trackId: trackId)
           ?? (needsMetadata ? nativeLyricsMetadata(trackId: trackId, timeout: 2) : nil) {
        currentTitle = info.title
        currentArtist = info.artist
        hasMetadata = true
    }

    // 5. Spotify Web API fallback using captured Bearer token.
    func lookupWebMetadata() throws {
        if !hasMetadata, let token = spotifyAccessToken,
           let info = try fetchTrackDetails(trackId: trackId, token: token) {
            currentTitle = info.title
            currentArtist = info.artist
            hasMetadata = true
            rememberPlaybackMetadata(trackId, currentTitle, currentArtist)
        }
    }
    if needsMetadata { try lookupWebMetadata() }
    var searchQuery: LyricsSearchQuery {
        LyricsSearchQuery(title: currentTitle ?? "", primaryArtist: currentArtist ?? "", spotifyTrackId: trackId)
    }

    let options = request.options
    
    var repository: LyricsRepository

    switch source {
    case .genius:
        repository = geniusLyricsRepository
    case .lrclib:
        repository = LrclibLyricsRepository.shared
    case .petit:
        repository = petitLyricsRepository
    case .spicylyrics:
        repository = SpicyLyricsRepository.shared
    case .notReplaced:
        throw LyricsError.invalidSource
    }
    
    let lyricsDto: LyricsDto
    
    var state = LyricsLoadingState()
    do {
        if needsMetadata && !hasMetadata { throw OfflineLyricsFetchError.noMetadata }
        lyricsDto = try repository.getLyrics(searchQuery, options: options)
    }
    catch let error {
        if let transport = error as? URLError, [.notConnectedToInternet, .cancelled].contains(transport.code) { throw error }
        if let lyricsError = error as? LyricsError {
            state.fallbackError = lyricsError
        } else {
            state.fallbackError = .unknownError
        }

        // Attempt Genius fallback if enabled and the primary source isn't already Genius.
        // Genius requires title + artist to search — only attempt if we have them.
        if source == .genius && geniusLyricsUnavailable(error) {
            writeDebugLog("[Lyrics] \(trackId): Genius unavailable (\(error)); trying SpicyLyrics by ID")
            source = .spicylyrics
            lyricsDto = try SpicyLyricsRepository.shared.getLyrics(searchQuery, options: options)
        } else if source != .genius && options.geniusFallback {
            if !needsMetadata { try lookupWebMetadata() }
            guard hasMetadata else { throw error }
            source = .genius
            lyricsDto = try geniusLyricsRepository.getLyrics(searchQuery, options: options)
        } else {
            throw error
        }
    }
    
    state.isEmpty = lyricsDto.lines.isEmpty
    state.wasRomanized = lyricsDto.romanization == .romanized
        || (lyricsDto.romanization == .canBeRomanized && options.romanization)
    state.loadedSuccessfully = true
    let karaoke = lyricsDto.karaoke ?? (source.supportsCustomLyricsView
        ? KaraokeLyricsDto.lineSynced(from: lyricsDto, providerName: source.description) : nil)
    publishPlaybackLyrics(request, state: state, karaoke: karaoke)
    writeDebugLog("[Lyrics] \(trackId): \(source.description), \(lyricsDto.lines.count) lines, synced=\(lyricsDto.timeSynced)")
    let lyrics = Lyrics.with {
        $0.data = lyricsDto.toSpotifyLyricsData(source: source.description)
    }
    
    return lyrics
}

/// Extracts the Spotify track ID from a `/color-lyrics/v2/track/{trackId}` URL path.
/// Returns nil if the path doesn't match the expected format.
func extractTrackId(from path: String) -> String? {
    guard let range = path.range(of: #"/track/([a-zA-Z0-9]+)"#, options: .regularExpression) else {
        return nil
    }
    let trackId = String(path[range].split(separator: "/").last ?? "")
    return trackId.isEmpty ? nil : trackId
}

func prefetchLyricsIfNeeded(trackId: String) {
    guard UserDefaults.lyricsSource.isReplacingLyrics else { return }
    requestPlaybackLyrics(trackId, prefetch: true, fetch: { try loadCustomLyrics($0).serializedData() }) { result in
        if case .failure(let error) = result { writeDebugLog("[Lyrics] prefetch failed for \(trackId): \(error)") }
    }
}

func getLyricsDataForCurrentTrack(_ originalPath: String, originalLyrics: Lyrics? = nil) throws -> Data {
    guard let id = extractTrackId(from: originalPath) else { throw LyricsError.noCurrentTrack }
    KaraokePlaybackTracker.shared.updateTrackIdFromLyricsFetch(id)
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<Data, Error>?
    requestPlaybackLyrics(id, prefetch: false, fetch: { try loadCustomLyrics($0).serializedData() }) { reply in
        result = reply
        semaphore.signal()
    }
    guard semaphore.wait(timeout: .now() + 12) == .success, let result else {
        throw OfflineLyricsFetchError.timedOut
    }
    var lyrics = try Lyrics(serializedBytes: result.get())

    let lyricsColorsSettings = UserDefaults.lyricsColors
    
    if lyricsColorsSettings.displayOriginalColors, let originalLyrics = originalLyrics {
        lyrics.colors = originalLyrics.colors
    }
    else {
        // no track object on 9.1.6: static color, else background color, else gray
        var color: Color
        
        if lyricsColorsSettings.useStaticColor {
            color = Color(hex: lyricsColorsSettings.staticColor)
        }
        else if let uiColor = backgroundViewModel?.color() {
            color = Color(uiColor)
                .normalized(lyricsColorsSettings.normalizationFactor)
        }
        else {
            color = Color.gray
        }
        
        lyrics.colors = LyricsColors.with {
            $0.backgroundColor = color.uInt32
            $0.lineColor = Color.black.uInt32
            $0.activeLineColor = Color.white.uInt32
        }
    }
    
    return try lyrics.serializedData()
}
