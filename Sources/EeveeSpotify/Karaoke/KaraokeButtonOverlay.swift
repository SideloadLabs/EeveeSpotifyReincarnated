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
/// Visibility is primarily driven by polling rather than a
/// viewDidAppear/viewWillDisappear hook on some specific Now Playing view
/// controller class. The Now Playing experience here is a single
/// UICollectionView hosting Now Playing/Lyrics/Queue as swipeable pages
/// within ONE container view controller (see
/// NowPlayingScrollViewController.swift / NPVScrollViewController.swift's
/// `collectionView()` — confirmed by NowPlayingScrollPrivateService
/// ImplementationHook in NowPlayingScrollViewControllerInstanceHook.x.swift,
/// which is what actually populates the `nowPlayingScrollViewController`/
/// `npvScrollViewController` globals this file reads), not a stack of
/// separately-lifecycled per-page view controllers — so there's no single
/// "page appeared" callback to hook for THAT screen. Checking whether that
/// already-tracked collection view currently has a non-nil `.window` is a
/// simple, reliable stand-in: it's true exactly when the Now Playing
/// screen (in any of its swiped-to pages) is actually on screen, false
/// otherwise, and it reuses infrastructure
/// (`nowPlayingScrollViewController`/`npvScrollViewController`) that's
/// already proven to populate reliably elsewhere in this codebase.
///
/// Spotify's separate native Lyrics *fullscreen* screen (a distinct pushed/
/// presented view controller, not one of the swiped-to pages above) is the
/// one exception: KaraokeButtonOverlayLyricsScreenHook watches that
/// screen's own appear/disappear and force-hides this button while it's
/// up, since the button belongs on the page where the music plays, not
/// the Lyrics page.
///
/// Implemented as a separate UIWindow (rather than injecting a UIView
/// into Spotify's own Encore view hierarchy, the way
/// CustomLyrics+ShowAttributes.x.swift does for the credits footer) so it
/// doesn't depend on Now Playing's internal layout at all. The window's
/// frame is sized to just the button's own corner — NOT the full screen —
/// positioned near the bottom action row (best-effort proximity to
/// Spotify's own share button; see the comment above ensureWindowExists
/// for why this isn't a true anchor to it). A UIWindow only ever receives
/// touches that land within its own frame, so this is what lets every tap
/// *outside* that corner reach Spotify's window untouched, with no custom
/// hitTest logic needed at all. (An earlier version made this window
/// full-screen and tried to manually pass non-button touches through via
/// a hitTest override — that didn't work, because SwiftUI's hosting view
/// does its own internal touch routing and hands back *itself* as the
/// hit-test result for essentially any point inside it, so the "is this
/// actually empty space, or a real button" check could never tell the
/// difference.)
@available(iOS 15.0, *)
final class KaraokeButtonOverlay {
    static let shared = KaraokeButtonOverlay()

    private var window: UIWindow?
    private var pollTimer: Timer?

    // Set by KaraokeButtonOverlayLyricsScreenHook (viewDidAppear/
    // viewWillDisappear on Spotify's native Lyrics fullscreen screen). This
    // button belongs on the page where the music plays, not the Lyrics
    // page — so this is a force-hide override, not a force-show. The
    // Lyrics fullscreen screen is a separate pushed/presented screen, not
    // one of the swiped-to pages inside the Now Playing scroll container
    // tracked by nowPlayingScrollViewController/npvScrollViewController
    // below, so without this the poll-based check alone wouldn't catch it
    // and the button would incorrectly linger on top of it.
    private var isOnNativeLyricsScreen = false

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
    /// Force-hides the button immediately (rather than waiting up to 0.5s
    /// for the next poll tick) as soon as Spotify's native Lyrics
    /// fullscreen screen finishes presenting.
    func hideForLyricsScreen() {
        isOnNativeLyricsScreen = true
        DispatchQueue.main.async { [weak self] in
            self?.refresh()
        }
    }

    /// Called by KaraokeButtonOverlayLyricsScreenHook's viewWillDisappear.
    /// Clears the override immediately so the button can reappear as soon
    /// as the Lyrics screen has started dismissing, without waiting for
    /// the next poll tick — normal poll-driven visibility (Now Playing
    /// page) takes back over from here.
    func showAfterLeavingLyricsScreen() {
        isOnNativeLyricsScreen = false
        DispatchQueue.main.async { [weak self] in
            self?.refresh()
        }
    }

    private func refresh() {
        let liveVC = !isOnNativeLyricsScreen ? KaraokeButtonOverlay.findLiveNowPlayingScrollViewController() : nil
        let isNowPlayingScreenVisible = !isOnNativeLyricsScreen && KaraokeButtonOverlay.isNowPlayingScreenCurrentlyVisible(liveVC: liveVC)
        let isMinimized = KaraokeButtonOverlay.isNowPlayingScreenMinimized(liveVC: liveVC)
        let hasKaraokeData = KaraokeOverlayPresenter.isAvailableForCurrentTrack()
        // !isPresented: while the karaoke view itself is open (full-screen,
        // on top of everything, including this overlay window's level),
        // there's nothing for this button to do, and leaving the window
        // visible there risks it swallowing taps meant for the karaoke
        // view's own close button if their corners ever overlap.
        //
        // Deliberately does NOT factor in isScrolledOffScreen here —
        // that's handled separately below, without tearing down scroll
        // tracking, so scrolling back into view is still noticed. If this
        // is false, the button isn't eligible to show at all regardless of
        // scroll position, and tracking is torn down for real.
        let shouldShow = isNowPlayingScreenVisible && !isMinimized && hasKaraokeData
            && !KaraokeOverlayPresenter.isPresented

        if shouldShow {
            ensureWindowExists()
            trackScrolling(of: liveVC)
            window?.isHidden = isScrolledOffScreen
        } else {
            window?.isHidden = true
            stopTrackingScrolling()
        }
    }

    // Verified against a real 9.1.74 IPA (binary string/ObjC-selector
    // inspection): the `provideScrollViewControllerWithDependencies:`
    // selector that NowPlayingScrollPrivateServiceImplementationHook hooks
    // (in NowPlayingScrollViewControllerInstanceHook.x.swift) no longer
    // exists anywhere in that build's ObjC method-name table at all —
    // Spotify restructured that DI factory method. That hook can never
    // attach on this build, so `nowPlayingScrollViewController`/
    // `npvScrollViewController` stay permanently nil — which is what made
    // this button (and, since it's the only reachable trigger for the
    // custom word-synced view on modern iOS, effectively the whole karaoke
    // feature) permanently invisible, independent of whether karaoke data
    // was actually available.
    //
    // The view controller CLASSES the old hook used to hand us a reference
    // to (NowPlayingScrollViewController / NPVScrollViewController, both
    // still present in the NowPlaying_ScrollImpl module per the same binary
    // inspection) are still real and still on screen — only the specific
    // factory method that used to capture a reference to them broke. So
    // instead of depending on that capture, this looks for a live instance
    // directly in the current view-controller hierarchy by runtime class
    // name every poll tick, then checks its own `.view.window` (see the
    // crash note on isNowPlayingScreenCurrentlyVisible below for why this
    // deliberately does NOT go through `.collectionView()`). This is more
    // resilient to Spotify's internal DI wiring changing again in the
    // future, at the cost of a per-tick hierarchy walk (bounded depth, only
    // every 0.5s, matching this class's existing poll cadence).
    private static let liveScrollViewControllerClassNames: Set<String> = [
        "NowPlaying_ScrollImpl.NowPlayingScrollViewController",
        "NowPlaying_ScrollImpl.NPVScrollViewController",
    ]

    private static func isNowPlayingScreenCurrentlyVisible(liveVC: UIViewController?) -> Bool {
        // Old hook-populated path first, in case a future Spotify build
        // restores the factory method (or this runs on a build where it
        // still works).
        if (nowPlayingScrollViewController?.collectionView().window != nil) ||
           (npvScrollViewController?.collectionView().window != nil) {
            return true
        }

        // Deliberately does NOT call .collectionView() on whatever's found
        // below. An earlier version did, via Dynamic.convert(_, to:
        // NowPlayingScrollViewController.self) — which force-dispatches the
        // selector with no existence check — and that crashed in production
        // with "-[NowPlaying_ScrollImpl.NPVScrollViewController
        // collectionView]: unrecognized selector sent to instance". The
        // class name still matches (confirmed via binary inspection, hence
        // this path finding it at all), but this build's instance doesn't
        // actually expose a `collectionView` selector to the ObjC runtime —
        // Spotify evidently reworked that accessor too, not just the
        // provideScrollViewControllerWithDependencies: factory method that
        // broke `nowPlayingScrollViewController`/`npvScrollViewController`
        // in the first place. Rather than chase yet another moving-target
        // selector name (or guard every call with responds(to:), which
        // still leaves this fragile to the *next* internal rename), just
        // check whether the view controller's own `.view` is on screen —
        // that's plain UIViewController/UIView API, not a Spotify-internal
        // accessor, so there's nothing here for Spotify to break.
        guard let liveVC = liveVC else { return false }
        return liveVC.view.window != nil
    }

    // Heuristic for "Now Playing is minimized to the mini-player bar rather
    // than fully expanded". Spotify doesn't expose a stable, safely-callable
    // selector for this that I could confirm from the IPA (same situation as
    // the broken collectionView() accessor above), so rather than guess at
    // another private accessor, this compares the live Now Playing view's
    // on-screen height against the screen height: full-screen presentation
    // is close to the whole screen; the collapsed mini-player bar is a thin
    // strip at the bottom. 40% is a starting guess, not a measured value —
    // if this over- or under-fires (button disappearing too early/late as
    // you collapse it), let me know how far off it looks and I can tighten
    // the threshold.
    private static let minimizedHeightFraction: CGFloat = 0.4

    private static func isNowPlayingScreenMinimized(liveVC: UIViewController?) -> Bool {
        guard let liveVC = liveVC, let window = liveVC.view.window else { return false }
        let visibleHeight = liveVC.view.convert(liveVC.view.bounds, to: window).height
        let screenHeight = window.bounds.height
        guard screenHeight > 0 else { return false }
        return (visibleHeight / screenHeight) < minimizedHeightFraction
    }

    /// Walks the live view-controller hierarchy — root(s) + children
    /// (generically covers UINavigationController/UITabBarController/
    /// UISplitViewController stacks, which all surface their contents via
    /// their own `.children`) + presentedViewController, recursively —
    /// looking for an instance whose runtime class matches one of
    /// `liveScrollViewControllerClassNames`.
    private static func findLiveNowPlayingScrollViewController() -> UIViewController? {
        let roots = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .compactMap { $0.rootViewController }

        func walk(_ vc: UIViewController) -> UIViewController? {
            if liveScrollViewControllerClassNames.contains(NSStringFromClass(type(of: vc))) {
                return vc
            }
            if let presented = vc.presentedViewController, let found = walk(presented) {
                return found
            }
            for child in vc.children {
                if let found = walk(child) { return found }
            }
            return nil
        }

        for root in roots {
            if let found = walk(root) { return found }
        }
        return nil
    }

    // MARK: - Scroll tracking
    //
    // Moves the button window's Y position to follow the Now Playing
    // screen's own scroll offset, so it stays visually attached to the
    // content instead of sitting at a fixed screen position while the user
    // scrolls Now Playing's content underneath it.
    //
    // Crash-safety note: this deliberately locates the scroll view by
    // *type* (`as? UIScrollView` — a plain Swift type check, not a runtime
    // selector dispatch) rather than by calling the broken
    // `collectionView()` accessor used elsewhere in this file. Walking
    // `.subviews` and `NSKeyValueObservation` on `contentOffset` are both
    // public, stable UIKit API — there's nothing Spotify-internal here for
    // a future build to break.

    private weak var trackedScrollView: UIScrollView?
    private var scrollObservation: NSKeyValueObservation?
    private var baseWindowY: CGFloat?
    private var baseContentOffsetY: CGFloat?
    private var isScrolledOffScreen = false

    private func trackScrolling(of liveVC: UIViewController?) {
        guard let liveVC = liveVC else {
            stopTrackingScrolling()
            return
        }

        let scrollView = KaraokeButtonOverlay.findFirstScrollView(in: liveVC.view)

        if scrollView !== trackedScrollView {
            stopTrackingScrolling()
            guard let scrollView = scrollView else { return }
            trackedScrollView = scrollView
            baseContentOffsetY = scrollView.contentOffset.y
            baseWindowY = window?.frame.origin.y
            scrollObservation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, change in
                guard let self = self, let newOffset = change.newValue else { return }
                DispatchQueue.main.async {
                    self.applyScrollOffset(newOffset.y)
                }
            }
        }
    }

    private func stopTrackingScrolling() {
        scrollObservation?.invalidate()
        scrollObservation = nil
        trackedScrollView = nil
        baseWindowY = nil
        baseContentOffsetY = nil
        isScrolledOffScreen = false
    }

    private func applyScrollOffset(_ currentOffsetY: CGFloat) {
        guard let window = window,
              let baseWindowY = baseWindowY,
              let baseContentOffsetY = baseContentOffsetY else { return }

        // Content scrolling up (offset increasing) should move the button up
        // with it, same direction Spotify's own content moves — hence
        // subtracting the delta rather than adding it.
        let delta = currentOffsetY - baseContentOffsetY
        var newFrame = window.frame
        newFrame.origin.y = baseWindowY - delta
        window.frame = newFrame

        // Deliberately NOT clamped to stay on screen (an earlier version
        // did) — the button should actually leave with the area it's
        // anchored near rather than getting stuck pinned at the screen
        // edge once that area scrolls away. Track whether it's still
        // within the visible screen bounds and toggle isHidden directly
        // here (rather than routing through refresh(), whose "not
        // eligible to show" branch also tears down scroll tracking — doing
        // that here would stop noticing if the user scrolls back into
        // view). refresh()'s own conditions (Now Playing visible,
        // karaoke data, etc.) are re-checked independently on the next
        // poll tick as usual.
        let screenHeight = window.windowScene?.screen.bounds.height ?? UIScreen.main.bounds.height
        let isOffScreen = newFrame.maxY <= 0 || newFrame.origin.y >= screenHeight
        isScrolledOffScreen = isOffScreen
        window.isHidden = isOffScreen
    }

    /// Walks `.subviews` (breadth-first) looking for the first UIScrollView
    /// (UICollectionView included, since it's a UIScrollView subclass).
    /// Pure type-checking, no selector calls — see the crash-safety note
    /// above trackScrolling.
    private static func findFirstScrollView(in root: UIView) -> UIScrollView? {
        var queue: [UIView] = [root]
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if let scrollView = view as? UIScrollView {
                return scrollView
            }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }

    private func ensureWindowExists() {
        guard window == nil else { return }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }

        let screenBounds = scene.screen.bounds
        let safeAreaBottom = scene.windows
            .first(where: { $0.isKeyWindow })?.safeAreaInsets.bottom ?? 34

        // Generous-but-tight size for the single button — wide enough for
        // longer translated copy once other languages get this key
        // translated, tall enough that the button's own tap target
        // (including its padding) is never clipped by the window edge.
        let areaWidth: CGFloat = 180
        let areaHeight: CGFloat = 56
        let bottomInset: CGFloat = 96
        let trailingInset: CGFloat = 8

        // Best-effort placement near where Spotify's own action row (share/
        // add-to-playlist/etc.) sits on the Now Playing screen, rather than
        // the previous top-right corner. This is a fixed offset, not a true
        // anchor to the real share button's frame — I looked for a stable,
        // safely-hookable reference to it (ActionBarView/actionBarContainer)
        // and couldn't confirm one from static binary inspection alone
        // (unlike the plain UIView-subclass targets elsewhere in this file,
        // it didn't resolve to a verifiable Module.ClassName, which reading
        // ivars or subviews off blind would risk another
        // "unrecognized selector"-style crash). If you can get me a rough
        // screenshot or the exact frame of the share button, this offset can
        // be tightened up considerably.
        let frame = CGRect(
            x: screenBounds.width - areaWidth - trailingInset,
            y: screenBounds.height - safeAreaBottom - bottomInset - areaHeight,
            width: areaWidth,
            height: areaHeight
        )

        let overlayWindow = UIWindow(windowScene: scene)
        overlayWindow.frame = frame
        // Screen-visibility gating (isNowPlayingScreenCurrentlyVisible) already
        // limits *when* this shows to the Now Playing screen. This level
        // controls *stacking*, separately: .alert - 1 (the previous value)
        // sits just below system alerts — meaning above sheets, toasts,
        // snackbars, the volume HUD, and any other transient UI Spotify
        // shows while the user is still on the Now Playing screen, which is
        // what "overlays over everything" actually referred to (visibility
        // timing was never the only problem). .normal + 1 sits just above
        // the app's own main content but still below all of that.
        overlayWindow.windowLevel = .normal + 1
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
