// Blocks the Swift service layer used by Spotify 9.1.x to create Premium
// sheets/cards. Legacy Encore popups are handled in UpsellPopupBlocker.

import Foundation
import Orion
import UIKit

private func upsellServiceLog(_ message: String) {
    NSLog("[EeveeSpotify][UpsellService] %@", message)
}

struct GeneralUpsellsServiceGroup: HookGroup {}
struct PremiumUpsellServiceGroup: HookGroup {}
struct ContextualPremiumPromoServiceGroup: HookGroup {}
struct ReferralsUpsellCardServiceGroup: HookGroup {}
struct DownloadUpsellServiceGroup: HookGroup {}
struct FreeHostedJamsUpsellServiceGroup: HookGroup {}
struct FreeUserSkipUpsellPageServiceGroup: HookGroup {}
struct FreeUserShuffleUpsellPageServiceGroup: HookGroup {}
struct SelfLoadingUpsellBannerViewGroup: HookGroup {}

class GeneralUpsellsServiceKill: ClassHook<NSObject> {
    typealias Group = GeneralUpsellsServiceGroup
    static let targetName = "_TtC19Upsells_ServiceImpl18UpsellsServiceImpl"

    func load() {
        upsellServiceLog("suppressed UpsellsServiceImpl.load")
        return
    }
}

class PremiumUpsellServiceKill: ClassHook<NSObject> {
    typealias Group = PremiumUpsellServiceGroup
    static let targetName = "_TtC31PremiumUpsell_UpsellServiceImpl17UpsellServiceImpl"

    func load() {
        upsellServiceLog("suppressed Premium UpsellServiceImpl.load")
        return
    }
}

class ContextualPremiumPromoServiceKill: ClassHook<NSObject> {
    typealias Group = ContextualPremiumPromoServiceGroup
    static let targetName =
        "_TtC45ReinventFree_ContextualUpsellPremiumPromoImpl39ContextualUpsellPremiumPromoServiceImpl"

    func load() {
        upsellServiceLog("suppressed ContextualUpsellPremiumPromoServiceImpl.load")
        return
    }
}

class ReferralsUpsellCardServiceKill: ClassHook<NSObject> {
    typealias Group = ReferralsUpsellCardServiceGroup
    static let targetName =
        "_TtC40Referrals_ReferralsUpsellCardElementImpl37ReferralsUpsellCardElementServiceImpl"

    func load() {
        upsellServiceLog("suppressed ReferralsUpsellCardElementServiceImpl.load")
        return
    }
}

// Download and Jam hosting are server-gated for free accounts. Suppress only
// their client-side Premium prompts; this does not pretend to enable either
// server feature and does not touch ordinary download/Jam status UI.
class DownloadUpsellServiceKill: ClassHook<NSObject> {
    typealias Group = DownloadUpsellServiceGroup
    static let targetName = "_TtC31ReinventFree_DownloadUpsellImpl21DownloadUpsellService"

    func load() {
        upsellServiceLog("suppressed DownloadUpsellService.load")
        return
    }
}

class FreeHostedJamsUpsellServiceKill: ClassHook<NSObject> {
    typealias Group = FreeHostedJamsUpsellServiceGroup
    static let targetName =
        "_TtC28Jam_FreeHostedJamsUpsellImpl31FreeHostedJamsUpsellServiceImpl"

    func load() {
        upsellServiceLog("suppressed FreeHostedJamsUpsellServiceImpl.load")
        return
    }
}

class FreeUserSkipUpsellPageServiceKill: ClassHook<NSObject> {
    typealias Group = FreeUserSkipUpsellPageServiceGroup
    static let targetName =
        "_TtC30Jam_FreeUserSkipUpsellPageImpl29FreeUserSkipUpsellPageService"

    func load() {
        upsellServiceLog("suppressed FreeUserSkipUpsellPageService.load")
        return
    }
}

class FreeUserShuffleUpsellPageServiceKill: ClassHook<NSObject> {
    typealias Group = FreeUserShuffleUpsellPageServiceGroup
    static let targetName =
        "_TtC38Jam_FreeUserShuffleUpsellSheetPageImpl37FreeUserShuffleUpsellSheetPageService"

    func load() {
        upsellServiceLog("suppressed FreeUserShuffleUpsellSheetPageService.load")
        return
    }
}

// Language-independent fallback for the reusable Premium banner UIView.
// DSA notices, library status and ordinary download progress use other classes.
class SelfLoadingUpsellBannerViewKill: ClassHook<UIView> {
    typealias Group = SelfLoadingUpsellBannerViewGroup
    static let targetName = "_TtC13Upsells_UIKit29SelfLoadingUpsellBannerUIView"

    func didMoveToSuperview() {
        orig.didMoveToSuperview()
        target.isHidden = true
        target.isUserInteractionEnabled = false
        if target.superview != nil {
            upsellServiceLog("suppressed SelfLoadingUpsellBannerUIView")
            target.removeFromSuperview()
        }
    }
}

func activateUpsellServiceBlocker() {
    let loadSelector = Selector(("load"))
    let targets: [(String, String, () -> Void)] = [
        (GeneralUpsellsServiceKill.targetName, "UpsellsServiceImpl", { GeneralUpsellsServiceGroup().activate() }),
        (PremiumUpsellServiceKill.targetName, "PremiumUpsellServiceImpl", { PremiumUpsellServiceGroup().activate() }),
        (ContextualPremiumPromoServiceKill.targetName, "ContextualPremiumPromoServiceImpl", { ContextualPremiumPromoServiceGroup().activate() }),
        (ReferralsUpsellCardServiceKill.targetName, "ReferralsUpsellCardElementService", { ReferralsUpsellCardServiceGroup().activate() }),
        (DownloadUpsellServiceKill.targetName, "DownloadUpsellService", { DownloadUpsellServiceGroup().activate() }),
        (FreeHostedJamsUpsellServiceKill.targetName, "FreeHostedJamsUpsellService", { FreeHostedJamsUpsellServiceGroup().activate() }),
        (FreeUserSkipUpsellPageServiceKill.targetName, "FreeUserSkipUpsellPageService", { FreeUserSkipUpsellPageServiceGroup().activate() }),
        (FreeUserShuffleUpsellPageServiceKill.targetName, "FreeUserShuffleUpsellSheetPageService", { FreeUserShuffleUpsellPageServiceGroup().activate() }),
    ]

    var activated = 0
    for (className, label, activate) in targets {
        guard let cls = NSClassFromString(className),
              class_getInstanceMethod(cls, loadSelector) != nil else {
            NSLog("[EeveeSpotify][UpsellService] %@/load unavailable; skipping", label)
            continue
        }
        activate()
        activated += 1
        NSLog("[EeveeSpotify][UpsellService] %@ hook activated", label)
    }

    let viewSelector = Selector(("didMoveToSuperview"))
    if let cls = NSClassFromString(SelfLoadingUpsellBannerViewKill.targetName) as? UIView.Type,
       class_getInstanceMethod(cls, viewSelector) != nil {
        SelfLoadingUpsellBannerViewGroup().activate()
        activated += 1
        NSLog("[EeveeSpotify][UpsellService] Premium banner view fallback activated")
    } else {
        NSLog("[EeveeSpotify][UpsellService] Premium banner view unavailable; skipping")
    }

    NSLog("[EeveeSpotify][UpsellService] activated %d/%d compatible hooks",
          activated, targets.count + 1)
}
