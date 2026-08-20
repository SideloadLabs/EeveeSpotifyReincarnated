import Foundation
import Orion

private let oneYearFromNowISO: String = {
    let d = Calendar.current.date(byAdding: .year, value: 1, to: Date()) ?? Date().addingTimeInterval(31_536_000)
    let f = ISO8601DateFormatter(); f.timeZone = TimeZone(abbreviation: "UTC")
    return f.string(from: d)
}()

private func forcedPremiumString(forKey key: String) -> String? {
    switch key {
    case "type":                                   return "premium"
    case "catalogue":                              return "premium"
    case "product":                                return "premium"
    case "name":                                   return "Spotify Premium"
    case "player-license":                         return "premium"
    case "player-license-v2":                      return "premium"
    case "financial-product":                      return "pr:premium,tc:0"

    case "ads":                                    return "0"
    case "ab-ad-player-targeting":                 return "0"
    case "allow-advertising-id-transmission":      return "0"
    case "restrict-advertising-id-transmission":   return "1"
    case "audio-ad-frequency":                     return "0"
    case "video-ad-frequency":                     return "0"
    case "ad-formats":                             return ""

    case "on-demand":                              return "1"
    case "unrestricted":                           return "1"
    case "shuffle-eligible":                       return "1"
    case "social-session":                         return "1"
    case "social-session-free-tier":               return "0"
    case "social-connect":                         return "1"
    case "tracks-in-collection-enabled":           return "1"
    case "is-eligible-premium-unboxing":           return "1"
    case "can_use_superbird":                      return "1"
    case "manager":                                return "1"
    case "nft-disabled":                           return "1"

    case "streaming-rules":                        return ""
    case "previous-streaming-rules":               return ""
    case "high-bitrate":                           return "1"
    case "very-high-bitrate":                      return "1"
    case "audio-quality":                          return "very_high"
    case "shuffle":                                return "0"
    case "shuffle-mode":                           return "0"
    case "pick-and-shuffle":                       return "0"

    case "offline":                                return "1"
    case "can-use-offline":                        return "1"
    case "has-offline-state":                      return "1"
    case "max-offline-downloads-per-device":       return "10000"
    case "max-offline-tracks":                     return "10000"

    case "subscription-enddate":                   return oneYearFromNowISO
    case "product-expiry":                         return oneYearFromNowISO
    case "trial-ends-at":                          return "9999999999"
    case "current-period-end":                     return "9999999999"
    case "premium-promotion-eligible":             return "0"
    case "payments-initial-campaign":              return "default"

    // Server pushes these to trigger ForcedLogoutDaemon / AccessTokenRevokerDaemon.
    case "forced_logout":                          return ""
    case "forced_logout_abroad_since":             return ""
    case "force_logout":                           return ""
    case "logout_required":                        return "0"
    case "session_invalidated":                    return "0"

    // Never spoof — would break server geo.
    case "country":                                return nil

    default:                                       return nil
    }
}

private let stripKeys: Set<String> = [
    "payment-state",
    "last-premium-activation-date",
    "on-demand-trial",
    "on-demand-trial-in-progress",
    "smart-shuffle",
]

private func rewritePremiumDict(_ dict: NSDictionary) -> NSDictionary {
    let mutable = NSMutableDictionary(dictionary: dict)
    var changed = 0

    for k in stripKeys {
        if mutable[k] != nil { mutable.removeObject(forKey: k); changed += 1 }
    }

    for (k, _) in dict {
        guard let key = k as? String, let forced = forcedPremiumString(forKey: key) else { continue }
        let cur = mutable[key] as? String
        if cur != forced { mutable[key] = forced; changed += 1 }
    }

    // Over-seeding caused greyed-out tracks (streaming-rules mismatch).
    // Only seed the safe core set; dates and logout keys override-only.
    let seedAlways = [
        "type", "catalogue", "product",
        "ads", "on-demand", "unrestricted", "shuffle-eligible",
        "player-license", "player-license-v2",
    ]
    for k in seedAlways {
        if mutable[k] == nil, let v = forcedPremiumString(forKey: k) {
            mutable[k] = v
            changed += 1
        }
    }

    if changed > 0 {
        NSLog("[FORCE][PS.dict] rewrote %d keys (in=%lu out=%lu)", changed, dict.count, mutable.count)
    }
    return mutable
}

private let premiumWatchKeys: [String] = [
    "type", "catalogue", "product", "name",
    "ads", "audio-ad-frequency", "video-ad-frequency",
    "on-demand", "unrestricted", "shuffle-eligible",
    "player-license", "player-license-v2",
    "subscription-enddate", "product-expiry",
    "forced_logout", "forced_logout_abroad_since", "force_logout",
    "logout_required", "session_invalidated",
    "payment-state", "last-premium-activation-date",
    "country", "financial-product",
]

private func passiveLogProductState(_ tag: String, _ dict: NSDictionary) {
    var pairs: [String] = []
    for k in premiumWatchKeys {
        if let v = dict[k] { pairs.append("\(k)=\(v)") }
    }
    if !pairs.isEmpty {
        NSLog("[REVERT_WATCH][%@] %@", tag, pairs.joined(separator: " "))
    } else if dict.count > 0 {
        NSLog("[REVERT_WATCH][%@] keys=%lu (no premium-relevant)", tag, dict.count)
    }
}

class CoreProductStateHook: ClassHook<NSObject> {
    typealias Group = EeveePremiumForceGroup
    static let targetName = "SPTCoreProductState"

    func setOriginalValues(_ dict: NSDictionary) {
        passiveLogProductState("setOriginal", dict)
        orig.setOriginalValues(enableDictRewrite ? rewritePremiumDict(dict) : dict)
    }

    func setOverrides(_ dict: NSDictionary) {
        passiveLogProductState("setOverrides", dict)
        orig.setOverrides(enableDictRewrite ? rewritePremiumDict(dict) : dict)
    }

    func initWithValuesDict(_ dict: NSDictionary, scheduler: UnsafeRawPointer) -> Any {
        let d = enableDictRewrite ? rewritePremiumDict(dict) : dict
        return orig.initWithValuesDict(d, scheduler: scheduler)
    }

    func stringForKey(_ key: NSString) -> NSString? {
        if enableDirectGetters, let forced = forcedPremiumString(forKey: key as String) {
            return forced as NSString
        }
        return orig.stringForKey(key)
    }

    func objectForKeyedSubscript(_ key: NSString) -> Any? {
        if enableDirectGetters, let forced = forcedPremiumString(forKey: key as String) {
            return forced as NSString
        }
        return orig.objectForKeyedSubscript(key)
    }

    func values() -> NSDictionary {
        let d = orig.values()
        return enableDictRewrite ? rewritePremiumDict(d) : d
    }

    func originalValues() -> NSDictionary {
        let d = orig.originalValues()
        return enableDictRewrite ? rewritePremiumDict(d) : d
    }

    func valuesDictFromMap(_ map: UnsafeRawPointer) -> NSDictionary {
        let d = orig.valuesDictFromMap(map)
        return enableDictRewrite ? rewritePremiumDict(d) : d
    }

    func valuesDictFromChangedKeys(_ keys: UnsafeRawPointer) -> NSDictionary {
        let d = orig.valuesDictFromChangedKeys(keys)
        return enableDictRewrite ? rewritePremiumDict(d) : d
    }
}

class AdsProductStateHook: ClassHook<NSObject> {
    typealias Group = EeveePremiumForceGroup
    static let targetName = "SPTAdsProductState"

    func adsEnabled() -> Bool {
        return enableAdsHook ? false : orig.adsEnabled()
    }
}

private func swizzleObjectGetter(_ cls: AnyClass, _ name: String, _ value: @escaping () -> AnyObject) {
    let sel = sel_registerName(name)
    let block: @convention(block) (AnyObject) -> AnyObject = { _ in value() }
    let imp = imp_implementationWithBlock(block)
    class_replaceMethod(cls, sel, imp, "@@:")
}

private func swizzleIntGetter(_ cls: AnyClass, _ name: String, _ value: Int) {
    let sel = sel_registerName(name)
    let block: @convention(block) (AnyObject) -> Int = { _ in value }
    let imp = imp_implementationWithBlock(block)
    class_replaceMethod(cls, sel, imp, "q@:")
}

private func swizzleBoolGetter(_ cls: AnyClass, _ name: String, _ value: Bool) {
    let sel = sel_registerName(name)
    let block: @convention(block) (AnyObject) -> Bool = { _ in value }
    let imp = imp_implementationWithBlock(block)
    class_replaceMethod(cls, sel, imp, "B@:")
}

struct EeveePremiumForceGroup: HookGroup {}

private let enableDictRewrite = false
private let enableDirectGetters = false
private let enableAdsHook = false
private let enablePassiveProductStateLog = true

func activateEeveePremiumForce() {
    NSLog("[FORCE] activating dict=%@ getters=%@ ads=%@ passiveLog=%@",
          enableDictRewrite   ? "on" : "off",
          enableDirectGetters ? "on" : "off",
          enableAdsHook       ? "on" : "off",
          enablePassiveProductStateLog ? "on" : "off")
    guard enableDictRewrite || enableDirectGetters || enableAdsHook || enablePassiveProductStateLog else {
        return
    }
    // This ran completely unguarded before - unlike every other hook group in this
    // codebase - so a Spotify build that renames/removes one of these methods would
    // fail the hook and (pre handleError override) instantly crash at launch.
    guard NSClassFromString("SPTCoreProductState") != nil else {
        NSLog("[FORCE] Skipped: SPTCoreProductState not found")
        return
    }
    EeveePremiumForceGroup().activate()
}
