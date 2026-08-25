// Drops premium upsell popups by intercepting presentPopUp(_:) and matching the
// dialog title/body against known upsell phrases.

import Orion
import UIKit
import ObjectiveC.runtime

struct UpsellPopupModelCaptureGroup: HookGroup {}
struct UpsellPopupDialogCaptureGroup: HookGroup {}
struct UpsellPopupBlockerGroup: HookGroup {}

private var upsellPopupAssociationKey: UInt8 = 0

private let upsellKeywords: [String] = [
    "premium",
    "upgrade",
    "subscribe",
    "subscription",
    "listening without limits",
    "unlimited skips",
    "play the songs you love",
    "go premium",
    "like listening",
    "free account",
    "ad-free",
    "ad free",
    "try free",
    "get premium",
    "start premium",
    "upsell",
    "paywall",
    "free tier",
    "limited listening",
    // Russian UI variants used by the same Encore popup model.
    "премиум",
    "оформить подписку",
    "купить подписку",
    "без ограничений",
    "бесплатный аккаунт",
]

private func isUpsellText(_ text: String?) -> Bool {
    guard let text = text else { return false }
    let lower = text.lowercased()
    return upsellKeywords.contains { lower.contains($0) }
}

// PopUpHelper uses this title for Eevee's own status/error dialogs, including
// the intentional server-sided download reminder. Those are never Spotify
// Premium upsells and must remain visible even if their localized body happens
// to contain one of the generic keywords above.
private func isEeveePopupTitle(_ title: String?) -> Bool {
    title == "EeveeSpotify"
}

private func markAsUpsell(_ object: AnyObject) {
    objc_setAssociatedObject(
        object,
        &upsellPopupAssociationKey,
        NSNumber(value: true),
        .OBJC_ASSOCIATION_RETAIN_NONATOMIC
    )
}

private func isMarkedAsUpsell(_ object: AnyObject) -> Bool {
    (objc_getAssociatedObject(object, &upsellPopupAssociationKey) as? NSNumber)?.boolValue == true
}

// responds(to:) gate is mandatory: value(forKey:) raises an uncatchable
// NSUnknownKeyException, which try?/do-catch can't trap.
private func kvcString(_ obj: NSObject, _ key: String) -> String? {
    guard obj.responds(to: Selector(key)) else { return nil }
    return obj.value(forKey: key) as? String
}

private func kvcObject(_ obj: NSObject, _ key: String) -> NSObject? {
    guard obj.responds(to: Selector(key)) else { return nil }
    return obj.value(forKey: key) as? NSObject
}

// Capture the strings at their source. The dialog passed to presentPopUp(_:) does
// not expose its model in all Spotify builds, which made the previous KVC-only
// implementation see nil title/body and allow the popup through.
class SPTEncorePopUpDialogModelHook: ClassHook<NSObject> {
    typealias Group = UpsellPopupModelCaptureGroup
    static let targetName = "SPTEncorePopUpDialogModel"

    func initWithTitle(
        _ title: String,
        description: String,
        image: Any?,
        primaryButtonTitle: String,
        secondaryButtonTitle: String?
    ) -> Target {
        let model = orig.initWithTitle(
            title,
            description: description,
            image: image,
            primaryButtonTitle: primaryButtonTitle,
            secondaryButtonTitle: secondaryButtonTitle
        )

        let containsUpsellText = isUpsellText(title)
            || isUpsellText(description)
            || isUpsellText(primaryButtonTitle)
            || isUpsellText(secondaryButtonTitle)

        if !isEeveePopupTitle(title) && containsUpsellText {
            markAsUpsell(model)
        }
        return model
    }
}

class SPTEncorePopUpDialogHook: ClassHook<NSObject> {
    typealias Group = UpsellPopupDialogCaptureGroup
    static let targetName = "SPTEncorePopUpDialog"

    func update(_ popUpModel: NSObject) {
        if isMarkedAsUpsell(popUpModel) {
            markAsUpsell(target)
        }
        orig.update(popUpModel)
    }
}

class SPTEncorePopUpPresenterHook: ClassHook<NSObject> {
    typealias Group = UpsellPopupBlockerGroup
    static let targetName = "SPTEncorePopUpPresenter"

    func presentPopUp(_ popUp: NSObject) {
        if isMarkedAsUpsell(popUp) {
            NSLog("[EeveeSpotify][UpsellBlock] Blocked popup captured from model")
            return
        }

        // dialog exposes a `model` with title/descriptionText; fall back to the
        // dialog itself in case the structure differs between builds
        let modelObj = kvcObject(popUp, "model")

        let title = modelObj.flatMap { kvcString($0, "title") ?? kvcString($0, "dialogTitle") }
                 ?? kvcString(popUp, "title") ?? kvcString(popUp, "dialogTitle")
        let desc  = modelObj.flatMap {
                        kvcString($0, "descriptionText")
                     ?? kvcString($0, "body")
                     ?? kvcString($0, "subtitle")
                 }
                 ?? kvcString(popUp, "descriptionText") ?? kvcString(popUp, "body")

        if isEeveePopupTitle(title) {
            orig.presentPopUp(popUp)
            return
        }

        if isUpsellText(title) || isUpsellText(desc) {
            NSLog("[EeveeSpotify][UpsellBlock] Blocked popup — title=%@ desc=%@",
                  title ?? "(nil)", desc ?? "(nil)")
            return
        }

        orig.presentPopUp(popUp)
    }
}

func activateUpsellPopupBlocker() {
    let targets: [(String, [Selector], String, () -> Void)] = [
        (
            SPTEncorePopUpDialogModelHook.targetName,
            [Selector(("initWithTitle:description:image:primaryButtonTitle:secondaryButtonTitle:"))],
            "dialog model capture",
            { UpsellPopupModelCaptureGroup().activate() }
        ),
        (
            SPTEncorePopUpDialogHook.targetName,
            [Selector(("update:"))],
            "dialog marker propagation",
            { UpsellPopupDialogCaptureGroup().activate() }
        ),
        (
            SPTEncorePopUpPresenterHook.targetName,
            [Selector(("presentPopUp:"))],
            "popup presenter",
            { UpsellPopupBlockerGroup().activate() }
        ),
    ]

    var activated = 0
    for (className, selectors, label, activate) in targets {
        guard let cls = NSClassFromString(className),
              selectors.allSatisfy({ class_getInstanceMethod(cls, $0) != nil }) else {
            NSLog("[EeveeSpotify][UpsellBlock] %@ unavailable; skipping", label)
            continue
        }
        activate()
        activated += 1
        NSLog("[EeveeSpotify][UpsellBlock] %@ activated", label)
    }

    NSLog("[EeveeSpotify][UpsellBlock] activated %d/%d compatible hooks",
          activated, targets.count)
}
