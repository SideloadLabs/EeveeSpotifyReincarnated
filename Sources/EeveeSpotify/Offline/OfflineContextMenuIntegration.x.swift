import Orion
import UIKit
import CryptoKit
import ObjectiveC.runtime

public class OfflineToastHUD {
    public static func show(message: String, icon: String = "arrow.down.circle.fill", duration: Double = 2.5) {
        OfflineDownloadPillHUD.shared.show(title: message, initialStatus: "")
    }
}

final class OfflineContextMenuActionRow: UIControl {
    var onTap: (() -> Void)?
    private let title = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.15, alpha: 0.85)
        layer.cornerRadius = 14
        translatesAutoresizingMaskIntoConstraints = false
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "offline_download".localized
        accessibilityIdentifier = "eevee-offline-download"

        let icon = UIImageView(image: UIImage(systemName: "arrow.down.circle",
                                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .medium)))
        icon.tintColor = UIColor(red: 30/255, green: 215/255, blue: 96/255, alpha: 1)
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)

        title.text = accessibilityLabel
        title.textColor = .white
        title.font = .preferredFont(forTextStyle: .headline)
        title.adjustsFontForContentSizeCategory = true
        title.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 14),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            title.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        addTarget(self, action: #selector(handleTap), for: .touchUpInside)
    }

    required init?(coder: NSCoder) { nil }

    override func accessibilityActivate() -> Bool {
        sendActions(for: .touchUpInside)
        return true
    }

    @objc private func handleTap() {
        onTap?()
    }

    override var isEnabled: Bool {
        didSet {
            title.text = (isEnabled ? "offline_download" : "offline_preparing").localized
            accessibilityLabel = title.text
        }
    }
}

func offlineObjectProperty(_ object: NSObject, _ name: String) -> AnyObject? {
    let selector = Selector(name)
    guard let method = class_getInstanceMethod(type(of: object), selector),
          method_getNumberOfArguments(method) == 2 else { return nil }
    let encoding = method_copyReturnType(method)
    defer { free(encoding) }
    guard encoding.pointee == 64 else { return nil }
    return object.perform(selector)?.takeUnretainedValue()
}

func findSpotifyURI(in root: AnyObject, type: String) -> String? {
    func matchingURI(_ value: Any?) -> String? {
        let string = (value as? URL)?.absoluteString ?? value as? String
        guard let string, !extractSpotifyId(from: string, type: type).isEmpty else { return nil }
        return string
    }
    if let uri = matchingURI(root) { return uri }

    let fields = Mirror(reflecting: root)
    let object = root as? NSObject
    let keys = ["pageURI", "trackURI", "playlistURI", "playlistURL", "entityURI", "targetURI", "entityURL",
                "spt_pageURI", "spotifyURI", "pageUri", "uri", "URI", "URL", "url",
                "playlistPlayerIdentifier", "pendingPlaylistURI"]
    for key in keys {
        if let uri = matchingURI(fields.descendant(key)) { return uri }
        if let object, let uri = matchingURI(offlineObjectProperty(object, key)) { return uri }
    }
    return nil
}

enum OfflineCollectionHistory {
    private static let lock = NSLock()
    private static var recent: [URL] = []

    static func record(_ urls: [URL]) {
        let collections = urls.compactMap { OfflineSpotifyIdentifier.collectionLink($0.absoluteString) }
        guard !collections.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        for url in collections {
            recent.removeAll { $0 == url }
            recent.insert(url, at: 0)
        }
        if recent.count > 16 { recent.removeLast(recent.count - 16) }
    }

    static func candidates(kind: String?) -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        guard let kind else { return Array(recent.prefix(6)) }
        let matches = recent.filter { !extractSpotifyId(from: $0.absoluteString, type: kind).isEmpty }
        return Array(matches.prefix(6))
    }
}

class OfflinePlaylistPageHook: ClassHook<UIViewController> {
    typealias Group = OfflineHookGroup
    static let targetName = "_TtC35ListUXPlatform_FreeTierPlaylistImpl17FTPViewController"

    func viewDidAppear(_ animated: Bool) {
        orig.viewDidAppear(animated)
        OfflineMenuHeaderHook.noteCollectionPage(target)
    }
}

class OfflineAlbumPageHook: ClassHook<UIViewController> {
    typealias Group = OfflineHookGroup
    static let targetName = "_TtC28CreativeWorkPlatform_PageKit30CreativeWorkPageViewController"

    func viewDidAppear(_ animated: Bool) {
        orig.viewDidAppear(animated)
        OfflineMenuHeaderHook.noteCollectionPage(target)
    }
}

class ContextMenuViewControllerHook: ClassHook<UIViewController> {
    typealias Group = OfflineHookGroup
    static let targetName = "_TtC24ContextMenu_InternalImpl25ContextMenuViewController"

    func viewWillAppear(_ animated: Bool) {
        orig.viewWillAppear(animated)
        Self.injectDownloadActionIfNeeded(in: target)
    }

    func viewDidAppear(_ animated: Bool) {
        orig.viewDidAppear(animated)
        Self.injectDownloadActionIfNeeded(in: target)
    }

    func viewDidLayoutSubviews() {
        orig.viewDidLayoutSubviews()
        DispatchQueue.main.async { [weak controller = target] in
            guard let controller, let view = controller.viewIfLoaded, view.window != nil else { return }
            Self.injectDownloadActionIfNeeded(in: controller)
        }
    }

    private static func injectDownloadActionIfNeeded(in target: UIViewController) {
        let tag = 77701
        let tableView = target.view.viewWithAccessibilityIdentifier("context-menu-table-view") as? UITableView
            ?? findTableView(in: target.view)
        guard let tableView, tableView.bounds.width > 32,
              tableView.tableHeaderView?.tag != tag else { return }

        let originalHeader = tableView.tableHeaderView
        let actionRow = OfflineContextMenuActionRow(frame: .zero)
        actionRow.onTap = { [weak target, weak tableView, weak originalHeader, weak actionRow] in
            guard let actionRow, actionRow.isEnabled else { return }
            actionRow.isEnabled = false
            DispatchQueue.main.async {
                guard let target, let tableView else {
                    actionRow.isEnabled = true
                    return
                }
                Self.downloadFromMenu(in: target, tableView: tableView, originalHeader: originalHeader, actionRow: actionRow)
            }
        }

        let container = UIView(frame: CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 70))
        container.tag = tag
        container.addSubview(actionRow)

        NSLayoutConstraint.activate([
            actionRow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            actionRow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            actionRow.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            actionRow.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6)
        ])

        if let existingHeader = originalHeader {
            let height = existingHeader.bounds.height
            tableView.tableHeaderView = nil
            let combined = UIStackView(arrangedSubviews: [existingHeader, container])
            combined.tag = tag
            combined.axis = .vertical
            combined.spacing = 8
            combined.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: height + 78)
            tableView.tableHeaderView = combined
        } else {
            tableView.tableHeaderView = container
        }
    }

    @MainActor
    private static func downloadFromMenu(in target: UIViewController, tableView: UITableView, originalHeader: UIView?,
                                         actionRow: OfflineContextMenuActionRow) {
        var loadingCollection = false
        defer { if !loadingCollection { actionRow.isEnabled = true } }
        let headers = [OfflineMenuHeaderHook.nativeHeader(in: target),
                       target.view.viewWithAccessibilityIdentifier("context-menu-header-view"),
                       originalHeader].compactMap { $0 }
        let selection = OfflineMenuHeaderHook.selection(in: target)
        let metadata = headers.compactMap { OfflineMenuHeaderHook.metadata(in: $0) }
        let header = metadata.first { $0.uri != nil } ?? metadata.first
        let title = [selection?.title, header?.title].compactMap { $0 }.first(where: OfflineSpotifyIdentifier.isMenuText)
            .map(cleanHtmlEntities)
        let metadataSubtitle = [selection?.subtitle, header?.subtitle].compactMap { $0 }
            .first(where: OfflineSpotifyIdentifier.isMenuText).map(cleanHtmlEntities)
        let entityURI = selection?.uri ?? header?.uri
        let headerURI = entityURI?.absoluteString
        let trackID = headerURI.map { extractSpotifyId(from: $0, type: "track") } ?? ""
        let trackActions = trackID.isEmpty && hasTrackAction(in: tableView)
        var fields: (title: String, subtitle: String) = ("", "")
        if title == nil || metadataSubtitle == nil || entityURI == nil {
            for header in headers {
                let text = OfflineSpotifyIdentifier.menuFields(headerText(in: header))
                if fields.title.isEmpty || !text.subtitle.isEmpty { fields = text }
                if !fields.subtitle.isEmpty { break }
            }
            if fields.subtitle.isEmpty {
                let tableTop = tableView.convert(tableView.bounds, to: target.view).minY
                let text = OfflineSpotifyIdentifier.menuFields(headerText(in: target.view, before: tableTop))
                if fields.title.isEmpty || !text.subtitle.isEmpty { fields = text }
            }
        }
        let rawTitle = title ?? fields.title
        let combined: (title: String, subtitle: String)?
        if trackID.isEmpty && !trackActions {
            combined = OfflineSpotifyIdentifier.splitCollectionTitle(rawTitle)
                ?? metadataSubtitle.flatMap(OfflineSpotifyIdentifier.splitCollectionTitle).flatMap { header in
                    OfflineRecordingMatch.normalized(header.title) == OfflineRecordingMatch.normalized(rawTitle) ? header : nil
                }
        } else {
            combined = nil
        }
        let foundTitle = combined?.title ?? rawTitle
        let subtitle = combined?.subtitle ?? metadataSubtitle ?? fields.subtitle
        let collectionKind = [combined?.subtitle, metadataSubtitle, fields.subtitle].compactMap { $0 }
            .lazy.compactMap(OfflineSpotifyIdentifier.menuCollectionKind).first
        let foundArtist = OfflineSpotifyIdentifier.menuArtist(subtitle) ?? ""
        let pageOwner = target.navigationController?.presentingViewController ?? target.presentingViewController
        let windowRoot = target.viewIfLoaded?.window?.rootViewController
        let recentPage = OfflineMenuHeaderHook.recentCollectionPage(in: target.viewIfLoaded?.window)
        let pageRoots = [pageOwner, recentPage, windowRoot].compactMap { $0 }
        func reportUnidentifiedItem() {
            OfflineDownloadPillHUD.shared.completeError(
                title: "offline_download".localized,
                errorMessage: (collectionKind == nil ? "offline_error_item_id" : "offline_error_collection_id").localized
            )
        }

        let albumID = headerURI.map { extractSpotifyId(from: $0, type: "album") } ?? ""
        let playlistID = headerURI.map { extractSpotifyId(from: $0, type: "playlist") } ?? ""
        if headerURI != nil, trackID.isEmpty, albumID.isEmpty, playlistID.isEmpty {
            reportUnidentifiedItem()
            return
        }
        let selectedCollection = !albumID.isEmpty || !playlistID.isEmpty ? entityURI : nil
        let visibleCollection: URL?
        if entityURI == nil, !trackActions, !foundTitle.isEmpty {
            let name = OfflineRecordingMatch.normalized(foundTitle)
            visibleCollection = pageRoots.lazy.compactMap {
                OfflineMenuHeaderHook.displayedCollection(in: $0, matching: name)
            }.first
        } else {
            visibleCollection = nil
        }
        let kind = trackID.isEmpty && !trackActions ? collectionKind : nil
        let fallbackTrackURI = entityURI == nil && visibleCollection == nil && kind == nil
            ? findSpotifyURI(in: target, type: "track") : nil
        let visibleTrackID = trackID.isEmpty && fallbackTrackURI == nil && selectedCollection == nil
            && visibleCollection == nil && kind == nil
            ? OfflineTrackBadges.visibleTrackID(in: pageRoots, title: foundTitle, artist: foundArtist) : nil
        let id = trackID.nonEmpty ?? fallbackTrackURI.map { extractSpotifyId(from: $0, type: "track") } ?? visibleTrackID

        let downloadTrack = { [weak target] in
            guard id != nil || (!foundTitle.isEmpty && !foundArtist.isEmpty) else {
                reportUnidentifiedItem()
                return
            }
            let key = OfflineRecordingMatch.normalized(foundTitle) + "\n" + OfflineRecordingMatch.normalized(foundArtist)
            let itemID = id ?? "track-" + SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
            if visibleTrackID != nil { EeveeLog.write("[Offline] Recovered track ID from the open page") }
            EeveeLog.write(id == nil ? "[Offline] Menu track identified by title and artist" : "[Offline] Menu track has Spotify ID")
            target?.dismiss(animated: true)
            OfflineDownloadManager.shared.downloadTrack(id: itemID, title: foundTitle.nonEmpty ?? "offline_download".localized,
                                                        artist: foundArtist)
        }
        if let collection = selectedCollection ?? visibleCollection {
            EeveeLog.write(selectedCollection == nil ? "[Offline] Matched collection to the open page"
                : "[Offline] Menu has a Spotify collection ID")
            let local = extractSpotifyId(from: collection.absoluteString, type: "playlist").nonEmpty.flatMap { id in
                pageRoots.lazy.compactMap { OfflineMenuHeaderHook.playlist(in: $0, id: id, matching: nil) }.first
            }
            let hint = albumID.isEmpty || foundTitle.isEmpty || foundArtist.isEmpty ? nil :
                OfflineSpotifyCollection.AlbumHint(title: foundTitle, artist: foundArtist, trackIDs: [])
            let album = OfflineMenuHeaderHook.albumHint(in: pageRoots, uri: collection, fallback: hint)
            target.dismiss(animated: true)
            PlaylistDownloaderHelper.fetchAndDownload(uri: collection, name: foundTitle.nonEmpty ?? "offline_collection".localized,
                                                      local: local, album: album)
        } else if id == nil, !trackActions, !foundTitle.isEmpty {
            let types = kind.map { [$0] } ?? ["playlist", "album"]
            let navigation = target.navigationController
            let candidates = [selection?.contextURI] + pageRoots.map { visibleCollectionURI($0, type: kind) } +
                types.map { type in navigation.flatMap { findSpotifyURI(in: $0, type: type).flatMap(URL.init(string:)) } }
            var seen = Set<URL>()
            let pages = candidates.compactMap { $0 }.compactMap { OfflineSpotifyIdentifier.collectionLink($0.absoluteString) }
                .filter { page in
                    types.contains { !extractSpotifyId(from: page.absoluteString, type: $0).isEmpty } && seen.insert(page).inserted
            }
            let previous = OfflineCollectionHistory.candidates(kind: kind).filter { !seen.contains($0) }
            if pages.isEmpty && previous.isEmpty && kind == nil {
                downloadTrack()
                return
            }
            loadingCollection = true
            if kind != nil {
                OfflineDownloadPillHUD.shared.show(title: foundTitle, initialStatus: "offline_read_collection".localized)
            }
            Task { @MainActor [weak target] in
                defer { actionRow.isEnabled = true }
                guard let target else { return }
                for page in pages {
                    let local = extractSpotifyId(from: page.absoluteString, type: "playlist").nonEmpty.flatMap { id in
                        pageRoots.lazy.compactMap { OfflineMenuHeaderHook.playlist(in: $0, id: id, matching: foundTitle) }.first
                    }
                    let album = OfflineMenuHeaderHook.albumHint(in: pageRoots, uri: page)
                    if await PlaylistDownloaderHelper.downloadVisibleCollection(uri: page, matching: foundTitle,
                                                                               local: local, album: album) {
                        target.dismiss(animated: true)
                        return
                    }
                }
                if await PlaylistDownloaderHelper.downloadRecentCollection(uris: previous, matching: foundTitle) {
                    target.dismiss(animated: true)
                    return
                }
                if let kind, await PlaylistDownloaderHelper.downloadCollectionByTitle(foundTitle, kind: kind) {
                    target.dismiss(animated: true)
                    return
                }
                if kind == nil { downloadTrack() }
                else { reportUnidentifiedItem() }
            }
        } else if kind != nil {
            reportUnidentifiedItem()
        } else {
            downloadTrack()
        }
    }

    private static func hasTrackAction(in tableView: UITableView) -> Bool {
        let trackActions: Set<String> = [
            "go to album", "view album", "view song credits", "view track credits", "hide this song", "hide song",
            "перейти к альбому", "показать альбом", "посмотреть сведения о треке", "скрыть этот трек", "скрыть песню"
        ]
        return tableView.visibleCells.contains { cell in
            headerText(in: cell.contentView).contains { trackActions.contains($0.lowercased()) }
        }
    }

    private static func headerText(in header: UIView, before bottom: CGFloat? = nil) -> [String] {
        var entries: [(text: String, y: CGFloat)] = []
        func visit(_ view: UIView) {
            guard !view.isHidden, !(view is OfflineContextMenuActionRow), !(view is UIButton),
                  !(view is UITableViewCell), !(view is UITableView) else { return }
            let frame = view.convert(view.bounds, to: header)
            let mayRead = bottom.map { view !== header && frame.height > 0 && frame.midY < $0 } ?? true
            let displayedText: String
            if !mayRead {
                displayedText = ""
            } else if let label = view as? UILabel {
                displayedText = label.text ?? label.attributedText?.string ?? ""
            } else if let text = OfflineMenuHeaderHook.encoreText(view), !text.isEmpty {
                displayedText = text
            } else if let value = offlineObjectProperty(view, "text") {
                let segments = (value as? [Any]) ?? [value]
                displayedText = segments.map(PlaylistDownloaderHelper.stringFromEncoreObject).joined()
            } else {
                displayedText = ""
            }
            let text = cleanHtmlEntities(displayedText)
            if OfflineSpotifyIdentifier.isMenuText(text) {
                entries.append((text, frame.minY))
                return
            }
            let previousCount = entries.count
            view.subviews.forEach(visit)
            if mayRead, entries.count == previousCount, !view.accessibilityTraits.contains(.button),
               let label = view.accessibilityLabel, OfflineSpotifyIdentifier.isMenuText(label),
               view.accessibilityTraits.contains(.staticText) || label.contains("\n") {
                entries.append((cleanHtmlEntities(label), frame.minY))
            }
        }
        visit(header)
        var seen = Set<String>()
        return entries.sorted { $0.y < $1.y }.map(\.text).filter { seen.insert($0).inserted }
    }

    private static func findTableView(in view: UIView) -> UITableView? {
        if let tv = view as? UITableView { return tv }
        for sub in view.subviews {
            if let found = findTableView(in: sub) { return found }
        }
        return nil
    }

    private static func visibleCollectionURI(_ root: UIViewController?, type: String?, depth: Int = 7) -> URL? {
        guard let root, depth > 0 else { return nil }
        if let uri = OfflineMenuHeaderHook.pageURI(in: root),
           (type.map { !extractSpotifyId(from: uri.absoluteString, type: $0).isEmpty }
            ?? ["playlist", "album"].contains { !extractSpotifyId(from: uri.absoluteString, type: $0).isEmpty }) { return uri }
        for kind in (type.map { [$0] } ?? ["playlist", "album"]) {
            if let uri = findSpotifyURI(in: root, type: kind).flatMap(URL.init(string:)) { return uri }
        }
        return OfflineMenuHeaderHook.pageChildren(in: root).lazy.compactMap {
            visibleCollectionURI($0, type: type, depth: depth - 1)
        }.first
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

private extension UIView {
    func viewWithAccessibilityIdentifier(_ identifier: String) -> UIView? {
        if accessibilityIdentifier == identifier { return self }
        guard !(self is UITableView) else { return nil }
        return subviews.lazy.compactMap { $0.viewWithAccessibilityIdentifier(identifier) }.first
    }
}
