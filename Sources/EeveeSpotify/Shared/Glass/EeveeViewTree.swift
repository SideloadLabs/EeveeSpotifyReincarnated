import UIKit

enum EeveeViewTree {

    static func forEachView(_ view: UIView, _ body: (UIView) -> Void) {
        body(view)
        for sub in view.subviews { forEachView(sub, body) }
    }

    static func frame(of view: UIView, in target: UIView) -> CGRect {
        guard let superview = view.superview else { return view.frame }
        return superview.convert(view.frame, to: target)
    }

    /// Whether `view` sits under `root`, stopping at a visual effect view on
    /// the way up — so a view that is already inside somebody's glass pane
    /// doesn't count as being in the host's own content.
    static func isInside(_ view: UIView, _ root: UIView?) -> Bool {
        guard let root else { return false }
        var current: UIView? = view
        while let v = current {
            if v is UIVisualEffectView { return false }
            if v === root { return true }
            current = v.superview
        }
        return false
    }

    /// The first wide stack view under `host` with at least two arranged
    /// children: a player row, or the row of items in the tab bar.
    static func row(in host: UIView?) -> UIStackView? {
        guard let host else { return nil }
        var found: UIStackView?
        forEachView(host) { v in
            guard found == nil,
                  let stack = v as? UIStackView,
                  stack.bounds.width > 200,
                  stack.arrangedSubviews.count >= 2
            else { return }
            found = stack
        }
        return found
    }

    static let backgroundWashImageThreshold: CGFloat = 64

    static func isBackgroundWashImage(_ view: UIView) -> Bool {
        let isLarge = view.bounds.width > backgroundWashImageThreshold
            || view.bounds.height > backgroundWashImageThreshold
        guard isLarge else { return false }
        return view is UIImageView || view.layer.contents != nil
    }

    static func keepsColor(_ view: UIView) -> Bool {
        if view is UIImageView { return !isBackgroundWashImage(view) }
        return view is UILabel || view.bounds.height <= 4
    }

    /// Clears opaque backgrounds and hides gradient layers beneath `view`, so
    /// a pane behind it has something to refract. Skips visual effect views —
    /// stripping those would blank out the panes themselves.
    /// Returns the number of background-wash images hidden, so the caller
    /// can log it once and confirm whether this was actually the blocker.
    @discardableResult
    static func stripBackgrounds(_ view: UIView) -> Int {
        if view is UIVisualEffectView { return 0 }

        if !keepsColor(view) {
            view.layer.backgroundColor = nil
        }

        var hiddenCount = 0

        if isBackgroundWashImage(view) {
            view.isHidden = true
            hiddenCount += 1
        }

        if view.layer is CAGradientLayer || NSStringFromClass(type(of: view)).contains("GradientView") {
            view.isHidden = true
        }
        for layer in view.layer.sublayers ?? [] where layer is CAGradientLayer {
            layer.isHidden = true
        }

        for sub in view.subviews { hiddenCount += stripBackgrounds(sub) }
        return hiddenCount
    }

    // MARK: - colour tests

    private static func components(_ color: CGColor) -> [CGFloat] {
        Array(UnsafeBufferPointer(start: color.components, count: color.numberOfComponents))
    }

    static func isVisibleColor(_ color: CGColor?) -> Bool {
        guard let color, color.alpha >= 0.05 else { return false }
        let c = components(color)
        guard c.count >= 2 else { return false }
        // Last component is alpha — brightness is the max of the rest.
        return c.dropLast().max() ?? 0 > 0.08
    }

    /// Spotify paints the search field white; this is how the field is found
    /// on a build that stops setting its accessibility identifier.
    static func isLightColor(_ color: CGColor?) -> Bool {
        guard let color, color.alpha >= 0.5 else { return false }
        let c = components(color)
        guard c.count >= 2 else { return false }
        return c.dropLast().allSatisfy { $0 >= 0.85 }
    }

    /// Spotify's base surface: the neutral #121212 it paints its pages with,
    /// or the black an AMOLED mode turns that into. Lighter greys (#1F1F1F
    /// placeholders, #292929 cards) and translucent paint are left alone.
    static func isBaseSurface(_ color: CGColor?) -> Bool {
        guard let color, color.alpha >= 0.95 else { return false }
        let c = components(color)
        if c.count == 2 { return c[0] <= 0.10 }
        guard c.count >= 4 else { return false }
        return c[0] <= 0.10
            && abs(c[0] - c[1]) < 0.02
            && abs(c[1] - c[2]) < 0.02
    }

    /// A painted, card-sized view — the now playing bar's card, for one.
    static func looksLikeCard(_ view: UIView, color: CGColor?) -> Bool {
        let size = view.bounds.size
        return size.height >= 40 && size.height <= 140
            && size.width >= 200
            && isVisibleColor(color)
    }
}
