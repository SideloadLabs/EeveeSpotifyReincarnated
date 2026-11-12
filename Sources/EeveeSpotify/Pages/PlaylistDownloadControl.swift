import UIKit

// Styles Spotify's original control. Its icon, animation and actions stay native.
@available(iOS 26.0, *)
enum PlaylistDownloadControl {
    private static var lookupKey: UInt8 = 0
    private static var glassKey: UInt8 = 0
    private static var hostKey: UInt8 = 0
    private final class Header { weak var root: UIView?; init(_ root: UIView) { self.root = root } }
    private final class Lookup {
        weak var control: UIView?
        var searched = false
        var hadControl = false
        var checkedInWindow = false
    }

    static func resolve(in root: UIView) -> UIView? {
        let lookup = objc_getAssociatedObject(root, &lookupKey) as? Lookup ?? {
            let lookup = Lookup()
            objc_setAssociatedObject(root, &lookupKey, lookup, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return lookup
        }()
        if let control = lookup.control,
           control.isDescendant(of: root) || (objc_getAssociatedObject(control, &hostKey) as? Header)?.root === root { return control }
        // A missing control is checked once, with one retry when its header
        // enters a window. A removed/replaced native control gets a new lookup.
        if lookup.searched && !lookup.hadControl {
            guard !lookup.checkedInWindow && root.window != nil else { return nil }
        }
        lookup.searched = true
        lookup.checkedInWindow = root.window != nil
        let source = root.eeveeFirst(UIButton.self) { $0.accessibilityIdentifier?.hasPrefix("DownloadButton.Granular.") == true }
            ?? PageLookup.find("Components.UI.DownloadIcon", in: root)
            ?? PageLookup.find("Components.UI.DownloadButton", in: root)
        let control = source.flatMap { source -> UIView? in
            if source is UIControl { return source }
            if let button = source.eeveeFirst(UIButton.self) { return button }
            var parent = source.superview
            while let view = parent, view !== root {
                if view is UIControl { return view }
                parent = view.superview
            }
            return source
        }
        lookup.control = control
        lookup.hadControl = control != nil
        return control
    }

    static func hosted(_ control: UIView, from root: UIView) {
        objc_setAssociatedObject(control, &hostKey, Header(root), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    static func style(_ control: UIView) {
        guard objc_getAssociatedObject(control, &glassKey) == nil else { return }
        // The shared Eevee glass pane sits behind the complete native artwork.
        // No icon extraction, replacement button or tap forwarding is involved.
        let pane = GlassKit.pane(in: control)
        pane.accessibilityIdentifier = "Eevee.Playlist.DownloadGlass"
        pane.frame = control.bounds
        pane.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        pane.cornerConfiguration = .capsule()
        objc_setAssociatedObject(control, &glassKey, pane, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}
