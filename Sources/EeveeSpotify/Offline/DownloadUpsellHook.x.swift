import UIKit

enum DownloadUpsellButtonHook {
    private static let selector = NSSelectorFromString("didTapDownloadUpsellButtonWithEntityPageMetadata:")

    static func install() {
        guard let cls = NSClassFromString("_TtC31ReinventFree_DownloadUpsellImpl33DownloadUpsellButtonViewModelImpl"),
              let method = class_getInstanceMethod(cls, selector), method_getNumberOfArguments(method) == 3,
              let argument = method_copyArgumentType(method, 2) else { return }
        let result = method_copyReturnType(method)
        defer { free(argument); free(result) }
        guard argument.pointee == 64, result.pointee == 118 else { return }

        typealias Original = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        let command = selector
        let replacement: @convention(block) (AnyObject, AnyObject?) -> Void = { target, metadata in
            if let metadata, downloadCollection(from: metadata) { return }
            original(target, command, metadata)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }

    private static func downloadCollection(from metadata: AnyObject) -> Bool {
        let uri = findSpotifyURI(in: metadata, type: "album") ?? findSpotifyURI(in: metadata, type: "playlist")
        guard let uri, let pageURI = URL(string: uri) else { return false }
        let fields = Mirror(reflecting: metadata)
        let entityName = fields.descendant("entityName") as? String ?? (metadata as? NSObject).flatMap { object in
            ["entityName", "title", "name", "headerTitle"].compactMap {
                offlineObjectProperty(object, $0) as? String
            }.first { !$0.isEmpty }
        }
        let creatorName = fields.descendant("creatorName") as? String
        let fallback: OfflineSpotifyCollection.AlbumHint?
        if let entityName, !entityName.isEmpty, let creatorName, !creatorName.isEmpty {
            fallback = .init(title: entityName, artist: creatorName, trackIDs: [])
        } else {
            fallback = nil
        }
        DispatchQueue.main.async {
            let window = OfflinePresentationHelper.activeWindow
            let roots = [OfflineMenuHeaderHook.recentCollectionPage(in: window), window?.rootViewController].compactMap { $0 }
            let album = OfflineMenuHeaderHook.albumHint(in: roots, uri: pageURI, fallback: fallback)
            let playlistID = extractSpotifyId(from: uri, type: "playlist")
            let local = playlistID.isEmpty ? nil : roots.lazy.compactMap {
                OfflineMenuHeaderHook.playlist(in: $0, id: playlistID, matching: nil)
            }.first
            let name = local?.name ?? album?.title ?? OfflineMenuHeaderHook.collectionName(in: roots, uri: pageURI)
                ?? entityName ?? "offline_collection".localized
            let alert = UIAlertController(
                title: String(format: "offline_confirm_collection".localized, name),
                message: "offline_collection_message".localized, preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "offline_download_collection".localized, style: .default) { _ in
                PlaylistDownloaderHelper.fetchAndDownload(uri: pageURI, name: name, local: local, album: album)
            })
            alert.addAction(UIAlertAction(title: "offline_cancel".localized, style: .cancel))
            OfflinePresentationHelper.safePresent(alert)
        }
        return true
    }
}
