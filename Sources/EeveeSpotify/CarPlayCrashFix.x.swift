import Orion
import Foundation
import ObjectiveC.runtime

// Issue #16: CarPlay private callbacks can raise an NSException on resigned builds
// and kill the app. We swallow them — trades a crash for degraded CarPlay.
// Split per-class so a build with only one selector doesn't hook the absent one.
struct CPInterfaceControllerCrashFixGroup: HookGroup {}
struct CPListTemplateCrashFixGroup: HookGroup {}

private var carPlayFixActivated = false
private var carPlayFixAttempt = 0
private let carPlayFixMaxAttempts = 30  // ~15s with 0.5s interval

class CPInterfaceControllerCarPlayCrashFixHook: ClassHook<NSObject> {
    typealias Group = CPInterfaceControllerCrashFixGroup
    static let targetName = "CPInterfaceController"

    @objc(clientAssistantCellUnavailableWithError:)
    func clientAssistantCellUnavailableWithError(_ error: Any?) {
        // no orig — this path can raise and crash the process
        writeDebugLog("[CarPlayFix] Swallowed clientAssistantCellUnavailableWithError:")
    }
}

class CPListTemplateAssistantCellConfigCrashFixHook: ClassHook<NSObject> {
    typealias Group = CPListTemplateCrashFixGroup
    static let targetName = "CPListTemplate"

    @objc(setAssistantCellConfiguration:)
    func setAssistantCellConfiguration(_ config: Any?) {
        // no orig — this path can raise an NSException
        writeDebugLog("[CarPlayFix] Swallowed setAssistantCellConfiguration:")
    }
}

func activateCarPlayCrashFix() {
    if carPlayFixActivated { return }

    // CarPlay.framework may not be loaded yet at init — retry until classes appear.
    guard let icCls = NSClassFromString("CPInterfaceController"),
          let ltCls = NSClassFromString("CPListTemplate") else {
        if carPlayFixAttempt < carPlayFixMaxAttempts {
            carPlayFixAttempt += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                activateCarPlayCrashFix()
            }
        } else {
            writeDebugLog("[CarPlayFix] Gave up waiting for CarPlay classes")
        }
        return
    }

    let icSel = Selector(("clientAssistantCellUnavailableWithError:"))
    let ltSel = Selector(("setAssistantCellConfiguration:"))

    let icOK = class_getInstanceMethod(icCls, icSel) != nil
    let ltOK = class_getInstanceMethod(ltCls, ltSel) != nil

    guard icOK || ltOK else {
        writeDebugLog("[CarPlayFix] Skipped (selectors missing)")
        return
    }

    if icOK { CPInterfaceControllerCrashFixGroup().activate() }
    if ltOK { CPListTemplateCrashFixGroup().activate() }
    carPlayFixActivated = true
    writeDebugLog("[CarPlayFix] Activated (ic=\(icOK) lt=\(ltOK))")
}
