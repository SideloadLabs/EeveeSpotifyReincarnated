import EeveeSpotifyC
import Orion
import ObjectiveC.runtime
import UIKit

private func showHighQualityPopUp() {
    PopUpHelper.showPopUp(
        message: "high_audio_quality_popup".localized,
        buttonText: "OK".uiKitLocalized
    )
}

private func showPlaylistDownloadingPopUp(_ isPlaylist: Bool, onSecondaryClick: (() -> Void)?) {
    let message = "playlist_downloading_popup".localized
    PopUpHelper.showPopUp(
        message: isPlaylist ? message + "\n\n" + "local_playlist_download_setting_hint".localized : message,
        buttonText: "OK".uiKitLocalized,
        secondButtonText: isPlaylist
            ? "download_local_playlist".localized
            : nil,
        onSecondaryClick: onSecondaryClick
    )
}

struct LocalPlaylistDownloadGroup: HookGroup {}

enum LocalPlaylistDownload {
    static let launchEnabled = UserDefaults.localPlaylistDownloadEnabled
    static weak var visiblePlaylist: UIViewController?
    private static var downloadKey: UInt8 = 0
    private static var confirmationButtonKey: UInt8 = 0
    private static var activeConfirmationKey: UInt8 = 0
    private static var loggedMissingControl = false
    private static let nativeButtonClasses: [AnyClass] = [
        "_TtC22RemoteDownloads_ECMKit31GranularDownloadButtonContainer",
        "_TtCOOOE32EncoreConsumerMobile_ElementsKitO19LegacyUI_ECMCoreKit10Components22GranularDownloadButton2UI7Private22GranularDownloadButton",
        "_TtC28EncoreConsumerMobile_BaseKitP33_B18AD9CFD34D2E2EF5BE4AC1DDAEB28B14DownloadButton",
    ].compactMap { NSClassFromString($0) }

    private static func findDownload(in root: UIView) -> UIView? {
        let header = PageLookup.find("PL.Header", in: root)
        if let header, let button = PageLookup.find("Components.UI.DownloadButton", in: header) {
            return button
        }
        return root.eeveeFirst(UIView.self) { view in
            let id = view.accessibilityIdentifier
            if id == "Components.UI.DownloadButton" || id == "spotify:playlist:download_button" {
                return true
            }
            return nativeButtonClasses.contains { view.isKind(of: $0) }
        }
    }

    static func updateHeader(in root: UIView, reportMissing: Bool = false) {
        let previous = objc_getAssociatedObject(root, &activeConfirmationKey) as? UIButton
        guard let download = PageLookup.cached(&downloadKey, in: root, {
            findDownload(in: root)
        }), let parent = download.superview else {
            previous?.removeFromSuperview()
            if reportMissing, !loggedMissingControl {
                loggedMissingControl = true
                writeDebugLog("[LOCAL_SYNC] Playlist appeared but download control was not found")
            }
            return
        }

        guard launchEnabled else {
            if !download.isHidden {
                download.isHidden = true
                writeDebugLog("[LOCAL_SYNC] Hid playlist download control")
            }
            return
        }

        // When the legacy reminder is hooked, the native tap already shows it.
        guard !LatestPremiumPatchingGroup.isActive, !IOS14And15PremiumPatchingGroup.isActive else { return }

        let confirmation = (objc_getAssociatedObject(download, &confirmationButtonKey) as? UIButton) ?? {
            let button = UIButton(type: .custom)
            button.addAction(UIAction { [weak download] _ in
                showPlaylistDownloadingPopUp(true) { [weak download] in
                    guard let download, download.window != nil, !download.isHidden else { return }
                    if !EeveeFireTap(download) {
                        writeDebugLog("[LOCAL_SYNC] Could not forward playlist download tap")
                    }
                }
            }, for: .primaryActionTriggered)
            download.isAccessibilityElement = false
            download.accessibilityElementsHidden = true
            objc_setAssociatedObject(download, &confirmationButtonKey, button, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            writeDebugLog("[LOCAL_SYNC] Attached playlist download reminder to \(type(of: download))")
            return button
        }()

        if previous !== confirmation {
            previous?.removeFromSuperview()
            objc_setAssociatedObject(root, &activeConfirmationKey, confirmation, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        // A sibling receives the tap before Spotify's button or its gesture recognizers.
        if confirmation.superview !== parent {
            parent.insertSubview(confirmation, aboveSubview: download)
        }
        confirmation.frame = download.frame
        confirmation.isHidden = download.isHidden
        confirmation.alpha = download.alpha
        confirmation.isEnabled = (download as? UIControl)?.isEnabled ?? download.isUserInteractionEnabled
        let label = download.accessibilityLabel ?? "download_local_playlist".localized
        if confirmation.accessibilityLabel != label {
            confirmation.accessibilityLabel = label
        }
    }
}

class LocalPlaylistDownloadHeaderHook: ClassHook<UIViewController> {
    typealias Group = LocalPlaylistDownloadGroup
    static let targetName = GlassPlaylistHook.targetName

    func viewDidAppear(_ animated: Bool) {
        orig.viewDidAppear(animated)
        LocalPlaylistDownload.visiblePlaylist = target
        if let root = target.viewIfLoaded {
            LocalPlaylistDownload.updateHeader(in: root, reportMissing: true)
        }
    }

    func viewDidDisappear(_ animated: Bool) {
        orig.viewDidDisappear(animated)
        if LocalPlaylistDownload.visiblePlaylist === target {
            LocalPlaylistDownload.visiblePlaylist = nil
        }
    }

    func viewDidLayoutSubviews() {
        orig.viewDidLayoutSubviews()
        if let root = target.viewIfLoaded {
            LocalPlaylistDownload.updateHeader(in: root)
        }
    }
}

// Temporary diagnostic for finding the native playlist download control.
class LocalPlaylistDownloadTouchProbe: ClassHook<UIWindow> {
    typealias Group = LocalPlaylistDownloadGroup

    func sendEvent(_ event: UIEvent) {
        if UserDefaults.debugLoggingEnabled,
           LocalPlaylistDownload.visiblePlaylist?.viewIfLoaded?.window === target,
           let touch = event.allTouches?.first(where: { $0.phase == .ended }),
           let hit = touch.view {
            var path: [String] = []
            var current: UIView? = hit
            while let view = current, path.count < 16 {
                let typeName = NSStringFromClass(type(of: view))
                let actions = (view as? UIControl).map { control in
                    let events: [UIControl.Event] = [.primaryActionTriggered, .touchUpInside]
                    let names = control.allTargets.flatMap { target in
                        events.flatMap { control.actions(forTarget: target.base, forControlEvent: $0) ?? [] }
                    }
                    return Set(names).sorted().joined(separator: ",")
                } ?? ""
                path.append(actions.isEmpty ? typeName : "\(typeName) {\(actions)}")
                current = view.superview
            }
            writeDebugLog("[LOCAL_SYNC] Playlist tap: " + path.joined(separator: " → "))
        }
        orig.sendEvent(event)
    }
}

//

class StreamQualitySettingsSectionHook: ClassHook<NSObject> {
    typealias Group = IOS14PremiumPatchingGroup
    static let targetName = "StreamQualitySettingsSection"

    func shouldResetSelection() -> Bool {
        showHighQualityPopUp()
        return true
    }
}

class ListRowInteractionListenerViewHook: ClassHook<UIView> {
    typealias Group = NonIOS14PremiumPatchingGroup
    static let targetName = "_TtC15Settings_ECMKit30ListRowInteractionListenerView"

    func performAction() {
        guard
            let accessibilityLabel = target.subviews.first?.accessibilityLabel,
            accessibilityLabel.hasSuffix("Premium")
        else {
            orig.performAction()
            return
        }
        
        showHighQualityPopUp()
    }
}

//

class ContentOffliningUIHelperImplementationHook: ClassHook<NSObject> {
    typealias Group = IOS14And15PremiumPatchingGroup
    static let targetName = "Offline_ContentOffliningUIImpl.ContentOffliningUIHelperImplementation"
    
    func downloadToggledWithCurrentAvailability(
        _ availability: NSInteger,
        addAction: NSObject,
        removeAction: NSObject,
        pageIdentifier: NSString,
        pageURI: NSURL
    ) {
        let isPlaylist = Dynamic.convert(pageURI, to: SPTURL.self)
            .isPlaylistURL()
        
        showPlaylistDownloadingPopUp(
            isPlaylist,
            onSecondaryClick: isPlaylist
                ? {
                    self.orig.downloadToggledWithCurrentAvailability(
                        availability,
                        addAction: addAction,
                        removeAction: removeAction,
                        pageIdentifier: pageIdentifier,
                        pageURI: pageURI
                    )
                }
                : nil
        )
    }
}

class ContentOffliningUIHelperImplementationModernHook: ClassHook<NSObject> {
    typealias Group = LatestPremiumPatchingGroup
    static let targetName = "Offline_ContentOffliningUIImpl.ContentOffliningUIHelperImplementation"

    static var isAvailable: Bool {
        let selector = Selector((
            "downloadToggledWithCurrentAvailability:addAction:removeAction:pageIdentifier:pageURI:interactionID:"
        ))
        guard let cls = NSClassFromString(targetName) else { return false }
        return class_getInstanceMethod(cls, selector) != nil
    }
    
    func downloadToggledWithCurrentAvailability(
        _ availability: NSInteger,
        addAction: NSObject,
        removeAction: NSObject,
        pageIdentifier: NSString,
        pageURI: NSURL,
        interactionID: NSString
    ) {
        let isPlaylist = Dynamic.convert(pageURI, to: SPTURL.self)
            .isPlaylistURL()
        
        showPlaylistDownloadingPopUp(
            isPlaylist,
            onSecondaryClick: isPlaylist
                ? {
                    self.orig.downloadToggledWithCurrentAvailability(
                        availability,
                        addAction: addAction,
                        removeAction: removeAction,
                        pageIdentifier: pageIdentifier,
                        pageURI: pageURI,
                        interactionID: interactionID
                    )
                }
                : nil
        )
    }
}
