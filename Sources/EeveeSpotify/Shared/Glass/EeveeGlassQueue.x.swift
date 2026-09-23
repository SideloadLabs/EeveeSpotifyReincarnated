import Orion
import UIKit

struct EeveeGlassQueueGroup: HookGroup {}

class EeveeQueueHook: ClassHook<UIViewController> {
    typealias Group = EeveeGlassQueueGroup

    // Queue_ViewImpl.QueueViewController — confirmed present in
    // ___Spotify_v9_1_84-AppAssassin.ipa's main binary strings before being
    // wired up here.
    static let targetName = "_TtC14Queue_ViewImpl19QueueViewController"

    func viewDidLayoutSubviews() {
        orig.viewDidLayoutSubviews()
        guard EeveeGlass.isEnabled, let view = target.viewIfLoaded, view.bounds.height >= 200 else { return }

        view.layer.backgroundColor = nil
        EeveeGlassRepaintRoots.queueRoot = clearAncestors(view)

        let glass = EeveeGlass.pane(for: view)
        glass.frame = view.bounds
        glass.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // Full bleed: a fresh pane makes no promises about corner radius, so
        // this has to say explicitly that it wants square ones.
        EeveeGlass.shape(glass, radius: 0, capsule: false)
    }
}

func activateEeveeQueueGlass() {
    guard EeveeGlass.isEnabled else { return }

    let exists = NSClassFromString(EeveeQueueHook.targetName) != nil
    writeDebugLog("[GlassQueue] classFound=\(exists ? "Y" : "N")")

    guard exists else { return }
    EeveeGlassQueueGroup().activate()
}
