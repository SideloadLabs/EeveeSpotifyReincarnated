import UIKit

/// Wires up the actual user-facing trigger for the karaoke overlay: a
/// small floating button added to the Now Playing screen. Deliberately
/// does NOT attempt to inject into Spotify's native button row/control
/// stack — that would need a fresh hook point we weren't able to discover
/// safely (Spotify's anti-instrumentation protections crash on Frida
/// attach before we can enumerate/identify those targets). Instead this
/// adds an independent floating subview, pinned with its own constraints
/// to the safe area corner of `nowPlayingScrollViewController.view` — a
/// reference EeveeSpotify already captures today via a proven, working
/// hook (NowPlayingScrollViewControllerInstanceHook.x.swift). Because the
/// button is just an additively-added subview with its own constraints
/// (not inserted into Spotify's existing constraint system), it can't
/// conflict with or break Spotify's own internal layout.
final class KaraokeTriggerButton {
    static let shared = KaraokeTriggerButton()

    private weak var attachedView: UIView?
    private weak var button: UIButton?

    private init() {}

    /// Call periodically (e.g. on every player state change) to (re)attach
    /// the button if the Now Playing screen's view has changed or wasn't
    /// ready yet on first attempt — Spotify can recreate this view
    /// controller across navigation events, so the button needs
    /// reattaching when that happens rather than assuming a one-time
    /// setup is enough. Also keeps the button's visibility in sync with
    /// whether karaoke data actually exists for the current track.
    func attachIfNeeded() {
        guard let controller = nowPlayingScrollViewController as? UIViewController,
              let view = controller.view else { return }

        if attachedView !== view {
            installButton(on: view)
            attachedView = view
        }

        button?.isHidden = !KaraokeOverlayPresenter.isAvailableForCurrentTrack()
    }

    private func installButton(on view: UIView) {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.tintColor = .white
        button.backgroundColor = UIColor.white.withAlphaComponent(0.14)
        button.layer.cornerRadius = 20

        let config = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        button.setImage(UIImage(systemName: "music.mic", withConfiguration: config), for: .normal)
        button.accessibilityLabel = "Karaoke"

        button.addTarget(self, action: #selector(handleTap), for: .touchUpInside)

        view.addSubview(button)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 40),
            button.heightAnchor.constraint(equalToConstant: 40),
            button.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            button.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
        ])

        self.button = button
        writeDebugLog("[Karaoke] trigger button attached to Now Playing view")
    }

    @objc private func handleTap() {
        guard KaraokeOverlayPresenter.isAvailableForCurrentTrack() else {
            writeDebugLog("[Karaoke] button tapped but no karaoke data available for current track — ignoring")
            return
        }
        writeDebugLog("[Karaoke] button tapped — presenting overlay")
        KaraokeOverlayPresenter.present()
    }
}
