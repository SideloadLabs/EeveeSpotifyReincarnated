import Orion
import UIKit

struct EeveeGlassSearchFieldGroup: HookGroup {}
struct EeveeGlassNowPlayingContainerGroup: HookGroup {}
struct EeveeGlassNowPlayingInnerGroup: HookGroup {}

// MARK: - search field

/// Spotify's search bar is an Encore tertiary button painted white, shared
/// app-wide as a class — so the instance is identified by its accessibility
/// identifier, falling back to "wide, short, and painted light" for a build
/// that stops setting it.
private let searchFieldIdentifier = "SearchHeaderFind.SearchBar"

private var styledFields = NSHashTable<UIView>.weakObjects()
private var loggedFields = NSHashTable<UIView>.weakObjects()

private func isSearchField(_ button: UIView) -> Bool {
    if button.accessibilityIdentifier == searchFieldIdentifier { return true }
    return EeveeViewTree.isLightColor(button.layer.backgroundColor)
}

/// Logs the reason a candidate button was or wasn't accepted, once per
/// distinct button instance — not once per layout pass, which would be
/// thousands of near-identical lines within seconds. This is the
/// instrumentation activateEeveeGlass's activation-only log was missing:
/// that log confirmed the hook installed, not that any button ever passed
/// its guards afterward.
private func logSearchFieldCandidate(_ button: UIView, accepted: Bool) {
    guard UserDefaults.debugLoggingEnabled, !loggedFields.contains(button) else { return }
    loggedFields.add(button)
    let size = button.bounds.size
    let bg = button.layer.backgroundColor
    writeDebugLog("""
        [GlassSearch] candidate size=\(Int(size.width))x\(Int(size.height)) \
        identifier=\(button.accessibilityIdentifier ?? "nil") \
        bg=\(bg.map(String.init(describing:)) ?? "nil") \
        isLight=\(EeveeViewTree.isLightColor(bg) ? "Y" : "N") \
        accepted=\(accepted ? "Y" : "N")
        """)
}

/// Encore's glyph view bakes its colour into what it draws, so tintColor
/// never reaches it — setForegroundColor: is the way in. Without this the
/// glyph and placeholder stay black and vanish against the glass.
private func whiten(_ view: UIView) {
    if let label = view as? UILabel {
        label.textColor = .white
    } else if NSStringFromClass(type(of: view)).contains("IconView") {
        let selector = Selector(("setForegroundColor:"))
        if view.responds(to: selector) {
            _ = view.perform(selector, with: UIColor.white)
        } else {
            view.tintColor = .white
        }
    }
}

private func styleSearchField(_ button: UIView) {
    guard EeveeGlass.isEnabled else { return }

    let size = button.bounds.size
    let alreadyStyled = styledFields.contains(button)
    let sizeOK = size.width >= 200 && size.height >= 40 && size.height <= 60
    let accepted = alreadyStyled || (sizeOK && isSearchField(button))
    logSearchFieldCandidate(button, accepted: accepted)
    guard accepted else { return }

    // Once a field has been styled it keeps being styled, even on a pass where
    // Spotify has already repainted it dark and isSearchField would now say no.
    styledFields.add(button)

    button.layer.backgroundColor = nil
    button.layer.cornerRadius = size.height / 2
    button.layer.cornerCurve = .continuous

    let glass = EeveeGlass.pane(for: button, at: 0)
    glass.frame = button.bounds
    EeveeGlass.shape(glass, radius: size.height / 2, capsule: true)

    EeveeViewTree.forEachView(button) { whiten($0) }
}

class EeveeSearchFieldHook: ClassHook<UIView> {
    typealias Group = EeveeGlassSearchFieldGroup

    // Encore's mangled Swift class name for Button.Tertiary.
    static let targetName = "_TtCCE16Encore_ButtonKitO16EncoreFoundation6Encore6Button8Tertiary"

    func layoutSubviews() {
        orig.layoutSubviews()
        styleSearchField(target)
    }

    /// Coming back from the full-screen search, the field is laid out before
    /// the next layout pass lands — without this it renders unstyled for about
    /// a second.
    func didMoveToWindow() {
        orig.didMoveToWindow()
        styleSearchField(target)
    }

    /// Spotify rebuilds the field's content when the page returns, which can
    /// take the pane out with it. Waiting for the next layout pass to put it
    /// back would leave the capsule blank.
    func didAddSubview(_ subview: UIView) {
        orig.didAddSubview(subview)
        if !(subview is UIVisualEffectView) {
            styleSearchField(target)
        }
    }
}

// MARK: - now playing bar

private let nowPlayingCardRadius: CGFloat = 12

private func detectColoredCard(in bar: UIView) -> UIView? {
    var best: UIView?
    var bestArea: CGFloat = 0
    EeveeViewTree.forEachView(bar) { v in
        if v is UIVisualEffectView || EeveeViewTree.keepsColor(v) { return }
        guard EeveeViewTree.looksLikeCard(v, color: v.layer.backgroundColor) else { return }
        let area = v.bounds.width * v.bounds.height
        if area > bestArea {
            bestArea = area
            best = v
        }
    }
    return best
}

private var lastNowPlayingLog: Date?

/// Throttled to once every 3 seconds rather than once per instance —
/// unlike the search field, the same host view stays alive across the
/// whole session while what's found inside it (the card) changes with
/// every track, so a single snapshot per instance would only ever show
/// the very first track played.
private func logNowPlayingBar(bar: UIView, card: UIView?, frame: CGRect, hiddenWashImages: Int) {
    guard UserDefaults.debugLoggingEnabled else { return }
    let now = Date()
    if let last = lastNowPlayingLog, now.timeIntervalSince(last) < 3 { return }
    lastNowPlayingLog = now

    let cardDesc = card.map {
        "size=\(Int($0.bounds.width))x\(Int($0.bounds.height)) bg=\($0.layer.backgroundColor.map(String.init(describing:)) ?? "nil")"
    } ?? "none found"
    writeDebugLog("""
        [GlassBar] bar=\(Int(bar.bounds.width))x\(Int(bar.bounds.height)) \
        card=\(cardDesc) \
        hiddenWashImages=\(hiddenWashImages) \
        finalFrame=\(Int(frame.width))x\(Int(frame.height))
        """)
}

private func styleNowPlayingBar(_ container: UIViewController) {
    guard EeveeGlass.isEnabled else { return }

    let barVC = container.children.first
    let bar = barVC?.viewIfLoaded ?? container.view
    guard let bar, let host = container.viewIfLoaded else { return }

    let card = detectColoredCard(in: bar)

    host.layer.backgroundColor = nil
    let hiddenWashImages = EeveeViewTree.stripBackgrounds(bar)

    var frame = card.map { EeveeViewTree.frame(of: $0, in: host) } ?? bar.bounds
    frame.size.height = min(frame.size.height, 80)
    logNowPlayingBar(bar: bar, card: card, frame: frame, hiddenWashImages: hiddenWashImages)
    guard frame.size.height >= 30, frame.size.width >= 100 else { return }

    let radius = min(nowPlayingCardRadius, frame.size.height / 2)

    if let card {
        card.layer.backgroundColor = nil
        card.layer.cornerRadius = radius
        card.layer.cornerCurve = .continuous
    }

    let glass = EeveeGlass.pane(for: host)
    glass.frame = frame
    EeveeGlass.shape(glass, radius: radius, capsule: false)
}

class EeveeNowPlayingBarHook: ClassHook<UIViewController> {
    typealias Group = EeveeGlassNowPlayingContainerGroup

    static let targetName = "_TtC18NowPlaying_BarImpl36NowPlayingBarContainerViewController"

    func viewDidLayoutSubviews() {
        orig.viewDidLayoutSubviews()
        styleNowPlayingBar(target)
    }
}

class EeveeNowPlayingBarInnerHook: ClassHook<UIViewController> {
    typealias Group = EeveeGlassNowPlayingInnerGroup

    static let targetName = "_TtC18NowPlaying_BarImpl27NowPlayingBarViewController"

    func viewDidLayoutSubviews() {
        orig.viewDidLayoutSubviews()
        if let parent = target.parent,
           NSStringFromClass(type(of: parent)).contains("NowPlayingBarContainer") {
            styleNowPlayingBar(parent)
        }
    }
}

// MARK: - activation

/// Activates only the hooks whose target classes actually exist in this build.
/// Orion treats hooking a missing class as fatal, and Spotify renames these
/// between versions — the same guarding pattern the rest of the tweak uses.
func activateEeveeGlass() {
    guard EeveeGlass.isEnabled else {
        writeDebugLog("[Glass] disabled in settings — not hooking")
        return
    }

    let searchFieldExists = NSClassFromString(EeveeSearchFieldHook.targetName) != nil
    let nowPlayingContainerExists = NSClassFromString(EeveeNowPlayingBarHook.targetName) != nil
    let nowPlayingInnerExists = NSClassFromString(EeveeNowPlayingBarInnerHook.targetName) != nil

    writeDebugLog("""
        [Glass] UIGlassEffect=\(EeveeGlass.isAvailable ? "Y" : "N") \
        searchField=\(searchFieldExists ? "Y" : "N") \
        nowPlayingContainer=\(nowPlayingContainerExists ? "Y" : "N") \
        nowPlayingInner=\(nowPlayingInnerExists ? "Y" : "N")
        """)

    // Each group is one class, one hook, gated on its own existence check —
    // never combined, since Orion treats activating a group whose target
    // class is missing as fatal and the two now-playing-bar classes can in
    // principle drift independently across Spotify versions even though
    // they are closely related today.
    if searchFieldExists { EeveeGlassSearchFieldGroup().activate() }
    if nowPlayingContainerExists { EeveeGlassNowPlayingContainerGroup().activate() }
    if nowPlayingInnerExists { EeveeGlassNowPlayingInnerGroup().activate() }

    if !searchFieldExists && !nowPlayingContainerExists && !nowPlayingInnerExists {
        writeDebugLog("[Glass] no known target classes in this build — nothing hooked")
    }
}
