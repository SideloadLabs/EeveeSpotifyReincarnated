import Foundation

enum LyricsError: Error, CustomStringConvertible {
    case noCurrentTrack
    case trackMismatch
    case decodingError
    case noSuchSong
    case unknownError
    case invalidSource
    case invalidSpicyKey
    
    // swift 5.8 compatible
    var description: String {
        switch self {
        case .noSuchSong:
            return "no_such_song".localized
        case .decodingError:
            return "decoding_error".localized
        case .unknownError:
            return "unknown_error".localized
        case .invalidSpicyKey:
            return "spicylyrics_key_invalid".localized
        default:
            return ""
        }
    }
}
