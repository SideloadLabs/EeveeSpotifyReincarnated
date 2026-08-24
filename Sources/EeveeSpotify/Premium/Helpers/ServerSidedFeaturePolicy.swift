import Foundation

struct ServerSidedFeaturePolicy {
    struct RemoteFlag: Equatable {
        let scope: String
        let name: String
    }

    // These values are real account entitlements. Spoofing them only exposes
    // incomplete UI; Spotify's backend still rejects the operation.
    static let serverAuthoritativeAccountAttributes: Set<String> = [
        "offline",
        "can-use-offline",
        "has-offline-state",
        "max-offline-downloads-per-device",
        "max-offline-tracks",
        "offline-backup",
        "lyrics-offline",
        "very-high-bitrate",
        "audio-quality",
        "social-session",
        "social-session-free-tier",
        "jam-social-session",
    ]

    // Hide only remote/Premium Jam hosting. Spotify's separate in-person join
    // and free-user hosting flag remains controlled by the live configuration.
    static let premiumGatedJamEntryPoint = RemoteFlag(
        scope: "ios-sociallistening-configuration-impl",
        name: "premium_gated_start_jam_buttons_enabled"
    )

    static func shouldOverwriteResolvedConfiguration(requested: Bool) -> Bool {
        requested
    }
}
