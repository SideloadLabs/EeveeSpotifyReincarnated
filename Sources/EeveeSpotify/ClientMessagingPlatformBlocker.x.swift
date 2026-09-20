// Blocks Spotify's ClientMessagingPlatform (CMP) marketing surfaces — the
// "welcome back / Ends soon: 2 months of Premium" fullscreen takeover and the
// "Final call: Get 2 months for $6.99" Home banner.
//
// 9.1.84 moved these onto com.spotify.pendragon.v1.ClientMessageService
// (FetchMessage / FetchMessageForPreview RPCs). The network side is blocked in
// URL+Extension.swift (isPendragonFetchMessageList); messages already persisted
// in CMP's on-device SQLite store can still present after that, so this adds a
// presentation-layer safety net.
//
// Scope: CMP only carries server-driven marketing/awareness messages.
// DSA transparency dialogs (DSA_Messaging*) and Eevee's own PopUpHelper dialogs
// live in separate modules and are untouched by these hooks.

import Foundation
import Orion
import UIKit

private func cmpLog(_ message: String) {
    // Debug file first (the tester log file), then system console.
    writeDebugLog("[CMPBlock] \(message)")
}

struct CMPFullscreenContainerGroup: HookGroup {}
struct CMPModalContainerGroup: HookGroup {}
struct CMPBottomSheetPageGroup: HookGroup {}
struct CMPBannerViewGroup: HookGroup {}
struct UpsellElementViewGroup: HookGroup {}

// Fullscreen takeovers, center modals and bottom sheets are presented in
// dedicated container view controllers. Dismiss from viewWillAppear so the
// container never becomes visible; dismiss(animated:false) keeps UIKit's
// presentation bookkeeping consistent. Hiding the view is a belt-and-suspenders
// fallback for custom-container presentations where dismiss would be a no-op.
class CMPFullscreenContainerHook: ClassHook<UIViewController> {
    typealias Group = CMPFullscreenContainerGroup
    static let targetName =
        "_TtC37Messaging_ClientMessagingPlatformImpl33FullscreenContainerViewController"

    func viewWillAppear(_ animated: Bool) {
        orig.viewWillAppear(animated)
        cmpLog("suppressed fullscreen message container")
        target.view.isHidden = true
        target.view.isUserInteractionEnabled = false
        target.dismiss(animated: false, completion: nil)
    }
}

class CMPModalContainerHook: ClassHook<UIViewController> {
    typealias Group = CMPModalContainerGroup
    static let targetName =
        "_TtC37Messaging_ClientMessagingPlatformImpl28ModalContainerViewController"

    func viewWillAppear(_ animated: Bool) {
        orig.viewWillAppear(animated)
        cmpLog("suppressed modal message container")
        target.view.isHidden = true
        target.view.isUserInteractionEnabled = false
        target.dismiss(animated: false, completion: nil)
    }
}

class CMPBottomSheetPageHook: ClassHook<UIViewController> {
    typealias Group = CMPBottomSheetPageGroup
    static let targetName =
        "_TtC37Messaging_ClientMessagingPlatformImpl52ClientMessagingPlatformBottomSheetPageViewController"

    func viewWillAppear(_ animated: Bool) {
        orig.viewWillAppear(animated)
        cmpLog("suppressed bottom-sheet message container")
        target.view.isHidden = true
        target.view.isUserInteractionEnabled = false
        target.dismiss(animated: false, completion: nil)
    }
}

// The Home banner is rendered by a dedicated banner view. Same pattern as
// SelfLoadingUpsellBannerViewKill: hide on attach, then detach.
class CMPBannerViewHook: ClassHook<UIView> {
    typealias Group = CMPBannerViewGroup
    static let targetName =
        "_TtC37Messaging_ClientMessagingPlatformImpl33ClientMessagingPlatformBannerView"

    func didMoveToSuperview() {
        orig.didMoveToSuperview()
        target.isHidden = true
        target.isUserInteractionEnabled = false
        if target.superview != nil {
            cmpLog("suppressed CMP banner view")
            target.removeFromSuperview()
        }
    }
}

// Upsell "element" views rendered from Hub/queue component trees. Named
// targets (UpsellBanner/PremiumUpsell in the class name), so no DSA or status
// UI can match.
class UpsellBannerElementUIHook: ClassHook<NSObject> {
    typealias Group = UpsellElementViewGroup
    static let targetName =
        "_TtC18Upsells_ElementKitP33_11E507536F1F78CA735FB7F17658749321UpsellBannerElementUI"

    func didMoveToSuperview() {
        orig.didMoveToSuperview()
        guard let view = target as? UIView else { return }
        view.isHidden = true
        view.isUserInteractionEnabled = false
        if view.superview != nil {
            cmpLog("suppressed UpsellBannerElementUI")
            view.removeFromSuperview()
        }
    }
}

class PremiumUpsellBannerElementUIHook: ClassHook<NSObject> {
    typealias Group = UpsellElementViewGroup
    static let targetName =
        "_TtC24Jam_QueueIntegrationImpl28PremiumUpsellBannerElementUI"

    func didMoveToSuperview() {
        orig.didMoveToSuperview()
        guard let view = target as? UIView else { return }
        view.isHidden = true
        view.isUserInteractionEnabled = false
        if view.superview != nil {
            cmpLog("suppressed PremiumUpsellBannerElementUI")
            view.removeFromSuperview()
        }
    }
}

class PremiumUpsellControlPanelHook: ClassHook<UIView> {
    typealias Group = UpsellElementViewGroup
    static let targetName =
        "_TtC19ReinventFree_ECMKit25PremiumUpsellControlPanel"

    func didMoveToSuperview() {
        orig.didMoveToSuperview()
        target.isHidden = true
        target.isUserInteractionEnabled = false
        if target.superview != nil {
            cmpLog("suppressed PremiumUpsellControlPanel")
            target.removeFromSuperview()
        }
    }
}

func activateClientMessagingPlatformBlocker() {
    let viewWillAppearSelector = Selector(("viewWillAppear:"))
    let didMoveToSuperviewSelector = Selector(("didMoveToSuperview"))

    let containerHooks: [(String, String, () -> Void)] = [
        (CMPFullscreenContainerHook.targetName, "FullscreenContainer", { CMPFullscreenContainerGroup().activate() }),
        (CMPModalContainerHook.targetName, "ModalContainer", { CMPModalContainerGroup().activate() }),
        (CMPBottomSheetPageHook.targetName, "BottomSheetPage", { CMPBottomSheetPageGroup().activate() }),
    ]

    let viewHooks: [(String, String, () -> Void)] = [
        (CMPBannerViewHook.targetName, "CMPBannerView", { CMPBannerViewGroup().activate() }),
        (UpsellBannerElementUIHook.targetName, "UpsellBannerElementUI", { UpsellElementViewGroup().activate() }),
        (PremiumUpsellBannerElementUIHook.targetName, "PremiumUpsellBannerElementUI", { UpsellElementViewGroup().activate() }),
        (PremiumUpsellControlPanelHook.targetName, "PremiumUpsellControlPanel", { UpsellElementViewGroup().activate() }),
    ]

    var activated = 0
    let total = containerHooks.count + viewHooks.count

    for (className, label, activate) in containerHooks {
        guard let cls = findTweakClass(className),
              class_getInstanceMethod(cls, viewWillAppearSelector) != nil else {
            cmpLog("\(label) unavailable; skipping (class not registered / no viewWillAppear)")
            continue
        }
        activate()
        activated += 1
        cmpLog("\(label) hook activated")
    }

    for (className, label, activate) in viewHooks {
        // No UIView cast here: some ElementUI classes are not UIView-
        // compatible on all builds (Orion rejects them with
        // targetHasIncompatibleType). Their hooks are declared against
        // NSObject and cast internally instead.
        guard let cls = findTweakClass(className),
              class_getInstanceMethod(cls, didMoveToSuperviewSelector) != nil else {
            cmpLog("\(label) unavailable; skipping (class not registered / no didMoveToSuperview)")
            continue
        }
        activate()
        activated += 1
        cmpLog("\(label) hook activated")
    }

    cmpLog("activated \(activated)/\(total) compatible hooks")
}
