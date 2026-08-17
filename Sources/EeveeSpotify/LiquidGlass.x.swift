import Orion
import Foundation
import UIKit

// Spotify ships with `UIDesignRequiresCompatibility = true` in its Info.plist. This is
// Apple's documented iOS 26 opt-out flag: when present and true, UIKit/SwiftUI keep
// rendering standard chrome (nav bars, tab bars, toolbars, alerts, search bars, etc.)
// in the pre-iOS 26 style instead of the new Liquid Glass material, regardless of the
// device's actual OS version. Spotify also ships its own hand-rolled glass components
// (Reprise_LiquidGlassKit — ChipGlassView, GradientView, SearchBarView, etc.) that are
// gated separately and rolled out gradually; those are internal Swift types with no
// exported symbols to hook, so they're out of reach here.
//
// This hook only flips the documented, Apple-level switch: NSBundle is intercepted so
// that when Spotify's own UIKit init path asks the main bundle for
// "UIDesignRequiresCompatibility", it gets `false` back, letting the OS apply native
// Liquid Glass to Spotify's standard UIKit/SwiftUI surfaces. Has no effect below iOS 26.

struct LiquidGlassGroup: HookGroup { }

class NSBundleLiquidGlassHook: ClassHook<NSObject> {
    typealias Group = LiquidGlassGroup
    static let targetName = "NSBundle"

    func objectForInfoDictionaryKey(_ key: NSString) -> Any? {
        if key == "UIDesignRequiresCompatibility",
           let bundle = target as? Bundle,
           bundle == Bundle.main {
            return NSNumber(value: false)
        }

        return orig.objectForInfoDictionaryKey(key)
    }
}

func activateLiquidGlass() {
    guard UserDefaults.forceLiquidGlass else { return }

    if #unavailable(iOS 26.0) {
        writeDebugLog("[LiquidGlass] Skipped: requires iOS 26+")
        return
    }

    LiquidGlassGroup().activate()
    writeDebugLog("[LiquidGlass] Activated - forcing UIDesignRequiresCompatibility=false")
}

// MARK: - Icon buttons / toggles
//
// The NSBundle trick above only affects genuine system-owned chrome (UINavigationBar's
// own background, UIToolbar, etc.) because that rendering is done inside UIKit itself,
// which checks the compatibility flag. Most of Spotify's actual screens are pure
// SwiftUI (Encore/Reprise_LiquidGlassKit) with zero ObjC-visible classes, so Orion
// can't reach them - there's no class name to hook.
//
// However, digging through the binary's Swift metadata (not the exported symbol
// table, which is nearly empty for app code - the ObjC-visible class *names* Swift
// still registers at runtime for any class descending from an ObjC/UIKit base) turned
// up two real, targetable classes:
//
//  - GLUEAccessoryIconButton: part of Spotify's older "GLUE" UIKit component library,
//    used for icon-style accessory buttons - this is the most likely candidate for
//    the nav bar back chevron / settings gear.
//  - SPTEncorePreferenceRowSwitch (module Settings_ECMKit): the settings toggle row
//    control, with accessibility identifiers "PreferenceRowSwitch.Switch" /
//    "PreferenceRowSwitch.ListRow" confirming it wraps an actual UISwitch.
//
// Both are hooked below by exact class name via targetName, the same technique
// ProgressBarSliderHook elsewhere in this tweak already uses for a private
// Swift-mangled class - so this isn't a new mechanism, just a new target.

private var glassBackingKey: UInt8 = 0

private func installGlassBacking(behind view: UIView, cornerRadius: CGFloat? = nil) {
    guard UserDefaults.forceLiquidGlass, #available(iOS 26.0, *) else { return }
    guard objc_getAssociatedObject(view, &glassBackingKey) == nil else { return }
    guard view.bounds.width > 0, view.bounds.height > 0 else { return }

    let effectView = UIVisualEffectView(effect: UIGlassEffect())
    effectView.frame = view.bounds
    effectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    effectView.isUserInteractionEnabled = false
    effectView.layer.cornerRadius = cornerRadius ?? min(view.bounds.width, view.bounds.height) / 2
    effectView.clipsToBounds = true

    view.insertSubview(effectView, at: 0)
    objc_setAssociatedObject(view, &glassBackingKey, effectView, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
}

private func firstSwitch(in view: UIView) -> UISwitch? {
    if let s = view as? UISwitch { return s }
    for sub in view.subviews {
        if let found = firstSwitch(in: sub) { return found }
    }
    return nil
}

// Confirmed class: back chevron / settings gear style accessory buttons.
class GLUEAccessoryIconButtonGlassHook: ClassHook<UIButton> {
    typealias Group = LiquidGlassGroup
    static let targetName = "GLUEAccessoryIconButton"

    func layoutSubviews() {
        orig.layoutSubviews()

        guard target.window != nil else { return }
        installGlassBacking(behind: target)
    }
}

// Confirmed class: settings toggle rows. Glass goes behind the nested UISwitch
// itself, not the whole row, so it doesn't paint the entire list row.
class SPTEncorePreferenceRowSwitchGlassHook: ClassHook<UIView> {
    typealias Group = LiquidGlassGroup
    static let targetName = "SPTEncorePreferenceRowSwitch"

    func layoutSubviews() {
        orig.layoutSubviews()

        guard target.window != nil, let toggle = firstSwitch(in: target) else { return }
        installGlassBacking(behind: toggle, cornerRadius: toggle.bounds.height / 2)
    }
}

private func isIconSizedButton(_ view: UIView) -> Bool {
    let w = view.bounds.width, h = view.bounds.height
    guard w > 0, h > 0 else { return false }
    let aspect = w / h
    return w >= 28 && w <= 60 && h >= 28 && h <= 60 && aspect > 0.7 && aspect < 1.4
}

class UIButtonGlassBackingHook: ClassHook<UIButton> {
    typealias Group = LiquidGlassGroup

    func didMoveToWindow() {
        orig.didMoveToWindow()

        guard target.window != nil,
              type(of: target).description() != "GLUEAccessoryIconButton",
              isIconSizedButton(target) else { return }
        installGlassBacking(behind: target)
    }
}
