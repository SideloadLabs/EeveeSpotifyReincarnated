import UIKit

/// Attaches a long-press gesture recognizer to the app window so the user
/// can summon the custom karaoke overlay from anywhere with a 0.5s
/// long-press. This was originally the *only* way to trigger the karaoke
/// view, which made it effectively undiscoverable — KaraokeButtonOverlay
/// now provides a real, visible button on Spotify's native Lyrics screen
/// and is the primary trigger. This gesture is kept as a secondary
/// shortcut for anyone who already relies on it.
/// Call attachIfNeeded() whenever playback state changes — it's idempotent.
final class KaraokeGestureTrigger {
    static let shared = KaraokeGestureTrigger()
    private var attached = false

    private init() {}

    func attachIfNeeded() {
        guard !attached else { return }
        guard KaraokeOverlayPresenter.isAvailableForCurrentTrack() else { return }
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })?
            .windows.first(where: { $0.isKeyWindow }) else { return }

        let recognizer = UILongPressGestureRecognizer(
            target: self,
            action: #selector(handleLongPress(_:))
        )
        recognizer.minimumPressDuration = 0.5
        window.addGestureRecognizer(recognizer)
        attached = true
        writeDebugLog("[Karaoke] gesture trigger attached")
    }

    @objc private func handleLongPress(_ sender: UILongPressGestureRecognizer) {
        guard sender.state == .began else { return }
        KaraokeOverlayPresenter.present()
    }
}
