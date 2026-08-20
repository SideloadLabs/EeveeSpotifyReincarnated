import Foundation

extension UserDefaults {
    @UserDefault(
        key: "experimentsOptions",
        defaultValue: ExperimentsOptions(
            showInstagramDestination: false,
            liveContainerSharing: true,
            disableFeelingsForElsa: true
        )
    )
    static var experimentsOptions
}
