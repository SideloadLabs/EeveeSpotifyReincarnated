import Foundation

enum LyricsError: Error, CustomStringConvertible {
    case noCurrentTrack
    case trackMismatch
    case musixmatchRestricted
    case invalidMusixmatchToken
    case decodingError
    case noSuchSong
    case unknownError
    case invalidSource
    case missingSpicyKey
    case invalidSpicyKey
    
    // swift 5.8 compatible
    var description: String {
        switch self {
        case .noSuchSong:
            return "no_such_song".localized
        case .musixmatchRestricted:
            return "musixmatch_restricted".localized
        case .invalidMusixmatchToken:
            return "invalid_musixmatch_token".localized
        case .decodingError:
            return "decoding_error".localized
        case .unknownError:
            return "unknown_error".localized
        case .missingSpicyKey:
            return "spicylyrics_key_missing".localized
        case .invalidSpicyKey:
            return "spicylyrics_key_invalid".localized
        default:
            return ""
        }
    }
}
