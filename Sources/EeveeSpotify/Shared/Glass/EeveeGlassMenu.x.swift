import Orion
import UIKit

struct EeveeGlassMenuGroup: HookGroup {}

private let menuCornerRadius: CGFloat = 20

class EeveeContextMenuHook: ClassHook<UIViewController> {
    typealias Group = EeveeGlassMenuGroup

    // ContextMenu_InternalImpl.ContextMenuViewController — confirmed
    // present in ___Spotify_v9_1_84-AppAssassin.ipa's main binary strings
    // before being wired up here.
    static let targetName = "_TtC24ContextMenu_InternalImpl25ContextMenuViewController"

    func viewDidLayoutSubviews() {
        orig.viewDidLayoutSubviews()
        guard EeveeGlass.isEnabled, let view = target.viewIfLoaded, view.bounds.height >= 60 else { return }

        view.layer.backgroundColor = nil
        EeveeViewTree.stripBackgrounds(view)
        // No EeveeGlassRepaintRoots entry for this one: unlike the lyrics
        // card/page and the queue, a menu doesn't sit on screen long enough
        // for Spotify's out-of-band album-colour repaint to matter — it's
        // opened, used, and dismissed before that would ever fire.
        clearAncestors(view)

        let glass = EeveeGlass.pane(for: view)
        glass.frame = view.bounds
        glass.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        EeveeGlass.shape(glass, radius: menuCornerRadius, capsule: false)
    }
}

func activateEeveeMenuGlass() {
    guard EeveeGlass.isEnabled else { return }

    let exists = NSClassFromString(EeveeContextMenuHook.targetName) != nil
    writeDebugLog("[GlassMenu] classFound=\(exists ? "Y" : "N")")

    guard exists else { return }
    EeveeGlassMenuGroup().activate()
}
