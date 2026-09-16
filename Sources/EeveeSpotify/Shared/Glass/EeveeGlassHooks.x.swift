import Orion
import UIKit

struct EeveeGlassSearchFieldGroup: HookGroup {}
struct EeveeGlassNowPlayingGroup: HookGroup {}

// MARK: - search field

/// Spotify's search bar is an Encore tertiary button painted white, shared
/// app-wide as a class — so the instance is identified by its accessibility
/// identifier, falling back to "wide, short, and painted light" for a build
/// that stops setting it.
private let searchFieldIdentifier = "SearchHeaderFind.SearchBar"

private var styledFields = NSHashTable<UIView>.weakObjects()

private func isSearchField(_ button: UIView) -> Bool {
    if button.accessibilityIdentifier == searchFieldIdentifier { return true }
    return EeveeViewTree.isLightColor(button.layer.backgroundColor)
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
    guard size.width >= 200, size.height >= 40, size.height <= 60 else { return }

    // Once a field has been styled it keeps being styled, even on a pass where
    // Spotify has already repainted it dark and isSearchField would now say no.
    let alreadyStyled = styledFields.contains(button)
    guard alreadyStyled || isSearchField(button) else { return }
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

/// The bar's coloured card — the view Spotify tints with the album colour.
/// Found by shape and paint rather than by class, since the class name moves
/// between Spotify versions.
private func detectColoredCard(in bar: UIView) -> UIView? {
    var best: UIView?
    EeveeViewTree.forEachView(bar) { v in
        guard best == nil else { return }
        let color = v.layer.backgroundColor
        guard EeveeViewTree.looksLikeCard(v, color: color),
              !EeveeViewTree.isBaseSurface(color)
        else { return }
        best = v
    }
    return best
}

private func styleNowPlayingBar(_ container: UIViewController) {
    guard EeveeGlass.isEnabled else { return }

    let barVC = container.children.first
    let bar = barVC?.viewIfLoaded ?? container.view
    guard let bar, let host = container.viewIfLoaded else { return }

    let card = detectColoredCard(in: bar)

    host.layer.backgroundColor = nil
    EeveeViewTree.stripBackgrounds(bar)

    var frame = card.map { EeveeViewTree.frame(of: $0, in: host) } ?? bar.bounds
    frame.size.height = min(frame.size.height, 80)
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
    typealias Group = EeveeGlassNowPlayingGroup

    static let targetName = "SPTNowPlayingBarContainerViewController"

    func viewDidLayoutSubviews() {
        orig.viewDidLayoutSubviews()
        styleNowPlayingBar(target)
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
    let nowPlayingBarExists = NSClassFromString(EeveeNowPlayingBarHook.targetName) != nil

    writeDebugLog("""
        [Glass] UIGlassEffect=\(EeveeGlass.isAvailable ? "Y" : "N") \
        searchField=\(searchFieldExists ? "Y" : "N") \
        nowPlayingBar=\(nowPlayingBarExists ? "Y" : "N")
        """)

    if searchFieldExists { EeveeGlassSearchFieldGroup().activate() }
    if nowPlayingBarExists { EeveeGlassNowPlayingGroup().activate() }

    if !searchFieldExists && !nowPlayingBarExists {
        writeDebugLog("[Glass] no known target classes in this build — nothing hooked")
    }
}
