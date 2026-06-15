// Drops premium upsell popups by intercepting presentPopUp(_:) and matching the
// dialog title/body against known upsell phrases.

import Orion
import UIKit

struct UpsellPopupBlockerGroup: HookGroup {}

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
]

private func isUpsellText(_ text: String?) -> Bool {
    guard let text = text else { return false }
    let lower = text.lowercased()
    return upsellKeywords.contains { lower.contains($0) }
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

class SPTEncorePopUpPresenterHook: ClassHook<NSObject> {
    typealias Group = UpsellPopupBlockerGroup
    static let targetName = "SPTEncorePopUpPresenter"

    func presentPopUp(_ popUp: NSObject) {
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

        if isUpsellText(title) || isUpsellText(desc) {
            NSLog("[EeveeSpotify][UpsellBlock] Blocked popup — title=%@ desc=%@",
                  title ?? "(nil)", desc ?? "(nil)")
            return
        }

        orig.presentPopUp(popUp)
    }
}

func activateUpsellPopupBlocker() {
    guard NSClassFromString("SPTEncorePopUpPresenter") != nil else {
        NSLog("[EeveeSpotify][UpsellBlock] SPTEncorePopUpPresenter not found; skipping")
        return
    }
    UpsellPopupBlockerGroup().activate()
    NSLog("[EeveeSpotify][UpsellBlock] UpsellPopupBlockerGroup activated")
}
