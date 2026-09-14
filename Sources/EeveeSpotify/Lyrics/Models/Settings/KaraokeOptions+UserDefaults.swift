import Foundation

extension UserDefaults {
    @UserDefault(
        key: "karaokeOptions",
        defaultValue: KaraokeOptions(
            textAlignment: .center,
            reversedDirection: false
        )
    )
    static var karaokeOptions
}
