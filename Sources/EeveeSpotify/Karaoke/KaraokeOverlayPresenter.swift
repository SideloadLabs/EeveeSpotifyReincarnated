import UIKit
import SwiftUI

/// Presents the custom karaoke lyrics view as a full-screen modal, on top
/// of whatever screen is currently shown — the "overlay" approach (Option D)
/// rather than replacing Spotify's native LyricsViewControllerImplementation,
/// since that would need a live-runtime hook point we weren't able to find
/// safely (Spotify's anti-instrumentation protections crash on Frida attach
/// before enumeration/hooking can happen).
///
/// Presents via WindowHelper.shared's captured-at-launch root view
/// controller (see topVC()'s doc comment for why a fresh windows-array
/// lookup, the pattern SponsorBlockReportingUI.swift's topVC() uses, isn't
/// safe to copy here now that KaraokeButtonOverlay's own small window
/// exists alongside Spotify's main one).
final class KaraokeOverlayPresenter {
    /// The karaoke view's hosting controller while it's up. Weak, so a
    /// dismissal from anywhere — our close button, or Spotify dismissing
    /// presented controllers on its own — is noticed without a callback.
    private static weak var hosting: UIViewController?

    /// True while the karaoke view itself is on screen. KaraokeButtonOverlay
    /// checks this (alongside isAvailableForCurrentTrack) so the floating
    /// launcher button hides itself once the karaoke view is open.
    ///
    /// Derived from the live controller rather than a stored flag: the flag
    /// used to be set *before* present() and only cleared by our own close
    /// button, so a presentation UIKit refused (another transition in
    /// flight) or a dismissal Spotify did itself left it stuck at true —
    /// the button then never showed again and taps did nothing.
    static var isPresented: Bool {
        guard let hosting = hosting else { return false }
        return hosting.presentingViewController != nil || hosting.isBeingPresented
    }

    /// Call this wherever the user triggers the karaoke view — the visible
    /// "Word-Synced Lyrics" button on the Now Playing screen
    /// (KaraokeButtonOverlay) is the primary trigger; the long-press
    /// gesture (KaraokeGestureTrigger) remains as a secondary shortcut.
    static func present(attempt: Int = 0) {
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
        // A host mid-transition silently drops present(); report it
        // instead of looking like a dead button.
        if attempt < 4, host.isBeingDismissed || host.isBeingPresented || host.transitionCoordinator != nil {
            writeDebugLog("[Karaoke] present() deferred: \(type(of: host)) is mid-transition")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { present(attempt: attempt + 1) }
            return
        }

        let view = KaraokeLyricsView(trackId: trackId, lyrics: lyrics, onDismiss: {
            hosting?.presentingViewController?.dismiss(animated: true)
        })
        let controller = UIHostingController(rootView: view)
        controller.overrideUserInterfaceStyle = .dark
        controller.modalPresentationStyle = .fullScreen
        controller.view.backgroundColor = .black

        hosting = controller
        host.present(controller, animated: true)
        writeDebugLog("[Karaoke] presented for \(trackId) from \(type(of: host))")
    }

    /// True if karaoke data exists for the current track — callers (e.g.
    /// whatever decides whether to show a "Karaoke" button at all) should
    /// check this rather than always presenting and risking a no-op.
    static func isAvailableForCurrentTrack() -> Bool {
        guard let trackId = KaraokePlaybackTracker.shared.currentTrackId() else { return false }
        return KaraokeLyricsStore.shared.lyrics(forTrackId: trackId) != nil
    }

    /// Walks from WindowHelper's captured-at-launch root view controller
    /// (NOT a fresh `UIApplication.shared...windows` lookup) down to
    /// whatever's actually topmost right now.
    ///
    /// This used to re-derive the "current key window" from scratch on
    /// every call, with `ws.windows.first(where: { $0.isKeyWindow }) ??
    /// ws.windows.first` as the fallback if nothing currently reports
    /// itself as key — and that fallback is exactly what was producing
    /// "loads it small": KaraokeButtonOverlay's own small floating-button
    /// window is a real, persistent window in that same windows array
    /// (deliberately small and non-key, since it only needs to occupy the
    /// button's own corner — see KaraokeButtonOverlay.swift). If the
    /// fallback ever triggered while that window happened to be first in
    /// the array, `top` resolved to *its* tiny hosting controller instead
    /// of Spotify's real screen — and presenting "full screen" from a
    /// host whose own window is only ~180x56 constrains the new view to
    /// that window's bounds, not the device's actual screen.
    /// WindowHelper.shared.window is captured once, very early at launch
    /// (well before this overlay window ever exists), so starting from it
    /// instead sidesteps the ambiguity entirely.
    private static func topVC() -> UIViewController? {
        var top = WindowHelper.shared.rootViewController
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }
}
