import Foundation

private struct SpotifyVersion: Comparable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ version: String) {
        let parts = version.split(separator: ".")
        guard parts.count >= 3,
              let major = Int(parts[0]),
              let minor = Int(parts[1]),
              let patch = Int(parts[2]) else {
            return nil
        }

        self.major = major
        self.minor = minor
        self.patch = patch
    }

    static func < (lhs: SpotifyVersion, rhs: SpotifyVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

enum BundledConfigurationPolicy {
    static let legacyResourceName = "resolveconfiguration"
    static let spotify9176ResourceName = "resolveconfiguration_9_1_76"
    private static let minimumVersionForSpotify9176Configuration = SpotifyVersion("9.1.76")!

    static func resourceName(for spotifyVersion: String) -> String {
        guard let currentVersion = SpotifyVersion(spotifyVersion) else {
            return legacyResourceName
        }

        return currentVersion < minimumVersionForSpotify9176Configuration
            ? legacyResourceName
            : spotify9176ResourceName
    }
}
