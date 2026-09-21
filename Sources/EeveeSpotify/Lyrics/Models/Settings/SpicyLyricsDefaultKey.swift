import Foundation

/// Built-in Spicy Lyrics client key, used when the user hasn't pasted their own
/// in EeveeSpotify's lyrics settings (UserDefaults.spicyLyricsApiKey wins).
///
/// This is a publishable key (sl_pk_...) created with "Allow requests with no
/// Origin header" enabled, which is what a native client needs. It is public
/// by design: it ships inside the binary. Never put a secret key (sl_sk_...)
/// here.
enum SpicyLyricsDefaultKey {
    static let value = "sl_pk_Ze_t4WKwuCYAUB1sWPT2nXlPrJ-NvoTlQnf_MY5ZD6k"
}
