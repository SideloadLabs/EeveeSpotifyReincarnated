import Foundation
import UIKit
import Orion
import ObjectiveC.runtime

struct RatingDialogBlockerGroup: HookGroup {}

// Blocks StoreKit's native app rating prompt ("Enjoying Spotify? Tap a star to rate it on the App Store").
class SKStoreReviewControllerHook: ClassHook<NSObject> {
    typealias Group = RatingDialogBlockerGroup
    static let targetName = "SKStoreReviewController"

    class func requestReview() {
        if UserDefaults.blockRatingDialogs {
            NSLog("[EeveeSpotify][RatingBlocker] Suppressed [SKStoreReviewController requestReview]")
            return
        }
        orig.requestReview()
    }

    class func requestReviewInScene(_ scene: AnyObject) {
        if UserDefaults.blockRatingDialogs {
            NSLog("[EeveeSpotify][RatingBlocker] Suppressed [SKStoreReviewController requestReviewInScene:]")
            return
        }
        orig.requestReviewInScene(scene)
    }
}

// Blocks UIAlertController rating / review prompts.
class UIAlertControllerRatingHook: ClassHook<UIViewController> {
    typealias Group = RatingDialogBlockerGroup
    static let targetName = "UIViewController"

    func present(
        _ viewControllerToPresent: UIViewController,
        animated flag: Bool,
        completion: (() -> Void)?
    ) {
        if UserDefaults.blockRatingDialogs,
           let alert = viewControllerToPresent as? UIAlertController {
            let title = (alert.title ?? "").lowercased()
            let msg = (alert.message ?? "").lowercased()
            let text = "\(title) \(msg)"
            let ratingTerms = [
                "rate spotify", "rate our app", "rate the app", "rate your experience",
                "star rating", "enjoying spotify", "app store review", "leave a review",
                "how would you rate", "give us feedback", "app review", "app rating",
                "оцените spotify", "оцените приложение", "оценить spotify"
            ]
            if ratingTerms.contains(where: { text.contains($0) }) {
                NSLog("[EeveeSpotify][RatingBlocker] Suppressed UIAlertController rating prompt: title=%@ msg=%@",
                      alert.title ?? "(nil)", alert.message ?? "(nil)")
                completion?()
                return
            }
        }
        orig.present(viewControllerToPresent, animated: flag, completion: completion)
    }
}

func activateRatingDialogBlocker() {
    guard UserDefaults.blockRatingDialogs else {
        NSLog("[EeveeSpotify][RatingBlocker] Disabled via settings")
        return
    }

    // Direct swizzling fallback on SKStoreReviewController metaclass to ensure suppression
    // regardless of whether StoreKit is loaded statically or dynamically.
    if let cls = NSClassFromString("SKStoreReviewController"),
       let metaCls = object_getClass(cls) {
        let sel1 = Selector(("requestReview"))
        if let m1 = class_getInstanceMethod(metaCls, sel1) {
            let block1: @convention(block) (AnyObject) -> Void = { _ in
                if UserDefaults.blockRatingDialogs {
                    NSLog("[EeveeSpotify][RatingBlocker] Runtime suppressed requestReview")
                    return
                }
            }
            method_setImplementation(m1, imp_implementationWithBlock(block1 as Any))
            NSLog("[EeveeSpotify][RatingBlocker] Swizzled +[SKStoreReviewController requestReview]")
        }

        let sel2 = Selector(("requestReviewInScene:"))
        if let m2 = class_getInstanceMethod(metaCls, sel2) {
            let block2: @convention(block) (AnyObject, AnyObject?) -> Void = { _, _ in
                if UserDefaults.blockRatingDialogs {
                    NSLog("[EeveeSpotify][RatingBlocker] Runtime suppressed requestReviewInScene:")
                    return
                }
            }
            method_setImplementation(m2, imp_implementationWithBlock(block2 as Any))
            NSLog("[EeveeSpotify][RatingBlocker] Swizzled +[SKStoreReviewController requestReviewInScene:]")
        }
    }

    RatingDialogBlockerGroup().activate()
    NSLog("[EeveeSpotify][RatingBlocker] Activated")
}
