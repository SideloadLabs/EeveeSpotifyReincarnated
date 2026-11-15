enum VersionHookTarget {
    case latest
    case lastAvailableiOS15
    case v91 // Spotify 9.1.x versions
    case lastAvailableiOS14

    // Spotify 9.2 dropped the UCS bootstrap/customize client from the app layer.
    // The product-state dictionary handed to SPTCoreProductState is the one
    // remaining place to force Premium values locally, so rewrite it from 9.2 on.
    // The pinned older builds keep the response-patching path untouched.
    static func requiresProductStateDictRewrite(_ version: String) -> Bool {
        switch version {
        case "9.0.48", "8.9.8":
            return false
        default:
            break
        }

        let parts = version.split(separator: ".").map { Int($0) }
        guard parts.count >= 2, let major = parts[0], let minor = parts[1] else {
            return true
        }

        return major > 9 || (major == 9 && minor >= 2)
    }
}
