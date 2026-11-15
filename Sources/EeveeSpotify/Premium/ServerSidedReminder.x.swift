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
    private static let actionViewClass = NSClassFromString(
        "_TtC35ListUXPlatform_FreeTierPlaylistImplP33_0FBF7F603415652909A2EEC13496CA7D10ActionView"
    )

    static func isDownloadButton(_ button: UIButton) -> Bool {
        guard let actionViewClass else { return false }
        var current: UIView? = button
        var hasDownloadText = false
        while let view = current {
            hasDownloadText = hasDownloadText ||
                view.accessibilityLabel?.caseInsensitiveCompare("Download") == .orderedSame ||
                view.accessibilityHint?.range(of: "tap to download and make available offline", options: .caseInsensitive) != nil
            if view.isKind(of: actionViewClass) { return hasDownloadText }
            if view is UIStackView { return false }
            current = view.superview
        }
        return false
    }
}

class LocalPlaylistDownloadHeaderHook: ClassHook<UIViewController> {
    typealias Group = LocalPlaylistDownloadGroup
    static let targetName = GlassPlaylistHook.targetName

    func viewDidLayoutSubviews() {
        orig.viewDidLayoutSubviews()
        // A warm launch can still use Spotify's previously cached account configuration.
        guard !LocalPlaylistDownload.launchEnabled,
              let root = target.viewIfLoaded,
              let button = root.eeveeFirst(UIButton.self, where: LocalPlaylistDownload.isDownloadButton) else { return }
        if !button.isHidden { button.isHidden = true }
    }
}

class LocalPlaylistDownloadActionHook: ClassHook<UIButton> {
    typealias Group = LocalPlaylistDownloadGroup

    func sendAction(_ action: Selector, to recipient: Any?, forEvent event: UIEvent?) {
        guard action == NSSelectorFromString("performAction"),
              LocalPlaylistDownload.isDownloadButton(target) else {
            orig.sendAction(action, to: recipient, forEvent: event)
            return
        }

        guard LocalPlaylistDownload.launchEnabled else { return }
        if LatestPremiumPatchingGroup.isActive || IOS14And15PremiumPatchingGroup.isActive {
            orig.sendAction(action, to: recipient, forEvent: event)
            return
        }

        showPlaylistDownloadingPopUp(true) {
            guard self.target.window != nil else { return }
            self.orig.sendAction(action, to: recipient, forEvent: nil)
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
