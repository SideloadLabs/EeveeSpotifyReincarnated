import UIKit
import SwiftUI

/// Presents the custom karaoke lyrics view as a full-screen modal, on top
/// of whatever screen is currently shown — the "overlay" approach (Option D)
/// rather than replacing Spotify's native LyricsViewControllerImplementation,
/// since that would need a live-runtime hook point we weren't able to find
/// safely (Spotify's anti-instrumentation protections crash on Frida attach
/// before enumeration/hooking can happen).
///
/// Mirrors SponsorBlockReportingUI.swift's topVC()+UIHostingController
/// presentation pattern, which is already proven working in this codebase.
final class KaraokeOverlayPresenter {
    /// True while the karaoke view itself is on screen. KaraokeButtonOverlay
    /// checks this (alongside isAvailableForCurrentTrack) so the floating
    /// launcher button hides itself once the karaoke view is open — without
    /// this, the button's overlay window (which sits above the app's main
    /// window so it can float over Spotify's native Lyrics screen) would
    /// also float on top of the karaoke view once presented, and tapping it
    /// again would stack a second presentation on top of the first.
    private(set) static var isPresented = false

    /// Call this wherever the user triggers the karaoke view — the visible
    /// "Word-Synced Lyrics" button on Spotify's native Lyrics screen
    /// (KaraokeButtonOverlay) is the primary trigger; the long-press
    /// gesture (KaraokeGestureTrigger) remains as a secondary shortcut.
    static func present() {
        guard !isPresented else { return }
        guard #available(iOS 15.0, *) else {
            writeDebugLog("[Karaoke] present() skipped: requires iOS 15+")
            return
        }
        guard let host = topVC() else {
            writeDebugLog("[Karaoke] present() called but no top view controller found")
            return
        }
        guard let trackId = KaraokePlaybackTracker.shared.currentTrackId(),
              let lyrics = KaraokeLyricsStore.shared.lyrics(forTrackId: trackId) else {
            writeDebugLog("[Karaoke] present() called but no karaoke (Syllable) data available for current track")
            return
        }

        let isCompact = UserDefaults.lyricsOptions.karaokeShrinkOverlay

        let view = KaraokeLyricsView(lyrics: lyrics, isCompact: isCompact, onDismiss: {
            isPresented = false
            topVC()?.dismiss(animated: true)
        })
        let hosting = UIHostingController(rootView: view)
        hosting.overrideUserInterfaceStyle = .dark

        if isCompact {
            // .overFullScreen (rather than .fullScreen) keeps `host`'s own
            // view — Spotify's native Lyrics screen, whatever's currently
            // on top — alive underneath instead of removing it from the
            // view hierarchy, and the clear background lets it show
            // through KaraokeLyricsView's own scrim/card. This is what
            // makes the overlay actually "shrink over" the native screen
            // rather than just being a smaller view on an otherwise
            // identical opaque takeover.
            hosting.modalPresentationStyle = .overFullScreen
            hosting.view.backgroundColor = .clear
        } else {
            hosting.modalPresentationStyle = .fullScreen
            hosting.view.backgroundColor = .black
        }

        isPresented = true
        host.present(hosting, animated: true)
    }

    /// True if karaoke data exists for the current track — callers (e.g.
    /// whatever decides whether to show a "Karaoke" button at all) should
    /// check this rather than always presenting and risking a no-op.
    static func isAvailableForCurrentTrack() -> Bool {
        guard let trackId = KaraokePlaybackTracker.shared.currentTrackId() else { return false }
        return KaraokeLyricsStore.shared.lyrics(forTrackId: trackId) != nil
    }

    private static func topVC() -> UIViewController? {
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene,
                  ws.activationState == .foregroundActive else { continue }
            let win = ws.windows.first(where: { $0.isKeyWindow }) ?? ws.windows.first
            guard var top = win?.rootViewController else { continue }
            while let p = top.presentedViewController { top = p }
            return top
        }
        return nil
    }
}
