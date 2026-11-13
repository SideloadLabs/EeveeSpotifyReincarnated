import Foundation

extension UserDefaults {
    @UserDefault(
        key: "lyricsOptions",
        defaultValue: LyricsOptions(
            romanization: false,
            lrclibUrl: LrclibLyricsRepository.originalApiUrl,
            geniusFallback: true,
            showFallbackReasons: true,
            hideOnError: false
        )
    )
    static var lyricsOptions
}
