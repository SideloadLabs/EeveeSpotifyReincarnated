import Orion
import UIKit

struct EeveeGlassLyricsCardGroup: HookGroup {}
struct EeveeGlassLyricsPageGroup: HookGroup {}
struct EeveeGlassRepaintGroup: HookGroup {}

// MARK: - repaint guard

enum EeveeGlassRepaintRoots {
    static weak var lyricsCardRoot: UIView?
    static weak var lyricsPageRoot: UIView?

    static var anySet: Bool { lyricsCardRoot != nil || lyricsPageRoot != nil }
}

class EeveeGlassRepaintHook: ClassHook<CALayer> {
    typealias Group = EeveeGlassRepaintGroup

    func setBackgroundColor(_ backgroundColor: CGColor?) {
        guard let backgroundColor, EeveeGlassRepaintRoots.anySet,
              let view = target.delegate as? UIView, view.layer === target,
              !EeveeViewTree.keepsColor(view),
              EeveeViewTree.isInside(view, EeveeGlassRepaintRoots.lyricsCardRoot)
                  || EeveeViewTree.isInside(view, EeveeGlassRepaintRoots.lyricsPageRoot)
        else {
            orig.setBackgroundColor(backgroundColor)
            return
        }
        orig.setBackgroundColor(nil)
    }
}

// MARK: - lyrics card (under the player)

private let lyricsCardRadius: CGFloat = 16

/// The painted, rounded cell Spotify wraps the card in — that's what gets
/// clipped and glassed, not the card view itself. Found by class rather than
/// by shape since "the wrapper two levels up" isn't a stable enough
/// description on its own.
private func cellAround(_ view: UIView) -> UIView? {
    guard let cellClass = NSClassFromString(EeveeLyricsCardHook.cellTargetName) else { return nil }
    var current: UIView? = view
    while let v = current {
        if v.isKind(of: cellClass) { return v }
        current = v.superview
    }
    return nil
}

class EeveeLyricsCardHook: ClassHook<UIView> {
    typealias Group = EeveeGlassLyricsCardGroup

    // Lyrics_CardElementImpl.CardView
    static let targetName = "_TtC22Lyrics_CardElementImpl8CardView"
    // Element_List.CollectionViewCell — the painted, rounded wrapper this
    // card sits in inside the player's scroll list.
    static let cellTargetName = "_TtC12Element_List18CollectionViewCell"

    func layoutSubviews() {
        orig.layoutSubviews()
        guard EeveeGlass.isEnabled else { return }

        // A card collapsed by some other declutter feature reports no
        // height; leave it alone rather than glassing a sliver.
        guard let cell = cellAround(target), cell.bounds.height >= 40 else { return }

        EeveeGlassRepaintRoots.lyricsCardRoot = cell
        EeveeViewTree.stripBackgrounds(cell)

        let glass = EeveeGlass.pane(for: cell)
        glass.frame = cell.bounds
        glass.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        EeveeGlass.shape(glass, radius: lyricsCardRadius, capsule: false)
    }
}

// MARK: - full-screen lyrics page

/// Clears every view from `view` up to (but not including) the presenting
/// transition context — the template views Spotify's presentation chain
/// paints opaque once, at setup, on the way to putting this page on screen.
/// Only that chain is touched, never the page's own subtree; the rest of the
/// page is left exactly as Spotify built it.
@discardableResult
private func clearAncestors(_ view: UIView) -> UIView {
    var top = view
    var current: UIView? = view
    while let v = current, !(v is UIWindow), !NSStringFromClass(type(of: v)).hasPrefix("UITransition") {
        v.layer.backgroundColor = nil
        top = v
        current = v.superview
    }
    return top
}

class EeveeLyricsPageHook: ClassHook<UIView> {
    typealias Group = EeveeGlassLyricsPageGroup

    // Lyrics_FullscreenElementPageImpl.FullscreenView
    static let targetName = "_TtC32Lyrics_FullscreenElementPageImpl14FullscreenView"

    /// A colour set here gets reapplied whenever UIKit feels like it, so
    /// rather than clear it after the fact this refuses it outright at the
    /// setter — the same approach EeveeGlassRepaintHook takes globally,
    /// applied at the source for this specific view.
    func setBackgroundColor(_ backgroundColor: UIColor?) {
        orig.setBackgroundColor(EeveeGlass.isEnabled ? nil : backgroundColor)
    }

    func layoutSubviews() {
        orig.layoutSubviews()
        guard EeveeGlass.isEnabled, target.bounds.height >= 200 else { return }

        target.layer.backgroundColor = nil
        EeveeGlassRepaintRoots.lyricsPageRoot = clearAncestors(target)

        let glass = EeveeGlass.pane(for: target)
        glass.frame = target.bounds
        glass.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // Full bleed: a fresh pane makes no promises about corner radius, so
        // this has to say explicitly that it wants square ones.
        EeveeGlass.shape(glass, radius: 0, capsule: false)
    }
}

// MARK: - activation

func activateEeveeLyricsGlass() {
    guard EeveeGlass.isEnabled else { return }

    let cardExists = NSClassFromString(EeveeLyricsCardHook.targetName) != nil
        && NSClassFromString(EeveeLyricsCardHook.cellTargetName) != nil
    let pageExists = NSClassFromString(EeveeLyricsPageHook.targetName) != nil

    writeDebugLog("""
        [GlassLyrics] card=\(cardExists ? "Y" : "N") page=\(pageExists ? "Y" : "N")
        """)

    // The repaint guard costs nothing while neither root is set, so it's
    // always safe to activate — CALayer itself is never going to be
    // missing the way a Spotify-internal class name can be.
    EeveeGlassRepaintGroup().activate()

    if cardExists { EeveeGlassLyricsCardGroup().activate() }
    if pageExists { EeveeGlassLyricsPageGroup().activate() }
}
