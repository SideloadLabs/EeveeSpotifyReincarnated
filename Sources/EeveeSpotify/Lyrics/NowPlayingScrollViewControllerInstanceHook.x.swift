import Orion
import UIKit
import ObjectiveC.runtime

var statefulPlayer: StatefulPlayerImplementation?
var backgroundViewModel: SPTNowPlayingBackgroundViewModel?
var scrollDataSource: NowPlayingScrollDataSourceImplementation?

var nowPlayingScrollViewController: NowPlayingScrollViewController?
var npvScrollViewController: NPVScrollViewController?

// Purely introspective — enumerates method/ivar names via the ObjC runtime's
// own reflection APIs and logs them. Never calls any of the selectors it
// finds, so unlike guessing a `value(forKey:)` key (which can raise an
// uncatchable NSException and crash the host app if the key doesn't exist),
// this is safe to run against a completely unknown object. Logs through
// writeDebugLog (not NSLog, unlike EeveeProbes.x.swift's very similar
// dumpClass) specifically so this shows up in the same eeveespotify_debug.log
// file already being used to diagnose the karaoke playback-tracking issue —
// NSLog-only output isn't visible there.
func karaokeDumpClassMethods(_ label: String, of object: AnyObject?) {
    guard let object = object else {
        writeDebugLog("[KaraokeProbe] \(label): object is nil")
        return
    }
    guard let cls = object_getClass(object) else {
        writeDebugLog("[KaraokeProbe] \(label): object_getClass returned nil")
        return
    }
    writeDebugLog("[KaraokeProbe] \(label): class=\(NSStringFromClass(cls))")
    var count: UInt32 = 0
    if let methods = class_copyMethodList(cls, &count) {
        var names: [String] = []
        for i in 0..<Int(count) {
            names.append(NSStringFromSelector(method_getName(methods[i])))
        }
        free(methods)
        writeDebugLog("[KaraokeProbe] \(label): methods=\(names.sorted())")
    }
    var ivarCount: UInt32 = 0
    if let ivars = class_copyIvarList(cls, &ivarCount) {
        var names: [String] = []
        for i in 0..<Int(ivarCount) {
            let name = ivar_getName(ivars[i]).map { String(cString: $0) } ?? "?"
            let type = ivar_getTypeEncoding(ivars[i]).map { String(cString: $0) } ?? "?"
            names.append("\(name):\(type)")
        }
        free(ivars)
        writeDebugLog("[KaraokeProbe] \(label): ivars=\(names)")
    }
}

private var didDumpStatefulPlayer = false

/// Class-based counterpart to karaokeDumpClassMethods(_:of:) above, for when
/// there's no live instance to inspect (yet, or ever, if the object simply
/// isn't reachable) but the Class itself is known — class_copyMethodList
/// works directly on a Class, no instance required.
func karaokeDumpClassMethods(_ label: String, ofClass cls: AnyClass) {
    writeDebugLog("[KaraokeProbe] \(label): class=\(NSStringFromClass(cls))")
    var count: UInt32 = 0
    if let methods = class_copyMethodList(cls, &count) {
        var names: [String] = []
        for i in 0..<Int(count) {
            names.append(NSStringFromSelector(method_getName(methods[i])))
        }
        free(methods)
        writeDebugLog("[KaraokeProbe] \(label): methods=\(names.sorted())")
    }
}

class LegacyNowPlayingPlatformSwiftServiceImplementationHook: ClassHook<NSObject> {
    typealias Group = IOS14PremiumPatchingGroup
    static let targetName = "NowPlaying_PlatformImpl.NowPlayingPlatformSwiftServiceImplementation"
    
    func provideStatefulPlayer() -> StatefulPlayerImplementation {
        statefulPlayer = orig.provideStatefulPlayer()
        if !didDumpStatefulPlayer {
            didDumpStatefulPlayer = true
            karaokeDumpClassMethods("statefulPlayer", of: statefulPlayer as AnyObject)
        }
        return statefulPlayer!
    }
}

class NowPlayingPlatformSwiftServiceImplementationHook: ClassHook<NSObject> {
    typealias Group = NonIOS14PremiumPatchingGroup
    static let targetName = "NowPlaying_PlatformImpl.NowPlayingPlatformSwiftServiceImplementation"
    
    func provideStatefulPlayerWithFeatureIdentifier(_ identifier: NSString) -> StatefulPlayerImplementation {
        statefulPlayer = orig.provideStatefulPlayerWithFeatureIdentifier(identifier)
        if !didDumpStatefulPlayer {
            didDumpStatefulPlayer = true
            karaokeDumpClassMethods("statefulPlayer", of: statefulPlayer as AnyObject)
        }
        return statefulPlayer!
    }
}

class NowPlayingScrollPrivateServiceImplementationHook: ClassHook<NSObject> {
    typealias Group = BaseLyricsGroup
    static let targetName = "NowPlaying_ScrollImpl.NowPlayingScrollPrivateServiceImplementation"
    
    func provideScrollViewControllerWithDependencies(_ dependencies: NSObject) -> UIViewController {
        let scrollViewController = orig.provideScrollViewControllerWithDependencies(dependencies)
        
        if NSStringFromClass(type(of: scrollViewController)) ~= "NowPlayingScrollViewController" {
            nowPlayingScrollViewController = Dynamic.convert(
                scrollViewController,
                to: NowPlayingScrollViewController.self
            )
        }
        else {
            scrollDataSource = Ivars<NowPlayingScrollDataSourceImplementation>(target)
                .$__lazy_storage_$_scrollDataSource
            npvScrollViewController = Dynamic.convert(
                scrollViewController,
                to: NPVScrollViewController.self
            )
        }
        
        backgroundViewModel = Ivars<SPTNowPlayingBackgroundViewModel>(dependencies)
            .backgroundViewModel
        
        return scrollViewController
    }
}
