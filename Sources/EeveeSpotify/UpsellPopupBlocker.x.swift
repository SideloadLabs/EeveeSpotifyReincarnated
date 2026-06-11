// UpsellPopupBlocker.x.swift
// Blocks Spotify's premium upsell / "Like listening without limits?" popups
// by intercepting SPTEncorePopUpPresenter.presentPopUp(_:) and dropping any
// dialog whose title or description text matches known upsell patterns.

import Orion
import UIKit

struct UpsellPopupBlockerGroup: HookGroup {}

// Keywords found in upsell / upgrade popup titles and descriptions.
// Checked case-insensitively against both the dialog title and body text.
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
    "learn more",
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

// Safely read a String KVC key from an NSObject, returning nil on exception.
private func kvcString(_ obj: NSObject, _ key: String) -> String? {
    obj.value(forKeyPath: key) as? String
}

class SPTEncorePopUpPresenterHook: ClassHook<NSObject> {
    typealias Group = UpsellPopupBlockerGroup
    static let targetName = "SPTEncorePopUpPresenter"

    func presentPopUp(_ popUp: NSObject) {
        // Read dialog text via KVC.
        // SPTEncorePopUpDialog exposes a `model` (SPTEncorePopUpDialogModel) with
        // `title` and `descriptionText`. Fall back to the same keys directly on the
        // dialog object in case the structure differs between Spotify builds.
        let modelObj = popUp.value(forKeyPath: "model") as? NSObject

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
            return  // swallow the call; popup never appears
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
