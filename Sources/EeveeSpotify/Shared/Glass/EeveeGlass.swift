import UIKit
import SwiftUI
import ObjectiveC
import EeveeSpotifyC

enum EeveeGlass {

    /// True when the running OS actually has `UIGlassEffect` (iOS 26+).
    /// Everywhere else the panes still render, as a dark chrome blur — the
    /// shape and layering are identical, only the material is plainer.
    static var isAvailable: Bool { EeveeGlassIsAvailable() }

    /// Both the OS supports it and the user hasn't turned it off.
    static var isEnabled: Bool { UserDefaults.liquidGlass }

    // MARK: - single pane per host

    private static var singlePaneKey: UInt8 = 0

    /// The pane belonging to `host`, created on first ask and reused after.
    /// Caller sets `.frame` and calls `shape(_:radius:capsule:)`.
    @discardableResult
    static func pane(for host: UIView) -> UIVisualEffectView {
        if let existing = objc_getAssociatedObject(host, &singlePaneKey) as? UIVisualEffectView {
            attach(existing, to: host)
            return existing
        }
        let pane = makePane()
        objc_setAssociatedObject(host, &singlePaneKey, pane, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        attach(pane, to: host)
        return pane
    }

    static func existingPane(for host: UIView) -> UIVisualEffectView? {
        objc_getAssociatedObject(host, &singlePaneKey) as? UIVisualEffectView
    }

    // MARK: - several panes per host

    private static var paneListKey: UInt8 = 0

    /// Pane number `index` on `host` — for a host that needs one pane per
    /// child, like a row of round buttons. Indices are stable across layout
    /// passes, so pane 2 is the same object every time.
    @discardableResult
    static func pane(for host: UIView, at index: Int) -> UIVisualEffectView {
        var panes = objc_getAssociatedObject(host, &paneListKey) as? [UIVisualEffectView] ?? []
        while panes.count <= index {
            panes.append(makePane())
        }
        objc_setAssociatedObject(host, &paneListKey, panes, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        let pane = panes[index]
        pane.isHidden = false
        attach(pane, to: host)
        return pane
    }

    /// Hides panes from `count` onwards — call it after a layout pass that
    /// used fewer panes than the last one, or stale panes stay on screen
    /// behind nothing.
    static func hideGlass(from host: UIView, count: Int) {
        guard let panes = objc_getAssociatedObject(host, &paneListKey) as? [UIVisualEffectView] else { return }
        for index in count..<max(count, panes.count) where index < panes.count {
            panes[index].isHidden = true
        }
    }

    // MARK: - shaping

    /// Rounds a pane. On iOS 26 this goes through `cornerConfiguration` so
    /// the material's edge lensing can spill outside the pane's bounds the
    /// way system glass does; older systems get a clipped continuous curve.
    /// See EeveeGlassApplyShape in Sources/EeveeSpotifyC/Tweak.m.
    ///
    /// `capsule` wins over `radius` — pass it for anything pill- or
    /// circle-shaped so the shape tracks height instead of being pinned to
    /// a number that stops being half the height the moment it re-lays out.
    static func shape(_ pane: UIView, radius: CGFloat, capsule: Bool = false) {
        EeveeGlassApplyShape(pane, radius, capsule)
    }

    // MARK: - internals

    private static func makePane() -> UIVisualEffectView {
        let pane = UIVisualEffectView(effect: EeveeGlassMakeEffect())
        pane.isUserInteractionEnabled = false
        pane.layer.zPosition = -1
        return pane
    }

    private static func attach(_ pane: UIVisualEffectView, to host: UIView) {
        guard pane.superview !== host else { return }
        host.insertSubview(pane, at: 0)
    }
}

// MARK: - a view that is simply glass

class EeveeGlassHostView: UIView {
    var cornerRadius: CGFloat = 14 { didSet { setNeedsLayout() } }
    var isCapsule: Bool = false { didSet { setNeedsLayout() } }

    /// Shown instead of glass when the user has the setting off, so callers
    /// don't each need their own fallback background.
    var fallbackBackgroundColor: UIColor = UIColor.black.withAlphaComponent(0.88)

    override func layoutSubviews() {
        super.layoutSubviews()

        guard EeveeGlass.isEnabled else {
            EeveeGlass.existingPane(for: self)?.isHidden = true
            backgroundColor = fallbackBackgroundColor
            layer.cornerRadius = isCapsule ? bounds.height / 2 : cornerRadius
            layer.cornerCurve = .continuous
            clipsToBounds = true
            return
        }

        backgroundColor = .clear
        // Shaping the host as well as the pane matters on the non-iOS-26
        // path, where the pane clips itself: without it the host's own
        // square corners show through at the edges of the rounded pane.
        layer.cornerRadius = isCapsule ? bounds.height / 2 : cornerRadius
        layer.cornerCurve = .continuous
        clipsToBounds = false

        let pane = EeveeGlass.pane(for: self)
        pane.isHidden = false
        pane.frame = bounds
        EeveeGlass.shape(pane, radius: cornerRadius, capsule: isCapsule)
    }
}

// MARK: - SwiftUI

/// Glass as a SwiftUI background. Bridged through UIKit rather than using
/// iOS 26's `glassEffect(_:in:)` modifier, because that modifier only exists
/// if you compile against the iOS 26 SDK and EeveeSpotify has to keep
/// building against older ones; going through `UIGlassEffect` by name at
/// runtime works from any SDK.
struct EeveeGlassBackground: UIViewRepresentable {
    var cornerRadius: CGFloat
    var capsule: Bool

    func makeUIView(context: Context) -> EeveeGlassHostView {
        let view = EeveeGlassHostView()
        view.cornerRadius = cornerRadius
        view.isCapsule = capsule
        view.fallbackBackgroundColor = .clear
        return view
    }

    func updateUIView(_ view: EeveeGlassHostView, context: Context) {
        view.cornerRadius = cornerRadius
        view.isCapsule = capsule
    }
}

extension View {
    /// Puts a glass pane behind this view.
    ///
    /// Falls back to `.ultraThinMaterial` when the setting is off or the OS
    /// has no `UIGlassEffect`, so a call site never has to branch. Pass
    /// `capsule: true` for pills and circles instead of guessing a radius.
    @ViewBuilder
    func eeveeGlass(cornerRadius: CGFloat = 14, capsule: Bool = false) -> some View {
        if EeveeGlass.isEnabled, EeveeGlass.isAvailable {
            self.background(EeveeGlassBackground(cornerRadius: cornerRadius, capsule: capsule))
        } else if #available(iOS 15.0, *) {
            self.background(
                RoundedRectangle(
                    cornerRadius: capsule ? 999 : cornerRadius,
                    style: .continuous
                )
                .fill(.ultraThinMaterial)
            )
        } else {
            self.background(
                RoundedRectangle(
                    cornerRadius: capsule ? 999 : cornerRadius,
                    style: .continuous
                )
                .fill(Color.black.opacity(0.7))
            )
        }
    }
}