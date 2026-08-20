// TESTING: extended ad blocker for Swift Service-based ad surfaces
// (Evo home brand-ads, NPV under-player ad, in-stream audio, native ads).
// Hooks SPTService -load on each ad service and skips orig so the service
// stays inert. Per-surface bool flips below if one needs disabling.

import Orion
import Foundation

struct EeveeAdBlockerExtendedGroup: HookGroup {}

#if ROOTHIDE
// RootHide can expose Spotify's Swift service classes at different points
// during injection. Isolate every descriptor so an unavailable service does
// not make Orion reject all extended hooks and terminate the application.
struct AdsServiceImplGroup: HookGroup {}
struct InStreamAdsServiceGroup: HookGroup {}
struct EmbeddedNPVServiceGroup: HookGroup {}
struct NativeAdsLoggerServiceGroup: HookGroup {}
struct SponsoredCtxAttachmentGroup: HookGroup {}
#endif

private let killAdsServiceImpl         = true
private let killInStreamAdsService     = true
private let killEmbeddedNPVService     = true
private let killNativeAdsLoggerService = true
private let killSponsoredCtxAttachment = true
private let logAdBlockerEvents         = true

@inline(__always)
private func adlog(_ what: String) {
    if logAdBlockerEvents { NSLog("[EeveeSpotify][AdBlock] suppressed %@", what) }
}

class AdsServiceImplKill: ClassHook<NSObject> {
    #if ROOTHIDE
    typealias Group = AdsServiceImplGroup
    #else
    typealias Group = EeveeAdBlockerExtendedGroup
    #endif
    static let targetName: String = "_TtC19AdsPlatform_AdsImpl14AdsServiceImpl"
    func load() {
        if killAdsServiceImpl { adlog("AdsServiceImpl.load"); return }
        orig.load()
    }
}

class InStreamAdsServiceKill: ClassHook<NSObject> {
    #if ROOTHIDE
    typealias Group = InStreamAdsServiceGroup
    #else
    typealias Group = EeveeAdBlockerExtendedGroup
    #endif
    static let targetName: String = "_TtC29AdsNowPlaying_InStreamAdsImpl18InStreamAdsService"
    func load() {
        if killInStreamAdsService { adlog("InStreamAdsService.load"); return }
        orig.load()
    }
}

class EmbeddedNPVServiceImplKill: ClassHook<NSObject> {
    #if ROOTHIDE
    typealias Group = EmbeddedNPVServiceGroup
    #else
    typealias Group = EeveeAdBlockerExtendedGroup
    #endif
    static let targetName: String = "_TtC29AdsNowPlaying_EmbeddedNPVImpl22EmbeddedNPVServiceImpl"
    func load() {
        if killEmbeddedNPVService { adlog("EmbeddedNPVServiceImpl.load"); return }
        orig.load()
    }
}

class NativeAdsLoggerServiceImplKill: ClassHook<NSObject> {
    #if ROOTHIDE
    typealias Group = NativeAdsLoggerServiceGroup
    #else
    typealias Group = EeveeAdBlockerExtendedGroup
    #endif
    static let targetName: String = "_TtC20NativeAds_LoggerImpl26NativeAdsLoggerServiceImpl"
    func load() {
        if killNativeAdsLoggerService { adlog("NativeAdsLoggerServiceImpl.load"); return }
        orig.load()
    }
}

// Passive log only — returning nil from init would crash the alloc chain.
// Upstream events are starved by killing AdsServiceImpl above.
class SponsoredCtxAttachmentProbe: ClassHook<NSObject> {
    #if ROOTHIDE
    typealias Group = SponsoredCtxAttachmentGroup
    #else
    typealias Group = EeveeAdBlockerExtendedGroup
    #endif
    static let targetName: String =
        "_TtC48AdsEmbedded_AdsSponsoredContextNPBAttachmentImpl25AdModelChangedEventSource"
    func `init`() -> Target {
        if killSponsoredCtxAttachment {
            adlog("SponsoredCtxAttachment.init (passive)")
        }
        return orig.`init`()
    }
}

func activateEeveeAdBlockerExtended() {
    #if ROOTHIDE
    let loadSelector = Selector(("load"))
    let initSelector = Selector(("init"))

    let loadTargets: [(String, String, () -> Void)] = [
        (AdsServiceImplKill.targetName, "AdsServiceImpl", { AdsServiceImplGroup().activate() }),
        (InStreamAdsServiceKill.targetName, "InStreamAdsService", { InStreamAdsServiceGroup().activate() }),
        (EmbeddedNPVServiceImplKill.targetName, "EmbeddedNPVServiceImpl", { EmbeddedNPVServiceGroup().activate() }),
        (NativeAdsLoggerServiceImplKill.targetName, "NativeAdsLoggerServiceImpl", { NativeAdsLoggerServiceGroup().activate() }),
    ]

    var activated = 0
    for (className, label, activate) in loadTargets {
        guard let cls = NSClassFromString(className),
              class_getInstanceMethod(cls, loadSelector) != nil else {
            NSLog("[EeveeSpotify][AdBlock] %@/load unavailable; skipping", label)
            continue
        }
        activate()
        activated += 1
        NSLog("[EeveeSpotify][AdBlock] %@ hook activated", label)
    }

    if let cls = NSClassFromString(SponsoredCtxAttachmentProbe.targetName),
       class_getInstanceMethod(cls, initSelector) != nil {
        SponsoredCtxAttachmentGroup().activate()
        activated += 1
        NSLog("[EeveeSpotify][AdBlock] SponsoredCtxAttachment hook activated")
    } else {
        NSLog("[EeveeSpotify][AdBlock] SponsoredCtxAttachment/init unavailable; skipping")
    }

    NSLog("[EeveeSpotify][AdBlock] activated %d/%d compatible extended hooks",
          activated, loadTargets.count + 1)
    #else
    let probes: [String] = [
        "_TtC19AdsPlatform_AdsImpl14AdsServiceImpl",
        "_TtC29AdsNowPlaying_InStreamAdsImpl18InStreamAdsService",
        "_TtC29AdsNowPlaying_EmbeddedNPVImpl22EmbeddedNPVServiceImpl",
        "_TtC20NativeAds_LoggerImpl26NativeAdsLoggerServiceImpl",
    ]
    let presentCount = probes.filter { NSClassFromString($0) != nil }.count
    NSLog("[EeveeSpotify][AdBlock] target classes resolved: %d/%d",
          presentCount, probes.count)
    guard presentCount > 0 else {
        NSLog("[EeveeSpotify][AdBlock] no target classes present; skip activation")
        return
    }
    EeveeAdBlockerExtendedGroup().activate()
    NSLog("[EeveeSpotify][AdBlock] EeveeAdBlockerExtendedGroup activated")
    #endif
}
