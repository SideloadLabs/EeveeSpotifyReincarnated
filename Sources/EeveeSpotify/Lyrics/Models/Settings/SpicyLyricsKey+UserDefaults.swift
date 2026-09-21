import Foundation

extension UserDefaults {
    private static let spicyLyricsApiKeyKey = "spicyLyricsApiKey"

    /// The user's Spicy Lyrics API key (sl_sk_... / sl_pk_...), created at
    /// developers.spicylyrics.org/dashboard. Empty when not set.
    static var spicyLyricsApiKey: String {
        get {
            (container.string(forKey: spicyLyricsApiKeyKey) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        set (key) {
            container.set(
                key.trimmingCharacters(in: .whitespacesAndNewlines),
                forKey: spicyLyricsApiKeyKey
            )
        }
    }
}
