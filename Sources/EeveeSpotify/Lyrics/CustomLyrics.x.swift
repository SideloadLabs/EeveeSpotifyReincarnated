import Orion
import SwiftUI
import MediaPlayer

//

struct BaseLyricsGroup: HookGroup { }

struct LegacyLyricsGroup: HookGroup { }
struct ModernLyricsGroup: HookGroup { }
struct V91LyricsGroup: HookGroup { }  // For Spotify 9.1.x - excludes incompatible hooks
struct LyricsErrorHandlingGroup: HookGroup { }  // ErrorViewController hooks - not compatible with 9.1.x

var lyricsState = LyricsLoadingState()

var hasShownRestrictedPopUp = false
var hasShownUnauthorizedPopUp = false

private let geniusLyricsRepository = GeniusLyricsRepository()
private let petitLyricsRepository = PetitLyricsRepository()

// Overload for 9.1.6 where we only have track ID from URL
private func loadCustomLyricsForTrackId(_ trackId: String) throws -> ColorLyricsResponse {
    
    let source = UserDefaults.lyricsSource
    
    // Always clear captured metadata to ensure we fetch fresh info
    var currentTitle: String? = nil
    var currentArtist: String? = nil
    var hasMetadata = false
    
    // If metadata is needed (Genius/LRCLIB/Petit), fetch using token
    let needsMetadata = source == .genius || source == .lrclib || source == .petit
    
    // Check if we already have the metadata cached for this exact trackId
    if capturedTrackId == trackId, let title = capturedTrackTitle, let artist = capturedArtistName {
        currentTitle = title
        currentArtist = artist
        hasMetadata = true
    }
    
    // Fetch if missing
    if !hasMetadata {
        
        // Try getting metadata from the current player state (most reliable)
        if let player = statefulPlayer, 
           let track = player.currentTrack() {
            let currentId = track.URI().spt_trackIdentifier()
            
            if currentId == trackId {
                currentTitle = track.trackTitle()
                currentArtist = track.artistName()
                hasMetadata = true
                
                // Cache it
                capturedTrackId = trackId
                capturedTrackTitle = currentTitle
                capturedArtistName = currentArtist
            } else {
            }
        } else {
        }

        if !hasMetadata {
            // Try MPNowPlayingInfoCenter (always available, version-independent)
            if let info = MPNowPlayingInfoCenter.default().nowPlayingInfo,
               let title = info[MPMediaItemPropertyTitle] as? String,
               let artist = info[MPMediaItemPropertyArtist] as? String,
               !title.isEmpty, !artist.isEmpty {
                currentTitle = title
                currentArtist = artist
                hasMetadata = true
                capturedTrackId = trackId
                capturedTrackTitle = title
                capturedArtistName = artist
            }
        }

        if !hasMetadata {
            if let token = spotifyAccessToken {
                if let info = fetchTrackDetails(trackId: trackId, token: token) {
                    currentTitle = info.title
                    currentArtist = info.artist
                    hasMetadata = true
                    
                    // Cache it
                    capturedTrackId = trackId
                    capturedTrackTitle = currentTitle
                    capturedArtistName = currentArtist
                }
            }
        }
    }
    
    if needsMetadata && !hasMetadata {
        throw LyricsError.noSuchSong
    }
    
    // Create search query with available data
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
        throw error
    }
    
    lyricsState.isEmpty = lyricsDto.lines.isEmpty
    
    lyricsState.wasRomanized = lyricsDto.romanization == .romanized
        || (lyricsDto.romanization == .canBeRomanized && UserDefaults.lyricsOptions.romanization)
    
    lyricsState.loadedSuccessfully = true

    var colorLyricsResponse = ColorLyricsResponse()
    colorLyricsResponse.lyrics = lyricsDto.toSpotifyLyricsData(source: source.description)
    
    return colorLyricsResponse
}

//

private func loadCustomLyricsForCurrentTrack() throws -> ColorLyricsResponse {
    
    guard
        let track = statefulPlayer?.currentTrack() ??
                    nowPlayingScrollViewController?.loadedTrack
        else {
            throw LyricsError.noCurrentTrack
        }
    
    let trackTitle = track.trackTitle()
    let artistName = EeveeSpotify.hookTarget == .lastAvailableiOS14
        ? track.artistName()
        : track.artistName()
    
    
    let searchQuery = LyricsSearchQuery(
        title: trackTitle,
        primaryArtist: artistName,
        spotifyTrackId: track.trackIdentifier
    )
    
    let options = UserDefaults.lyricsOptions
    var source = UserDefaults.lyricsSource
    
    // switched to swift 5.8 syntax to compile with Theos on Linux.
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
        
        if source == .genius || !UserDefaults.lyricsOptions.geniusFallback {
            throw error
        }
        
        source = .genius
        repository = GeniusLyricsRepository()
        
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
    
    // Extract track ID from URL path since player objects are nil in 9.1.6
    // Format: /color-lyrics/v2/track/{trackId} or /lyrics/.../{trackId}
    let trackIdentifier: String
    if let range = originalPath.range(of: #"/track/([a-zA-Z0-9]+)"#, options: .regularExpression) {
        let match = originalPath[range]
        trackIdentifier = String(match.split(separator: "/").last ?? "")
    } else {
        throw LyricsError.noCurrentTrack
    }
    
    // Verify track ID was extracted
    if trackIdentifier.isEmpty {
        throw LyricsError.noCurrentTrack
    }
    
    // Try to capture metadata from view hierarchy at lyrics request time
    // Always try to capture fresh metadata when track changes
    // Clear old metadata if track ID changed
    if capturedTrackId != trackIdentifier {
        capturedTrackTitle = nil
        capturedArtistName = nil
        capturedTrackId = nil
    }
    
    
    // We strictly use API fetching now (handled in loadCustomLyricsForTrackId)
    // No more UI scraping or system info hacking
    
    // Use track ID version for 9.1.6 where we don't have track objects
    var colorLyricsResponse = try loadCustomLyricsForTrackId(trackIdentifier)
    
    let lyricsColorsSettings = UserDefaults.lyricsColors
    
    if lyricsColorsSettings.displayOriginalColors, let originalLyrics = originalLyrics {
        colorLyricsResponse.colors = originalLyrics.colors
    }
    else {
        // For 9.1.6, we don't have track object to extract color from
        // Use static color if enabled, otherwise use background color or gray
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
        // 直接使用 Int32(bitPattern:) 转换 UInt32 到 Int32
        colorData.background = Int32(bitPattern: color.uInt32)
        colorData.text = Int32(bitPattern: Color.black.uInt32)
        colorData.highlightText = Int32(bitPattern: Color.white.uInt32)
        
        colorLyricsResponse.colors = colorData
    }
    
    let serializedData = try colorLyricsResponse.serializedBytes()
    return serializedData
}