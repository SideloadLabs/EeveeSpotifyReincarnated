import Foundation

// MARK: - Product state on Spotify 9.2: nebula/v1/configuration/attributes
//
// Up to 9.1 it was enough to rewrite the ObjC product-state surface. On 9.2 the
// account attributes the core actually enforces arrive over HTTP, and the launch
// order is:
//
//   login5/v4/login -> login5/v3/login -> dealer websocket
//   -> nebula/v1/configuration/attributes
//   -> productStateUpdated   (73ms after nebula, 1.1s after login5)
//
// That request is conditional, and the server answers 304 on every launch after
// the first. With no body on the wire, SpotifyResponsePatcher has nothing to
// patch and the core reloads the Free attributes from its own cache about a
// second into the session - which is why seeding the ObjC objects could never
// win, and why queue, add-to-queue and on-demand track selection stayed Free
// while "Your plan" already showed Premium.
//
// The fix is to drop the cache validators on that one request so the server
// answers 200 with a real body. The body is an AccountAttributesResponse, the
// proto this repo already generates, so SpotifyResponsePatcher can rewrite it to
// Premium before the core ingests it (see rewriteAccountAttributesData).
//
// Only requests whose path is nebula/v1/configuration/attributes are touched;
// every other request is passed through to the original implementation
// unchanged. The cost is one extra non-cached response per launch.

enum NebulaAttributes {
    /// Only 9.2 and later are known to deliver product state this way, so both
    /// the request hook and the response rewrite are limited to them; 9.1.x and
    /// older keep their tested behaviour. Fixed for the life of the process.
    static let isEnabled = UserDefaults.patchType.isPatching
        && EeveeSpotify.hookTarget == .v91
        && !EeveeSpotify.spotifyVersion.hasPrefix("9.1.")

    /// A copy of `request` without the cache validators, so the server cannot
    /// answer 304 and the attributes body reaches our response hooks.
    private static func unconditional(_ request: URLRequest) -> URLRequest {
        var copy = request
        copy.setValue(nil, forHTTPHeaderField: "If-None-Match")
        copy.setValue(nil, forHTTPHeaderField: "If-Modified-Since")
        copy.cachePolicy = .reloadIgnoringLocalCacheData
        writeDebugLog("[Nebula] Stripped cache validators from \(request.url?.path ?? "?")")
        return copy
    }

    // Every data task in the process passes through here, so check the URL on
    // the NSURLRequest and only bridge to URLRequest for the one we rewrite.
    private static func rewriteIfNebula(_ request: AnyObject?) -> AnyObject? {
        guard let nsRequest = request as? NSURLRequest,
              let url = nsRequest.url,
              url.isNebulaAttributes else { return request }
        return unconditional(nsRequest as URLRequest) as NSURLRequest
    }

    /// Swaps the two NSURLSession task factories Spotify's HTTP client uses.
    /// Installed directly, ahead of the Orion hook groups, so it is in place
    /// before Spotify's first attributes request and does not depend on any
    /// group being activated.
    static func installRequestHook() {
        guard let cls: AnyClass = NSClassFromString("NSURLSession") else {
            writeDebugLog("[Nebula] Skipped: NSURLSession not found")
            return
        }

        let selector = NSSelectorFromString("dataTaskWithRequest:")
        if let method = class_getInstanceMethod(cls, selector) {
            typealias Fn = @convention(c) (AnyObject, Selector, AnyObject?) -> AnyObject?
            let original = method_getImplementation(method)
            let block: @convention(block) (AnyObject, AnyObject?) -> AnyObject? = { this, request in
                unsafeBitCast(original, to: Fn.self)(this, selector, rewriteIfNebula(request))
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }

        let completionSelector = NSSelectorFromString("dataTaskWithRequest:completionHandler:")
        if let method = class_getInstanceMethod(cls, completionSelector) {
            typealias Fn = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?) -> AnyObject?
            let original = method_getImplementation(method)
            let block: @convention(block) (AnyObject, AnyObject?, AnyObject?) -> AnyObject? = { this, request, handler in
                unsafeBitCast(original, to: Fn.self)(this, completionSelector, rewriteIfNebula(request), handler)
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }

        writeDebugLog("[Nebula] Request hook installed")
    }
}

func activateNebulaAttributes() {
    guard NebulaAttributes.isEnabled else { return }
    NebulaAttributes.installRequestHook()
}
