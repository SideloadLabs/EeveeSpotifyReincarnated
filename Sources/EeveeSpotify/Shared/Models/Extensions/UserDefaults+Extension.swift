import Foundation

extension UserDefaults {
    static var container: UserDefaults = .standard
    
    private static let musixmatchTokenKey = "musixmatchToken"
    private static let darkPopUpsKey = "darkPopUps"
    private static let patchTypeKey = "patchType"
    private static let trueShuffleEnabledKey = "trueShuffleEnabled"
    private static let overwriteConfigurationKey = "overwriteConfiguration"
    private static let lyricsColorsKey = "lyricsColors"
    private static let lyricsOptionsKey = "lyricsOptions"
    private static let hasShownCommonIssuesTipKey = "hasShownCommonIssuesTip"
    private static let hasPatchedBootstrapKey = "eeveeHasPatchedBootstrap"

    static var musixmatchToken: String {
        get {
            container.string(forKey: musixmatchTokenKey) ?? ""
        }
        set (token) {
            container.set(token, forKey: musixmatchTokenKey)
        }
    }

    static var darkPopUps: Bool {
        get {
            container.object(forKey: darkPopUpsKey) as? Bool ?? true
        }
        set (darkPopUps) {
            container.set(darkPopUps, forKey: darkPopUpsKey)
        }
    }

    static var patchType: EeveePatchType {
        get {
            if let rawValue = container.object(forKey: patchTypeKey) as? Int {
                return EeveePatchType(rawValue: rawValue) ?? .requests
            }

            // If the key is missing (fresh install / "reset data"), default to patching.
            // This avoids users silently falling back to Free tier.
            return .requests
        }
        set (patchType) {
            container.set(patchType.rawValue, forKey: patchTypeKey)
        }
    }

    static var trueShuffleEnabled: Bool {
        get {
            container.object(forKey: trueShuffleEnabledKey) as? Bool ?? false
        }
        set (isEnabled) {
            container.set(isEnabled, forKey: trueShuffleEnabledKey)
        }
    }
    
    static var overwriteConfiguration: Bool {
        get {
            container.bool(forKey: overwriteConfigurationKey)
        }
        set (overwriteConfiguration) {
            container.set(overwriteConfiguration, forKey: overwriteConfigurationKey)
        }
    }
    
    static var hasPatchedBootstrap: Bool {
        get { container.bool(forKey: hasPatchedBootstrapKey) }
        set { container.set(newValue, forKey: hasPatchedBootstrapKey) }
    }

    static var hasShownCommonIssuesTip: Bool {
        get {
            container.bool(forKey: hasShownCommonIssuesTipKey)
        }
        set (hasShownCommonIssuesTip) {
            container.set(hasShownCommonIssuesTip, forKey: hasShownCommonIssuesTipKey)
        }
    }
}
