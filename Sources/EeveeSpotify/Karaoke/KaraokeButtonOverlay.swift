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
    // The frame computed in ensureWindowExists — the button's true "resting"
    // position for the current screen/idiom. Recorded once at creation and
    // never touched by applyScrollOffset, specifically so trackScrolling can
    // reset to it below.
    private var restFrame: CGRect?
    private var pollTimer: Timer?
    private weak var buttonController: KaraokeButtonViewController?

    /// While a finger is on the button, the window must not move or hide:
    /// the scroll-follow logic used to reposition it under the finger
    /// (and re-found the scroll view every 0.15s, resetting the frame),
    /// which cancelled the touch — the "tap it ten times" bug.
    private var isTouchingButton: Bool { buttonController?.button.isTracking ?? false }

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
        // Was 0.5s; a noticeable delay was reported between minimizing Now
        // Playing on iPhone and the button actually disappearing. This walk
        // is a bounded, shallow view-controller/view-hierarchy traversal —
        // cheap enough to afford running well more often than that — so
        // this trades a bit more CPU time for a much shorter worst-case
        // delay on any of this class's poll-driven visibility changes, not
        // just the iPhone-minimize one specifically.
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
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
    /// Force-hides the button immediately (rather than waiting up to one
    /// poll tick — see startPolling for the current interval) as soon as Spotify's native Lyrics
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

    // Only logs on an actual change of the summarized state (not every poll
    // tick) — this is a 0.15s timer, logging unconditionally would flood the
    // debug log. Format: found class name (or "none"), then each gate as
    // visible/minimized/data/presented → shouldShow.
    private var lastLoggedDiagnostic: String?

    private func refresh() {
        if isTouchingButton { return }
        let liveVC = !isOnNativeLyricsScreen ? KaraokeButtonOverlay.findLiveNowPlayingScrollViewController() : nil
        let isNowPlayingScreenVisible = !isOnNativeLyricsScreen && KaraokeButtonOverlay.isNowPlayingScreenCurrentlyVisible(liveVC: liveVC)
        let isMinimized = KaraokeButtonOverlay.isNowPlayingScreenMinimized(liveVC: liveVC)
        let hasKaraokeData = KaraokeOverlayPresenter.isAvailableForCurrentTrack()
        // Catches Spotify's own in-app overlays presented on top of Now
        // Playing — the custom share sheet (the WhatsApp/Instagram-style
        // destination picker) being the reported case, but this isn't
        // specific to that one screen. Those are ordinary presented view
        // controllers within Spotify's own window, and this window's
        // higher windowLevel (see ensureWindowExists) puts it above ALL of
        // Spotify's own window content unconditionally — UIWindow stacking
        // doesn't interleave with another window's internal view
        // z-ordering, so there's no way to sit "under" a specific view
        // within Spotify's own hierarchy. Hiding whenever something's
        // presented above Now Playing is the only way to actually stay out
        // from on top of it.
        let hasOverlayAboveNowPlaying = liveVC.map { KaraokeButtonOverlay.isSomethingPresentedAbove(liveVC: $0) } ?? false
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
            && !KaraokeOverlayPresenter.isPresented && !hasOverlayAboveNowPlaying

        // Diagnostic only — traces every gate that feeds shouldShow, since
        // this has been the recurring point of breakage (wrong class names,
        // over-eager minimize detection, etc.) and guessing blind at the
        // next fix without this has cost a few rounds already. Search the
        // debug log for "[KaraokeButton]" — a line is written each time any
        // of these values actually changes, not on every poll tick.
        let foundClassName = liveVC.map { NSStringFromClass(type(of: $0)) } ?? "none"
        // Only run the extra hierarchy sweep when needed — it's diagnostic-
        // only overhead, no reason to pay for it once the real lookup above
        // is already finding the right thing.
        let nearbyClasses = liveVC == nil
            ? KaraokeButtonOverlay.diagnosticNearbyNowPlayingClassNames()
            : []
        let diagnostic = "class=\(foundClassName) nearby=\(nearbyClasses) onLyricsScreen=\(isOnNativeLyricsScreen) " +
            "visible=\(isNowPlayingScreenVisible) minimized=\(isMinimized) " +
            "hasData=\(hasKaraokeData) karaokePresented=\(KaraokeOverlayPresenter.isPresented) " +
            "overlayAbove=\(hasOverlayAboveNowPlaying) shouldShow=\(shouldShow)"
        if diagnostic != lastLoggedDiagnostic {
            writeDebugLog("[KaraokeButton] \(diagnostic)")
            lastLoggedDiagnostic = diagnostic
        }

        if shouldShow {
            ensureWindowExists(liveVC: liveVC)
            refreshGeometryIfNeeded(liveVC: liveVC)
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
    // every 0.15s, matching this class's existing poll cadence).
    private static let liveScrollViewControllerClassNames: Set<String> = [
        "NowPlaying_ScrollImpl.NowPlayingScrollViewController",
        "NowPlaying_ScrollImpl.NPVScrollViewController",
    ]

    // Found via string inspection of the provided 9.1.78 decrypted IPA:
    // NowPlaying_BarPageImpl.CompactNowPlayingViewController, alongside
    // sibling types in the same module — BottomBarTransitionImpl,
    // TouchPassthroughView, NowPlayingReducedUIModel — which reads like the
    // actual mini-player bar's own implementation module, not merely an
    // expand/collapse transition helper (that's the separate, differently-
    // named NowPlayingCompactAnimator/NowPlayingRegularAnimator pair, which
    // by their naming look tied to sheet-style/size-class presentation
    // rather than to the resting collapsed state itself). I couldn't fully
    // confirm this class's superclass from strings alone the way I could
    // confirm the two names above by their selector table — like those,
    // this is walked and checked via plain UIView API (see
    // isNowPlayingScreenMinimized below for exactly what's checked and why
    // window-attachment alone wasn't enough), so a wrong guess here just
    // means it never matches (falls through to the height-ratio check
    // below), not a crash.
    private static let miniPlayerBarClassNames: Set<String> = [
        "NowPlaying_BarPageImpl.CompactNowPlayingViewController",
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
    //
    // This is now the FALLBACK signal, checked only when
    // miniPlayerBarClassNames isn't found on screen (see
    // isNowPlayingScreenMinimized below) — kept in case that class-name
    // lookup doesn't apply on some build/flow, rather than removing the
    // only thing that used to work on iPhone.
    private static let minimizedHeightFraction: CGFloat = 0.4

    private static func isNowPlayingScreenMinimized(liveVC: UIViewController?) -> Bool {
        // Primary signal: Spotify's own mini-player bar view controller is
        // live AND actually visible on screen — not merely attached to a
        // window. This was originally checking `.view.window != nil` alone,
        // which turned out to be wrong: it's very plausible (and matches
        // what broke here) that Spotify keeps this view controller mounted
        // in the hierarchy even while the full Now Playing screen is
        // expanded on top of it — just hidden/covered rather than removed —
        // in which case `.view.window` stays non-nil the entire time and
        // this unconditionally reported "minimized", hiding the button on
        // both iPhone and iPad regardless of actual state. Checking
        // isHidden/alpha and that it has non-trivial visible height on
        // screen (rather than being collapsed to zero height, or covered
        // and therefore never actually laid out with real bounds) is a
        // closer approximation of "is this actually what the user sees
        // right now" — plain UIView/UIViewController API throughout, so
        // still no risk of the unrecognized-selector crash this file
        // avoids elsewhere. Still unverified beyond static inspection,
        // though: if the button now shows even while the mini bar visibly
        // IS on screen, or still doesn't show when it should, tell me which
        // and I can add a rough screen-recording-based check on the actual
        // bar height/position instead of guessing further blind.
        if let bar = findLiveViewController(matching: miniPlayerBarClassNames),
           bar.isViewLoaded,
           let view = bar.view {
            if let window = view.window, !view.isHidden, view.alpha > 0.01 {
                let visibleHeight = view.convert(view.bounds, to: window).height
                if visibleHeight > 1 {
                    return true
                }
            }
        }

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
    /// looking for an instance whose runtime class matches one of the given
    /// names. Shared by findLiveNowPlayingScrollViewController and the
    /// mini-player bar lookup above; only ever used to reach plain
    /// UIViewController/UIView API (`.view.window`) on whatever it finds,
    /// never a Spotify-internal selector, so a class name that doesn't
    /// actually exist or doesn't match what's on screen just means "not
    /// found" here, not a crash.
    private static func findLiveViewController(matching classNames: Set<String>) -> UIViewController? {
        let roots = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .compactMap { $0.rootViewController }

        func walk(_ vc: UIViewController) -> UIViewController? {
            if classNames.contains(NSStringFromClass(type(of: vc))) {
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

    private static func findLiveNowPlayingScrollViewController() -> UIViewController? {
        findLiveViewController(matching: liveScrollViewControllerClassNames)
    }

    /// True if something (a sheet, Spotify's own custom share destination
    /// picker, an alert presented as a view controller, etc.) is currently
    /// presented on top of the Now Playing screen. Walks up liveVC's
    /// `.parent` chain to its outermost ancestor — covering
    /// UINavigationController/UITabBarController/custom container setups,
    /// all of which surface their contents via `.parent` the same way —
    /// then checks THAT ancestor's `.presentedViewController`. Deliberately
    /// `.presentedViewController`, not `.presentingViewController`: the
    /// latter would just describe how Now Playing itself got shown, which
    /// says nothing about anything stacked further on top of it.
    ///
    /// KaraokeOverlayPresenter's own karaoke view doesn't affect this check
    /// — it's a separate UIWindow, not a view-controller presentation, so
    /// it never touches presentedViewController here (already covered
    /// separately by the isPresented check above).
    private static func isSomethingPresentedAbove(liveVC: UIViewController) -> Bool {
        var top = liveVC
        while let parent = top.parent {
            top = parent
        }
        return top.presentedViewController != nil
    }

    /// Diagnostic-only, not used for any actual show/hide decision: walks
    /// the same hierarchy as findLiveViewController but collects every
    /// runtime class name containing "nowplaying" (case-insensitive)
    /// instead of matching a fixed set. Only called from refresh() when the
    /// expected class names above aren't found, specifically so the debug
    /// log can tell apart "wrong class name for this Spotify build" (this
    /// finds real NowPlaying-related classes that aren't in our sets) from
    /// "right class name, but not reachable via this children/presented
    /// walk" (this finds nothing either). Capped at 30 to keep the log
    /// readable if something's deeply nested.
    private static func diagnosticNearbyNowPlayingClassNames() -> [String] {
        let roots = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .compactMap { $0.rootViewController }

        var found: [String] = []
        func walk(_ vc: UIViewController) {
            guard found.count < 30 else { return }
            let name = NSStringFromClass(type(of: vc))
            if name.lowercased().contains("nowplaying") {
                found.append(name)
            }
            if let presented = vc.presentedViewController { walk(presented) }
            for child in vc.children { walk(child) }
        }
        for root in roots { walk(root) }
        return found
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
    // Set by applyScrollOffset once the button's tracked position has
    // scrolled fully out of the visible screen area; cleared again once it
    // scrolls back. refresh() folds this into shouldShow so a poll tick
    // doesn't undo it before the user scrolls back.
    private var isScrolledOffScreen = false

    private func trackScrolling(of liveVC: UIViewController?) {
        guard let liveVC = liveVC else {
            stopTrackingScrolling()
            return
        }

        // Walking the whole Now Playing hierarchy every poll tick was both
        // main-thread cost and a source of frame resets whenever a
        // different scroll view happened to be found first.
        if let tracked = trackedScrollView, tracked.window != nil, tracked.isDescendant(of: liveVC.view) {
            return
        }
        let scrollView = KaraokeButtonOverlay.findFirstScrollView(in: liveVC.view)

        if scrollView !== trackedScrollView {
            stopTrackingScrolling()
            guard let scrollView = scrollView else { return }
            trackedScrollView = scrollView
            // Reset to the canonical rest position before establishing the
            // new anchor pair below. Without this, a fresh tracking session
            // anchored off whatever y the window happened to be sitting at
            // from the END of the previous session (e.g. from having
            // scrolled Now Playing before opening the karaoke view, or
            // before minimizing/backgrounding) — and since Now Playing's
            // own scroll offset often resets to the top by the time you're
            // back (reopening from the mini-player, or returning from the
            // karaoke view), the new baseContentOffsetY captured below could
            // land at 0 while baseWindowY still reflected that old, already
            // -scrolled-up position. That combination pins the button at the
            // wrong height indefinitely, which is what read as the button
            // "rising higher" each time you left and came back rather than
            // returning to where it started.
            if let restFrame = restFrame {
                window?.frame = restFrame
            }
            // Anchored to true content-top (0), not scrollView.contentOffset.y
            // read live at this moment. That was the actual bug behind
            // "button drops into the lyrics area after opening/closing
            // karaoke, then looks right again the next time": if the user
            // wasn't scrolled all the way back to the top of Now Playing
            // exactly when this session (re)started, that non-zero offset
            // got treated as if it WERE the rest position — so scrolling
            // back up afterward moved the button below restFrame rather
            // than back to it, and it only looked "fixed" on some later
            // cycle if the scroll position happened to be back near 0 right
            // when tracking restarted that time. Anchoring to a fixed 0
            // makes "scrolled to the top" always map to restFrame's exact
            // position, regardless of where the scroll offset was sitting
            // at the moment tracking (re)began.
            baseContentOffsetY = 0
            baseWindowY = restFrame?.origin.y
            // Apply the CURRENT real scroll offset right away, rather than
            // leaving the button sitting at raw rest position until the
            // next scroll event happens to fire. Without this, reopening
            // Now Playing (or closing karaoke) while already scrolled down
            // snapped the button to its rest spot and left it there —
            // visually wrong for however long until the user scrolled again
            // — even though the anchor itself (above) was already correct.
            applyScrollOffset(scrollView.contentOffset.y)
            scrollObservation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, change in
                guard let self = self, let newOffset = change.newValue else { return }
                // UIScrollView's contentOffset KVO already fires on the main
                // thread (scrolling is driven by the main run loop), and it
                // fires far more often per visible frame than this window's
                // own screen refresh does. Deferring to a fresh
                // DispatchQueue.main.async block here queued each update a
                // full run-loop turn behind the content it was supposed to
                // track — with updates arriving that rapidly, that lag was
                // enough for the button's position to visibly overshoot and
                // correct itself against the content scrolling underneath
                // it, which is what read as jiggling. Calling straight
                // through keeps it exactly in phase.
                self.applyScrollOffset(newOffset.y)
            }
            // Establishing the anchor above doesn't itself move the window —
            // it only sets up the (baseWindowY, baseContentOffsetY) pair that
            // future contentOffset KVO events get measured against. If the
            // user doesn't scroll again after this session starts (e.g. they
            // just close the karaoke view and leave Now Playing exactly
            // where it already was, already scrolled down), that KVO
            // observer never fires — nothing "changes" from its point of
            // view — and the window would be left sitting at restFrame
            // (from the reset above) even though the actual content is
            // still scrolled down. This one-time explicit call syncs the
            // window to wherever the content *actually* is right now, so a
            // session that starts mid-scroll reflects that immediately
            // rather than only on the next scroll gesture.
            applyScrollOffset(scrollView.contentOffset.y)
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
        guard !isTouchingButton,
              let window = window,
              let baseWindowY = baseWindowY,
              let baseContentOffsetY = baseContentOffsetY else { return }

        // Content scrolling up (offset increasing) should move the button up
        // with it, same direction Spotify's own content moves — hence
        // subtracting the delta rather than adding it.
        let delta = currentOffsetY - baseContentOffsetY
        var newFrame = window.frame
        // Rounded to a whole point: contentOffset itself is sub-pixel, so
        // without rounding, newFrame.origin.y inherits that sub-pixel value
        // on every single update. A UIWindow (unlike an ordinary view inside
        // a scroll view, where the system already snaps this for you) has
        // nothing upstream doing that snapping, so the capsule's border and
        // text were being re-rasterized at a slightly different fractional
        // offset on practically every frame during a scroll — that
        // sub-pixel-to-sub-pixel shimmer is what read as jiggling, distinct
        // from the actual (correct) whole-pixel translation.
        newFrame.origin.y = (baseWindowY - delta).rounded()
        // CATransaction here (rather than relying on window.frame's own
        // setter) explicitly disables implicit layer actions for this
        // change. UIWindow.frame doesn't normally animate on its own, but
        // this write happens from a KVO callback that can fire while
        // UIScrollView's own deceleration/bounce is mid-animation-block on
        // the same run loop turn — leaving this unguarded risked silently
        // inheriting that surrounding transaction's animation curve/duration
        // instead of applying instantly, which would show up as the button
        // easing toward each new position rather than tracking it directly,
        // i.e. more jiggle.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        window.frame = newFrame
        CATransaction.commit()

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
        //
        // The boundary is the safe area, not the literal screen edge — using
        // the near edge of the button against that boundary (origin.y for
        // the top, maxY for the bottom) hides it as soon as it starts
        // crossing in, not only once the whole button has passed through.
        //
        // Uses the same foregroundActive-scene lookup as ensureWindowExists,
        // rather than searching for `isKeyWindow` — on iPad's multi-pane/
        // multi-window layouts (like Split View) `isKeyWindow` can fail to
        // match the window actually on screen, silently defaulting
        // safeAreaTop to 0 and making the button need to reach the literal
        // physical edge (i.e., look like it required *full* entry into the
        // status bar) rather than the safe-area boundary just inside it.
        let scene = window.windowScene ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })
        let referenceWindow = scene?.windows.first(where: { $0 !== window }) ?? scene?.windows.first
        let safeAreaTop = referenceWindow?.safeAreaInsets.top ?? 20
        let safeAreaBottom = referenceWindow?.safeAreaInsets.bottom ?? 20
        // coordinateSpace.bounds, not screen.bounds — newFrame itself is
        // computed relative to the scene's own coordinate space (see
        // idealFrame), so comparing it against the full physical screen
        // height here instead would silently break this check in iPad
        // Split View/Slide Over, where the scene's actual height is smaller
        // than the device screen: newFrame's range would almost never reach
        // anywhere near a full-screen-sized threshold.
        let screenHeight = scene?.coordinateSpace.bounds.height ?? UIScreen.main.bounds.height
        let isOffScreen = newFrame.origin.y <= safeAreaTop || newFrame.maxY >= screenHeight - safeAreaBottom
        isScrolledOffScreen = isOffScreen
        window.isHidden = isOffScreen
    }

    /// Walks `.subviews` (breadth-first) looking for a UIScrollView
    /// (UICollectionView included, since it's a UIScrollView subclass) that
    /// fills most of `root`'s own height — i.e. the page's main content
    /// scroll view, not a nested horizontal carousel row (also a
    /// UIScrollView) that happens to sit closer to the root in the view
    /// tree at the moment of this call. Falls back to the first ScrollView
    /// found at all if nothing meets that bar, so this never returns "no
    /// match" in a case the old plain-first-found version would have
    /// matched.
    ///
    /// Added after a report of the button vanishing and only reappearing
    /// after a long delay during fast up/down scrolling. My working theory:
    /// scrolling fast enough churns cell reuse enough that this walk could
    /// occasionally land on a nested carousel's small scroll view instead of
    /// the main one at the instant it ran, latching scroll-tracking onto
    /// something whose offset changes don't correspond to the actual
    /// content moving underneath the button. I can't fully confirm that
    /// mechanism from static inspection alone — if the button still
    /// misbehaves the same way after this, that theory was wrong and I'll
    /// need a screen recording of it happening to dig further. Pure
    /// type-checking either way, no selector calls — see the crash-safety
    /// note above trackScrolling.
    private static func findFirstScrollView(in root: UIView) -> UIScrollView? {
        var queue: [UIView] = [root]
        var firstFound: UIScrollView?
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if let scrollView = view as? UIScrollView {
                if firstFound == nil { firstFound = scrollView }
                if root.bounds.height > 0, scrollView.bounds.height >= root.bounds.height * 0.6 {
                    return scrollView
                }
            }
            queue.append(contentsOf: view.subviews)
        }
        return firstFound
    }

    /// Computes the button window's ideal (rest) frame for the scene's
    /// CURRENT bounds. Split out from ensureWindowExists so it can also be
    /// re-run later, on bounds changes, not just once at creation.
    private func idealFrame(in scene: UIWindowScene) -> CGRect {
        // scene.coordinateSpace.bounds, NOT scene.screen.bounds. The latter
        // is the full physical device screen and stays that size regardless
        // of what's actually going on — in iPad Split View or Slide Over,
        // Spotify's own window only occupies part of the screen, but
        // scene.screen.bounds doesn't reflect that at all. Computing this
        // window's geometry against the full screen while Spotify's real
        // window is smaller/shifted is exactly why the button could end up
        // floating disconnected from Spotify's own content — visually
        // "over everything," including whatever app now occupies the rest
        // of the screen — and why it wouldn't budge when Now Playing itself
        // got pushed aside: coordinateSpace.bounds is scene-relative and
        // updates with the scene's actual current size, screen.bounds never
        // does.
        let screenBounds = scene.coordinateSpace.bounds
        let safeAreaBottom = scene.windows
            .first(where: { $0.isKeyWindow })?.safeAreaInsets.bottom ?? 34

        let isPhone = UIDevice.current.userInterfaceIdiom == .phone
        // Generous-but-tight size for the single button — wide enough for
        // longer translated copy once other languages get this key
        // translated, tall enough that the button's own tap target
        // (including its padding) is never clipped by the window edge.
        //
        // Smaller on iPad: the button's own content (see
        // KaraokeButtonOverlayView below) is sized down a step there too —
        // this just shrinks the window to match, so there isn't dead
        // tappable space left around a now-smaller button.
        let areaWidth: CGFloat = isPhone ? 180 : 152
        let areaHeight: CGFloat = isPhone ? 44 : 46
        // Lower on iPhone specifically — iPhone's Now Playing layout puts
        // the action row closer to the bottom of the screen than iPad's
        // does (iPad has more vertical space above the mini-player/controls
        // area), so the same inset that looked right on iPad sat too high
        // on iPhone. This is still a fixed guess, not a true anchor — see
        // the comment below on why I couldn't verify the real button's
        // frame — so let me know if it needs further adjustment.
        let bottomInset: CGFloat = isPhone ? 24 : 100
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
        //
        // iPhone only: centered horizontally instead of trailing-aligned,
        // and sat lower (smaller bottomInset) than iPad — see the matching
        // idiom check in KaraokeButtonOverlayView's alignment below.
        let originX = isPhone
            ? (screenBounds.width - areaWidth) / 2
            : screenBounds.width - areaWidth - trailingInset
        return CGRect(
            x: originX,
            y: screenBounds.height - safeAreaBottom - bottomInset - areaHeight,
            width: areaWidth,
            height: areaHeight
        )
    }

    // Last scene coordinateSpace.bounds size this window's geometry was
    // computed against — checked each poll tick (see refreshGeometryIfNeeded)
    // so entering/exiting Split View or Slide Over *after* the button
    // already exists still gets picked up, not just its state at creation.
    private var lastSceneBoundsSize: CGSize?

    /// Re-run from refresh() every poll tick, cheap CGRect/CGSize math only.
    /// Recomputes and reapplies geometry when the scene's actual bounds
    /// changed since last time — the multitasking-layout counterpart to
    /// ensureWindowExists only ever running its computation once.
    private func refreshGeometryIfNeeded(liveVC: UIViewController?) {
        // If Spotify's own Now Playing screen is now hosted in a different
        // scene than the one this window was created in, there's no way to
        // move an existing UIWindow to a different UIWindowScene — the only
        // correct fix is to tear this one down and let the next poll tick's
        // ensureWindowExists recreate it properly attached. This is the
        // recovery path for the case resolvedScene's fallback guess below
        // ever gets it wrong at creation time (e.g. liveVC's own window
        // wasn't available yet that first tick) — on iPad Split View,
        // where more than one app's scene can be simultaneously
        // .foregroundActive, guessing "the first one" could otherwise mean
        // this window stays attached to a completely unrelated app's scene
        // indefinitely.
        if let window = window, let liveScene = liveVC?.view.window?.windowScene, window.windowScene !== liveScene {
            self.window = nil
            self.restFrame = nil
            self.lastSceneBoundsSize = nil
            stopTrackingScrolling()
            return
        }

        guard let window = window, let scene = window.windowScene else { return }
        let currentSize = scene.coordinateSpace.bounds.size
        guard currentSize != lastSceneBoundsSize else { return }
        lastSceneBoundsSize = currentSize

        let newFrame = idealFrame(in: scene)
        restFrame = newFrame
        // Only snap the window itself to the new rest frame when there's no
        // active scroll-tracking session moving it around right now — the
        // next trackScrolling "new session" reset (or the immediate
        // applyScrollOffset call added alongside it) will pick up the
        // updated restFrame naturally. Forcing it here too, mid-session,
        // would fight whatever position scrolling had already placed it at.
        if trackedScrollView == nil {
            window.frame = newFrame
        }
    }

    /// Prefers the scene actually hosting Spotify's own Now Playing screen
    /// over a blind "any foreground-active scene" guess. On iPad, Split View
    /// runs each app in its own separate UIWindowScene, and BOTH can
    /// simultaneously report .foregroundActive — guessing "the first one"
    /// risked attaching this overlay to a completely unrelated app's scene,
    /// which is what was behind the button floating disconnected from
    /// Spotify's own content and not reacting when Now Playing itself got
    /// resized/repositioned within Split View. Falls back to the old guess
    /// only when liveVC isn't attached to a window yet (shouldn't normally
    /// happen — this is only called once shouldShow is already true, which
    /// implies liveVC is on screen — but kept as a safety net rather than
    /// simply failing to create a window at all in that edge case).
    private static func resolvedScene(liveVC: UIViewController?) -> UIWindowScene? {
        if let scene = liveVC?.view.window?.windowScene {
            return scene
        }
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })
    }

    private func ensureWindowExists(liveVC: UIViewController?) {
        guard window == nil else { return }
        guard let scene = KaraokeButtonOverlay.resolvedScene(liveVC: liveVC) else { return }

        let frame = idealFrame(in: scene)
        lastSceneBoundsSize = scene.coordinateSpace.bounds.size

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

        let controller = KaraokeButtonViewController()
        overlayWindow.rootViewController = controller
        buttonController = controller

        window = overlayWindow
        restFrame = frame
    }
}

/// The launcher button. Plain UIKit rather than a SwiftUI Button in a
/// hosting controller: the whole overlay window is one UIButton, so any
/// touch landing in the window counts, and UIButton's touch-up tracking
/// tolerates the finger drifting while pressed.
private final class KaraokeButtonViewController: UIViewController {
    let button = UIButton(type: .custom)
    private let capsule = CapsuleView()
    private let label = UILabel()
    private let icon = UIImageView()

    private var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        button.frame = view.bounds
        button.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        button.addTarget(self, action: #selector(tapped), for: .touchUpInside)
        button.addTarget(self, action: #selector(pressed), for: [.touchDown, .touchDragEnter])
        button.addTarget(self, action: #selector(released), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        view.addSubview(button)

        let fontSize: CGFloat = isPhone ? 13 : 11
        icon.image = UIImage(systemName: "text.bubble.fill")
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: fontSize, weight: .semibold)
        icon.tintColor = .white
        label.text = "karaoke_word_synced_button".localized
        label.font = .systemFont(ofSize: fontSize, weight: .semibold)
        label.textColor = .white

        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.spacing = 6
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false

        capsule.isUserInteractionEnabled = false
        capsule.backgroundColor = UIColor.white.withAlphaComponent(0.18)
        capsule.layer.borderColor = UIColor.white.withAlphaComponent(0.25).cgColor
        capsule.layer.borderWidth = 1
        capsule.layer.shadowColor = UIColor.black.cgColor
        capsule.layer.shadowOpacity = 0.3
        capsule.layer.shadowRadius = 8
        capsule.layer.shadowOffset = CGSize(width: 0, height: 2)
        capsule.translatesAutoresizingMaskIntoConstraints = false
        capsule.addSubview(stack)
        button.addSubview(capsule)

        let horizontal: CGFloat = isPhone ? 14 : 11
        let vertical: CGFloat = isPhone ? 10 : 8
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: capsule.leadingAnchor, constant: horizontal),
            stack.trailingAnchor.constraint(equalTo: capsule.trailingAnchor, constant: -horizontal),
            stack.topAnchor.constraint(equalTo: capsule.topAnchor, constant: vertical),
            stack.bottomAnchor.constraint(equalTo: capsule.bottomAnchor, constant: -vertical),
            capsule.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            isPhone
                ? capsule.centerXAnchor.constraint(equalTo: button.centerXAnchor)
                : capsule.trailingAnchor.constraint(equalTo: button.trailingAnchor),
        ])
    }

    @objc private func tapped() {
        KaraokeOverlayPresenter.present()
    }

    @objc private func pressed() {
        UIView.animate(withDuration: 0.1) { self.capsule.alpha = 0.6 }
    }

    @objc private func released() {
        UIView.animate(withDuration: 0.15) { self.capsule.alpha = 1 }
    }
}

/// Rounds itself from its own layout pass — the view controller's
/// viewDidLayoutSubviews ran before the button laid the capsule out, so
/// the radius was computed from a zero height (a plain rectangle).
private final class CapsuleView: UIView {
    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }
}
