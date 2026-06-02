import Foundation
import ObjectiveC.runtime

// Stops Smart Shuffle from injecting recommended (non-playlist) tracks into
// the free-tier shuffle queue. Two BOOL gates on SmartShuffleHandler:
//   - checkRecommendationsEnabled                 -> NO
//   - recommendationIsBeingAddedWithTrackID:      -> NO
// Both bool returns, no nil-deref risk. Gated by Settings toggle.

enum TrueShuffleHook {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true

        guard UserDefaults.trueShuffleEnabled else {
            NSLog("[EeveeSpotify][TrueShuffle] disabled via settings")
            return
        }

        guard let cls = findClass(suffix: ".SmartShuffleHandlerImplementation") else {
            NSLog("[EeveeSpotify][TrueShuffle] SmartShuffleHandler not found")
            return
        }
        swizzleBool(cls, NSSelectorFromString("checkRecommendationsEnabled"), takesArg: false)
        swizzleBool(cls, NSSelectorFromString("recommendationIsBeingAddedWithTrackID:"), takesArg: true)
        NSLog("[EeveeSpotify][TrueShuffle] recs killed on %s", class_getName(cls))
    }

    private static func findClass(suffix: String) -> AnyClass? {
        let total = objc_getClassList(nil, 0)
        guard total > 0 else { return nil }
        let buf = UnsafeMutablePointer<AnyClass>.allocate(capacity: Int(total))
        defer { buf.deallocate() }
        let n = objc_getClassList(AutoreleasingUnsafeMutablePointer<AnyClass>(buf), total)
        for i in 0..<Int(n) {
            let raw = UnsafeRawPointer(buf).load(fromByteOffset: i * MemoryLayout<UnsafeRawPointer>.size,
                                                  as: UnsafeRawPointer.self)
            let cls: AnyClass = unsafeBitCast(raw, to: AnyClass.self)
            if String(cString: class_getName(cls)).hasSuffix(suffix) { return cls }
        }
        return nil
    }

    private static func swizzleBool(_ cls: AnyClass, _ sel: Selector, takesArg: Bool) {
        guard let m = class_getInstanceMethod(cls, sel) else {
            NSLog("[EeveeSpotify][TrueShuffle] missing %@ on %s",
                  NSStringFromSelector(sel), class_getName(cls))
            return
        }
        if takesArg {
            let b: @convention(block) (AnyObject, AnyObject?) -> Bool = { _, _ in false }
            method_setImplementation(m, imp_implementationWithBlock(b as Any))
        } else {
            let b: @convention(block) (AnyObject) -> Bool = { _ in false }
            method_setImplementation(m, imp_implementationWithBlock(b as Any))
        }
    }
}
