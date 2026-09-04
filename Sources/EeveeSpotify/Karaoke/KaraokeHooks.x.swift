import Foundation
import Orion
import UIKit

private var karaokeObserverRegistered = false
private let karaokeObserver = EeveeKaraokeObserver()

@objc final class EeveeKaraokeObserver: NSObject {
    @objc func player(_ player: AnyObject, stateDidChange newState: AnyObject) {
        KaraokePlaybackTracker.shared.processStateChange(state: newState)
        DispatchQueue.main.async {
            KaraokeGestureTrigger.shared.attachIfNeeded()
        }
    }

    @objc func player(_ player: AnyObject, stateDidChange newState: AnyObject, fromState oldState: AnyObject) {
        KaraokePlaybackTracker.shared.processStateChange(state: newState)
        DispatchQueue.main.async {
            KaraokeGestureTrigger.shared.attachIfNeeded()
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

    // "SPTPlayerServiceImplementation" alone stopped resolving as of the
    // 9.1.78 IPA I was given to inspect — `NSClassFromString` on that bare
    // name returned nil, which meant this hook silently never attached, the
    // karaoke observer never registered, KaraokePlaybackTracker's
    // currentTrackId() stayed nil forever, and the Word-Synced button never
    // showed even with syllable lyrics confirmed fetched and stored (its own
    // "hasData" gate depends on that trackId). Binary inspection turned up
    // the class still present, just now apparently exported under Swift's
    // older mangled ObjC name instead of the plain one — the same situation
    // this codebase already has a precedent for elsewhere (see
    // "_TtC21Settings_PlatformImpl26SettingsListViewController" in
    // Tweak.x.swift, a different class hitting the same kind of rename).
    // Trying the legacy name first preserves whatever older Spotify version
    // this originally targeted; falling back to the mangled one is what
    // should recover it on 9.1.78. If NEITHER resolves on some future
    // version, this returns the legacy name as the last resort — same
    // silent-no-op outcome as before, not a new failure mode.
    static var targetName: String {
        if NSClassFromString("SPTPlayerServiceImplementation") != nil {
            return "SPTPlayerServiceImplementation"
        }
        if NSClassFromString("_TtC17Player_CommonImpl30SPTPlayerServiceImplementation") != nil {
            return "_TtC17Player_CommonImpl30SPTPlayerServiceImplementation"
        }
        return "SPTPlayerServiceImplementation"
    }

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
    // Mirrors the same two-name fallback as KaraokePlayerServiceObserverHook
    // above — this is only the startup diagnostic log, but it should report
    // the same "found" outcome as whichever name the hook itself resolves,
    // or the log becomes actively misleading (saying "missing" right above
    // a hook that then attaches fine).
    let legacyName = "SPTPlayerServiceImplementation"
    let mangledName = "_TtC17Player_CommonImpl30SPTPlayerServiceImplementation"
    let resolvedName: String? = NSClassFromString(legacyName) != nil ? legacyName
        : (NSClassFromString(mangledName) != nil ? mangledName : nil)
    writeDebugLog("[Karaoke] activate: class=\(resolvedName ?? "<missing>")")
    KaraokeGroup().activate()
    writeDebugLog("[Karaoke] hook group activated")

    // Just referencing .shared is enough to trigger KaraokeButtonOverlay's
    // lazy init, which kicks off its own Now-Playing-visibility polling
    // timer — there's no other natural one-time startup hook for it here.
    if #available(iOS 15.0, *) {
        _ = KaraokeButtonOverlay.shared
    }
}
