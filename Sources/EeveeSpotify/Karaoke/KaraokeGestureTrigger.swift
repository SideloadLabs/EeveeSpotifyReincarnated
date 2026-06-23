import UIKit

/// Wires up the actual user-facing trigger for the karaoke overlay: a
/// long-press anywhere on the Now Playing screen. Deliberately does NOT
/// attempt to inject a new button into Spotify's native view hierarchy —
/// that would need a fresh hook point we weren't able to discover safely
/// (Spotify's anti-instrumentation protections crash on Frida attach
/// before we can enumerate/identify button targets). Instead this reuses
/// `nowPlayingScrollViewController`, a reference EeveeSpotify already
/// captures today via a proven, working hook
/// (NowPlayingScrollViewControllerInstanceHook.x.swift) — so no new
/// discovery is required, only a gesture recognizer on a view we already
/// have safe, legitimate access to.
///
/// Long-press (rather than a visible button) is a pragmatic first version:
/// it needs zero new UI placed into Spotify's layout, so there's no risk
/// of overlapping/clashing with native controls. A discoverable on-screen
/// button is a reasonable follow-up once a safe way to add one is found.
final class KaraokeGestureTrigger {
    static let shared = KaraokeGestureTrigger()

    private weak var attachedView: UIView?

    private init() {}

    /// Call periodically (e.g. from the same place that already polls/uses
    /// nowPlayingScrollViewController) to (re)attach the gesture if the
    /// Now Playing screen's view has changed or wasn't ready yet on first
    /// attempt — Spotify can recreate this view controller across
    /// navigation events, so the gesture recognizer needs reattaching
    /// when that happens rather than assuming a one-time setup is enough.
    func attachIfNeeded() {
        guard let controller = nowPlayingScrollViewController as? UIViewController,
              let view = controller.view else { return }

        if attachedView === view { return } // already attached to this exact view instance

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.6
        view.addGestureRecognizer(longPress)
        attachedView = view
        writeDebugLog("[Karaoke] long-press gesture attached to Now Playing view")
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        guard KaraokeOverlayPresenter.isAvailableForCurrentTrack() else {
            writeDebugLog("[Karaoke] long-press triggered but no karaoke data available for current track — ignoring")
            return
        }
        writeDebugLog("[Karaoke] long-press triggered — presenting overlay")
        KaraokeOverlayPresenter.present()
    }
}
