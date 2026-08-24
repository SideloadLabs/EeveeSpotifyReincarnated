import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fatalError("FAIL: \(message)")
    }
}

let protectedAttributes = ServerSidedFeaturePolicy.serverAuthoritativeAccountAttributes
for name in [
    "offline",
    "audio-quality",
    "social-session",
    "social-session-free-tier",
    "jam-social-session",
] {
    require(protectedAttributes.contains(name), "missing server-authoritative attribute: \(name)")
}

require(
    ServerSidedFeaturePolicy.shouldOverwriteResolvedConfiguration(
        requested: true
    ),
    "explicit overwrite must use the version-selected bundled configuration"
)
require(
    !ServerSidedFeaturePolicy.shouldOverwriteResolvedConfiguration(
        requested: false
    ),
    "disabled overwrite must retain the live configuration"
)

require(
    ServerSidedFeaturePolicy.premiumGatedJamEntryPoint == .init(
        scope: "ios-sociallistening-configuration-impl",
        name: "premium_gated_start_jam_buttons_enabled"
    ),
    "Premium-gated Jam entry point changed unexpectedly"
)

print("Server-sided feature policy tests passed")
