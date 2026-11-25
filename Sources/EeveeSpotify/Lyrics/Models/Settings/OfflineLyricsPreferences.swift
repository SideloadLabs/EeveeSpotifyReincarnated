import Foundation

extension UserDefaults {
    static var offlineLyricsEnabled: Bool {
        get { container.object(forKey: "PixieOfflineLyricsEnabled") as? Bool ?? true }
        set { container.set(newValue, forKey: "PixieOfflineLyricsEnabled") }
    }
}
