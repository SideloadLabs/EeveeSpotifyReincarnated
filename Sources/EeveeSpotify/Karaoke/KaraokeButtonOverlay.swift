import SwiftUI
import UIKit

/// A small floating button shown on top of the Now Playing screen
/// whenever word-synced (karaoke) data is available for the current
/// track — this is the visible, discoverable way to open the karaoke
/// view, replacing the previous behavior where the *only* trigger was an
/// undocumented 0.5s long-press anywhere on screen (KaraokeGestureTrigger,
/// which still works as a shortcut once you know about it, but isn't
/// something a user would ever stumble onto).
///
/// Visibility is driven by polling rather than a viewDidAppear/
/// viewWillDisappear hook on some specific Now Playing view controller
/// class. An earlier version did try a class-name-targeted hook, but
/// pointed it at the wrong screen (Spotify's native *Lyrics* fullscreen
/// page) — and more fundamentally, the Now Playing experience here is a
/// single UICollectionView hosting Now Playing/Lyrics/Queue as swipeable
/// pages within ONE container view controller (see
/// NowPlayingScrollViewController.swift / NPVScrollViewController.swift's
/// `collectionView()` — confirmed by NowPlayingScrollPrivateService
/// ImplementationHook in NowPlayingScrollViewControllerInstanceHook.x.swift,
/// which is what actually populates the `nowPlayingScrollViewController`/
/// `npvScrollViewController` globals this file reads), not a stack of
/// separately-lifecycled per-page view controllers — so there's no single
/// "page appeared" callback to hook here in the first place. Checking
/// whether that already-tracked collection view currently has a non-nil
/// `.window` is a simple, reliable stand-in: it's true exactly when the
/// Now Playing screen (in any of its swiped-to pages) is actually on
/// screen, false otherwise, and it reuses infrastructure
/// (`nowPlayingScrollViewController`/`npvScrollViewController`) that's
/// already proven to populate reliably elsewhere in this codebase.
///
/// Implemented as a separate UIWindow (rather than injecting a UIView
/// into Spotify's own Encore view hierarchy, the way
/// CustomLyrics+ShowAttributes.x.swift does for the credits footer) so it
/// doesn't depend on Now Playing's internal layout at all. The window's
/// frame is sized to just the button's own corner — NOT the full screen —
/// positioned top-right. A UIWindow only ever receives touches that land
/// within its own frame, so this is what lets every tap *outside* that
/// corner reach Spotify's window untouched, with no custom hitTest logic
/// needed at all. (An earlier version made this window full-screen and
/// tried to manually pass non-button touches through via a hitTest
/// override — that didn't work, because SwiftUI's hosting view does its
/// own internal touch routing and hands back *itself* as the hit-test
/// result for essentially any point inside it, so the "is this actually
/// empty space, or a real button" check could never tell the difference.)
@available(iOS 15.0, *)
final class KaraokeButtonOverlay {
    static let shared = KaraokeButtonOverlay()

    private var window: UIWindow?
    private var pollTimer: Timer?

    // Set by KaraokeButtonOverlayLyricsScreenHook (viewDidAppear/
    // viewWillDisappear on the native Lyrics fullscreen screen). That
    // screen isn't necessarily reflected by nowPlayingScrollViewController/
    // npvScrollViewController's collectionView().window check below (it's
    // a separate pushed/presented screen, not one of the swiped-to pages
    // inside the Now Playing scroll container) — so this is an additional,
    // more immediate signal, OR'd in alongside the existing poll-based one
    // rather than replacing it.
    private var isLyricsScreenVisible = false

    private init() {
        // Timer setup needs the main run loop; init() can in principle be
        // triggered from any thread the first time .shared is touched, so
        // hop to main rather than assuming the caller already is.
        DispatchQueue.main.async { [weak self] in
            self?.startPolling()
        }
    }

    private func startPolling() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // .common (not .default) so this keeps firing even while the user
        // is mid-scroll/mid-drag elsewhere in the app, since UIScrollView
        // tracking normally pauses .default-mode timers.
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        refresh()
    }

    /// Called by KaraokeButtonOverlayLyricsScreenHook's viewDidAppear.
    /// Triggers an immediate refresh rather than waiting up to 0.5s for
    /// the next poll tick, so the button appears right as the Lyrics
    /// screen finishes presenting.
    func show() {
        isLyricsScreenVisible = true
        DispatchQueue.main.async { [weak self] in
            self?.refresh()
        }
    }

    /// Called by KaraokeButtonOverlayLyricsScreenHook's viewWillDisappear.
    /// Same immediacy reasoning as show() — don't let the button linger
    /// for up to 0.5s after the Lyrics screen has already started
    /// dismissing.
    func hide() {
        isLyricsScreenVisible = false
        DispatchQueue.main.async { [weak self] in
            self?.refresh()
        }
    }

    private func refresh() {
        let isNowPlayingScreenVisible =
            isLyricsScreenVisible ||
            (nowPlayingScrollViewController?.collectionView().window != nil) ||
            (npvScrollViewController?.collectionView().window != nil)
        let hasKaraokeData = KaraokeOverlayPresenter.isAvailableForCurrentTrack()
        // !isPresented: while the karaoke view itself is open (full-screen,
        // on top of everything, including this overlay window's level),
        // there's nothing for this button to do, and leaving the window
        // visible there risks it swallowing taps meant for the karaoke
        // view's own close button if their corners ever overlap.
        let shouldShow = isNowPlayingScreenVisible && hasKaraokeData && !KaraokeOverlayPresenter.isPresented

        if shouldShow {
            ensureWindowExists()
            window?.isHidden = false
        } else {
            window?.isHidden = true
        }
    }

    private func ensureWindowExists() {
        guard window == nil else { return }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }

        let screenBounds = scene.screen.bounds
        let safeAreaTop = scene.windows
            .first(where: { $0.isKeyWindow })?.safeAreaInsets.top ?? 44

        // Generous-but-tight size for the single button — wide enough for
        // longer translated copy once other languages get this key
        // translated, tall enough that the button's own tap target
        // (including its padding) is never clipped by the window edge.
        let areaWidth: CGFloat = 180
        let areaHeight: CGFloat = 56
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
        overlayWindow.isHidden = true // refresh() unhides it when appropriate

        let hosting = UIHostingController(rootView: KaraokeButtonOverlayView())
        hosting.view.backgroundColor = .clear
        overlayWindow.rootViewController = hosting

        window = overlayWindow
    }
}

@available(iOS 15.0, *)
private struct KaraokeButtonOverlayView: View {
    var body: some View {
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
        // Right-aligned within the window's own (already top-right
        // positioned) frame, rather than the window itself spanning the
        // full screen with alignment logic inside it.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }
}
