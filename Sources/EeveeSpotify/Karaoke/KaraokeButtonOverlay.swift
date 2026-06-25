import SwiftUI
import UIKit

/// A small floating button shown on top of Spotify's native Lyrics
/// fullscreen screen whenever word-synced (karaoke) data is available for
/// the current track — this is the visible, discoverable way to open the
/// karaoke view, replacing the previous behavior where the *only* trigger
/// was an undocumented 0.5s long-press anywhere on screen
/// (KaraokeGestureTrigger, which still works as a shortcut once you know
/// about it, but isn't something a user would ever stumble onto).
///
/// Shown/hidden by KaraokeButtonOverlayHooks.x.swift's viewDidAppear/
/// viewWillDisappear hooks on the native Lyrics screen. Implemented as a
/// separate UIWindow (rather than injecting a UIView into Spotify's own
/// Encore view hierarchy, the way CustomLyrics+ShowAttributes.x.swift does
/// for the credits footer) because the button needs to work identically
/// across all the Lyrics_*ViewController class variants this codebase
/// already has to switch on by iOS/Spotify version — a separate overlay
/// window sidesteps that entirely, at the cost of not being "really"
/// part of the native screen's own view tree.
@available(iOS 15.0, *)
final class KaraokeButtonOverlay {
    static let shared = KaraokeButtonOverlay()

    private var window: PassthroughWindow?

    private init() {}

    func show() {
        guard window == nil else { return }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }

        let overlayWindow = PassthroughWindow(windowScene: scene)
        overlayWindow.windowLevel = .alert - 1
        overlayWindow.backgroundColor = .clear
        overlayWindow.isHidden = false

        let hosting = UIHostingController(rootView: KaraokeButtonOverlayView())
        hosting.view.backgroundColor = .clear
        overlayWindow.rootViewController = hosting

        window = overlayWindow
    }

    func hide() {
        window?.isHidden = true
        window = nil
    }
}

/// A UIWindow that only intercepts touches that actually land on one of
/// its own button subviews — everywhere else, touches pass straight
/// through to whatever's underneath (Spotify's native Lyrics screen), so
/// this overlay never blocks scrolling or tapping on the screen beneath it.
private final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        // The hosting controller's own root view fills the whole window
        // and would otherwise swallow every touch; only let through hits
        // that landed on a real subview (an actual button) of it.
        return (hit == self || hit == rootViewController?.view) ? nil : hit
    }
}

@available(iOS 15.0, *)
private struct KaraokeButtonOverlayView: View {
    @State private var isAvailable = KaraokeOverlayPresenter.isAvailableForCurrentTrack()
        && !KaraokeOverlayPresenter.isPresented
    @State private var shrinkOverlay = UserDefaults.lyricsOptions.karaokeShrinkOverlay

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                if isAvailable {
                    HStack(spacing: 10) {
                        shrinkToggleButton
                        wordSyncedButton
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
        }
        .padding(.trailing, 20)
        .padding(.bottom, 110) // clears Spotify's native playback controls
        .animation(.easeOut(duration: 0.25), value: isAvailable)
        // Polling rather than an event/notification hook: karaoke data can
        // finish loading slightly after the Lyrics screen itself appears
        // (the SpicyLyrics fetch is async), and the current track can
        // change while the Lyrics screen stays open (skipping tracks
        // without leaving the screen), so a periodic re-check is simpler
        // and more robust here than threading a notification through every
        // place that could affect availability.
        .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { _ in
            isAvailable = KaraokeOverlayPresenter.isAvailableForCurrentTrack()
                && !KaraokeOverlayPresenter.isPresented
        }
    }

    private var wordSyncedButton: some View {
        Button(action: { KaraokeOverlayPresenter.present() }) {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble.fill")
                    .font(.system(size: 13, weight: .semibold))
                Text("karaoke_word_synced_button".localized)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Capsule().fill(Color.white.opacity(0.18)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
    }

    /// Lets the shrink/full preference be flipped right from the Lyrics
    /// screen, in addition to the persistent toggle in Lyrics Settings —
    /// both read/write the same LyricsOptions.karaokeShrinkOverlay value.
    private var shrinkToggleButton: some View {
        Button(action: {
            shrinkOverlay.toggle()
            var options = UserDefaults.lyricsOptions
            options.karaokeShrinkOverlay = shrinkOverlay
            UserDefaults.lyricsOptions = options
        }) {
            Image(systemName: shrinkOverlay ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
                .padding(10)
                .background(Circle().fill(Color.white.opacity(0.14)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
                .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
    }
}
