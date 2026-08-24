import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fatalError("FAIL: \(message)")
    }
}

require(
    BundledConfigurationPolicy.resourceName(for: "9.1.75")
        == BundledConfigurationPolicy.legacyResourceName,
    "Spotify 9.1.75 must use the legacy configuration"
)

require(
    BundledConfigurationPolicy.resourceName(for: "9.1.76")
        == BundledConfigurationPolicy.spotify9176ResourceName,
    "Spotify 9.1.76 must use the new configuration"
)

require(
    BundledConfigurationPolicy.resourceName(for: "9.1.80")
        == BundledConfigurationPolicy.spotify9176ResourceName,
    "Spotify 9.1.80 must use the new configuration"
)

print("BundledConfigurationPolicy tests passed")
