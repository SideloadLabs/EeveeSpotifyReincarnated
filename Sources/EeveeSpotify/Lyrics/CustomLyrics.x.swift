import Orion
import SwiftUI
import MediaPlayer

struct BaseLyricsGroup: HookGroup { }

struct LegacyLyricsGroup: HookGroup { }
struct ModernLyricsGroup: HookGroup { }
struct V91LyricsGroup: HookGroup { }            // 9.1.x-safe subset
struct LyricsErrorHandlingGroup: HookGroup { }  // not activated on 9.1.x

var lyricsState = LyricsLoadingState()

var hasShownRestrictedPopUp = false
var hasShownUnauthorizedPopUp = false

private let geniusLyricsRepository = GeniusLyricsRepository()
private let petitLyricsRepository = PetitLyricsRepository()

// MARK: - 繁体转简体辅助函数
private func traditionalToSimplified(_ text: String) -> String {
    return text.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? text
}

/// Returns a serialized empty lyrics payload.
/// Used as a fallback when every lyrics source (including fallback) fails,
/// so we show "no lyrics" instead of leaking Spotify's own response.
func emptyLyricsData(originalLyrics: ColorLyricsResponse? = nil) -> Data? {
    let emptyDto = LyricsDto(lines: [], timeSynced: false, romanization: .original, translation: nil)
    var colorLyricsResponse = ColorLyricsResponse()
    colorLyricsResponse.lyrics = emptyDto.toSpotifyLyricsData(source: "")
    if let originalLyrics = originalLyrics {
        colorLyricsResponse.colors = originalLyrics.colors
    }
    return try? colorLyricsResponse.serializedBytes()
}

// Overload for 9.1.6 where we only have track ID from URL
private func loadCustomLyricsForTrackId(_ trackId: String) throws -> ColorLyricsResponse {
    
    var source = UserDefaults.lyricsSource

    var currentTitle: String? = nil
    var currentArtist: String? = nil
    var hasMetadata = false

    let needsMetadata = source == .genius || source == .lrclib || source == .petit

    // 1. Use cached metadata if it's for the same track
    if capturedTrackId == trackId, let title = capturedTrackTitle, let artist = capturedArtistName {
        currentTitle = title
        currentArtist = artist
        hasMetadata = true
    }

    // 2. Try statefulPlayer (most reliable on modern Spotify)
    if !hasMetadata {
        if let player = statefulPlayer,
           let track = player.currentTrack() {
            let currentId = track.URI().spt_trackIdentifier()

            if currentId == trackId {
                currentTitle = track.trackTitle()
                currentArtist = track.artistName()
                hasMetadata = true
                capturedTrackId = trackId
                capturedTrackTitle = currentTitle
                capturedArtistName = currentArtist
            }
        }
    }

    // 3. MPNowPlayingInfoCenter — must be read on the main thread
    if !hasMetadata {
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
            capturedTrackId = trackId
            capturedTrackTitle = title
            capturedArtistName = artist
        }
    }

    // 4. Spotify Web API fallback using captured Bearer token
    if !hasMetadata, let token = spotifyAccessToken {
        if let info = fetchTrackDetails(trackId: trackId, token: token) {
            currentTitle = info.title
            currentArtist = info.artist
            hasMetadata = true
            capturedTrackId = trackId
            capturedTrackTitle = currentTitle
            capturedArtistName = currentArtist
        }
    }

    if needsMetadata && !hasMetadata {
        throw LyricsError.noSuchSong
    }

    let searchQuery = LyricsSearchQuery(
        title: currentTitle ?? "",
        primaryArtist: currentArtist ?? "",
        spotifyTrackId: trackId
    )
    
    let options = UserDefaults.lyricsOptions
    
    var repository: LyricsRepository

    switch source {
    case .genius:
        repository = geniusLyricsRepository
    case .lrclib:
        repository = LrclibLyricsRepository.shared
    case .musixmatch:
        repository = MusixmatchLyricsRepository.shared
    case .petit:
        repository = petitLyricsRepository
    case .notReplaced:
        throw LyricsError.invalidSource
    }
    
    let lyricsDto: LyricsDto
    
    lyricsState = LyricsLoadingState()
    
    do {
        lyricsDto = try repository.getLyrics(searchQuery, options: options)
    }
    catch let error {
        if let lyricsError = error as? LyricsError {
            lyricsState.fallbackError = lyricsError

            switch lyricsError {
            case .invalidMusixmatchToken:
                if !hasShownUnauthorizedPopUp {
                    DispatchQueue.main.async {
                        PopUpHelper.showPopUp(
                            delayed: false,
                            message: "musixmatch_unauthorized_popup".localized,
                            buttonText: "OK".uiKitLocalized
                        )
                    }
                    hasShownUnauthorizedPopUp = true
                }
            case .musixmatchRestricted:
                if !hasShownRestrictedPopUp {
                    DispatchQueue.main.async {
                        PopUpHelper.showPopUp(
                            delayed: false,
                            message: "musixmatch_restricted_popup".localized,
                            buttonText: "OK".uiKitLocalized
                        )
                    }
                    hasShownRestrictedPopUp = true
                }
            default:
                break
            }
        } else {
            lyricsState.fallbackError = .unknownError
        }

        // 改动1：将回退目标从 Genius 改为 Musixmatch
        let canFallbackToMusixmatch = source != .musixmatch
            && UserDefaults.lyricsOptions.geniusFallback
            && !(currentTitle ?? "").isEmpty
            && !(currentArtist ?? "").isEmpty
        
        if canFallbackToMusixmatch {
            source = .musixmatch
            lyricsDto = try MusixmatchLyricsRepository.shared.getLyrics(searchQuery, options: options)
        } else {
            throw error
        }
    }
    
    lyricsState.isEmpty = lyricsDto.lines.isEmpty
    
    lyricsState.wasRomanized = lyricsDto.romanization == .romanized
        || (lyricsDto.romanization == .canBeRomanized && UserDefaults.lyricsOptions.romanization)
    
    lyricsState.loadedSuccessfully = true

    var colorLyricsResponse = ColorLyricsResponse()
    colorLyricsResponse.lyrics = lyricsDto.toSpotifyLyricsData(source: source.description)
    
    return colorLyricsResponse
}

private func loadCustomLyricsForCurrentTrack() throws -> ColorLyricsResponse {
    
    guard
        let track = statefulPlayer?.currentTrack() ??
                    nowPlayingScrollViewController?.loadedTrack
        else {
            throw LyricsError.noCurrentTrack
        }
    
    let trackTitle = track.trackTitle()
    let artistName = track.artistName()

    let searchQuery = LyricsSearchQuery(
        title: trackTitle,
        primaryArtist: artistName,
        spotifyTrackId: track.trackIdentifier
    )
    
    let options = UserDefaults.lyricsOptions
    var source = UserDefaults.lyricsSource
    
    var repository: LyricsRepository

    switch source {
    case .genius:
        repository = geniusLyricsRepository
    case .lrclib:
        repository = LrclibLyricsRepository.shared
    case .musixmatch:
        repository = MusixmatchLyricsRepository.shared
    case .petit:
        repository = petitLyricsRepository
    case .notReplaced:
        throw LyricsError.invalidSource
    }
    
    let lyricsDto: LyricsDto
    
    lyricsState = LyricsLoadingState()
    
    do {
        lyricsDto = try repository.getLyrics(searchQuery, options: options)
    }
    catch let error {
        if let error = error as? LyricsError {
            lyricsState.fallbackError = error
            
            switch error {
                
            case .invalidMusixmatchToken:
                if !hasShownUnauthorizedPopUp {
                    PopUpHelper.showPopUp(
                        delayed: false,
                        message: "musixmatch_unauthorized_popup".localized,
                        buttonText: "OK".uiKitLocalized
                    )
                    
                    hasShownUnauthorizedPopUp.toggle()
                }
            
            case .musixmatchRestricted:
                if !hasShownRestrictedPopUp {
                    PopUpHelper.showPopUp(
                        delayed: false,
                        message: "musixmatch_restricted_popup".localized,
                        buttonText: "OK".uiKitLocalized
                    )
                    
                    hasShownRestrictedPopUp.toggle()
                }
                
            default:
                break
            }
        }
        else {
            lyricsState.fallbackError = .unknownError
        }
        
        // 改动2：将回退目标从 Genius 改为 Musixmatch
        if source == .musixmatch || !UserDefaults.lyricsOptions.geniusFallback {
            throw error
        }
        
        source = .musixmatch
        repository = MusixmatchLyricsRepository.shared
        
        lyricsDto = try repository.getLyrics(searchQuery, options: options)
    }
    
    lyricsState.isEmpty = lyricsDto.lines.isEmpty
    
    lyricsState.wasRomanized = lyricsDto.romanization == .romanized
        || (lyricsDto.romanization == .canBeRomanized && UserDefaults.lyricsOptions.romanization)
    
    lyricsState.loadedSuccessfully = true

    var colorLyricsResponse = ColorLyricsResponse()
    colorLyricsResponse.lyrics = lyricsDto.toSpotifyLyricsData(source: source.description)
    
    return colorLyricsResponse
}

func getLyricsDataForCurrentTrack(_ originalPath: String, originalLyrics: ColorLyricsResponse? = nil) throws -> Data {
    
    // track id from URL path; player objects are nil on 9.1.6
    // path: /color-lyrics/v2/track/{trackId}
    let trackIdentifier: String
    if let range = originalPath.range(of: #"/track/([a-zA-Z0-9]+)"#, options: .regularExpression) {
        let match = originalPath[range]
        trackIdentifier = String(match.split(separator: "/").last ?? "")
    } else {
        throw LyricsError.noCurrentTrack
    }

    if trackIdentifier.isEmpty {
        throw LyricsError.noCurrentTrack
    }

    if capturedTrackId != trackIdentifier {
        capturedTrackTitle = nil
        capturedArtistName = nil
        capturedTrackId = nil
    }

    var colorLyricsResponse = try loadCustomLyricsForTrackId(trackIdentifier)
    
    // 改动3：如果歌词来自 Musixmatch，将繁体转简体
    if colorLyricsResponse.lyrics.provider == "Musixmatch" {
        var lyrics = colorLyricsResponse.lyrics
        for i in 0..<lyrics.lines.count {
            lyrics.lines[i].words = traditionalToSimplified(lyrics.lines[i].words)
        }
        colorLyricsResponse.lyrics = lyrics
    }
    
    let lyricsColorsSettings = UserDefaults.lyricsColors
    
    if lyricsColorsSettings.displayOriginalColors, let originalLyrics = originalLyrics {
        colorLyricsResponse.colors = originalLyrics.colors
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
        
        var colorData = ColorData()
        colorData.background = Int32(bitPattern: color.uInt32)
        colorData.text = Int32(bitPattern: Color.black.uInt32)
        colorData.highlightText = Int32(bitPattern: Color.white.uInt32)
        
        colorLyricsResponse.colors = colorData
    }
    
    let serializedData = try colorLyricsResponse.serializedBytes()
    return serializedData
}