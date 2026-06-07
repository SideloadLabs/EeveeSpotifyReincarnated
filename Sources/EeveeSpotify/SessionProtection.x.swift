import Orion
import Foundation

// MARK: - Session Logout Protection
// Hooks all logout-related methods to prevent Spotify from logging out
// when it detects the account isn't actually premium.
// Also intercepts Ably WebSocket messages to block server-side revocation events.
// Additionally blocks network endpoints that trigger session invalidation.
// Extends OAuth token expiry to prevent internal reauth triggers.

// Split into smaller groups so missing selectors/classes don't crash on activation.
// Spotify occasionally renames/removes private session-related selectors between minor versions.
// By gating each group behind runtime checks, we keep compatibility across 9.1.x.
struct SessionLogoutAuthHookGroup: HookGroup { }
struct SessionLogoutConnectivityHookGroup: HookGroup { }
struct SessionLogoutAblyHookGroup: HookGroup { }
struct SessionLogoutNetworkHookGroup: HookGroup { }

// Ably action name mapping for readable logs
private let ablyActionNames: [Int: String] = [
    0: "heartbeat", 1: "ack", 2: "nack", 3: "connect", 4: "connected",
    5: "disconnect", 6: "disconnected", 7: "close", 8: "closed", 9: "error",
    10: "attach", 11: "attached", 12: "detach", 13: "detached",
    14: "presence", 15: "message", 16: "sync", 17: "auth"
]

// MARK: - SPTAuthSessionImplementation — Core Session Hooks

class SPTAuthSessionHook: ClassHook<NSObject> {
    typealias Group = SessionLogoutAuthHookGroup
    static let targetName = "SPTAuthSessionImplementation"

    // orion:new
    static var allowLogout = false

    func logout() {
        let elapsed = Int(Date().timeIntervalSince(tweakInitTime))
        if SPTAuthSessionHook.allowLogout {
            writeDebugLog("[AUTH] Allowed logout() at \(elapsed)s")
            orig.logout()
        } else {
            writeDebugLog("[AUTH] Blocked logout() at \(elapsed)s")
        }
    }

    func logoutWithReason(_ reason: AnyObject) {
        let elapsed = Int(Date().timeIntervalSince(tweakInitTime))
        if SPTAuthSessionHook.allowLogout {
            writeDebugLog("[AUTH] Allowed logoutWithReason at \(elapsed)s: \(reason)")
            orig.logoutWithReason(reason)
        } else {
            writeDebugLog("[AUTH] Blocked logoutWithReason at \(elapsed)s: \(reason)")
        }
    }

    func callSessionDidLogoutOnDelegateWithReason(_ reason: AnyObject) {
        let elapsed = Int(Date().timeIntervalSince(tweakInitTime))
        if SPTAuthSessionHook.allowLogout {
            orig.callSessionDidLogoutOnDelegateWithReason(reason)
        } else {
            writeDebugLog("[AUTH] Blocked callSessionDidLogoutOnDelegate at \(elapsed)s: \(reason)")
        }
    }

    func logWillLogoutEventWithLogoutReason(_ reason: AnyObject) {
        let elapsed = Int(Date().timeIntervalSince(tweakInitTime))
        if SPTAuthSessionHook.allowLogout {
            orig.logWillLogoutEventWithLogoutReason(reason)
        } else {
            writeDebugLog("[AUTH] Blocked logWillLogoutEvent at \(elapsed)s: \(reason)")
        }
    }

    func destroy() {
        let elapsed = Int(Date().timeIntervalSince(tweakInitTime))
        if SPTAuthSessionHook.allowLogout {
            orig.destroy()
        } else {
            let trace = Thread.callStackSymbols.prefix(15).joined(separator: "\n")
            writeDebugLog("[AUTH] Blocked session destroy at \(elapsed)s\n[TRACE] \(trace)")
        }
    }

    func productStateUpdated(_ state: AnyObject) {
        let elapsed = Int(Date().timeIntervalSince(tweakInitTime))
        writeDebugLog("[AUTH] productStateUpdated at \(elapsed)s -- \(state)")
        orig.productStateUpdated(state)
    }

    func tryReconnect(_ arg1: AnyObject, toAP arg2: AnyObject) {
        let elapsed = Int(Date().timeIntervalSince(tweakInitTime))
        writeDebugLog("[AUTH] tryReconnect at \(elapsed)s -- AP: \(arg2)")
        orig.tryReconnect(arg1, toAP: arg2)
    }
}

// MARK: - SessionServiceImpl (Connectivity_SessionImpl module)

class SessionServiceImplHook: ClassHook<NSObject> {
    typealias Group = SessionLogoutConnectivityHookGroup
    static let targetName = "_TtC24Connectivity_SessionImpl18SessionServiceImpl"

    func automatedLogoutThenLogin() {
        let elapsed = Int(Date().timeIntervalSince(tweakInitTime))
        writeDebugLog("[SESSION] Blocked automatedLogoutThenLogin at \(elapsed)s")
    }

    func userInitiatedLogout() {
        let elapsed = Int(Date().timeIntervalSince(tweakInitTime))
        if Thread.isMainThread {
            writeDebugLog("[SESSION] Allowed userInitiatedLogout at \(elapsed)s (main thread)")
            SPTAuthSessionHook.allowLogout = true
            orig.userInitiatedLogout()
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                SPTAuthSessionHook.allowLogout = false
            }
        } else {
            writeDebugLog("[SESSION] Blocked automated userInitiatedLogout at \(elapsed)s (bg thread)")
        }
    }

    func sessionDidLogout(_ session: AnyObject, withReason reason: AnyObject) {
        let elapsed = Int(Date().timeIntervalSince(tweakInitTime))
        if SPTAuthSessionHook.allowLogout {
            orig.sessionDidLogout(session, withReason: reason)
        } else {
            writeDebugLog("[SESSION] Blocked sessionDidLogout at \(elapsed)s: \(reason)")
        }
    }
}

// MARK: - SPTAuthLegacyLoginControllerImplementation

class LegacyLoginControllerHook: ClassHook<NSObject> {
    typealias Group = SessionLogoutAuthHookGroup
    static let targetName = "SPTAuthLegacyLoginControllerImplementation"

    func sessionDidLogout(_ session: AnyObject, withReason reason: AnyObject) {
        let elapsed = Int(Date().timeIntervalSince(tweakInitTime))
        if SPTAuthSessionHook.allowLogout {
            orig.sessionDidLogout(session, withReason: reason)
        } else {
            writeDebugLog("[LEGACY] Blocked sessionDidLogout at \(elapsed)s: \(reason)")
        }
    }

    func destroySession() {
        let elapsed = Int(Date().timeIntervalSince(tweakInitTime))
        if SPTAuthSessionHook.allowLogout {
            orig.destroySession()
        } else {
            writeDebugLog("[LEGACY] Blocked destroySession at \(elapsed)s")
        }
    }

    func forgetStoredCredentials() {
        let elapsed = Int(Date().timeIntervalSince(tweakInitTime))
        if SPTAuthSessionHook.allowLogout {
            orig.forgetStoredCredentials()
        } else {
            writeDebugLog("[LEGACY] Blocked forgetStoredCredentials at \(elapsed)s")
        }
    }

    func invalidate() {
        let elapsed = Int(Date().timeIntervalSince(tweakInitTime))
        if SPTAuthSessionHook.allowLogout {
            orig.invalidate()
        } else {
            writeDebugLog("[LEGACY] Blocked invalidate at \(elapsed)s")
        }
    }
}

// MARK: - OauthAccessTokenBridge — Extend token expiry
// This private class inside Connectivity_SessionImpl controls the OAuth token's
// expiry time. By hooking expiresAt to return a far-future date, we prevent
// the internal timer from marking the token as expired.

class OauthAccessTokenBridgeHook: ClassHook<NSObject> {
    typealias Group = SessionLogoutConnectivityHookGroup
    static let targetName = "_TtC24Connectivity_SessionImplP33_831B98CC28223E431E21CD27ADD20AF222OauthAccessTokenBridge"

    // Hook the GETTER
    func expiresAt() -> Any {
        let farFuture = Date(timeIntervalSinceNow: 365 * 24 * 60 * 60)
        return farFuture
    }

    func setExpiresAt(_ date: Any) {
        let farFuture = Date(timeIntervalSinceNow: 365 * 24 * 60 * 60)
        orig.setExpiresAt(farFuture)
    }

    // Hook init to directly modify the ivar using ObjC runtime
    // This catches cases where C++ sets the ivar without going through the ObjC setter
    func `init`() -> NSObject? {
        let result = orig.`init`()
        extendExpiryIvar()
        // Also start a repeating timer to keep extending the ivar
        startExpiryExtender()
        return result
    }

    // orion:new
    func extendExpiryIvar() {
        let bridgeClass: AnyClass = type(of: target)
        if let ivar = class_getInstanceVariable(bridgeClass, "expiresAt") {
            let farFuture = Date(timeIntervalSinceNow: 365 * 24 * 60 * 60)
            object_setIvar(target, ivar, farFuture)
        }
    }

    // orion:new
    func startExpiryExtender() {
        let weak = target
        // Extend the ivar every 60 seconds
        DispatchQueue.global(qos: .utility).async {
            while true {
                Thread.sleep(forTimeInterval: 60)
                guard let obj = weak as? NSObject else { break }
                let cls: AnyClass = type(of: obj)
                if let ivar = class_getInstanceVariable(cls, "expiresAt") {
                    let farFuture = Date(timeIntervalSinceNow: 365 * 24 * 60 * 60)
                    object_setIvar(obj, ivar, farFuture)
                }
            }
        }
    }
}



// NOTE: ColdStartupTimeKeeperImplementation is a pure Swift class (not NSObject).
// Cannot hook it with Orion — crashes with targetHasIncompatibleType.
// NOTE: executeBlockRunner on SPTAsyncNativeTimerManagerThreadImpl is too broad —
// blocking it kills ALL timers including playback advancement.

// MARK: - Ably WebSocket Transport Hooks
// Intercepts Ably real-time messages to block server-side logout/revocation events

// Blocked Ably protocol actions:
// 5=disconnect, 6=disconnected, 7=close, 8=closed, 9=error, 12=detach, 13=detached, 17=auth
private let blockedAblyActions: Set<Int> = [5, 6, 7, 8, 9, 12, 13, 17]

private func extractAblyAction(_ text: String) -> Int? {
    guard let range = text.range(of: "\"action\":") else { return nil }
    let afterAction = text[range.upperBound...]
    let digits = afterAction.prefix(while: { $0.isNumber })
    return Int(digits)
}

class ARTWebSocketTransportHook: ClassHook<NSObject> {
    typealias Group = SessionLogoutAblyHookGroup
    static let targetName = "ARTWebSocketTransport"

    func webSocket(_ ws: AnyObject, didReceiveMessage message: AnyObject) {
        if let msgString = message as? String {
            if let action = extractAblyAction(msgString) {
                let actionName = ablyActionNames[action] ?? "unknown"
                let elapsed = Int(Date().timeIntervalSince(tweakInitTime))
                if blockedAblyActions.contains(action) {
                    writeDebugLog("[ABLY] Blocked action \(action) (\(actionName)) at \(elapsed)s")
                    return
                }
                // Filter action-15 (message) payloads.
                // Spotify sends 'ap://product-state-update' Ably messages that trigger
                // a fresh re-fetch of the customize endpoint. If the re-fetched response
                // is not intercepted in time, the app re-enables ad feature flags.
                // We block these specific messages to prevent ad re-delivery after hours of use.
                if action == 15 {
                    let preview = String(msgString.prefix(300))
                    writeDebugLog("[ABLY] Message (action 15) at \(elapsed)s: \(preview)")
                    if msgString.contains("product-state-update") ||
                       msgString.contains("product_state_update") ||
                       msgString.contains("productStateUpdate") {
                        writeDebugLog("[ABLY] Blocked product-state-update message at \(elapsed)s")
                        return
                    }
                }
            }
        }
        orig.webSocket(ws, didReceiveMessage: message)
    }

    func webSocket(_ ws: AnyObject, didFailWithError error: AnyObject) {
        let elapsed = Int(Date().timeIntervalSince(tweakInitTime))
        writeDebugLog("[ABLY] Blocked WebSocket didFailWithError at \(elapsed)s: \(error)")
    }
}

// MARK: - Ably SRWebSocket Frame Hook

class ARTSRWebSocketHook: ClassHook<NSObject> {
    typealias Group = SessionLogoutAblyHookGroup
    static let targetName = "ARTSRWebSocket"

    func _handleFrameWithData(_ data: NSData, opCode code: Int) {
        if code == 1,
           let text = String(data: data as Data, encoding: .utf8) {
            if let action = extractAblyAction(text) {
                let actionName = ablyActionNames[action] ?? "unknown"
                let elapsed = Int(Date().timeIntervalSince(tweakInitTime))
                if blockedAblyActions.contains(action) {
                    writeDebugLog("[ABLY-SR] Blocked frame action \(action) (\(actionName)) at \(elapsed)s")
                    return
                }
                // Filter action-15 (message) payloads.
                // Same as ARTWebSocketTransportHook — block product-state-update messages
                // that trigger ad re-delivery after a few hours of use.
                if action == 15 {
                    let preview = String(text.prefix(300))
                    writeDebugLog("[ABLY-SR] Message (action 15) at \(elapsed)s: \(preview)")
                    if text.contains("product-state-update") ||
                       text.contains("product_state_update") ||
                       text.contains("productStateUpdate") {
                        writeDebugLog("[ABLY-SR] Blocked product-state-update message at \(elapsed)s")
                        return
                    }
                }
            }
        }
        orig._handleFrameWithData(data, opCode: code)
    }
}

// MARK: - Global URLSessionTask hook to catch auth traffic bypassing SPTDataLoaderService

class URLSessionTaskResumeHook: ClassHook<NSObject> {
    typealias Group = SessionLogoutNetworkHookGroup
    static let targetName = "NSURLSessionTask"

    // Flip to true to dump the URLSession-delegate class for every
    // premium-relevant URL — needed only when investigating a route that
    // bypasses both currently-hooked delegates.
    static let enableNetDelegateProbe = false

    func resume() {
        if let task = target as? URLSessionTask,
           let url = task.currentRequest?.url ?? task.originalRequest?.url,
           let host = url.host?.lowercased() {

            let elapsed = Date().timeIntervalSince(tweakInitTime)
            let elapsedInt = Int(elapsed)
            let path = url.path

            // DISABLED: previously cancelled subsequent bootstraps to defend against
            // session re-init wiping premium state. Broke fresh-login flow on 9.1.34
            // (first bootstrap is anonymous signup-screen, second is post-login user state).
            // Let all bootstraps through; modifyRemoteConfiguration is idempotent.
            // Diagnostic probe (off by default). Logs the URLSession-delegate
            // class for any premium-relevant URL — used to discover which
            // delegate Spotify uses for a given route. We currently hook
            // SPTDataLoaderService and HttpClientURLSession; if a future
            // build/region adds a third delegate, flip this on to find its
            // class name.
            if URLSessionTaskResumeHook.enableNetDelegateProbe {
                let isPremiumRelevantURL =
                    path.contains("bootstrap/v1/bootstrap") ||
                    path.contains("pam-view-service") ||
                    path.contains("GetYourPremiumBadge") ||
                    path.contains("GetPlanOverview") ||
                    path.contains("GetPremiumPlanRow") ||
                    path.contains("v1/customize")

                if isPremiumRelevantURL {
                    let sessionDelegate: String = {
                        if let s = task.value(forKey: "session") as? URLSession, let d = s.delegate {
                            return NSStringFromClass(type(of: d as AnyObject))
                        }
                        return "<no-session-delegate>"
                    }()
                    let tag = path.contains("bootstrap/v1/bootstrap") ? "Bootstrap" :
                              (path.contains("GetYourPremiumBadge")  ? "PAM.Badge"  :
                              (path.contains("GetPlanOverview")      ? "PAM.PlanOverview" :
                              (path.contains("GetPremiumPlanRow")    ? "PAM.PlanRow" :
                              (path.contains("pam-view-service")     ? "PAM.Other" : "Customize"))))
                    writeDebugLog("[NET][\(tag)] host=\(host) path=\(path) at \(elapsedInt)s sessDelegate=\(sessionDelegate)")
                }
            }

            // Log auth-related requests for diagnostics
            let isAuthRelated = host.contains("login5") ||
                host.contains("apresolve") ||
                (host.contains("googleapis.com") && path.contains("/token")) ||
                path.contains("bootstrap/v1/bootstrap") ||
                path.contains("DeleteToken") ||
                path.contains("signup/public") ||
                path.contains("pses/screenconfig") ||
                path.contains("logout") ||
                path.contains("sign-out") ||
                path.contains("session/purge") ||
                path.contains("token/revoke") ||
                path.contains("auth/expire") ||
                path.contains("product-state") ||
                path.contains("melody") ||
                path.contains("auth/v1")

            if isAuthRelated {
                let method = task.currentRequest?.httpMethod ?? "?"
                writeDebugLog("[NET] Auth request: \(method) \(host)\(path) at \(elapsedInt)s")
            }

            // NOTE: Do NOT block login5 or googleapis.com/token.
            // login5 re-auths every ~3 min; blocking it causes a crash/panic loop.
            // Logout protection comes from blocking session destroy, DeleteToken, etc. below.

            // Block outgoing DeleteToken/signup requests at network level
            // Only block after initial startup (30s) to allow fresh login/signup
            if host.contains("spotify") || host.contains("spclient") {
                if elapsed > 30 && path.contains("DeleteToken") {
                    writeDebugLog("[NET] Cancelled DeleteToken at \(elapsedInt)s")
                    task.cancel()
                    return
                }
                if elapsed > 30 && path.contains("signup/public") {
                    writeDebugLog("[NET] Cancelled signup/public at \(elapsedInt)s")
                    task.cancel()
                    return
                }
                if elapsed > 30 && path.contains("pses/screenconfig") {
                    writeDebugLog("[NET] Cancelled pses/screenconfig at \(elapsedInt)s")
                    task.cancel()
                    return
                }
                // (Bootstrap is logged by the premium-relevant probe above —
                // dropped duplicate "(late)" log to keep output clean.)
                // Block periodic re-fetches of the customize endpoint.
                // Spotify's RemoteConfigurationSDK AuthFetcher re-fetches the customize
                // endpoint after minimumFetchIntervalSeconds (typically a few hours).
                // This re-fetch can bypass the DataLoaderService hook if it uses a
                // background URLSession, causing ads to reappear.
                // We block re-fetches after the initial 30s startup window.
                if elapsed > 30 && path.contains("v1/customize") {
                    writeDebugLog("[NET] Cancelled customize re-fetch at \(elapsedInt)s")
                    task.cancel()
                    return
                }
                if elapsed > 30 && host.contains("apresolve") {
                    writeDebugLog("[NET] Cancelled apresolve at \(elapsedInt)s")
                    task.cancel()
                    return
                }
            }
        }
        orig.resume()
    }
}


