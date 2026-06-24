import UIKit

/// Attaches a long-press gesture recognizer to the Now Playing lyrics button
/// so the user can summon the custom karaoke overlay.
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
