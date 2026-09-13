import Foundation
import UIKit
import Orion
import ObjectiveC.runtime

struct HideJamFromMenuGroup: HookGroup {}

private func kvcString(_ obj: NSObject, _ key: String) -> String? {
    guard obj.responds(to: Selector(key)) else { return nil }
    return obj.value(forKey: key) as? String
}

private func isJamAction(_ obj: AnyObject) -> Bool {
    let className = String(cString: class_getName(object_getClass(obj) ?? type(of: obj)))
    let lowerClass = className.lowercased()
    
    // Check if the class itself is a Jam or SocialListening context menu action
    if (lowerClass.contains("jam") || lowerClass.contains("sociallistening"))
        && (lowerClass.contains("action") || lowerClass.contains("contextmenu") || lowerClass.contains("item")) {
        return true
    }

    if let obj = obj as? NSObject {
        let title = (kvcString(obj, "title") ?? kvcString(obj, "actionTitle") ?? "").lowercased()
        let identifier = (kvcString(obj, "identifier") ?? kvcString(obj, "actionIdentifier") ?? "").lowercased()

        if identifier.contains("jam") || identifier.contains("social-listening") || identifier.contains("groupsession") {
            return true
        }

        // Specifically match Jam action titles (avoiding false positives on songs/albums named "Jam")
        if title == "start a jam" || title == "start jam"
            || title.hasPrefix("start a jam") || title.hasPrefix("start jam")
            || title.contains("jam session")
            || title.contains("iniciar una sesión jam")
            || title.contains("commencer un jam")
            || title.contains("eine jam starten")
            || title.contains("iniciar um jam")
            || title.contains("начать jam") {
            return true
        }
    }
    return false
}

// Hook legacy/ObjC context menu presenter if present in this build
class SPTContextMenuPresenterJamHook: ClassHook<NSObject> {
    typealias Group = HideJamFromMenuGroup
    static let targetName = "SPTContextMenuPresenter"

    func presentContextMenuWithActions(_ actions: [AnyObject]) {
        guard UserDefaults.hideJamFromMenu else {
            orig.presentContextMenuWithActions(actions)
            return
        }
        let filtered = actions.filter { !isJamAction($0) }
        orig.presentContextMenuWithActions(filtered)
    }
}

enum HideJamFromMenuHook {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true

        guard UserDefaults.hideJamFromMenu else {
            NSLog("[EeveeSpotify][HideJam] Disabled via settings")
            return
        }

        // Find and suppress Jam context menu action providers in the Objective-C / Swift runtime
        let total = objc_getClassList(nil, 0)
        guard total > 0 else { return }
        let buf = UnsafeMutablePointer<AnyClass>.allocate(capacity: Int(total))
        defer { buf.deallocate() }
        let count = objc_getClassList(AutoreleasingUnsafeMutablePointer<AnyClass>(buf), total)

        var suppressedActions = 0
        for i in 0..<Int(count) {
            let raw = UnsafeRawPointer(buf).load(
                fromByteOffset: i * MemoryLayout<UnsafeRawPointer>.size,
                as: UnsafeRawPointer.self
            )
            let cls: AnyClass = unsafeBitCast(raw, to: AnyClass.self)
            let name = String(cString: class_getName(cls))
            let lower = name.lowercased()

            // Target action providers / actions for Jam and SocialListening
            let isTargetClass = (lower.contains("jam") || lower.contains("sociallistening"))
                && (lower.contains("contextmenu") || lower.contains("actionprovider") || lower.contains("actionfactory"))

            if isTargetClass {
                var modified = false

                // 1. isAvailable -> false
                let selAvailable = Selector(("isAvailable"))
                if let m = class_getInstanceMethod(cls, selAvailable) {
                    let b: @convention(block) (AnyObject) -> Bool = { _ in
                        UserDefaults.hideJamFromMenu ? false : true
                    }
                    method_setImplementation(m, imp_implementationWithBlock(b as Any))
                    modified = true
                }

                // 2. isAvailableForURI: -> false
                let selAvailableURI = Selector(("isAvailableForURI:"))
                if let m = class_getInstanceMethod(cls, selAvailableURI) {
                    let b: @convention(block) (AnyObject, AnyObject?) -> Bool = { _, _ in
                        UserDefaults.hideJamFromMenu ? false : true
                    }
                    method_setImplementation(m, imp_implementationWithBlock(b as Any))
                    modified = true
                }

                // 3. action / contextMenuAction -> nil
                let selAction = Selector(("action"))
                if let m = class_getInstanceMethod(cls, selAction) {
                    let origIMP = method_getImplementation(m)
                    let b: @convention(block) (AnyObject) -> AnyObject? = { target in
                        if UserDefaults.hideJamFromMenu { return nil }
                        typealias OrigFn = @convention(c) (AnyObject, Selector) -> AnyObject?
                        return unsafeBitCast(origIMP, to: OrigFn.self)(target, selAction)
                    }
                    method_setImplementation(m, imp_implementationWithBlock(b as Any))
                    modified = true
                }

                if modified {
                    suppressedActions += 1
                    NSLog("[EeveeSpotify][HideJam] Neutralized action provider: %@", name)
                }
            }

            // Also neutralize Jam device picker integration entry points
            if lower.contains("jamdevicepicker") || (lower.contains("jam") && lower.contains("devicepickerintegration")) {
                let selLoad = Selector(("load"))
                if let m = class_getInstanceMethod(cls, selLoad) {
                    let b: @convention(block) (AnyObject) -> Void = { _ in
                        if UserDefaults.hideJamFromMenu {
                            NSLog("[EeveeSpotify][HideJam] Suppressed %@", name)
                            return
                        }
                    }
                    method_setImplementation(m, imp_implementationWithBlock(b as Any))
                    NSLog("[EeveeSpotify][HideJam] Neutralized device picker service: %@", name)
                }
            }
        }

        NSLog("[EeveeSpotify][HideJam] Scanned %d classes, neutralized %d Jam action providers",
              count, suppressedActions)
    }
}

func activateHideJamFromMenu() {
    if let cls = NSClassFromString("SPTContextMenuPresenter"),
       class_getInstanceMethod(cls, Selector(("presentContextMenuWithActions:"))) != nil {
        HideJamFromMenuGroup().activate()
        NSLog("[EeveeSpotify][HideJam] SPTContextMenuPresenterJamHook activated")
    }

    HideJamFromMenuHook.install()
    NSLog("[EeveeSpotify][HideJam] HideJamFromMenu activated")
}
