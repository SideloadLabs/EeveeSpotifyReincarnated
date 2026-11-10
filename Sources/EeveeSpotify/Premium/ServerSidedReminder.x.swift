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
    private static var headerKey: UInt8 = 0
    private static var downloadKey: UInt8 = 0
    private static var confirmationButtonKey: UInt8 = 0

    static func updateHeader(in root: UIView) {
        guard let header = PageLookup.cached(&headerKey, in: root, {
            PageLookup.find("PL.Header", in: root)
        }), let download = PageLookup.cached(&downloadKey, in: header, {
            PageLookup.find("Components.UI.DownloadButton", in: header)
        }) else { return }

        guard launchEnabled else {
            if !download.isHidden { download.isHidden = true }
            return
        }

        // When the legacy reminder is hooked, the native tap already shows it.
        guard !LatestPremiumPatchingGroup.isActive, !IOS14And15PremiumPatchingGroup.isActive else { return }

        let confirmation = (objc_getAssociatedObject(download, &confirmationButtonKey) as? UIButton) ?? {
            let button = UIButton(type: .custom)
            button.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            button.addAction(UIAction { [weak download, weak button] _ in
                showPlaylistDownloadingPopUp(true) { [weak download, weak button] in
                    guard let download, let button, download.window != nil, !download.isHidden else { return }
                    // Replay Spotify's action without finding our own control.
                    button.removeFromSuperview()
                    defer { download.addSubview(button) }
                    if !EeveeFireTap(download) {
                        writeDebugLog("[LOCAL_SYNC] Could not forward playlist download tap")
                    }
                }
            }, for: .primaryActionTriggered)
            button.frame = download.bounds
            download.addSubview(button)
            download.isAccessibilityElement = false
            download.accessibilityElements = [button]
            objc_setAssociatedObject(download, &confirmationButtonKey, button, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return button
        }()

        confirmation.frame = download.bounds
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

    func viewDidLayoutSubviews() {
        orig.viewDidLayoutSubviews()
        if let root = target.viewIfLoaded {
            LocalPlaylistDownload.updateHeader(in: root)
        }
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
