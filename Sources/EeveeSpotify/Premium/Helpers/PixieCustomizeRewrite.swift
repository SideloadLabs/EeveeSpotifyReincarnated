import Foundation

/// Applies the Pixie companion's offline entitlements to a customize body.
///
/// Eevee replays its own saved copy of the customize response on every warm relaunch
/// (the server answers 304) and for re-fetches. That replay goes straight to Spotify's
/// original delegate method, so a saved copy made before Pixie was installed (or made by
/// a build without Pixie's flags) reaches Spotify without them. That is why Pixie only
/// worked after a clean reinstall. Rewriting the copy here, every time it is saved or
/// replayed, makes the result independent of hook order and of what an older build saved.
/// The rewrite is idempotent and does nothing when the companion is not loaded.
enum PixieCustomizeRewrite {
    private typealias Rewrite = @convention(c) (NSData, Bool) -> NSData

    private static let rewrite: Rewrite? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SAPRewriteOfflineConfig") else {
            return nil
        }
        return unsafeBitCast(symbol, to: Rewrite.self)
    }()

    static func apply(_ data: Data?) -> Data? {
        guard let data, !data.isEmpty, let rewrite else { return data }
        return rewrite(data as NSData, false) as Data
    }
}
