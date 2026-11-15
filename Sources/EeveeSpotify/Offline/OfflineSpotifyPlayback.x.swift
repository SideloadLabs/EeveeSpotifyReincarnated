import Foundation
import ObjectiveC.runtime
import Orion

enum OfflineSpotifyPlayback {
    static private(set) weak var player: NSObject?
    private static var isPlaying = false
    private static let sessionLock = NSLock()
    private static weak var sessionController: NSObject?
    private static var offlineOwnsVolume = false

    static func setLocalVolumeOwner(_ active: Bool) {
        sessionLock.withLock { offlineOwnsVolume = active }
    }

    private static var usesLocalVolume: Bool { sessionLock.withLock { offlineOwnsVolume } }

    static func installVolumeRouting() {
        let eventSource = "_TtC18Connect_VolumeImpl30SystemVolumeChangedEventSource"
        let presenters = [
            "_TtC20Connect_VolumeUXImpl21VolumeUXPresenterImpl",
            "_TtC20Connect_VolumeUXImpl28SmartControlVolumeController",
            "_TtC20Connect_VolumeUXImpl27RemoteVolumePopupController"
        ]
        for name in [eventSource] + presenters {
            guard let type = NSClassFromString(name) else { continue }
            let selectors = name == eventSource ? ["systemVolumeChangedTo:"] : [
                "systemVolumeChangedTo:", "connectVolumeDidChangeToValue:", "remoteMediaSessionVolumeDidChangeToValue:"
            ]
            for name in selectors {
                let selector = NSSelectorFromString(name)
                guard let method = volumeMethod(type, selector, encoding: "v24@0:8d16") else { continue }
                typealias Callback = @convention(c) (AnyObject, Selector, Double) -> Void
                let original = unsafeBitCast(method_getImplementation(method), to: Callback.self)
                let block: @convention(block) (AnyObject, Double) -> Void = { observer, volume in
                    if !usesLocalVolume { original(observer, selector, volume) }
                }
                method_setImplementation(method, imp_implementationWithBlock(block))
            }
            if name != eventSource {
                let selector = NSSelectorFromString("groupedDeviceVolumeDidChangeToValue:groupDeviceIdentifier:")
                guard let method = volumeMethod(type, selector, encoding: "v32@0:8d16@24") else { continue }
                typealias Callback = @convention(c) (AnyObject, Selector, Double, AnyObject?) -> Void
                let original = unsafeBitCast(method_getImplementation(method), to: Callback.self)
                let block: @convention(block) (AnyObject, Double, AnyObject?) -> Void = { observer, volume, device in
                    if !usesLocalVolume { original(observer, selector, volume, device) }
                }
                method_setImplementation(method, imp_implementationWithBlock(block))
            }
        }
        let selector = NSSelectorFromString("systemVolumeChangedTo:source:isOperatingSystemChange:")
        guard let type = NSClassFromString(eventSource),
              let method = volumeMethod(type, selector, encoding: "v36@0:8d16@24B32") else { return }
        typealias Callback = @convention(c) (AnyObject, Selector, Double, AnyObject?, Bool) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Callback.self)
        let block: @convention(block) (AnyObject, Double, AnyObject?, Bool) -> Void = { observer, volume, source, system in
            if !usesLocalVolume { original(observer, selector, volume, source, system) }
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    private static func volumeMethod(_ type: AnyClass, _ selector: Selector, encoding: String) -> Method? {
        guard let method = class_getInstanceMethod(type, selector), let signature = method_getTypeEncoding(method),
              String(cString: signature) == encoding else { return nil }
        return method
    }

    static func rememberSessionController(_ controller: NSObject?) {
        sessionLock.withLock { sessionController = controller }
    }

    static func acquireAudioSession() -> NSObject? {
        let selector = NSSelectorFromString("activateAudioSessionForComponent:")
        guard let controller = sessionLock.withLock({ sessionController }),
              let method = class_getInstanceMethod(type(of: controller), selector),
              method_getNumberOfArguments(method) == 3,
              let argument = method_copyArgumentType(method, 2) else { return nil }
        let returnType = method_copyReturnType(method)
        defer { free(returnType); free(argument) }
        guard returnType.pointee == 64, argument.pointee == 64 else { return nil }
        return controller.perform(selector, with: "EeveeOfflinePlayback" as NSString)?.takeUnretainedValue() as? NSObject
    }

    static func releaseAudioSession(_ lease: NSObject) {
        let selector = NSSelectorFromString("deactivate")
        guard let method = class_getInstanceMethod(type(of: lease), selector),
              method_getNumberOfArguments(method) == 2 else { return }
        let result = method_copyReturnType(method)
        defer { free(result) }
        guard result.pointee == 118 else { return }
        typealias Action = @convention(c) (NSObject, Selector) -> Void
        unsafeBitCast(method_getImplementation(method), to: Action.self)(lease, selector)
    }

    static func pause(_ player: NSObject) -> Bool {
        if readBool(player, NSSelectorFromString("isPaused")) == true { return true }
        let selector = NSSelectorFromString("setIsPaused:")
        guard let method = class_getInstanceMethod(type(of: player), selector),
              method_getNumberOfArguments(method) == 3,
              let argument = method_copyArgumentType(method, 2) else { return false }
        let result = method_copyReturnType(method)
        defer { free(argument); free(result) }
        guard result.pointee == 118, argument.pointee == 66 || argument.pointee == 99 else { return false }
        typealias Setter = @convention(c) (NSObject, Selector, ObjCBool) -> Void
        unsafeBitCast(method_getImplementation(method), to: Setter.self)(player, selector, true)
        return true
    }

    private static func readBool(_ object: NSObject, _ selector: Selector) -> Bool? {
        guard let method = class_getInstanceMethod(type(of: object), selector),
              method_getNumberOfArguments(method) == 2 else { return nil }
        let encoding = method_copyReturnType(method)
        defer { free(encoding) }
        guard encoding.pointee == 66 || encoding.pointee == 99 else { return nil }
        typealias Getter = @convention(c) (NSObject, Selector) -> ObjCBool
        return unsafeBitCast(method_getImplementation(method), to: Getter.self)(object, selector).boolValue
    }

    static func stateChanged(player: NSObject, state: NSObject) {
        let paused = readBool(state, NSSelectorFromString("isPaused"))
        let playing = readBool(state, NSSelectorFromString("isPlaying")) == true && paused == false
        let update = {
            let wasPlaying = Self.player === player && Self.isPlaying
            Self.player = player
            Self.isPlaying = playing || (wasPlaying && paused != true)
            if playing && !wasPlaying { OfflinePlaybackController.shared.spotifyDidStartPlaying() }
        }
        if Thread.isMainThread { update() }
        else { DispatchQueue.main.async(execute: update) }
    }
}

class OfflineStatefulPlayerHook: ClassHook<NSObject> {
    typealias Group = OfflineHookGroup
    static let targetName = "_TtC23NowPlaying_PlatformImpl28StatefulPlayerImplementation"

    func player(_ player: NSObject, stateDidChange state: NSObject) {
        orig.player(player, stateDidChange: state)
        OfflineSpotifyPlayback.stateChanged(player: target, state: state)
    }
}

class OfflineAudioSessionControllerHook: ClassHook<NSObject> {
    typealias Group = OfflineHookGroup
    static let targetName = "SPTAudioSessionControllerImpl"

    func player(_ player: NSObject, stateDidChange state: NSObject) {
        OfflineSpotifyPlayback.rememberSessionController(target)
        orig.player(player, stateDidChange: state)
    }
}
