import Foundation
#if canImport(UIKit)
import UIKit
#endif

// Only named retained fields are read. No raw offsets, KVC, selector guesses,
// player state, or private Swift runtime ABI are used.
enum SAPNativeShareCore {
    struct Values { let uri: String; let ui: Any; let dependencies: Any; let data: Any }
    static func unwrapped(_ value: Any) -> Any? {
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional else { return value }
        guard let child = mirror.children.first else { return nil }
        return unwrapped(child.value)
    }
    static func child(_ value: Any, _ name: String) -> Any? {
        guard let value = unwrapped(value) else { return nil }
        var mirror: Mirror? = Mirror(reflecting: value)
        while let current = mirror {
            if let found = current.children.first(where: { $0.label == name }) {
                return unwrapped(found.value)
            }
            mirror = current.superclassMirror
        }
        return nil
    }
    static func canonicalURI(_ text: String) -> String? {
        var kind: String, identifier: String
        // Track rows in playlists and Liked Songs share "spotify:track:ID?context=spotify:playlist:ID&rowId=...".
        var text = text
        if text.hasPrefix("spotify:"), let cut = text.firstIndex(where: { $0 == "?" || $0 == "#" }) { text = String(text[..<cut]) }
        let pieces = text.split(separator: ":", omittingEmptySubsequences: false)
        if pieces.count == 3 && pieces[0] == "spotify" {
            kind = String(pieces[1]); identifier = String(pieces[2])
        } else {
            guard let url = URLComponents(string: text), url.scheme == "https",
                  url.host == "open.spotify.com", url.user == nil, url.password == nil,
                  url.port == nil else { return nil }
            let path = url.path.split(separator: "/")
            guard path.count == 2 else { return nil }
            kind = String(path[0]); identifier = String(path[1])
        }
        guard kind == "track" || kind == "album", identifier.utf8.count == 22,
              identifier.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else { return nil }
        return "spotify:\(kind):\(identifier)"
    }
    static func values(_ root: Any) -> Values? {
        guard let element = child(root, "elementView"), let erased = child(element, "elementUI"),
              let ui = child(erased, "ui"), let dependencies = child(ui, "dependencies"),
              let data = child(dependencies, "shareMenuData"),
              let url = child(data, "spotifyURI") as? URL,
              let uri = canonicalURI(url.absoluteString) else { return nil }
        if let entity = child(dependencies, "entityURI") {
            guard let entityURL = entity as? URL, canonicalURI(entityURL.absoluteString) == uri else { return nil }
        }
        return Values(uri: uri, ui: ui, dependencies: dependencies, data: data)
    }
    static func sectionValues(_ ui: Any) -> [String: Any]? {
        guard let dictionary = child(ui, "actionElementViews") else { return nil }
        let mirror = Mirror(reflecting: dictionary)
        guard mirror.displayStyle == .dictionary, mirror.children.count <= 8 else { return nil }
        var result: [String: Any] = [:]
        for entry in mirror.children {
            guard let key = child(entry.value, "key"), let lazy = child(entry.value, "value"),
                  Mirror(reflecting: key).displayStyle == .enum else { return nil }
            let name = String(describing: key)
            guard name == "onPlatform" || name == "offPlatform" else { return nil }
            if let box = child(lazy, "elementViewBox"), let view = child(box, "elementView") { result[name] = view }
        }
        guard result["onPlatform"] != nil, result["offPlatform"] != nil else { return nil }
        return result
    }
    static func handoffIsCurrent(expires: TimeInterval, now: TimeInterval, generation: UInt, captured: UInt, enabled: Bool) -> Bool {
        enabled && generation == captured && now < expires
    }
    private static let shareURLs = try! NSRegularExpression(pattern: "spotify:(?:track|album):[A-Za-z0-9]{22}(?![A-Za-z0-9])|https://open\\.spotify\\.com/(?:track|album)/[A-Za-z0-9]{22}(?![A-Za-z0-9])")
    static func matchesPayload(_ payload: Any, uri: String) -> Bool {
        guard canonicalURI(uri) == uri else { return false }
        var remaining = 64
        func match(_ value: Any, depth: Int) -> Bool {
            remaining -= 1
            guard remaining >= 0, depth <= 5 else { return false }
            if let url = value as? URL { return match(url.absoluteString, depth: depth + 1) }
            if let data = value as? Data, data.count <= 16384, let text = String(data: data, encoding: .utf8) { return match(text, depth: depth + 1) }
            if var text = value as? String {
                guard text.utf8.count <= 16384 else { return false }
                for _ in 0..<3 {
                    let range = NSRange(text.startIndex..., in: text)
                    for found in shareURLs.matches(in: text, range: range) {
                        if let r = Range(found.range, in: text), canonicalURI(String(text[r])) == uri { return true }
                    }
                    guard let decoded = text.removingPercentEncoding, decoded != text else { break }
                    text = decoded
                }
                return false
            }
            if let array = value as? [Any], array.count <= 32 { return array.contains { match($0, depth: depth + 1) } }
            if let dictionary = value as? [AnyHashable: Any], dictionary.count <= 32 { return dictionary.values.contains { match($0, depth: depth + 1) } }
            return false
        }
        return match(payload, depth: 0)
    }
}

#if canImport(UIKit)
@objc(SAPNativeShareBridge)
final class SAPNativeShareBridge: NSObject {
    @objc(handoffExpires:now:generation:captured:enabled:)
    static func handoff(expires: Double, now: Double, generation: UInt, captured: UInt, enabled: Bool) -> Bool {
        SAPNativeShareCore.handoffIsCurrent(expires: expires, now: now, generation: generation, captured: captured, enabled: enabled)
    }
    @objc(matchesPayload:uri:)
    static func matches(_ payload: Any, uri: String) -> Bool { SAPNativeShareCore.matchesPayload(payload, uri: uri) }
    @objc(bindingForController:)
    static func binding(for controller: UIViewController) -> NSDictionary? {
        guard Thread.isMainThread else { return nil }
        let name = String(reflecting: type(of: controller))
        guard name == "Share_MenuImpl.NativeShareMenuViewController" || name == "Share_MenuImpl.LegacyShareMenuViewController",
              let values = SAPNativeShareCore.values(controller),
              String(reflecting: type(of: values.ui)) == "Share_MenuImpl.ShareMenuElementUI",
              String(reflecting: type(of: values.dependencies)) == "Share_MenuImpl.ShareMenuElementDependencies",
              String(reflecting: type(of: values.data)) == "Share_ShareFormatsAPI.ShareMenuData",
              let stack = SAPNativeShareCore.child(values.ui, "contentStackView") as? UIStackView,
              let sections = SAPNativeShareCore.child(values.ui, "sectionsStackView") as? UIStackView,
              stack !== sections, stack.isDescendant(of: controller.view),
              sections.isDescendant(of: stack) else { return nil }
        var binding: [String: Any] = ["uri": values.uri, "stack": stack, "sections": sections]
        if let dictionary = SAPNativeShareCore.child(values.ui, "actionElementViews") {
            for entry in Mirror(reflecting: dictionary).children {
                guard let key = SAPNativeShareCore.child(entry.value, "key"), String(reflecting: type(of: key)) == "Share_ShareMenuElementsAPI.ActionSection" else { return nil }
            }
        }
        guard let views = SAPNativeShareCore.sectionValues(values.ui),
              views["onPlatform"] != nil, views["offPlatform"] != nil else { return nil }
        do {
            for (name, value) in views {
                guard let view = value as? UIView, view !== sections, view.isDescendant(of: sections) else { return nil }
                binding[name] = view
            }
        }
        return binding as NSDictionary
    }
}
#endif
