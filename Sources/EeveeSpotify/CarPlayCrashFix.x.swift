import Orion
import Foundation
import ObjectiveC.runtime

// Fix for Issue #16: CarPlay launching can crash inside CarPlay.framework.
//
// Observed crash signatures so far:
// - -[CPInterfaceController clientAssistantCellUnavailableWithError:] (older log)
// - -[CPListTemplate setAssistantCellConfiguration:] (newer log)
//
// In sideloaded/resigned Spotify builds, CarPlay can raise an NSException from
// these private callbacks, which terminates the app.
//
// We hook the callbacks and swallow them (no-op) so Spotify stays alive.
// This trades a crash for a non-fatal CarPlay-unavailable / degraded state.

struct CarPlayCrashFixGroup: HookGroup {}

private var carPlayFixActivated = false
private var carPlayFixAttempt = 0
private let carPlayFixMaxAttempts = 30  // ~15s with 0.5s interval

class CPInterfaceControllerCarPlayCrashFixHook: ClassHook<NSObject> {
    typealias Group = CarPlayCrashFixGroup
    static let targetName = "CPInterfaceController"

    // Private API selector (observed in crash log)
    @objc(clientAssistantCellUnavailableWithError:)
    func clientAssistantCellUnavailableWithError(_ error: Any?) {
        // Intentionally do NOT call orig — on affected OS versions this path
        // can raise an exception and crash the entire process.
        writeDebugLog("[CarPlayFix] Swallowed clientAssistantCellUnavailableWithError: \(String(describing: error))")
    }
}

class CPListTemplateAssistantCellConfigCrashFixHook: ClassHook<NSObject> {
    typealias Group = CarPlayCrashFixGroup
    static let targetName = "CPListTemplate"

    // Private API selector (observed in crash log)
    @objc(setAssistantCellConfiguration:)
    func setAssistantCellConfiguration(_ config: Any?) {
        // Do NOT call orig — this path can raise an NSException.
        writeDebugLog("[CarPlayFix] Swallowed CPListTemplate setAssistantCellConfiguration: \(String(describing: config))")
    }
}

func activateCarPlayCrashFix() {
    if carPlayFixActivated { return }

    // CarPlay.framework may not be loaded yet during tweak init.
    // Retry a few times on the main queue until the classes appear.
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

    CarPlayCrashFixGroup().activate()
    carPlayFixActivated = true
    writeDebugLog("[CarPlayFix] Activated")
}
