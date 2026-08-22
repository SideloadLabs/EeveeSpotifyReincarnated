import Orion
import UIKit

struct AmoledThemeGroup: HookGroup { }

enum AmoledTheme {
    /// Spotify 9.1.x uses several almost-neutral dark grays for its flat
    /// surfaces. Only replace opaque, neutral background colors so album-art
    /// tints, gradients, text, separators, and translucent materials keep their
    /// original appearance.
    static func backgroundColor(replacing color: UIColor?) -> UIColor? {
        guard let color = color else { return nil }

        let resolved = color.resolvedColor(
            with: UITraitCollection(userInterfaceStyle: .dark)
        )

        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0

        guard resolved.getRed(
            &red,
            green: &green,
            blue: &blue,
            alpha: &alpha
        ) else {
            return color
        }

        // Skip clear/translucent colors and true black, and keep colored dark
        // surfaces such as the Now Playing artwork-derived background intact.
        guard alpha >= 0.95 else { return color }

        let brightestComponent = max(red, max(green, blue))
        let darkestComponent = min(red, min(green, blue))
        let isNeutral = brightestComponent - darkestComponent <= 0.025
        let isDarkSurface = brightestComponent >= 0.035 && brightestComponent <= 0.22

        guard isNeutral && isDarkSurface else { return color }

        return UIColor(white: 0, alpha: alpha)
    }
}

/// `UIView.backgroundColor` is a stable UIKit boundary across Spotify builds,
/// including the UIKit hosting views used by Spotify 9.1.x SwiftUI screens.
/// Keeping the hook on the setter avoids globally changing UIColor instances
/// that may also be used for text, icons, shadows, or artwork.
class UIViewAmoledThemeHook: ClassHook<UIView> {
    typealias Group = AmoledThemeGroup

    func setBackgroundColor(_ backgroundColor: UIColor?) {
        orig.setBackgroundColor(
            AmoledTheme.backgroundColor(replacing: backgroundColor)
        )
    }
}

func activateAmoledTheme() {
    guard UserDefaults.amoledTheme else { return }

    AmoledThemeGroup().activate()
    writeDebugLog("[AMOLED] UIView background-color hook activated")
}
