import Orion
import UIKit

enum CleanShareLinks {
    private static let spotifyShareURLPattern = #"https?://(?:[a-z0-9-]+\.)*open\.spotify\.com/[^\s"<>]+"#
    private static let spotifyShareURLRegex = try! NSRegularExpression(
        pattern: spotifyShareURLPattern,
        options: [.caseInsensitive]
    )

    /// Returns a copy of the URL with Spotify's `si` tracking parameter
    /// (and any `utm_*` marketing parameters) removed.
    static func cleanedURL(from url: URL) -> URL {
        guard UserDefaults.cleanShareLinks,
              let host = url.host?.lowercased(),
              host == "open.spotify.com" || host.hasSuffix(".open.spotify.com"),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.percentEncodedQueryItems, !items.isEmpty
        else {
            return url
        }

        // percentEncodedQueryItems preserves the original query encoding
        // (e.g. `context=spotify%3Aalbum%3A...`) instead of re-encoding it.
        let cleanedItems = items.filter { item in
            let name = item.name.lowercased()
            return name != "si" && !name.hasPrefix("utm_")
        }

        guard cleanedItems.count != items.count else { return url }

        components.percentEncodedQueryItems = cleanedItems.isEmpty ? nil : cleanedItems
        return components.url ?? url
    }

    /// Returns a copy of the string with any Spotify share links cleaned.
    static func cleanedString(from string: String) -> String {
        guard UserDefaults.cleanShareLinks else { return string }

        let nsString = string as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        var replacements: [(NSRange, String)] = []

        for match in spotifyShareURLRegex.matches(in: string, options: [], range: fullRange) {
            let urlString = nsString.substring(with: match.range)
            guard let url = URL(string: urlString) else { continue }

            let cleanedURLString = cleanedURL(from: url).absoluteString
            if cleanedURLString != urlString {
                replacements.append((match.range, cleanedURLString))
            }
        }

        guard !replacements.isEmpty else { return string }

        var result = string
        for (range, replacement) in replacements.reversed() {
            result = (result as NSString).replacingCharacters(in: range, with: replacement)
        }
        return result
    }

    static func cleanedActivityItem(_ item: Any) -> Any {
        if let url = item as? URL {
            return cleanedURL(from: url)
        }
        if let string = item as? String {
            return cleanedString(from: string)
        }
        return item
    }

    // MARK: - Deep link cleaning

    /// Returns a copy of the URL being opened by the system with any Spotify share
    /// links embedded in it cleaned of tracking parameters.
    ///
    /// The in-app share sheet's direct-destination buttons (Instagram Stories,
    /// WhatsApp, Telegram, Messenger, …) hand the Spotify share URL to another app
    /// through a deep link instead of the pasteboard or the share sheet, e.g.
    ///
    ///     whatsapp://send?text=...https://open.spotify.com/track/...?si=...
    ///     instagram-stories://share?source_application=...&content_url=...%3Fsi%3D...
    ///
    /// Hooking `UIApplication.openURL` lets us clean the Spotify URL right before
    /// it leaves the process.
    static func cleanedDeepLinkURL(_ url: URL) -> URL {
        guard UserDefaults.cleanShareLinks else { return url }

        // The URL being opened is itself a Spotify share link.
        if let host = url.host?.lowercased(),
           host == "open.spotify.com" || host.hasSuffix(".open.spotify.com") {
            return cleanedURL(from: url)
        }

        // Clean Spotify URLs embedded in query-item values. URLComponents
        // percent-decodes each value, so the regex can find the plain
        // `https://...?si=...` form; assigning back re-encodes the values.
        // Note: only the changed values trigger a rebuild, and receivers like
        // WhatsApp/Instagram decode query strings leniently, so the re-encoding
        // of untouched items (`+` -> `%20`, `%3F` -> `?`) is semantically safe.
        if var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let items = components.queryItems, !items.isEmpty {
            var changed = false
            let cleanedItems = items.map { item -> URLQueryItem in
                guard let value = item.value else { return item }
                let cleaned = cleanedString(from: value)
                if cleaned != value { changed = true }
                return URLQueryItem(name: item.name, value: cleaned)
            }
            if changed {
                components.queryItems = cleanedItems
                if let rebuilt = components.url {
                    return rebuilt
                }
            }
        }

        // Fallback for payloads URLComponents can't parse (e.g. a raw, unencoded
        // Spotify URL in the query): clean any Spotify URLs in the raw string.
        let raw = url.absoluteString
        let cleanedRaw = cleanedString(from: raw)
        return cleanedRaw == raw ? url : (URL(string: cleanedRaw) ?? url)
    }

    // MARK: - Pasteboard value cleaning

    static func cleanPasteboardItems(_ items: [[String: Any]]) -> [[String: Any]] {
        items.map { item in
            item.mapValues { value in cleanedValue(value) }
        }
    }

    static func cleanedValue(_ value: Any) -> Any {
        if let url = value as? URL {
            return cleanedURL(from: url)
        }
        if let string = value as? String {
            return cleanedString(from: string)
        }
        if let data = value as? Data {
            return cleanedData(data) ?? data
        }
        if let urls = value as? [URL] {
            return urls.map { cleanedURL(from: $0) }
        }
        if let strings = value as? [String] {
            return strings.map { cleanedString(from: $0) }
        }
        return value
    }

    /// Cleans pasteboard data written through `setData:forPasteboardType:`.
    ///
    /// Handles both representations of a URL pasteboard type:
    /// 1. The raw URL string (UTF-8), used by `public.utf8-plain-text` and `public.url`.
    /// 2. A keyed-archived `NSURL` object.
    static func cleanedData(_ data: Data?) -> Data? {
        guard let data = data else { return nil }

        // Plain-text representation.
        if let string = String(data: data, encoding: .utf8) {
            let cleaned = cleanedString(from: string)
            return cleaned == string ? data : cleaned.data(using: .utf8)
        }

        // Keyed-archived NSURL.
        if let url = unarchiveURL(from: data) {
            let cleaned = cleanedURL(from: url)
            if cleaned != url {
                // Prefer a secure-coded archive so consumers that unarchive with
                // `requiringSecureCoding: true` still succeed.
                if let rearchived = try? NSKeyedArchiver.archivedData(
                    withRootObject: cleaned as NSURL,
                    requiringSecureCoding: true
                ) {
                    return rearchived
                }
                if let rearchived = try? NSKeyedArchiver.archivedData(
                    withRootObject: cleaned as NSURL,
                    requiringSecureCoding: false
                ) {
                    return rearchived
                }
            }
        }

        return data
    }

    private static func unarchiveURL(from data: Data) -> URL? {
        if let url = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSURL.self, from: data) {
            return url as URL
        }
        if let object = try? NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data),
           let url = object as? URL {
            return url
        }
        return nil
    }
}

/// Cleans Spotify share links written to the pasteboard through the base-class API.
class UIPasteboardCleanShareLinksHook: ClassHook<UIPasteboard> {
    func setURL(_ url: URL?) {
        orig.setURL(url.map { CleanShareLinks.cleanedURL(from: $0) })
    }

    func setURLs(_ urls: [URL]?) {
        orig.setURLs(urls?.map { CleanShareLinks.cleanedURL(from: $0) })
    }

    func setString(_ string: String?) {
        orig.setString(string.map { CleanShareLinks.cleanedString(from: $0) })
    }

    func setStrings(_ strings: [String]?) {
        orig.setStrings(strings?.map { CleanShareLinks.cleanedString(from: $0) })
    }

    func setItems(_ items: [[String: Any]], options: [UIPasteboard.OptionsKey: Any]) {
        orig.setItems(CleanShareLinks.cleanPasteboardItems(items), options: options)
    }

    func addItems(_ items: [[String: Any]]) {
        orig.addItems(CleanShareLinks.cleanPasteboardItems(items))
    }

    func setValue(_ value: Any?, forPasteboardType pasteboardType: String) {
        orig.setValue(value.map { CleanShareLinks.cleanedValue($0) }, forPasteboardType: pasteboardType)
    }

    func setData(_ data: Data?, forPasteboardType pasteboardType: String) {
        orig.setData(CleanShareLinks.cleanedData(data), forPasteboardType: pasteboardType)
    }
}

/// Cleans Spotify share links passed to the system share sheet.
class UIActivityViewControllerCleanShareLinksHook: ClassHook<UIActivityViewController> {
    func initWithActivityItems(_ activityItems: [Any], applicationActivities: [UIActivity]?) -> Target {
        let cleanedItems = activityItems.map { CleanShareLinks.cleanedActivityItem($0) }
        return orig.initWithActivityItems(cleanedItems, applicationActivities: applicationActivities)
    }
}

/// Cleans Spotify share links inside deep links the app opens.
///
/// The in-app share sheet's direct-destination buttons (Instagram, WhatsApp, …)
/// bypass the pasteboard and the share sheet by handing the Spotify share URL to
/// another app through a URL scheme, so we intercept it at the `UIApplication`
/// boundary. Same hook point as `UIApplicationLiveContainerSharingHook`; both are
/// in Orion's DefaultGroup and coexist fine.
class UIApplicationCleanShareLinksHook: ClassHook<UIApplication> {
    func openURL(
        _ url: URL,
        options: [String: Any],
        completionHandler: (@MainActor (ObjCBool) -> Void)?
    ) {
        orig.openURL(
            CleanShareLinks.cleanedDeepLinkURL(url),
            options: options,
            completionHandler: completionHandler
        )
    }
}

/// Manually swizzles the concrete class returned by `UIPasteboard.general`.
///
/// `UIPasteboard.general` is backed by a private subclass (e.g.
/// `UIPasteboardAutomaticPasteboard`) that can override the setter methods with its
/// own daemon-backed implementations. Messages then dispatch to that subclass's
/// implementation and never reach the `ClassHook<UIPasteboard>` swizzles above, so
/// we also replace the implementations directly on the concrete class. Between the
/// two layers, every setter the instance responds to is intercepted.
enum PasteboardConcreteSwizzler {
    private static var installed = false

    static func install() {
        // Tweak.x.swift can re-init within the same process; only swizzle once.
        guard !installed else { return }
        installed = true

        let concrete: AnyClass = object_getClass(UIPasteboard.general)!
        let base: AnyClass = UIPasteboard.self

        // The `as AnyObject` casts bridge Swift value types to the ObjC `id` the
        // swizzled IMPs deal in.
        swizzleOneArg(concrete, base, "setString:") { value in
            guard let string = value as? String else { return value }
            return CleanShareLinks.cleanedString(from: string) as AnyObject
        }
        swizzleOneArg(concrete, base, "setStrings:") { value in
            guard let strings = value as? [String] else { return value }
            return strings.map { CleanShareLinks.cleanedString(from: $0) } as AnyObject
        }
        swizzleOneArg(concrete, base, "setURL:") { value in
            guard let url = value as? URL else { return value }
            return CleanShareLinks.cleanedURL(from: url) as AnyObject
        }
        swizzleOneArg(concrete, base, "setURLs:") { value in
            guard let urls = value as? [URL] else { return value }
            return urls.map { CleanShareLinks.cleanedURL(from: $0) } as AnyObject
        }
        swizzleOneArg(concrete, base, "addItems:") { value in
            guard let items = value as? [[String: Any]] else { return value }
            return CleanShareLinks.cleanPasteboardItems(items) as AnyObject
        }

        swizzleTwoArgs(concrete, base, "setValue:forPasteboardType:") { value, _ in
            guard let value = value else { return nil }
            return CleanShareLinks.cleanedValue(value) as AnyObject
        }
        swizzleTwoArgs(concrete, base, "setData:forPasteboardType:") { value, _ in
            guard let data = value as? Data else { return value }
            return (CleanShareLinks.cleanedData(data) ?? data) as AnyObject
        }
        swizzleTwoArgs(concrete, base, "setItems:options:") { value, _ in
            guard let items = value as? [[String: Any]] else { return value }
            return CleanShareLinks.cleanPasteboardItems(items) as AnyObject
        }

        NSLog("[EeveeSpotify][CleanShareLinks] pasteboard concrete-class swizzles installed on %s",
              class_getName(concrete))
    }

    /// Replaces a one-argument setter (`void (id, SEL, id)`) on the concrete class,
    /// but only when the concrete class declares its own implementation rather than
    /// inheriting the base one (inherited methods are already covered by the
    /// `ClassHook<UIPasteboard>` swizzles).
    private static func swizzleOneArg(
        _ concrete: AnyClass,
        _ base: AnyClass,
        _ selectorName: String,
        _ clean: @escaping (AnyObject?) -> AnyObject?
    ) {
        let sel = NSSelectorFromString(selectorName)
        guard let own = class_getInstanceMethod(concrete, sel),
              let baseMethod = class_getInstanceMethod(base, sel),
              method_getImplementation(own) != method_getImplementation(baseMethod)
        else { return }

        let origIMP = method_getImplementation(own)
        // Note: `AnyObject?` (== ObjC `id`) rather than `Any?` — `Any` is an
        // existential container in the Swift ABI, while the ObjC runtime calls the
        // swizzled IMP with a single object pointer per the method's `@` encoding.
        let block: @convention(block) (AnyObject, AnyObject?) -> Void = { target, value in
            typealias OrigFn = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
            unsafeBitCast(origIMP, to: OrigFn.self)(target, sel, clean(value))
        }
        method_setImplementation(own, imp_implementationWithBlock(block as Any))
        NSLog("[EeveeSpotify][CleanShareLinks] swizzled %@ on %s",
              NSStringFromSelector(sel), class_getName(concrete))
    }

    /// Same as `swizzleOneArg` for two-argument setters (`void (id, SEL, id, id)`);
    /// the second argument is passed through untouched.
    private static func swizzleTwoArgs(
        _ concrete: AnyClass,
        _ base: AnyClass,
        _ selectorName: String,
        _ clean: @escaping (AnyObject?, AnyObject?) -> AnyObject?
    ) {
        let sel = NSSelectorFromString(selectorName)
        guard let own = class_getInstanceMethod(concrete, sel),
              let baseMethod = class_getInstanceMethod(base, sel),
              method_getImplementation(own) != method_getImplementation(baseMethod)
        else { return }

        let origIMP = method_getImplementation(own)
        let block: @convention(block) (AnyObject, AnyObject?, AnyObject?) -> Void = { target, first, second in
            typealias OrigFn = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?) -> Void
            unsafeBitCast(origIMP, to: OrigFn.self)(target, sel, clean(first, second), second)
        }
        method_setImplementation(own, imp_implementationWithBlock(block as Any))
        NSLog("[EeveeSpotify][CleanShareLinks] swizzled %@ on %s",
              NSStringFromSelector(sel), class_getName(concrete))
    }
}
