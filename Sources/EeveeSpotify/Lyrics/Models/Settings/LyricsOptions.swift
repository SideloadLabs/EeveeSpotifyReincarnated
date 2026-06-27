import Foundation

struct LyricsOptions: Codable, Hashable {
    var romanization: Bool
    var musixmatchLanguage: String
    var lrclibUrl: String
    var geniusFallback: Bool
    var showFallbackReasons: Bool
    var hideOnError: Bool
}
