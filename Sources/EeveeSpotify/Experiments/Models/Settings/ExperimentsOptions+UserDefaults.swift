import Foundation

extension UserDefaults {
    @UserDefault(
        key: "experimentsOptions",
        defaultValue: ExperimentsOptions(
            showInstagramDestination: false,
            liveContainerSharing: true
        )
    )
    static var experimentsOptions
}
