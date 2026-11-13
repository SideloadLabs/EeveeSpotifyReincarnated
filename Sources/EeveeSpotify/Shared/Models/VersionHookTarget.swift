enum VersionHookTarget {
    case latest
    case lastAvailableiOS15
    case v91 // Spotify 9.1.x and later
    case lastAvailableiOS14

    // Every release from 9.1 on uses the 9.1 hooks; a string match on "9.1"
    // sent 9.2.0 down the pre-9.1 path, which never activates Premium.
    static func forSpotifyVersion(_ version: String) -> VersionHookTarget {
        switch version {
        case "9.0.48":
            return .lastAvailableiOS15
        case "8.9.8":
            return .lastAvailableiOS14
        default:
            break
        }

        let parts = version.split(separator: ".").map { Int($0) }
        guard parts.count >= 2, let major = parts[0], let minor = parts[1] else {
            return .latest
        }

        if major > 9 || (major == 9 && minor >= 1) {
            return .v91
        }
        return .latest
    }
}
