import Foundation
import Orion
import UIKit

private var karaokeObserverRegistered = false
private let karaokeObserver = EeveeKaraokeObserver()

@objc final class EeveeKaraokeObserver: NSObject {
    @objc func player(_ player: AnyObject, stateDidChange newState: AnyObject) {
        KaraokePlaybackTracker.shared.processStateChange(state: newState)
        DispatchQueue.main.async {
            KaraokeTriggerButton.shared.attachIfNeeded()
        }
    }

    @objc func player(_ player: AnyObject, stateDidChange newState: AnyObject, fromState oldState: AnyObject) {
        KaraokePlaybackTracker.shared.processStateChange(state: newState)
        DispatchQueue.main.async {
            KaraokeTriggerButton.shared.attachIfNeeded()
        }
    }

    @objc func player(_ player: AnyObject, didEncounterError error: AnyObject) {}
    @objc func player(_ player: AnyObject, didMoveToRelativeTrack relativeIndex: Int) {}
    @objc func player(_ player: AnyObject, queueDidChange queue: AnyObject) {}
}

// Separate hook (not reusing SponsorBlock's PlayerServiceObserverHook) so the
// karaoke overlay's playback tracking works independently of whether
// SponsorBlock is enabled/active. addPlayerObserver supports multiple
// observers being registered, so this is additive and doesn't interfere
// with SponsorBlock's own observer registration.
class KaraokePlayerServiceObserverHook: ClassHook<NSObject> {
    typealias Group = KaraokeGroup
    static let targetName = "SPTPlayerServiceImplementation"

    func addPlayerObserver(_ observer: AnyObject) {
        orig.addPlayerObserver(observer)
        if !karaokeObserverRegistered {
            karaokeObserverRegistered = true
            writeDebugLog("[Karaoke] registering playback observer on service")
            orig.addPlayerObserver(karaokeObserver)
        }
    }
}

struct KaraokeGroup: HookGroup {}

func activateKaraokeHooks() {
    let cls = NSClassFromString("SPTPlayerServiceImplementation")
    writeDebugLog("[Karaoke] activate: class=\(cls == nil ? "<missing>" : "<found>")")
    KaraokeGroup().activate()
    writeDebugLog("[Karaoke] hook group activated")
}
