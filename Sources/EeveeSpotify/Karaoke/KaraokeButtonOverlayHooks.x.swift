import Orion
import UIKit

/// Shows the floating "Word-Synced Lyrics" button (KaraokeButtonOverlay)
/// whenever Spotify's native Lyrics fullscreen screen is on screen, and
/// hides it as soon as that screen goes away — so the button never lingers
/// on top of some other unrelated screen.
///
/// Targets the same view controller as LyricsFullscreenViewControllerHook
/// in CustomLyrics+DisableReportButton.x.swift (same targetName switch,
/// kept in sync with it deliberately), but as its own ClassHook rather
/// than adding to that one — this only watches appear/disappear, it
/// doesn't touch the report button or any other native UI, and Orion
/// hook groups support multiple ClassHooks sharing the same target/group
/// (BaseLyricsGroup already does this — see
/// NowPlayingScrollViewControllerInstanceHook.x.swift and
/// CustomLyrics+ScrollCrashFix.x.swift for other examples).
class KaraokeButtonOverlayLyricsScreenHook: ClassHook<UIViewController> {
    typealias Group = BaseLyricsGroup

    static var targetName: String {
        switch EeveeSpotify.hookTarget {
        case .lastAvailableiOS14: return "Lyrics_CoreImpl.FullscreenViewController"
        case .lastAvailableiOS15: return "Lyrics_FullscreenPageImpl.FullscreenViewController"
        default: return "Lyrics_FullscreenElementPageImpl.FullscreenElementViewController"
        }
    }

    func viewDidAppear(_ animated: Bool) {
        orig.viewDidAppear(animated)
        guard #available(iOS 15.0, *) else { return }
        KaraokeButtonOverlay.shared.show()
    }

    func viewWillDisappear(_ animated: Bool) {
        orig.viewWillDisappear(animated)
        guard #available(iOS 15.0, *) else { return }
        KaraokeButtonOverlay.shared.hide()
    }
}
