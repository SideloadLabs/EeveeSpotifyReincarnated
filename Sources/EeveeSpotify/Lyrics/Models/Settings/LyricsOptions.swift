import Foundation

struct LyricsOptions: Codable, Hashable {
    var romanization: Bool
    var musixmatchLanguage: String
    var lrclibUrl: String
    var geniusFallback: Bool
    var showFallbackReasons: Bool
    var hideOnError: Bool
    /// When true, the word-synced karaoke overlay (KaraokeLyricsView) is
    /// presented as a smaller, rounded-corner card floating above Spotify's
    /// native Lyrics screen — which stays visible, dimmed, behind it —
    /// instead of taking over the whole screen with an opaque background.
    /// Toggled either here or via the quick toggle button on the karaoke
    /// overlay itself / the floating launcher button on the native Lyrics
    /// screen (KaraokeButtonOverlay) — both read/write this same setting.
    var karaokeShrinkOverlay: Bool

    init(
        romanization: Bool,
        musixmatchLanguage: String,
        lrclibUrl: String,
        geniusFallback: Bool,
        showFallbackReasons: Bool,
        hideOnError: Bool,
        karaokeShrinkOverlay: Bool = false
    ) {
        self.romanization = romanization
        self.musixmatchLanguage = musixmatchLanguage
        self.lrclibUrl = lrclibUrl
        self.geniusFallback = geniusFallback
        self.showFallbackReasons = showFallbackReasons
        self.hideOnError = hideOnError
        self.karaokeShrinkOverlay = karaokeShrinkOverlay
    }

    // Decodes each field independently with a fallback default rather than
    // relying on the synthesized all-or-nothing Decodable conformance —
    // otherwise, adding karaokeShrinkOverlay would make every existing
    // user's already-saved LyricsOptions JSON (which has no such key) fail
    // to decode entirely, silently resetting ALL of their lyrics settings
    // (romanization, Musixmatch language, etc.) back to defaults the first
    // time they update, not just this one new field. Matches the pattern
    // already used for this exact reason in SponsorBlockOptions.swift.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        romanization = (try? c.decode(Bool.self, forKey: .romanization)) ?? false
        musixmatchLanguage = (try? c.decode(String.self, forKey: .musixmatchLanguage))
            ?? (Locale.current.languageCode ?? "")
        lrclibUrl = (try? c.decode(String.self, forKey: .lrclibUrl))
            ?? LrclibLyricsRepository.originalApiUrl
        geniusFallback = (try? c.decode(Bool.self, forKey: .geniusFallback)) ?? true
        showFallbackReasons = (try? c.decode(Bool.self, forKey: .showFallbackReasons)) ?? true
        hideOnError = (try? c.decode(Bool.self, forKey: .hideOnError)) ?? false
        karaokeShrinkOverlay = (try? c.decode(Bool.self, forKey: .karaokeShrinkOverlay)) ?? false
    }
}
