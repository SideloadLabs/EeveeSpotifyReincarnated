import EeveeSpotifyC
import Orion
import UIKit

struct GlassAlbumGroup: HookGroup {}

@available(iOS 26.0, *)
enum GlassAlbum {
    static let meter = PerfMeter("Glass][Album")
    private static var backdropKey: UInt8 = 0
    private static var heroKey: UInt8 = 0
    private static var logged = false
    private static var albumKey: UInt8 = 0
    private static var templateKey: UInt8 = 0
    private static var backgroundKey: UInt8 = 0
    private static var headerKey: UInt8 = 0
    private static var artworkKey: UInt8 = 0
    private static var scrollKey: UInt8 = 0
    private static var controlsKey: UInt8 = 0

    // Artist and other creative-work pages share this template; only pages with a cover are albums.
    static func isAlbum(_ template: UIView) -> Bool {
        objc_getAssociatedObject(template, &albumKey) as? Bool == true
    }

    static func template(in root: UIView) -> UIView? {
        PageLookup.cached(&templateKey, in: root) { PageLookup.find("CreativeWorkPlatform.CreativeWorkTemplateView", in: root) }
    }

    // Spotify's album-color gradient stays hidden until the page proves to be something else (an artist), so it never flashes.
    private static func setSpotifyGradient(in background: UIView, visible: Bool) {
        for sub in background.subviews where !(sub is CoverBackdrop) && !(sub is HeroCover) {
            let alpha: CGFloat = visible ? 1 : 0
            if sub.alpha != alpha { sub.alpha = alpha }
        }
    }

    // Scoped to the header so track rows' own add buttons are never picked up.
    private static func controls(around header: UIView, in template: UIView) -> UIView? {
        PageLookup.cached(&controlsKey, in: template) {
            guard let play = PageLookup.find("header-play-button", in: template) else { return nil }
            var container: UIView? = header
            while let view = container, !play.isDescendant(of: view) {
                if view === template { return nil }
                container = view.superview
            }
            return container
        }
    }

    static func style(_ template: UIView) {
        let verdict = objc_getAssociatedObject(template, &albumKey) as? Bool
        guard verdict != false,
              let background = PageLookup.cached(&backgroundKey, in: template, {
                  template.subviews.first { NSStringFromClass(type(of: $0)).hasSuffix("HeaderView") }
              }) else { return }
        let header = PageLookup.cached(&headerKey, in: template, { PageLookup.find("CreativeWorkPlatform.Header", in: template) })
        let artwork = header.flatMap { header in
            PageLookup.cached(&artworkKey, in: header, { PageLookup.find("CreativeWorkPlatform.Components.UI.ArtWorkElement.WithCoverArt", in: header) })
        }
        let scroll = PageLookup.cached(&scrollKey, in: template, { PageLookup.find("PCFFTabLayoutViewController.containerScrollView", in: template) }) as? UIScrollView
        guard let header, let artwork else {
            let loaded = (scroll?.alpha ?? 0) > 0.01
            setSpotifyGradient(in: background, visible: loaded)
            if loaded, header != nil { objc_setAssociatedObject(template, &albumKey, false, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
            return
        }
        if verdict == nil { objc_setAssociatedObject(template, &albumKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
        if template.backgroundColor != .black { template.backgroundColor = .black }
        setSpotifyGradient(in: background, visible: false)
        let coverView = artwork.eeveeFirst(UIImageView.self) { $0.bounds.width > 100 }

        let backdrop = objc_getAssociatedObject(background, &backdropKey) as? CoverBackdrop ?? {
            let backdrop = CoverBackdrop(bottomAlpha: 1)
            objc_setAssociatedObject(background, &backdropKey, backdrop, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return backdrop
        }()
        let existingHero = objc_getAssociatedObject(background, &heroKey) as? HeroCover
        let hero: HeroCover? = !GlassPlaylist.options.fullCover ? nil : existingHero ?? {
            let hero = HeroCover()
            objc_setAssociatedObject(background, &heroKey, hero, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return hero
        }()
        if hero == nil { existingHero?.removeFromSuperview() }
        let stacked: [UIView] = hero.map { [backdrop, $0] } ?? [backdrop]
        GlassPlaylist.stack(stacked, on: background)
        backdrop.frame = background.bounds
        backdrop.track(coverView)
        if let hero {
            hero.frame = background.bounds
            hero.track(coverView)
            if artwork.alpha != 0 { artwork.alpha = 0 }
        } else {
            if artwork.alpha == 0 { artwork.alpha = 1 }
        }

        centerTitleBlock(in: header)
        let row = controls(around: header, in: template).map { GlassPlaylist.actionRow(host: template, controls: $0, scroll: scroll) } ?? false
        if !logged {
            logged = true
            eeveeLog("[EeveeSpotify][Glass] Album header styled, action row %@", row ? "on" : "MISSING")
        }
    }
}

@available(iOS 26.0, *)
extension GlassAlbum {
    static func centerTitleBlock(in header: UIView) {
        guard let title = PageLookup.find("CreativeWorkPlatform.Components.UI.TitleRow", in: header),
              let metadata = PageLookup.find("Components.UI.MetadataRow", in: header),
              title.bounds.width > 0 else { return }
        // The title is centred by its text, not by the row around it. Where Spotify gives the row the whole width
        // and left-aligns the text inside, moving the row alone changes nothing.
        let visible: (UIView) -> Bool = { !$0.isHidden && $0.alpha > 0.01 && $0.bounds.width > 0 }
        let labels = GlassPlaylist.collect(UILabel.self, in: title).filter(visible)
        let textViews = GlassPlaylist.collect(UITextView.self, in: title).filter(visible)
        labels.forEach(GlassPlaylist.centerText)
        textViews.forEach { if $0.textAlignment != .center { $0.textAlignment = .center } }
        var titleBox = CGRect.null
        (labels as [UIView] + textViews as [UIView]).forEach { titleBox = titleBox.union($0.convert($0.bounds, to: title)) }
        GlassPlaylist.center(title, box: titleBox.isNull ? title.bounds : titleBox, in: header)

        var box = CGRect.null
        GlassPlaylist.collect(UILabel.self, in: metadata).forEach { box = box.union($0.convert($0.bounds, to: metadata)) }
        if !box.isNull, box.width > 0 { GlassPlaylist.center(metadata, box: box, in: header) }

        let top = title.convert(title.bounds, to: header).maxY - 1
        let bottom = metadata.convert(metadata.bounds, to: header).minY + 1
        let artist = GlassPlaylist.collect(UIControl.self, in: header).first {
            let frame = $0.convert($0.bounds, to: header)
            return frame.width > 0 && frame.minY >= top && frame.maxY <= bottom
        }
        if let artist { GlassPlaylist.center(artist, box: artist.bounds, in: header) }
    }
}

class GlassAlbumHook: ClassHook<UIViewController> {
    typealias Group = GlassAlbumGroup
    static let targetName = "_TtC28CreativeWorkPlatform_PageKit30CreativeWorkPageViewController"

    func viewDidLayoutSubviews() {
        orig.viewDidLayoutSubviews()
        guard #available(iOS 26.0, *), let root = target.viewIfLoaded, let template = GlassAlbum.template(in: root) else { return }
        GlassAlbum.meter.measure { GlassAlbum.style(template) }
    }

    func viewWillAppear(_ animated: Bool) {
        orig.viewWillAppear(animated)
        guard #available(iOS 26.0, *), let root = target.viewIfLoaded, let template = GlassAlbum.template(in: root) else { return }
        GlassAlbum.style(template)
    }

    // Content fades in without a layout pass of this controller; these catch the page once it's classified.
    func viewDidAppear(_ animated: Bool) {
        orig.viewDidAppear(animated)
        guard #available(iOS 26.0, *) else { return }
        for delay in [0.3, 0.8, 1.6] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak target] in
            guard let root = target?.viewIfLoaded, root.window != nil, let template = GlassAlbum.template(in: root) else { return }
            GlassAlbum.style(template)
        } }
    }
}

class GlassAlbumListHook: ClassHook<UIView> {
    typealias Group = GlassAlbumGroup
    static let targetName = "_TtC32CreativeWorkPlatform_TemplateKit28CreativeWorkTemplateListView"

    func layoutSubviews() {
        orig.layoutSubviews()
        guard #available(iOS 26.0, *), let list = target.subviews.first(where: { $0 is UICollectionView }) as? UIScrollView else { return }
        var template = target.superview
        while let view = template, view.accessibilityIdentifier != "CreativeWorkPlatform.CreativeWorkTemplateView" { template = view.superview }
        guard let template, GlassAlbum.isAlbum(template) else { return }
        PlaylistListPaint.meter.measure { PlaylistListPaint.clear(list) }
    }
}
