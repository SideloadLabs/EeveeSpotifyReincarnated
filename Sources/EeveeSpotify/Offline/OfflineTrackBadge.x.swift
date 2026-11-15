import Orion
import UIKit

@MainActor
final class OfflineTrackBadges {
    static let shared = OfflineTrackBadges()
    static let identifier = "eevee-offline-track-badge"

    private let cells = NSHashTable<UICollectionViewCell>.weakObjects()
    private var saved = OfflineTrackBadgeIndex(tracks: OfflineLibraryStore.shared.downloadedTracks())

    private init() {
        NotificationCenter.default.addObserver(forName: OfflineLibraryStore.changed, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.saved = OfflineTrackBadgeIndex(tracks: OfflineLibraryStore.shared.downloadedTracks())
                for cell in self.cells.allObjects where cell.window != nil { self.refresh(cell) }
            }
        }
    }

    func update(_ cell: UICollectionViewCell) {
        cells.add(cell)
        refresh(cell)
    }

    private func refresh(_ cell: UICollectionViewCell) {
        let content = cell.contentView
        let existing = content.subviews.first { $0.accessibilityIdentifier == Self.identifier }
        guard !saved.isEmpty else {
            existing?.removeFromSuperview()
            return
        }
        let row = Self.trackRow(in: content)
        let usesArtistLayout = row == nil && PageLookup.ancestor(of: cell, id: "creator-page") != nil
        guard row != nil || usesArtistLayout || Self.isAlbumList(cell),
              let subtitle = Self.subtitle(in: row ?? content, cell: cell, saved: saved, numericOnly: usesArtistLayout) else {
            existing?.removeFromSuperview()
            return
        }
        let text = subtitle.attributedText ?? NSAttributedString(
            string: subtitle.text ?? "", attributes: [.font: subtitle.font ?? UIFont.systemFont(ofSize: 14)]
        )
        let bounds = subtitle.convert(subtitle.bounds, to: content)
        let size: CGFloat = 13
        let width = min(bounds.width, ceil(text.size().width))
        let rtl = subtitle.effectiveUserInterfaceLayoutDirection == .rightToLeft
        var x = rtl ? bounds.maxX - width - size - 5 : bounds.minX + width + 5
        if x < 4 || x + size > content.bounds.width - 12 {
            x = rtl ? bounds.maxX + 4 : bounds.minX - size - 4
        }
        guard bounds.height >= size, x >= 4, x + size <= content.bounds.width - 12 else {
            existing?.removeFromSuperview()
            return
        }
        let badge = existing ?? Self.makeBadge(size: size)
        badge.frame = CGRect(x: x, y: bounds.midY - size / 2, width: size, height: size).integral
        if badge.superview == nil { content.addSubview(badge) }
    }

    private static let nativeListRow: AnyClass? = NSClassFromString("_TtCE16Encore_LayoutKitO16EncoreFoundation6Encore7ListRow")

    private static func trackRow(in view: UIView) -> UIView? {
        guard !view.isHidden, view.alpha > 0.01 else { return nil }
        let name = NSStringFromClass(type(of: view))
        if nativeListRow.map({ view.isKind(of: $0) }) == true || name.hasSuffix("Encore7ListRow")
            || name.hasSuffix("Martini_ElementImpl.TrackRowView")
            || name.hasSuffix("Martini_ElementImpl12TrackRowView") { return view }
        return view.subviews.lazy.compactMap(trackRow).first
    }

    private static func trackID(_ cell: UICollectionViewCell, row: UIView) -> String? {
        let cellFields = Mirror(reflecting: cell)
        let plugin = cellFields.descendant("viewItem", "some", "pluginView")
            ?? cellFields.descendant("viewItem", "pluginView")
        let fields = plugin.map(Mirror.init(reflecting:))
        let config = cell.contentConfiguration.map(Mirror.init(reflecting:))
        let links = [Mirror(reflecting: row).descendant("currentTrackUri"),
                     config?.descendant("props", "entityURI"),
                     fields?.descendant("props", "some", "entityURI"), fields?.descendant("props", "entityURI"),
                     fields?.descendant("entityURL")]
        return links.lazy.compactMap { value -> String? in
            let uri = (value as? URL)?.absoluteString ?? value as? String
            guard let uri else { return nil }
            let id = extractSpotifyId(from: uri, type: "track")
            return id.isEmpty ? nil : id
        }.first
    }

    static func visibleTrackID(in roots: [UIViewController], title: String, artist: String) -> String? {
        guard !title.isEmpty, !artist.isEmpty else { return nil }
        let title = OfflineRecordingMatch.normalized(title)
        let artist = OfflineRecordingMatch.normalized(artist)
        var ids = Set<String>()
        for root in roots {
            guard let view = root.viewIfLoaded else { continue }
            var pending = [view]
            while let current = pending.popLast() {
                guard !current.isHidden else { continue }
                if let cell = current as? UICollectionViewCell {
                    let row = trackRow(in: cell.contentView) ?? cell.contentView
                    guard let id = trackID(cell, row: row),
                          hasLabel(title, in: row),
                          hasLabel(artist, in: row)
                              || artistName(for: cell).map(OfflineRecordingMatch.normalized) == artist else { continue }
                    ids.insert(id)
                } else {
                    pending.append(contentsOf: current.subviews)
                }
            }
        }
        return ids.count == 1 ? ids.first : nil
    }

    private static func hasLabel(_ normalized: String, in view: UIView) -> Bool {
        view.eeveeFirst(UILabel.self) {
            !$0.isHidden && OfflineRecordingMatch.normalized($0.attributedText?.string ?? $0.text ?? "") == normalized
        } != nil
    }

    private static func subtitle(in row: UIView, cell: UICollectionViewCell, saved: OfflineTrackBadgeIndex,
                                 numericOnly: Bool) -> UILabel? {
        let content = cell.contentView
        var labels: [(view: UILabel, text: String, frame: CGRect)] = []
        func visit(_ view: UIView) {
            guard !view.isHidden, view.alpha > 0.01, view.bounds.height > 0, !(view is UIButton) else { return }
            if let label = view as? UILabel, let text = label.attributedText?.string ?? label.text, !text.isEmpty {
                labels.append((label, text, label.convert(label.bounds, to: content)))
            } else {
                view.subviews.forEach(visit)
            }
        }
        visit(row)
        guard labels.contains(where: { saved.hasTitle($0.text) }) else { return nil }
        let trackID = trackID(cell, row: row)
        let exact = trackID.map(saved.contains(id:)) == true
        let pageArtist = !exact && labels.contains(where: { isPlayCount($0.text) }) ? artistName(for: cell) : nil
        for title in labels where saved.hasTitle(title.text) {
            for detail in labels where detail.frame.midY > title.frame.midY + 4 &&
                abs(detail.frame.minX - title.frame.minX) < 70 {
                let numeric = isPlayCount(detail.text)
                if numericOnly && !numeric { continue }
                if exact || saved.contains(title: title.text, artist: detail.text) { return detail.view }
                if numeric, let pageArtist,
                   saved.contains(title: title.text, artist: pageArtist, legacyOnly: trackID != nil) {
                    return detail.view
                }
            }
        }
        return nil
    }

    private static let countSeparators = CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",.٬"))
    private static var artistHeaderKey: UInt8 = 0

    private static func isPlayCount(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: CharacterSet.decimalDigits.contains) &&
            text.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) || countSeparators.contains($0) }
    }

    private static func artistName(for cell: UICollectionViewCell) -> String? {
        guard let page = PageLookup.ancestor(of: cell, id: "creator-page"),
              let header = PageLookup.cached(&artistHeaderKey, in: page, {
                  page.eeveeFirst(UIView.self) {
                      let name = NSStringFromClass(type(of: $0))
                      return name.contains("CreativeWorkPlatform_TemplateKit") && name.hasSuffix("HeaderContainer")
                  }
              }) else { return nil }
        let heading = header.eeveeFirst(UILabel.self) { label in
            !label.isHidden && label.font.pointSize >= 24 && !(label.attributedText?.string ?? label.text ?? "").isEmpty
        }
        return heading?.attributedText?.string ?? heading?.text
    }

    static func isAlbumList(_ list: UIView) -> Bool {
        guard let pageType = NSClassFromString(OfflineAlbumPageHook.targetName) else { return false }
        let responders = sequence(first: list as UIResponder, next: { $0.next })
        guard let page = responders.first(where: { $0.isKind(of: pageType) }) as? UIViewController,
              let uri = OfflineMenuHeaderHook.pageURI(in: page) else { return false }
        return !extractSpotifyId(from: uri.absoluteString, type: "album").isEmpty
    }

    private static func makeBadge(size: CGFloat) -> UIImageView {
        let image = UIImage(systemName: "arrow.down.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: size))
        let badge = UIImageView(image: image)
        badge.tintColor = UIColor(red: 30/255, green: 215/255, blue: 96/255, alpha: 1)
        badge.isUserInteractionEnabled = false
        badge.isAccessibilityElement = true
        badge.accessibilityIdentifier = identifier
        badge.accessibilityLabel = "offline_downloaded".localized
        return badge
    }
}

class OfflinePlaylistTrackBadgeHook: ClassHook<UICollectionViewCell> {
    typealias Group = OfflineHookGroup
    static let targetName = "_TtC35ListUXPlatform_FreeTierPlaylistImpl25ElementCollectionViewCell"

    func layoutSubviews() {
        orig.layoutSubviews()
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated { OfflineTrackBadges.shared.update(target) }
    }
}

struct OfflineLegacyAlbumBadgeHookGroup: HookGroup {}

class OfflineAlbumTrackBadgeHook: ClassHook<UICollectionViewCell> {
    typealias Group = OfflineLegacyAlbumBadgeHookGroup
    static let targetName = "_TtC27CreativeWorkPlatform_ECMKit4Cell"

    func layoutSubviews() {
        orig.layoutSubviews()
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated { OfflineTrackBadges.shared.update(target) }
    }
}

class OfflineTemplateTrackBadgeHook: ClassHook<UIView> {
    typealias Group = OfflineHookGroup
    static let targetName = "_TtC32CreativeWorkPlatform_TemplateKit28CreativeWorkTemplateListView"

    @objc(collectionView:willDisplayCell:forItemAtIndexPath:)
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        orig.collectionView(collectionView, willDisplay: cell, forItemAt: indexPath)
        DispatchQueue.main.async { [weak collectionView, weak cell] in
            guard let collectionView, let cell, collectionView.cellForItem(at: indexPath) === cell else { return }
            if PageLookup.ancestor(of: cell, id: "creator-page") != nil ||
                OfflineTrackBadges.isAlbumList(collectionView) {
                OfflineTrackBadges.shared.update(cell)
            }
        }
    }
}
