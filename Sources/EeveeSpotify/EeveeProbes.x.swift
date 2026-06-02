import Foundation
import Orion

private func probeEnabled(_ name: String) -> Bool {
    guard let v = getenv(name) else { return false }
    let s = String(cString: v)
    return s == "1" || s.lowercased() == "true" || s.lowercased() == "yes"
}

private let traceNet:   Bool = false
private let traceNotif: Bool = false
// TESTING: dumps ad-class methods/ivars on launch.
private let traceAds:   Bool = false
// TESTING: dumps SPTPlayer* surface + widens notif filter to include
// "player/track/position" so SponsorBlock can find episode-uri/seek path.
private let traceSB:    Bool = false
// TESTING: dumps SmartShuffle / FreeShuffle service classes so we can
// pick real selectors for a TrueShuffle hook on this Spotify version.
private let traceShuffle: Bool = false

private let importantNotifSubstrings: [String] = [
    "premium", "product", "account", "session", "login", "logout",
    "authState", "authSession", "subscription"
]

private let sbNotifSubstrings: [String] = [
    "player", "track", "position", "episode", "playback", "queue"
]

class TaskResumeProbeHook: ClassHook<NSObject> {
    typealias Group = ProbeNetGroup
    static let targetName = "NSURLSessionTask"

    func resume() {
        if traceNet, let task = target as? URLSessionTask,
           let url = task.currentRequest?.url ?? task.originalRequest?.url {
            let host = url.host ?? "?"
            if host.contains("spotify") || host.contains("scdn") || host.contains("spclient")
                || host.contains("googleapis") || host.contains("apresolve") {
                let method = task.currentRequest?.httpMethod ?? "?"
                NSLog("[PROBE][NET] >> %@ %@%@", method, host, url.path)
            }
        }
        orig.resume()
    }
}

class NotifPostHook: ClassHook<NSObject> {
    typealias Group = ProbeNotifGroup
    static let targetName = "NSNotificationCenter"

    // Don't touch notification.object — can be a zombie ref. type(of:) on a
    // dealloc'd NSObject dispatches to __NSGenericDeallocHandler and aborts.
    func postNotification(_ notification: Notification) {
        let name = notification.name.rawValue
        let lower = name.lowercased()
        let important = importantNotifSubstrings.contains { lower.contains($0) }
            || (traceSB && sbNotifSubstrings.contains { lower.contains($0) })
        if traceNotif || important {
            NSLog("[PROBE][NOTIF] %@", name)
        }
        orig.postNotification(notification)
    }

    func postNotificationName(_ aName: NSNotification.Name, object anObject: Any?) {
        let name = aName.rawValue
        let lower = name.lowercased()
        let important = importantNotifSubstrings.contains { lower.contains($0) }
            || (traceSB && sbNotifSubstrings.contains { lower.contains($0) })
        if traceNotif || important {
            NSLog("[PROBE][NOTIF] %@", name)
        }
        orig.postNotificationName(aName, object: anObject)
    }

    func postNotificationName(_ aName: NSNotification.Name, object anObject: Any?, userInfo aUserInfo: [AnyHashable : Any]?) {
        let name = aName.rawValue
        let lower = name.lowercased()
        let important = importantNotifSubstrings.contains { lower.contains($0) }
            || (traceSB && sbNotifSubstrings.contains { lower.contains($0) })
        if traceNotif || important {
            let uiKeys = aUserInfo?.keys.map { "\($0)" }.joined(separator: ",") ?? ""
            NSLog("[PROBE][NOTIF] %@ userInfo=[%@]", name, uiKeys)
        }
        orig.postNotificationName(aName, object: anObject, userInfo: aUserInfo)
    }
}

struct ProbeNetGroup: HookGroup {}
struct ProbeNotifGroup: HookGroup {}

private let classesToDump: [String] = [
    "Authentication_ForcedLogoutImpl.ForcedLogoutDaemon",
    "Authentication_AuthImpl.AccessTokenRevokerDaemon",
    "Authentication_AuthImpl.AccessTokenUpdateTask",
    "Authentication_AuthImpl.AuthTaskV",
    "Authentication_AuthImpl.Login",
    "Authentication_LogoutAPI.LogoutService",
    "Authentication_ReloginAPI.ReloginService",
    "Authentication_AuthAPI.LogoutNotifierService",
    "Authentication_AuthAPI.AuthLoginNotifierService",
    "Connectivity_SessionImpl.SessionServiceImpl",
    "Connectivity_SessionImpl.SessionFactoryImpl",
]

// TESTING: ad-class targets for traceAds dump.
private let adClassesToDump: [String] = [
    "_TtC19AdsPlatform_AdsImpl14AdsServiceImpl",
    "_TtC19AdsPlatform_AdsImpl16AdPreviewHandler",
    "_TtC29AdsNowPlaying_EmbeddedNPVImpl22EmbeddedNPVServiceImpl",
    "_TtC29AdsNowPlaying_InStreamAdsImpl18InStreamAdsService",
    "_TtC20NativeAds_LoggerImpl26NativeAdsLoggerServiceImpl",
    "_TtC21NativeAds_ElementImpl27NativeAdsElementServiceImpl",
    "_TtC28AdsPlatform_AdsBaseSwiftImpl19AdSlotRegistrarImpl",
    "_TtC48AdsEmbedded_AdsSponsoredContextNPBAttachmentImpl25AdModelChangedEventSource",
    "_TtC16Home_EvoPageImpl27SectionProviderRegistryImpl",
    "_TtC16Home_EvoPageImpl24AdPreviewSectionProvider",
    "_TtC16Home_EvoPageImpl31VideoBrandAdITGCSectionProvider",
    "_TtC16Home_EvoPageImpl33DisplayBrandAdITGCSectionProvider",
]

private let runClassDump = false

private let shuffleClassesToDump: [String] = [
    "FreeShuffle_RecommendationsImpl.FreeShuffleRecommendationsServiceImplementation",
    "FreeShuffle_RecommendationsImpl.FreeSmartShuffleServiceImplementation",
    "FreeShuffle_RecommendationsImpl.FreeSmartShuffleConfigurationImplementation",
    "FreeShuffle_RecommendationsImpl.PlayingTrackImplementation",
    "FreeShuffle_RecommendationsImpl.PlayingTrackProviderImplementation",
    "FreeShuffle_RecommendationsImpl.PlayingTrackResolverImplementation",
    "FreeShuffle_RecommendationsImpl.PlayingTrackContextProviderImplementation",
    "FreeShuffle_RecommendationsImpl.ApplicationStateObserverImplementation",
    "FreeShuffle_RecommendationsImpl.TestManagerImplementation",
    "SmartShuffle_CoreImpl.SmartShuffleCoreServiceImpl",
    "SmartShuffle_CoreImpl.SmartShuffleHandlerImplementation",
    "SmartShuffle_CoreImpl.CentralizedShuffleStateDataLoaderImplementation",
    "SmartShuffle_CoreImpl.SmartShufflePredicatesImplementation",
    "SmartShuffle_CoreImpl.SmartShuffleSignalsHandlerImplementation",
    "SmartShuffle_CoreImpl.SmartShufflePlayerContextControllerImplementation",
    "SmartShuffle_CoreImpl.SmartShuffleStateReactiveValue",
    "SmartShuffle_CoreImpl.SmartShuffleHandlerObserverWrapper",
    "Queue_ViewImpl.QueueTrackShuffledList",
    "ListUXPlatform_PlaylistTrackCloudImpl.LikedTrackCloudShuffle",
]

private let sbClassesToDump: [String] = [
    "SPTVideoCoordinatorPlayerRouter",
    "SPTVideoCoordinatorDataSavingVideoDisabler",
    "AdsPlatform_ComScoreImpl.ComScorePlayerObserver",
    "_TtC24AdsPlatform_ComScoreImpl22ComScorePlayerObserver",
    "Player_ReactiveValueKit.ReactivePlayerState",
]
private var classDumpDone = false

private func dumpClass(_ name: String) {
    guard let cls = NSClassFromString(name) else {
        NSLog("[PROBE][CLASS] %@: <not found>", name)
        return
    }
    NSLog("[PROBE][CLASS] %@", name)
    var count: UInt32 = 0
    if let methods = class_copyMethodList(cls, &count) {
        for i in 0..<Int(count) {
            let m = methods[i]
            let sel = method_getName(m)
            let enc = method_getTypeEncoding(m).map { String(cString: $0) } ?? "?"
            NSLog("[PROBE][CLASS]   - %@  (enc=%@)", NSStringFromSelector(sel), enc)
        }
        free(methods)
    }
    if let metaCls = object_getClass(cls) {
        var ccount: UInt32 = 0
        if let cmethods = class_copyMethodList(metaCls, &ccount) {
            for i in 0..<Int(ccount) {
                let m = cmethods[i]
                let sel = method_getName(m)
                let enc = method_getTypeEncoding(m).map { String(cString: $0) } ?? "?"
                NSLog("[PROBE][CLASS]   + %@  (enc=%@)", NSStringFromSelector(sel), enc)
            }
            free(cmethods)
        }
    }
    var ivCount: UInt32 = 0
    if let ivars = class_copyIvarList(cls, &ivCount) {
        for i in 0..<Int(ivCount) {
            let iv = ivars[i]
            let nm = ivar_getName(iv).map { String(cString: $0) } ?? "?"
            let tp = ivar_getTypeEncoding(iv).map { String(cString: $0) } ?? "?"
            NSLog("[PROBE][CLASS]   * %@ :: %@", nm, tp)
        }
        free(ivars)
    }
}

private func dumpClassesOnce() {
    guard runClassDump || traceAds || traceSB || traceShuffle, !classDumpDone else { return }
    classDumpDone = true
    if runClassDump {
        for n in classesToDump { dumpClass(n) }
    }
    // TESTING: ad-class dump (independent of runClassDump)
    if traceAds {
        NSLog("[PROBE][ADS] === ad class dump begin ===")
        for n in adClassesToDump { dumpClass(n) }
        NSLog("[PROBE][ADS] === ad class dump end ===")
    }
    // SponsorBlock: dump player classes to find episode-uri / position / seek path.
    if traceSB {
        NSLog("[PROBE][SB] === sponsorblock class dump begin ===")
        for n in sbClassesToDump { dumpClass(n) }
        NSLog("[PROBE][SB] === sponsorblock class dump end ===")
    }
    // TrueShuffle: dump FreeShuffle / SmartShuffle service surface.
    // NSClassFromString("Module.Class") is unreliable for Swift; iterate the
    // runtime and dump methods inline when the name matches a target suffix.
    if traceShuffle {
        let targetSuffixes: [String] = [
            ".FreeShuffleRecommendationsServiceImplementation",
            ".FreeSmartShuffleServiceImplementation",
            ".FreeSmartShuffleConfigurationImplementation",
            ".PlayingTrackProviderImplementation",
            ".PlayingTrackResolverImplementation",
            ".PlayingTrackContextProviderImplementation",
            ".SmartShuffleCoreServiceImpl",
            ".SmartShuffleHandlerImplementation",
            ".CentralizedShuffleStateDataLoaderImplementation",
            ".SmartShufflePredicatesImplementation",
            ".SmartShuffleSignalsHandlerImplementation",
            ".SmartShufflePlayerContextControllerImplementation",
            ".SmartShuffleStateReactiveValue",
            ".SmartShuffleAllowedSettingImpl",
            ".SmartShuffleAllowedSettingAlwaysEnabled",
            ".ShuffleSettingsServiceImpl",
            ".MixingShuffleHandlerImpl",
            ".ShuffledListEffectHandler",
            ".ReshuffleEffectHandler",
            ".QueueTrackShuffledList",
            ".LikedTrackCloudShuffle",
            ".SmartShufflePlayerAdapter",
            ".SmartShuffleInteropImpl",
            ".ShuffleControllerImpl",
            ".HeaderShuffleActionManager",
            ".ContextualShuffleService",
            ".ContextualShuffleLocalEntityModelImpl",
            ".ShuffleManagerImpl",
            ".ShuffleElementServiceImpl",
        ]
        NSLog("[PROBE][SHUF] === shuffle class dump begin ===")
        let total = objc_getClassList(nil, 0)
        let buf = UnsafeMutablePointer<AnyClass>.allocate(capacity: Int(total))
        defer { buf.deallocate() }
        let cn = objc_getClassList(AutoreleasingUnsafeMutablePointer<AnyClass>(buf), total)
        for i in 0..<Int(cn) {
            let raw = UnsafeRawPointer(buf).load(fromByteOffset: i * MemoryLayout<UnsafeRawPointer>.size,
                                                  as: UnsafeRawPointer.self)
            let cls: AnyClass = unsafeBitCast(raw, to: AnyClass.self)
            let nm = String(cString: class_getName(cls))
            let hit = targetSuffixes.first { nm.hasSuffix($0) }
            guard hit != nil else { continue }
            NSLog("[PROBE][SHUF][CLS] %s", class_getName(cls))
            var mc: UInt32 = 0
            if let methods = class_copyMethodList(cls, &mc) {
                for j in 0..<Int(mc) {
                    let m = methods[j]
                    let sel = method_getName(m)
                    let enc = method_getTypeEncoding(m).map { String(cString: $0) } ?? "?"
                    NSLog("[PROBE][SHUF]   - %@  (enc=%@)", NSStringFromSelector(sel), enc)
                }
                free(methods)
            }
            var ic: UInt32 = 0
            if let ivars = class_copyIvarList(cls, &ic) {
                for j in 0..<Int(ic) {
                    let iv = ivars[j]
                    let inm = ivar_getName(iv).map { String(cString: $0) } ?? "?"
                    let itp = ivar_getTypeEncoding(iv).map { String(cString: $0) } ?? "?"
                    NSLog("[PROBE][SHUF]   * %@ :: %@", inm, itp)
                }
                free(ivars)
            }
        }
        NSLog("[PROBE][SHUF] === shuffle class dump end ===")
    }

    // objc_copyClassList returns AutoreleasingUnsafeMutablePointer; subscripting
    // triggers retain/autorelease msgSend which aborts on iOS 26's baked-in
    // __NSGenericDeallocHandler entries. objc_getClassList with a raw buffer
    // sidesteps it.
    let total = objc_getClassList(nil, 0)
    NSLog("[PROBE][CLASSLIST] scanning %d classes…", Int(total))
    let buf = UnsafeMutablePointer<AnyClass>.allocate(capacity: Int(total))
    defer { buf.deallocate() }
    let n = objc_getClassList(AutoreleasingUnsafeMutablePointer<AnyClass>(buf), total)
    for i in 0..<Int(n) {
        let raw = UnsafeRawPointer(buf).load(fromByteOffset: i * MemoryLayout<UnsafeRawPointer>.size,
                                              as: UnsafeRawPointer.self)
        let cstr = class_getName(unsafeBitCast(raw, to: AnyClass.self))
        let nm = String(cString: cstr)
        if nm.contains("ProductState") || nm.contains("AccountAttribute")
            || nm.contains("PremiumOnly") || nm.contains("Subscription")
            || (nm.contains("SPT") && (nm.contains("Account") || nm.contains("User")))
            || nm.contains("Esperanto") || nm.contains("ProductType") {
            NSLog("[PROBE][CLASSLIST] %s", cstr)
        }
    }
    NSLog("[PROBE][CLASSLIST] done")
}

func activateEeveeProbes() {
    let netOn = traceNet
    let notifOn = true
    NSLog("[PROBE] activating: net=%@ notif=%@ ads=%@ sb=%@",
          netOn ? "on" : "off",
          notifOn ? "on" : "off",
          traceAds ? "on" : "off",
          traceSB ? "on" : "off")
    if netOn { ProbeNetGroup().activate() }
    if notifOn { ProbeNotifGroup().activate() }
    dumpClassesOnce()
}
