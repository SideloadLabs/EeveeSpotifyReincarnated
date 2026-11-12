import EeveeSpotifyC
import Orion
import UIKit

struct GlassPlaylistGroup: HookGroup {}

@available(iOS 26.0, *)
enum GlassPlaylist {
    static let meter = PerfMeter("Glass][Playlist")
    private static var backdropKey: UInt8 = 0
    private static var logged = false
    private static var headerKey: UInt8 = 0
    private static var listKey: UInt8 = 0
    private static var heroKey: UInt8 = 0
    private static let listClass: AnyClass? = NSClassFromString(PlaylistListHook.targetName)
    private static var storedOptions = UserDefaults.playlistOptions
    private static let observer = NotificationCenter.default.addObserver(
        forName: .eeveePlaylistOptionsChanged, object: nil, queue: .main
    ) { _ in
        storedOptions = UserDefaults.playlistOptions
    }

    static var options: PlaylistOptions {
        _ = observer
        return storedOptions
    }

    private static func header(in root: UIView) -> UIView? {
        PageLookup.cached(&headerKey, in: root) {
            root.subviews.lazy.compactMap { $0.eeveeFirst(UIView.self, where: { $0.accessibilityIdentifier == "PL.Header" }) }.first
        }
    }

    private static func list(in root: UIView) -> UIScrollView? {
        guard let listClass else { return nil }
        return PageLookup.cached(&listKey, in: root) { root.eeveeFirst(UIScrollView.self) { $0.isKind(of: listClass) } } as? UIScrollView
    }

    // On top of Spotify's gradient, which it fades back in while the header collapses on scroll.
    static func stack(_ views: [UIView], on container: UIView) {
        guard !container.subviews.suffix(views.count).elementsEqual(views, by: { $0 === $1 }) else { return }
        views.forEach { container.addSubview($0) }
    }

    static func style(_ root: UIView) {
        if root.backgroundColor != .black { root.backgroundColor = .black }
        guard let header = header(in: root) else { return }
        let options = Self.options

        if let container = header.eeveeFirst(UIView.self, where: { $0.accessibilityIdentifier == "_backgroundViewContainer" }) {
            let backdrop = objc_getAssociatedObject(container, &backdropKey) as? CoverBackdrop ?? {
                let backdrop = CoverBackdrop(bottomAlpha: 1)
                objc_setAssociatedObject(container, &backdropKey, backdrop, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                return backdrop
            }()
            let artwork = header.eeveeFirst(UIView.self, where: { $0.accessibilityIdentifier == "Components.Header.UI.ArtworkImage" })
            let coverView = artwork?.eeveeFirst(UIImageView.self, where: { $0.bounds.width > 100 })
            let existingHero = objc_getAssociatedObject(container, &heroKey) as? HeroCover
            let hero: HeroCover? = !options.fullCover ? nil : existingHero ?? {
                let hero = HeroCover()
                objc_setAssociatedObject(container, &heroKey, hero, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                return hero
            }()
            if hero == nil { existingHero?.removeFromSuperview() }
            let stacked: [UIView] = hero.map { [backdrop, $0] } ?? [backdrop]
            stack(stacked, on: container)
            backdrop.frame = container.bounds
            backdrop.track(coverView)
            if let hero {
                hero.frame = container.bounds
                hero.track(coverView)
                artwork.map { if $0.alpha != 0 { $0.alpha = 0 } }
            } else {
                artwork.map { if $0.alpha == 0 { $0.alpha = 1 } }
            }
        }

        if let find = header.eeveeFirst(UIView.self, where: { $0.accessibilityIdentifier == "Components.Header.UI.Toolbar.SearchField" }) {
            let alpha: CGFloat = options.hideFind ? 0 : 1
            if find.alpha != alpha {
                find.alpha = alpha
                find.isUserInteractionEnabled = !options.hideFind
            }
        }

        let sort = PageLookup.find("Components.Header.UI.Toolbar.ButtonContainer", in: header)
        sort.map { GlassFindField.style($0) }
        let row = actionRow(host: root, controls: header, scroll: list(in: root))
        if !logged {
            logged = true
            eeveeLog("[EeveeSpotify][Glass] Playlist header styled, sort %@, action row %@", sort != nil ? "glass" : "absent", row ? "on" : "MISSING")
        }
    }
}

@available(iOS 26.0, *)
extension GlassPlaylist {
    private static var rowKey: UInt8 = 0
    private static var nearRowKey: UInt8 = 0
    private static let coreLabelClass: AnyClass? = NSClassFromString("_TtCE14Encore_TextKitO16EncoreFoundation6Encore9CoreLabel")

    static func centerTitleBlock(in header: UIView) {
        if let coreLabelClass {
            for label in collect(UILabel.self, in: header) where label.isKind(of: coreLabelClass) { centerText(label) }
        }
        guard header.bounds.height > 0 else { return }
        guard let metadata = PageLookup.find("Components.Header.UI.Metadata", in: header), !hiddenBelow(header, metadata) else {
            centerTitleOnly(in: header)
            return
        }
        var block: UIView = metadata
        while block.bounds.height < 60, block !== header, let parent = block.superview { block = parent }
        centerRows(in: block)
    }

    private static func centerRows(in block: UIView) {
        for row in block.subviews where row.bounds.width > 0 && !row.isHidden {
            let textViews = collect(UITextView.self, in: row)
            if !textViews.isEmpty {
                if !row.transform.isIdentity { row.transform = .identity }
                textViews.forEach { if $0.textAlignment != .center { $0.textAlignment = .center } }
                continue
            }
            let labels = collect(UILabel.self, in: row)
            var box = CGRect.null
            for leaf in labels as [UIView] + collect(UIControl.self, in: row) as [UIView] where !leaf.isHidden && leaf.alpha > 0 {
                box = box.union(leaf.convert(leaf.bounds, to: row))
            }
            if box.isNull || box.width > row.bounds.width * 0.8 || box.minX < 0 || box.maxX > row.bounds.width + 1 {
                if !row.transform.isIdentity { row.transform = .identity }
                labels.forEach(centerText)
                continue
            }
            center(row, box: box, in: block)
        }
    }

    private static func inToolbar(_ view: UIView, _ header: UIView) -> Bool {
        var current: UIView? = view
        while let node = current, node !== header {
            if node.accessibilityIdentifier?.hasPrefix("Components.Header.UI.Toolbar") == true { return true }
            current = node.superview
        }
        return false
    }

    private static func hiddenBelow(_ header: UIView, _ view: UIView) -> Bool {
        var current: UIView? = view
        while let node = current, node !== header {
            if node.isHidden { return true }
            current = node.superview
        }
        return false
    }

    // With the metadata rows hidden only the title is left to anchor on.
    private static func centerTitleOnly(in header: UIView) {
        guard let title = header.eeveeFirst(UILabel.self, where: {
            !($0.text ?? "").isEmpty && $0.alpha > 0 && $0.bounds.width > 0 && !inToolbar($0, header) && !hiddenBelow(header, $0)
        }) else { return }
        var columns = [UIView]()
        for anchor in [title, PageLookup.find("Components.PlaylistHeader.collaboratorsButton", in: header)].compactMap({ $0 }) {
            var row: UIView = anchor
            while row.bounds.width < header.bounds.width * 0.9, let parent = row.superview, parent !== header { row = parent }
            let column = row.superview ?? header
            if !columns.contains(where: { $0 === column }) { columns.append(column) }
        }
        columns.forEach(centerRows)
    }

    // Styled text carries its own paragraph alignment, which textAlignment alone doesn't override.
    static func centerText(_ label: UILabel) {
        if label.textAlignment != .center { label.textAlignment = .center }
        guard let text = label.attributedText, text.length > 0 else { return }
        let current = text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        guard current?.alignment != .center else { return }
        let styled = NSMutableAttributedString(attributedString: text)
        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            let style = ((value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            style.alignment = .center
            styled.addAttribute(.paragraphStyle, value: style, range: range)
        }
        label.attributedText = styled
    }

    static func collect<T: UIView>(_ type: T.Type, in root: UIView) -> [T] {
        var found = [T]()
        var queue = [root]
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if let match = view as? T, view !== root { found.append(match); continue }
            queue += view.subviews
        }
        return found
    }

    static func actionRow(host: UIView, controls: UIView, scroll: UIScrollView? = nil, preservePreviewLayout: Bool = false) -> Bool {
        let cached = objc_getAssociatedObject(host, &rowKey) as? PlaylistActionRow
        func source(_ identifier: String, previous: UIView?) -> UIView? {
            if let found = PageLookup.find(identifier, in: controls) { return found }
            guard cached?.sourceRoot === controls, let previous,
                  previous.isDescendant(of: controls) else { return nil }
            return previous
        }
        let sourceShuffle = source("Components.UI.ShuffleButton", previous: cached?.shuffle)
        let sourcePlay = source("header-play-button", previous: cached?.play)
        guard let shuffle = sourceShuffle, let play = sourcePlay else { return false }
        let add = source("Components.UI.AddToButton", previous: cached?.add)
        let share = source("Components.UI.ShareButton", previous: cached?.share)
        let follow = source("Curation.FollowButtonElementKit.FollowButton", previous: cached?.followControl)

        for control in [shuffle, add, share, follow].compactMap({ $0 }) {
            guard let holder = holder(of: control) else { continue }
            PlayerDeclutter.vanish(holder)
        }

        let row = objc_getAssociatedObject(host, &rowKey) as? PlaylistActionRow ?? {
            let row = PlaylistActionRow()
            objc_setAssociatedObject(host, &rowKey, row, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return row
        }()
        let download = PlaylistDownloadControl.resolve(in: controls)
        let explore = row.sourceRoot === controls && row.hosts(row.explore) ? row.explore : PageLookup.find("Components.UI.WatchFeedEntityExplorerButton", in: controls)
        if row.superview !== host || host.subviews.last !== row { host.addSubview(row) }
        row.bindNative(download: download, preview: explore, root: controls, preservePreviewLayout: preservePreviewLayout)
        row.shuffle = shuffle
        row.play = play
        row.add = add
        row.share = share
        row.followControl = follow
        row.bindArtistDownloads(header: host.accessibilityIdentifier == "creator-page" ? controls : nil)
        row.anchor = add ?? shuffle
        row.playHolder = holder(of: play)
        row.controlsRow = wideAncestor(of: shuffle, below: host)
        row.place()
        row.sync()
        var ancestor = host.superview
        while let view = ancestor, !(view is UIScrollView) { ancestor = view.superview }
        row.follow(scroll ?? ancestor as? UIScrollView)
        if host.window != nil { PlaylistActionRow.current = row }
        return true
    }


    static func row(near view: UIView) -> PlaylistActionRow? {
        if let row = (objc_getAssociatedObject(view, &nearRowKey) as? PageLookup.WeakView)?.view as? PlaylistActionRow { return row }
        var ancestor = view.superview
        while let current = ancestor {
            if let row = objc_getAssociatedObject(current, &rowKey) as? PlaylistActionRow {
                objc_setAssociatedObject(view, &nearRowKey, PageLookup.WeakView(row), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                return row
            }
            ancestor = current.superview
        }
        return nil
    }

    // Spotify's full-width row around its controls; it hides this once the header collapses.
    private static func wideAncestor(of control: UIView, below host: UIView) -> UIView? {
        var view = control.superview
        while let current = view, current !== host {
            if current.bounds.width >= 300 { return current }
            view = current.superview
        }
        return nil
    }

    // Frames are zero before layout; climbing then would hide page content.
    private static func holder(of control: UIView) -> UIView? {
        guard control.bounds.width > 0 else { return nil }
        var holder = control
        for _ in 0..<4 {
            guard let parent = holder.superview, parent.accessibilityIdentifier == nil,
                  parent.bounds.width > 0, parent.bounds.width <= 120, parent.bounds.height <= 60 else { break }
            holder = parent
        }
        return holder
    }

    static func center(_ view: UIView, box: CGRect, in host: UIView) {
        let left = view.convert(box.origin, to: host).x - view.transform.tx
        let dx = (host.bounds.width - box.width) / 2 - left
        if abs(dx - view.transform.tx) > 0.5 { view.transform = CGAffineTransform(translationX: dx, y: 0) }
    }
}

class GlassPlaylistHook: ClassHook<UIViewController> {
    typealias Group = GlassPlaylistGroup
    static let targetName = "_TtC35ListUXPlatform_FreeTierPlaylistImpl17FTPViewController"

    func viewDidLayoutSubviews() {
        orig.viewDidLayoutSubviews()
        guard #available(iOS 26.0, *), let root = target.viewIfLoaded else { return }
        GlassPlaylist.meter.measure { GlassPlaylist.style(root) }
    }

    func viewWillAppear(_ animated: Bool) {
        orig.viewWillAppear(animated)
        guard #available(iOS 26.0, *), let root = target.viewIfLoaded else { return }
        root.layoutIfNeeded()
    }

    // The cover loads after the first layout.
    func viewDidAppear(_ animated: Bool) {
        orig.viewDidAppear(animated)
        guard #available(iOS 26.0, *) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak target] in
            if let root = target?.viewIfLoaded, root.window != nil { GlassPlaylist.style(root) }
        }
    }
}

class PlaylistPlayStateHook: ClassHook<UIView> {
    typealias Group = GlassPlaylistGroup
    static let targetName = "_TtC28EncoreConsumerMobile_BaseKit14PlayButtonView"

    func setAccessibilityLabel(_ label: String?) {
        orig.setAccessibilityLabel(label)
        guard #available(iOS 26.0, *), target.accessibilityIdentifier == "header-play-button" else { return }
        if let row = GlassPlaylist.row(near: target) {
            row.sync()
        } else if let row = PlaylistActionRow.current, row.window != nil {
            row.sync()
        }
    }
}

// Spotify paints every row #121212; cleared per cell content so the cover fades into pure black with no seam.
@available(iOS 26.0, *)
enum PlaylistListPaint {
    static let meter = PerfMeter("Glass][PlaylistList")
    private static var paintedKey: UInt8 = 0
    private static var dividerKey: UInt8 = 0
    private static var insetKey: UInt8 = 0

    private final class Mark {
        weak var content: UIView?
        let inset: CGFloat?
        let time = CACurrentMediaTime()
        init(_ content: UIView?, inset: CGFloat? = nil) { self.content = content; self.inset = inset }
    }

    private static func cellContent(of cell: UIView) -> UIView? {
        if let cell = cell as? UICollectionViewCell { return cell.contentView.subviews.first }
        return cell.subviews.first
    }

    // Track rows only: playlist rows start their text after the artwork, album rows at the edge.
    private static func dividerInset(of cell: UIView, content: UIView?) -> CGFloat? {
        if let mark = objc_getAssociatedObject(cell, &insetKey) as? Mark, mark.content === content,
           mark.inset != nil || CACurrentMediaTime() - mark.time < 1 {
            return mark.inset
        }
        guard cell.bounds.height > 0 else { return nil }
        let inset: CGFloat?
        if cell.accessibilityIdentifier == "Playlist.ItemCell" {
            inset = 76
        } else if PageLookup.find("Components.UI.RetrievalRowElementUI", in: cell) != nil {
            inset = 16
        } else {
            inset = nil
        }
        objc_setAssociatedObject(cell, &insetKey, Mark(content, inset: inset), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return inset
    }

    static func clear(_ list: UIScrollView) {
        if list.backgroundColor != .black { list.backgroundColor = .black }
        let dividers = GlassPlaylist.options.dividers
        for cell in list.subviews {
            let content = cellContent(of: cell)
            let line = objc_getAssociatedObject(cell, &dividerKey) as? UIView
            guard let inset = dividerInset(of: cell, content: content) else {
                line?.isHidden = true
                continue
            }
            guard dividers else {
                line?.isHidden = true
                continue
            }
            let divider = line ?? {
                let divider = UIView()
                divider.backgroundColor = UIColor(white: 1, alpha: 0.1)
                divider.isUserInteractionEnabled = false
                cell.addSubview(divider)
                objc_setAssociatedObject(cell, &dividerKey, divider, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                return divider
            }()
            divider.isHidden = false
            let frame = CGRect(x: inset, y: cell.bounds.height - 0.5, width: cell.bounds.width - inset - 16, height: 0.5)
            if divider.frame != frame { divider.frame = frame }
        }
        for cell in list.subviews where cell.bounds.height > 0 {
            let content = cellContent(of: cell)
            if let content, (objc_getAssociatedObject(cell, &paintedKey) as? Mark)?.content === content { continue }
            objc_setAssociatedObject(cell, &paintedKey, Mark(content), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            var queue = [cell]
            while !queue.isEmpty {
                let view = queue.removeFirst()
                queue += view.subviews
                if let color = view.layer.backgroundColor, color.alpha > 0.9, UIColor(cgColor: color).isBaseSurface {
                    _ = EeveeInterceptBackground(view) { _ in }
                }
            }
        }
    }
}

class PlaylistListHook: ClassHook<UIScrollView> {
    typealias Group = GlassPlaylistGroup
    static let targetName = "_TtC35ListUXPlatform_FreeTierPlaylistImpl32FTPTouchCancellingCollectionView"

    func layoutSubviews() {
        orig.layoutSubviews()
        guard #available(iOS 26.0, *) else { return }
        PlaylistListPaint.meter.measure { PlaylistListPaint.clear(target) }
        GlassPlaylist.row(near: target)?.place()
    }
}

enum PlaylistHeader {
    private static var verdictKey: UInt8 = 0

    static func contains(_ view: UIView) -> Bool {
        PageLookup.isInside(view, id: "PL.Header", key: &verdictKey)
    }
}

// Spotify resets artwork alpha each scroll step; artist headers share this view.
class PlaylistArtworkHook: ClassHook<UIView> {
    typealias Group = GlassPlaylistGroup
    static let targetName = "_TtC19LegacyUI_ECMCoreKit15ShadowContainer"

    func setAlpha(_ alpha: CGFloat) {
        guard #available(iOS 26.0, *), GlassPlaylist.options.fullCover,
              target.accessibilityIdentifier == "Components.Header.UI.ArtworkImage", PlaylistHeader.contains(target) else {
            orig.setAlpha(alpha)
            return
        }
        orig.setAlpha(0)
    }
}

// Centered inside Spotify's own header layout pass, so the text is never drawn left-aligned first.
class PlaylistHeaderLayoutHook: ClassHook<UIView> {
    typealias Group = GlassPlaylistGroup
    static let targetName = "_TtC28EncoreConsumerMobile_BaseKit19HeaderContentLayout"

    func layoutSubviews() {
        orig.layoutSubviews()
        guard #available(iOS 26.0, *), PlaylistHeader.contains(target) else { return }
        GlassPlaylist.centerTitleBlock(in: target)
    }
}

// Curation pills (Add, Edit, Sort, …) already sit on a blur view; its effect is swapped for real glass.
@available(iOS 26.0, *)
enum PlaylistChips {
    private static var verdictKey: UInt8 = 0
    private static var logged = false

    static func style(_ button: UIView) {
        let verdict = objc_getAssociatedObject(button, &verdictKey) as? Bool
        if verdict == false { return }
        guard button.subviews.first is UIVisualEffectView, button.bounds.height > 0 else { return }
        if verdict == nil {
            var ancestor = button.superview
            var inToolbar = false
            for _ in 0..<10 {
                guard let view = ancestor else { break }
                if view.accessibilityIdentifier == "PlaylistCuration.Row.CurationActionsToolbar" { inToolbar = true; break }
                ancestor = view.superview
            }
            objc_setAssociatedObject(button, &verdictKey, inToolbar, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            guard inToolbar else { return }
        }
        if GlassKit.glassBlur(in: button) {
            if !logged {
                logged = true
                eeveeLog("[EeveeSpotify][Glass] Playlist pills on glass")
            }
        }
    }
}

class PlaylistChipHook: ClassHook<UIView> {
    typealias Group = GlassPlaylistGroup
    static let targetName = "_TtCCE16Encore_ButtonKitO16EncoreFoundation6Encore6Button7Primary"

    func layoutSubviews() {
        orig.layoutSubviews()
        guard #available(iOS 26.0, *) else { return }
        PlaylistChips.style(target)
    }
}
