import Orion
import Foundation

// HUB JSON component structure (from open-source HubFramework):
// Each component dict has:
//   "component": {"namespace": "mobile", "name": "display-ad-card"}
//     — OR in some versions just a string "mobile:display-ad-card"
//   "id": "some-identifier"
//   "metadata": {...}
//   "logging": {...}
//   "body": [...] (child components)
//   "header": {...}
//   "overlays": [...]
//   "sections": [...]
//
// Known ad component identifiers found in Spotify 9.1.x binary:
//   mobile-display-ad-card          (namespace: mobile, name: display-ad-card)
//   mobile-ads-display-ad-element   (namespace: mobile-ads, name: display-ad-element)
//   mobile-ads-fullbleed-display-card
//   mobile-ads-embedded-npv-display-card
//   native-ad-home-shelf
//   com.spotify.service.marquee

// Strips ad components from HUB JSON (home/browse/search) before the builder
// renders them. Known ad ids: mobile-display-ad-card, mobile-ads-display-ad-element,
// mobile-ads-fullbleed-display-card, native-ad-home-shelf, com.spotify.service.marquee.

struct AdBlockerGroup: HookGroup { }

class HubsAdBlocker: ClassHook<NSObject> {
    typealias Group = AdBlockerGroup
    static let targetName: String = "HUBViewModelBuilderImplementation"

    // Bare "ad"/"ads" intentionally absent: as substrings they hit real shelf ids
    // (made-for-you, release-radar). Matched only against structural fields, never titles.
    private static let hardAdKeywords: [String] = [
        "sponsored", "upsell", "campaign", "promoted", "premium-upsell",
        "billboard", "interstitial", "marquee",
        "leavebehind", "leave-behind", "displayad", "display-ad", "fullbleed",
        "full-bleed", "leaderboard", "advertisement", "sponsor", "native-ad",
        "mobile-ads", "on-surface", "onsurface", "search-ad", "home-ad",
        "sponsored-content", "sponsored-ad", "ad-card", "native-ad-home-shelf",
        "sponsored-shelf", "sponsored-row", "ad-shelf", "ad-row", "sponsored-item",
        "ad-item", "upgrade-component",
        "mobile-display-ad-card", "mobile-ads-display-ad-element"
    ]

    private static let promotionalIntentKeywords: [String] = [
        "premium", "upgrade", "offer", "marketing", "promo", "promotion",
        "subscribe", "subscription",
    ]

    private static let promotionalSurfaceKeywords: [String] = [
        "banner", "card", "popup", "pop-up", "sheet", "overlay", "component",
        "message",
    ]

    private static func containsAdKeyword(_ str: String) -> Bool {
        let lower = str.lowercased()
        if hardAdKeywords.contains(where: { lower.contains($0) }) { return true }
        let hasPromotionalIntent = promotionalIntentKeywords.contains { lower.contains($0) }
        let hasPromotionalSurface = promotionalSurfaceKeywords.contains { lower.contains($0) }
        return hasPromotionalIntent && hasPromotionalSurface
    }

    private func isAdComponent(_ component: [String: Any]) -> Bool {
        if let componentDict = component["component"] as? [String: Any] {
            let ns = componentDict["namespace"] as? String ?? ""
            let name = componentDict["name"] as? String ?? ""
            if HubsAdBlocker.containsAdKeyword(ns) { return true }
            if HubsAdBlocker.containsAdKeyword(name) { return true }
            if HubsAdBlocker.containsAdKeyword("\(ns):\(name)") { return true }
        }
        // plain string form, e.g. "mobile:display-ad-card"
        if let componentStr = component["component"] as? String {
            if HubsAdBlocker.containsAdKeyword(componentStr) { return true }
        }

        if let id = component["id"] as? String, HubsAdBlocker.containsAdKeyword(id) { return true }
        if let type_ = component["type"] as? String, HubsAdBlocker.containsAdKeyword(type_) { return true }

        if let metadata = component["metadata"] as? [String: Any] {
            if metadata["ad"] as? Bool == true { return true }
            if metadata["is_ad"] as? Bool == true { return true }
            if metadata["is_sponsored"] as? Bool == true { return true }
            for key in metadata.keys where HubsAdBlocker.containsAdKeyword(key) { return true }
        }

        if let logging = component["logging"] as? [String: Any] {
            if let logType = logging["type"] as? String, HubsAdBlocker.containsAdKeyword(logType) { return true }
            for key in logging.keys where HubsAdBlocker.containsAdKeyword(key) { return true }
        }

        if let custom = component["custom"] as? [String: Any] {
            for key in custom.keys where HubsAdBlocker.containsAdKeyword(key) { return true }
        }

        // Display strings (title/subtitle/text) are NOT matched — real content
        // ("Billboard Hot 100", "Ticket to Ride") trips the keywords.
        return false
    }

    private func filterComponents(_ components: [[String: Any]]) -> [[String: Any]] {
        var result = [[String: Any]]()
        for var component in components {
            if isAdComponent(component) {
                continue
            }
            if let children = component["children"] as? [[String: Any]] {
                component["children"] = filterComponents(children)
            }
            if let rows = component["rows"] as? [[String: Any]] {
                component["rows"] = filterComponents(rows)
            }
            if let body = component["body"] as? [[String: Any]] {
                component["body"] = filterComponents(body)
            }
            result.append(component)
        }
        return result
    }

    func addJSONDictionary(_ dictionary: NSDictionary?) {
        guard var mutableDict = dictionary as? [String: Any] else {
            orig.addJSONDictionary(dictionary)
            return
        }

        // Filter top-level "body" array
        if let body = mutableDict["body"] as? [[String: Any]] {
            mutableDict["body"] = filterComponents(body)
        }

        // Filter "header" component
        if var header = mutableDict["header"] as? [String: Any] {
            if isAdComponent(header) {
                mutableDict.removeValue(forKey: "header")
            } else {
                if let children = header["children"] as? [[String: Any]] {
                    header["children"] = filterComponents(children)
                }
                mutableDict["header"] = header
            }
        }

        // Filter "overlays" array
        if let overlays = mutableDict["overlays"] as? [[String: Any]] {
            mutableDict["overlays"] = filterComponents(overlays)
        }

        // Filter "sections" array (used in some page types)
        if let sections = mutableDict["sections"] as? [[String: Any]] {
            mutableDict["sections"] = filterComponents(sections)
        }

        orig.addJSONDictionary(mutableDict as NSDictionary)
    }
}
