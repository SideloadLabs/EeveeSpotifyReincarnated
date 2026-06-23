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
    /// Call this wherever the user triggers the karaoke view (e.g. a new
    /// button added to the Now Playing screen, or a long-press on the
    /// existing lyrics button — the actual trigger wiring is a separate
    /// step from this presentation helper).
    static func present() {
        guard let host = topVC() else {
            writeDebugLog("[Karaoke] present() called but no top view controller found")
            return
        }
        guard let trackId = KaraokePlaybackTracker.shared.currentTrackId(),
              let lyrics = KaraokeLyricsStore.shared.lyrics(forTrackId: trackId) else {
            writeDebugLog("[Karaoke] present() called but no karaoke (Syllable) data available for current track")
            return
        }

        let view = KaraokeLyricsView(lyrics: lyrics, onDismiss: {
            topVC()?.dismiss(animated: true)
        })
        let hosting = UIHostingController(rootView: view)
        hosting.modalPresentationStyle = .fullScreen
        hosting.overrideUserInterfaceStyle = .dark
        hosting.view.backgroundColor = .black
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
