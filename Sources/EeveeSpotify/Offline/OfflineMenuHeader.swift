import ObjectiveC.runtime
import UIKit

final class OfflineMenuHeader: NSObject {
    let title: String
    let subtitle: String
    let uri: URL?
    let contextURI: URL?

    init(title: String, subtitle: String, uri: URL?, contextURI: URL? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.uri = uri
        self.contextURI = contextURI
    }
}

enum OfflineMenuHeaderHook {
    private static var key: UInt8 = 0
    private static let selector = NSSelectorFromString("createContextMenuViewHeaderWithTitle:subtitle:entityURL:imageURL:fallbackHeader:")
    private static weak var lastPage: UIViewController?
    private static weak var lastPageWindow: UIWindow?

    static func noteCollectionPage(_ controller: UIViewController) {
        lastPage = controller
        lastPageWindow = controller.viewIfLoaded?.window
        if let uri = pageURI(in: controller) { OfflineCollectionHistory.record([uri]) }
    }

    static func recentCollectionPage(in window: UIWindow?) -> UIViewController? {
        guard let window, lastPageWindow === window else { return nil }
        return lastPage
    }

    static func install(on factory: AnyClass?) {
        guard let factory, let method = class_getInstanceMethod(factory, selector),
              method_getNumberOfArguments(method) == 7 else { return }
        let returnType = method_copyReturnType(method)
        defer { free(returnType) }
        guard returnType.pointee == 64 else { return }
        for index in 2..<7 {
            guard let type = method_copyArgumentType(method, UInt32(index)) else { return }
            let isObject = type.pointee == 64
            free(type)
            guard isObject else { return }
        }

        typealias Original = @convention(c) (AnyObject, Selector, NSString?, NSString?, NSURL?, NSURL?, UIView?) -> UIView?
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        let command = selector
        let block: @convention(block) (AnyObject, NSString?, NSString?, NSURL?, NSURL?, UIView?) -> UIView? = {
            factory, title, subtitle, uri, artwork, fallback in
            let view = original(factory, command, title, subtitle, uri, artwork, fallback)
            if let view, Thread.isMainThread {
                let header = uri.map {
                    OfflineMenuHeader(title: title as String? ?? "", subtitle: subtitle as String? ?? "", uri: $0 as URL)
                }
                objc_setAssociatedObject(view, &key, header, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
            return view
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    static func metadata(in view: UIView) -> OfflineMenuHeader? {
        if let header = objc_getAssociatedObject(view, &key) as? OfflineMenuHeader { return header }
        let fields = Mirror(reflecting: view)
        let model = fields.descendant("model").map(Mirror.init(reflecting:))
        let uri = spotifyURL(fields.descendant("entityURL") ?? model?.descendant("entityURL"))
        let title = model?.descendant("title") as? String ?? fields.descendant("title") as? String
            ?? encoreText(fields.descendant("titleLabel") as? UIView)
        let detail = model?.descendant("metadata") as? String ?? ""
        let subtitle = OfflineSpotifyIdentifier.menuCollectionKind(detail) != nil ? detail :
            model?.descendant("subtitle") as? String ?? encoreText(fields.descendant("subtitleLabel") as? UIView)
        if uri != nil || (title != nil && subtitle != nil) {
            return OfflineMenuHeader(title: title ?? "", subtitle: subtitle ?? "", uri: uri)
        }
        return view.subviews.lazy.compactMap { metadata(in: $0) }.first
    }

    static func nativeHeader(in controller: UIViewController) -> UIView? {
        Mirror(reflecting: controller).descendant("$__lazy_storage_$_headerView") as? UIView
    }

    static func pageURI(in controller: UIViewController) -> URL? {
        let fields = Mirror(reflecting: controller)
        let page = pageController(in: controller).map(Mirror.init(reflecting:))
        return [
            fields.descendant("template", "creativeWork", "uri"),
            fields.descendant("template", "uri"),
            fields.descendant("playlistViewModel", "entityModel", "entityURL"),
            fields.descendant("playlistViewModel", "entityModel", "metadata", "playlistUrl"),
            fields.descendant("playlistViewModel", "playlistModel", "playlistURL"),
            page?.descendant("pageURI"), page?.descendant("uri"), page?.descendant("identity", "uri")
        ].lazy.compactMap(spotifyURL).first
    }

    static func displayedCollection(in controller: UIViewController, matching title: String,
                                    depth: Int = 7) -> URL? {
        guard depth > 0 else { return nil }
        if let name = collectionName(in: controller), OfflineRecordingMatch.normalized(name) == title,
           let uri = pageURI(in: controller), let collection = OfflineSpotifyIdentifier.collectionLink(uri.absoluteString) {
            return collection
        }
        return pageChildren(in: controller).lazy.compactMap {
            displayedCollection(in: $0, matching: title, depth: depth - 1)
        }.first
    }

    static func collectionName(in roots: [UIViewController], uri: URL, depth: Int = 7) -> String? {
        guard depth > 0, let collection = OfflineSpotifyIdentifier.collectionLink(uri.absoluteString) else { return nil }
        for root in roots {
            if let uri = pageURI(in: root), OfflineSpotifyIdentifier.collectionLink(uri.absoluteString) == collection,
               let name = collectionName(in: root), !name.isEmpty { return name }
            if let name = collectionName(in: pageChildren(in: root), uri: collection, depth: depth - 1) { return name }
        }
        return nil
    }

    private static func collectionName(in controller: UIViewController) -> String? {
        let fields = Mirror(reflecting: controller)
        return fields.descendant("template", "creativeWork", "traits", "name") as? String
            ?? fields.descendant("playlistViewModel", "entityModel", "metadata", "name") as? String
    }

    static func albumHint(in roots: [UIViewController], uri: URL,
                          fallback: OfflineSpotifyCollection.AlbumHint? = nil,
                          depth: Int = 7) -> OfflineSpotifyCollection.AlbumHint? {
        guard depth > 0, let collection = OfflineSpotifyIdentifier.collectionLink(uri.absoluteString),
              !extractSpotifyId(from: collection.absoluteString, type: "album").isEmpty else { return nil }
        for root in roots {
            if let pageURI = pageURI(in: root),
               OfflineSpotifyIdentifier.collectionLink(pageURI.absoluteString) == collection,
               let work = Mirror(reflecting: root).descendant("template", "creativeWork") {
                let fields = Mirror(reflecting: work)
                if let name = fields.descendant("traits", "name") as? String, !name.isEmpty,
                   let agents = fields.descendant("agents") as? [Any],
                   let artist = agents.lazy.compactMap({ Mirror(reflecting: $0).descendant("name") as? String })
                       .first(where: { !$0.isEmpty }) {
                    let date = fields.descendant("traits", "releaseDate") as? Date
                    let releaseDate = date.map { date in
                        let formatter = DateFormatter()
                        formatter.locale = Locale(identifier: "en_US_POSIX")
                        formatter.dateFormat = "yyyy-MM-dd"
                        return formatter.string(from: date)
                    }
                    return albumTracks(in: root.viewIfLoaded, collection: collection, title: name, artist: artist,
                                       releaseDate: releaseDate)
                }
                if let fallback {
                    return albumTracks(in: root.viewIfLoaded, collection: collection, title: fallback.title,
                                       artist: fallback.artist, releaseDate: fallback.releaseDate)
                }
            }
            if let result = albumHint(in: pageChildren(in: root), uri: collection, depth: depth - 1) {
                return result
            }
        }
        return fallback
    }

    private static func albumTracks(in root: UIView?, collection: URL, title: String, artist: String,
                                    releaseDate: String?) -> OfflineSpotifyCollection.AlbumHint {
        var empty = OfflineSpotifyCollection.AlbumHint(title: title, artist: artist, trackIDs: [], releaseDate: releaseDate)
        guard let root else { return empty }
        func addVisibleLabels(to hint: inout OfflineSpotifyCollection.AlbumHint) {
            guard hint.visibleTracks.isEmpty else { return }
            let artistName = OfflineRecordingMatch.normalized(artist)
            let albumName = OfflineRecordingMatch.normalized(title)
            var queue = [root]
            while let view = queue.popLast(), hint.visibleTracks.count < 8 {
                guard !view.isHidden, view.alpha > 0.01 else { continue }
                guard view is UICollectionViewCell || view is UITableViewCell else {
                    queue.append(contentsOf: view.subviews.reversed())
                    continue
                }
                guard let credit = view.eeveeFirst(UILabel.self, where: {
                    !$0.isHidden && OfflineRecordingMatch.normalized(OfflineRecordingMatch.primaryCredit(labelText($0))) == artistName
                }) else { continue }
                let creditFrame = credit.convert(credit.bounds, to: view)
                guard let track = view.eeveeFirst(UILabel.self, where: {
                    let text = labelText($0)
                    let frame = $0.convert($0.bounds, to: view)
                    return !$0.isHidden && frame.midY < creditFrame.midY - 4 && abs(frame.minX - creditFrame.minX) < 45
                        && OfflineSpotifyIdentifier.isMenuText(text)
                        && OfflineRecordingMatch.normalized(text) != albumName && view.bounds.width > 120
                }) else { continue }
                let id = "visible-\(hint.visibleTracks.count)"
                hint.visibleTracks.append(QueuedTrackItem(id: id, title: labelText(track), artist: labelText(credit), album: title))
                if !hint.hasExplicitTrack {
                    hint.hasExplicitTrack = view.eeveeFirst(UIView.self) {
                        !$0.isHidden && (NSStringFromClass(type(of: $0)).contains("ExplicitBadge")
                            || ($0 as? UILabel).map(labelText) == "E")
                    } != nil
                }
            }
        }
        guard let listType = NSClassFromString("_TtC32CreativeWorkPlatform_TemplateKit28CreativeWorkTemplateListView"),
              let list = root.eeveeFirst(UIView.self, where: { $0.isKind(of: listType) }) else {
            addVisibleLabels(to: &empty)
            return empty
        }
        let fields = Mirror(reflecting: list)
        let renderer = fields.descendant("renderer", "some").map(Mirror.init(reflecting:))
        let snapshot = renderer?.descendant("contentDataSource", "contentSnapshot").map(Mirror.init(reflecting:))
        let items = snapshot?.descendant("items") as? [AnyHashable: Any] ?? [:]
        let rows = items.values.compactMap { item -> (id: String, index: Int?)? in
            guard let props = Mirror(reflecting: item).descendant("item", "configuration", "props") else { return nil }
            let row = Mirror(reflecting: props)
            guard let id = albumTrackID(row, collection: collection) else { return nil }
            return (id, row.descendant("indexNumber") as? Int)
        }
        let indices = rows.compactMap(\.index).sorted()
        let ordered = !indices.isEmpty && indices.count == rows.count &&
            (indices.first == 1 || indices.first == 0) &&
            (indices.last ?? 0) - (indices.first ?? 0) == rows.count - 1 &&
            Set(indices).count == indices.count
        let trackIDs = ordered ? rows.sorted { ($0.index ?? 0) < ($1.index ?? 0) }.map(\.id) : rows.map(\.id)
        var hint = OfflineSpotifyCollection.AlbumHint(title: title, artist: artist, trackIDs: trackIDs,
                                                     releaseDate: releaseDate, hasTrackOrder: ordered)
        let listView = fields.descendant("collectionView") as? UICollectionView
        let sections = snapshot?.descendant("sections") as? [Any] ?? []
        for cell in listView?.visibleCells ?? [] {
            let config = cell.contentConfiguration.map(Mirror.init(reflecting:))
            let content = cell.contentView.eeveeFirst(UIView.self) {
                let name = NSStringFromClass(type(of: $0))
                return name.contains("Element_UIKit") && name.contains("ElementContentView")
            }.map(Mirror.init(reflecting:))
            let item = listView?.indexPath(for: cell).flatMap { index -> Any? in
                guard sections.indices.contains(index.section),
                      let keys = Mirror(reflecting: sections[index.section]).descendant("items") as? [AnyHashable],
                      keys.indices.contains(index.item) else { return nil }
                return items[keys[index.item]]
            }
            let props = config?.descendant("props") ?? content?.descendant("elementConfiguration", "props")
                ?? item.flatMap { Mirror(reflecting: $0).descendant("item", "configuration", "props") }
            guard let props, let id = albumTrackID(Mirror(reflecting: props), collection: collection) else { continue }
            let titleLabel = retrievalLabel(in: cell, suffix: "9TitleView")
            guard let name = titleLabel, !name.isEmpty else { continue }
            let credit = retrievalLabel(in: cell, suffix: "12SubtitleView") ?? artist
            hint.visibleTracks.append(QueuedTrackItem(id: id, title: name, artist: credit, album: title))
            if !hint.hasExplicitTrack {
                hint.hasExplicitTrack = cell.eeveeFirst(UIView.self) {
                    !$0.isHidden && NSStringFromClass(type(of: $0)).hasSuffix("13ExplicitBadge")
                } != nil
            }
        }
        addVisibleLabels(to: &hint)
        return hint
    }

    private static func labelText(_ label: UILabel) -> String {
        label.attributedText?.string ?? label.text ?? ""
    }

    private static func albumTrackID(_ props: Mirror, collection: URL) -> String? {
        guard let parent = spotifyURL(props.descendant("parentURI")),
              OfflineSpotifyIdentifier.collectionLink(parent.absoluteString) == collection,
              let url = spotifyURL(props.descendant("entityURI")) else { return nil }
        let id = extractSpotifyId(from: url.absoluteString, type: "track")
        return id.isEmpty ? nil : id
    }

    private static func retrievalLabel(in cell: UICollectionViewCell, suffix: String) -> String? {
        let component = cell.eeveeFirst(UIView.self) {
            let name = NSStringFromClass(type(of: $0))
            return name.contains("RetrievalRowElementUI") && name.hasSuffix(suffix)
        }
        let label = component?.eeveeFirst(UILabel.self) {
            !$0.isHidden && !($0.attributedText?.string ?? $0.text ?? "").isEmpty
        }
        return label?.attributedText?.string ?? label?.text
    }

    static func pageChildren(in controller: UIViewController) -> [UIViewController] {
        if let nav = controller as? UINavigationController { return [nav.topViewController].compactMap { $0 } }
        if let tabs = controller as? UITabBarController { return [tabs.selectedViewController].compactMap { $0 } }
        let fields = Mirror(reflecting: controller)
        if let current = ["contentViewController", "currentChild"].lazy
            .compactMap({ fields.descendant($0) as? UIViewController }).first { return [current] }
        return controller.children.reversed().filter { $0.viewIfLoaded?.isHidden == false }
    }

    static func playlist(in controller: UIViewController, id: String, matching title: String?,
                         depth: Int = 7) -> OfflineSpotifyCollection.Result? {
        guard depth > 0 else { return nil }
        let fields = Mirror(reflecting: controller)
        if let model = fields.descendant("playlistViewModel", "entityModel"),
           let uri = spotifyURL(Mirror(reflecting: model).descendant("entityURL")),
           extractSpotifyId(from: uri.absoluteString, type: "playlist") == id {
            let model = Mirror(reflecting: model)
            let name = model.descendant("metadata", "name") as? String
            let tracks = model.descendant("tracks").map(Mirror.init(reflecting:))
            let totals = [tracks?.descendant("unrangedLength"), tracks?.descendant("unfilteredLength"),
                          model.descendant("metadata", "totalLength")].compactMap { $0 as? Int }
            if title == nil || name.map(OfflineRecordingMatch.normalized) == title.map(OfflineRecordingMatch.normalized),
               let rows = tracks?.descendant("items") as? [Any],
               let total = totals.max(), total >= rows.count {
                let items = rows.compactMap { row -> QueuedTrackItem? in
                    let loaded = Mirror(reflecting: Mirror(reflecting: row).descendant("loaded") ?? row)
                    guard let uri = spotifyURL(loaded.descendant("uri")) else { return nil }
                    let trackID = extractSpotifyId(from: uri.absoluteString, type: "track")
                    let metadata = loaded.descendant("metadata").map(Mirror.init(reflecting:))
                    guard !trackID.isEmpty, let name = metadata?.descendant("name") as? String, !name.isEmpty,
                          let artists = metadata?.descendant("artists") as? [Any] else { return nil }
                    let artist = artists.compactMap { Mirror(reflecting: $0).descendant("name") as? String }
                        .filter { !$0.isEmpty }.joined(separator: ", ")
                    guard !artist.isEmpty else { return nil }
                    let duration = metadata?.descendant("duration") as? Double
                    return QueuedTrackItem(id: trackID, title: name, artist: artist,
                                           album: metadata?.descendant("albumName") as? String,
                                           duration: duration.flatMap { $0 > 0 ? $0 : nil })
                }
                if !items.isEmpty {
                    return OfflineSpotifyCollection.Result(tracks: items, unavailable: total - items.count, name: name)
                }
            }
        }
        return pageChildren(in: controller).lazy.compactMap {
            playlist(in: $0, id: id, matching: title, depth: depth - 1)
        }.first
    }

    static func selection(in controller: UIViewController) -> OfflineMenuHeader? {
        guard let navigation = controller.navigationController,
              let top = navigation.topViewController,
              top === controller || controller.isDescendant(of: top),
              let parameters = [controller, navigation].lazy.compactMap({
                  pageController(in: $0).flatMap { Mirror(reflecting: $0).descendant("parameters") }
              }).first else { return nil }
        let fields = Mirror(reflecting: parameters)
        let selection = fields.descendant("selectionContext").map(Mirror.init(reflecting:))
        let multiple = selection?.descendant("target", "multiTarget") as? [Any]
        let uri = spotifyURL(selection?.descendant("target", "singleTarget"))
            ?? spotifyURL(selection?.descendant("target", "singleTarget", ".0"))
            ?? (multiple?.count == 1 ? spotifyURL(multiple?.first) : nil)
        let detail = fields.descendant("header", "header", "metadata") as? String ?? ""
        let subtitle = OfflineSpotifyIdentifier.menuCollectionKind(detail) != nil ? detail :
            fields.descendant("header", "header", "subtitle") as? String ?? ""
        let context = selection?.descendant("pageContext").map(Mirror.init(reflecting:))
        let contextURI = spotifyURL(context?.descendant("uri")) ?? spotifyURL(context?.descendant("uri", ".0"))
            ?? spotifyURL(fields.descendant("loggingURI"))
        return OfflineMenuHeader(title: fields.descendant("header", "header", "title") as? String ?? "",
                                 subtitle: subtitle, uri: uri, contextURI: contextURI)
    }

    private static func pageController(in controller: UIViewController) -> Any? {
        if let page = offlineObjectProperty(controller, "spt_currentPageController") { return page }
        guard let page = Mirror(reflecting: controller).descendant("currentPageController") else { return nil }
        let fields = Mirror(reflecting: page)
        return fields.displayStyle == .optional ? fields.children.first?.value : page
    }

    private static func spotifyURL(_ value: Any?) -> URL? {
        guard let value else { return nil }
        let raw = value as? String ?? Mirror(reflecting: value).descendant("rawValue") as? String
        let url = value as? URL ?? raw.flatMap(URL.init(string:))
        guard let url, !extractSpotifyId(from: url.absoluteString).isEmpty else { return nil }
        return url
    }

    static func encoreText(_ view: UIView?) -> String? {
        guard let view, let label = Mirror(reflecting: view).descendant("internalLabel") as? UILabel else { return nil }
        return label.attributedText?.string ?? label.text
    }
}

private extension UIViewController {
    func isDescendant(of controller: UIViewController) -> Bool {
        var ancestor = parent
        while let current = ancestor {
            if current === controller { return true }
            ancestor = current.parent
        }
        return false
    }
}
