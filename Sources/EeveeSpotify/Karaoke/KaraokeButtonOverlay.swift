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
/// window sidesteps that entirely, at the cost of not being "really" part
/// of the native screen's own view tree.
///
/// The window's frame is deliberately sized to just the button row's own
/// corner — NOT the full screen — positioned top-right. A UIWindow only
/// ever receives touches that land within its own frame, so this is what
/// lets every tap *outside* that corner reach Spotify's window untouched,
/// with no custom hitTest logic needed at all. An earlier version made
/// this window full-screen and tried to manually pass non-button touches
/// through via a hitTest override that compared the hit-tested view
/// against the hosting controller's root view — that didn't work, because
/// SwiftUI's hosting view does its own internal touch routing and hands
/// back *itself* as the hit-test result for essentially any point inside
/// it (SwiftUI buttons aren't discrete child UIViews at their own frame
/// the way a plain UIButton would be), so the "is this actually empty
/// space, or a real button" check could never tell the difference —
/// every tap, including real button taps, looked identical to that check
/// and got silently swallowed as "not a button."
@available(iOS 15.0, *)
final class KaraokeButtonOverlay {
    static let shared = KaraokeButtonOverlay()

    private var window: UIWindow?

    private init() {}

    func show() {
        guard window == nil else { return }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }

        let screenBounds = scene.screen.bounds
        let safeAreaTop = scene.windows
            .first(where: { $0.isKeyWindow })?.safeAreaInsets.top ?? 44

        // Generous size for the two-button row — wider than it needs to be
        // for the current English copy so there's headroom for longer
        // translated strings once other languages get these new keys
        // translated, and tall enough that the buttons' own tap targets
        // (including their padding) are never clipped by the window edge.
        let areaWidth: CGFloat = 240
        let areaHeight: CGFloat = 64
        // Sits just below the safe area, clear of the status bar/notch —
        // and, since this is the *top*-right corner, clear of Spotify's
        // native playback controls at the bottom too. If this overlaps
        // Spotify's own header controls on some screen size, nudge
        // topInset up/down here.
        let topInset: CGFloat = 8
        let trailingInset: CGFloat = 8

        let frame = CGRect(
            x: screenBounds.width - areaWidth - trailingInset,
            y: safeAreaTop + topInset,
            width: areaWidth,
            height: areaHeight
        )

        let overlayWindow = UIWindow(windowScene: scene)
        overlayWindow.frame = frame
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

@available(iOS 15.0, *)
private struct KaraokeButtonOverlayView: View {
    @State private var isAvailable = KaraokeOverlayPresenter.isAvailableForCurrentTrack()
        && !KaraokeOverlayPresenter.isPresented
    @State private var shrinkOverlay = UserDefaults.lyricsOptions.karaokeShrinkOverlay

    var body: some View {
        HStack(spacing: 10) {
            if isAvailable {
                shrinkToggleButton
                wordSyncedButton
            }
        }
        // Right-aligned within the window's own (already top-right
        // positioned) frame, rather than the window itself spanning the
        // full screen with alignment logic inside it.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
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
