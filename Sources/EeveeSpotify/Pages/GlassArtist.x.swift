import Orion
import UIKit

struct GlassArtistGroup: HookGroup {}

class GlassArtistHook: ClassHook<UIViewController> {
    typealias Group = GlassArtistGroup
    static let targetName = "_TtC32CreativeWorkPlatform_TemplateKit22TemplateViewController"
    static var logged = false
    static var scrollKey: UInt8 = 0
    static var headerKey: UInt8 = 0
    static let meter = PerfMeter("Glass][Artist")

    func viewDidLayoutSubviews() {
        orig.viewDidLayoutSubviews()
        guard #available(iOS 26.0, *), let page = target.viewIfLoaded, page.accessibilityIdentifier == "creator-page" else { return }
        let row: Bool? = Self.meter.measure {
            guard let scroll = PageLookup.cached(&Self.scrollKey, in: page, {
                      PageLookup.find("PCFFTabLayoutViewController.containerScrollView", in: page)
                  }) as? UIScrollView,
                  let header = PageLookup.cached(&Self.headerKey, in: scroll, {
                      scroll.eeveeFirst(UIView.self, where: { NSStringFromClass(type(of: $0)).hasSuffix("HeaderContainer") })
                  })
            else { return nil }
            return GlassPlaylist.actionRow(host: page, controls: header, scroll: scroll, preservePreviewLayout: true)
        }
        if !Self.logged, let row {
            Self.logged = true
            eeveeLog("[EeveeSpotify][Glass] Artist action row %@", row ? "on" : "MISSING")
        }
    }
}
