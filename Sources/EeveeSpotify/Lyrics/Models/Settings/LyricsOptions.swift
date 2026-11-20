import Foundation

struct LyricsOptions: Codable, Hashable {
    var romanization: Bool
    var lrclibUrl: String
    var geniusFallback: Bool
    var showFallbackReasons: Bool
    var hideOnError: Bool

    var downloadOptions: Self {
        var options = self
        options.showFallbackReasons = false
        options.hideOnError = false
        return options
    }
}
