import EeveeSpotifyC
import Orion
import UIKit

struct GlassNowPlayingBarGroup: HookGroup {}

@available(iOS 26.0, *)
enum GlassNowPlayingBar {
    static let meter = PerfMeter("Glass][NowPlayingBar")
    private static weak var card: UIView?
    private static weak var pane: UIVisualEffectView?
    private static weak var container: UIViewController?
    private static weak var artwork: UIView?
    private static var albumColor: UIColor?
    private static var misses = 0
    private static var styled: Styled?
    private static var options = UserDefaults.nowPlayingBarOptions
    private static let observer = NotificationCenter.default.addObserver(
        forName: .eeveeNowPlayingBarOptionsChanged, object: nil, queue: .main
    ) { _ in
        options = UserDefaults.nowPlayingBarOptions
        eeveeLog("[EeveeSpotify][Glass] Now playing bar options changed")
        if let container { style(container) }
    }

    private struct Styled: Equatable {
        let frame: CGRect
        // Visual cover rect in the card, origin and size. Spotify can put the art back on the
        // capsule edge without changing bounds; a size-only cache treats that move as a hit.
        let artwork: CGRect?
        let options: NowPlayingBarOptions
    }

    // Contour gap for both square and circular cover art. Not device-checked.
    private static let artworkBreathingRoom: CGFloat = 4

    private static var tint: UIColor? {
        options.albumTint ? albumColor?.withAlphaComponent(0.2) : nil
    }

    static func style(_ container: UIViewController) {
        _ = observer
        self.container = container
        guard let host = container.viewIfLoaded else { return }
        host.backgroundColor = .clear

        if card?.isDescendant(of: host) != true {
            guard let found = findCard(in: host) else {
                if misses < 10 {
                    misses += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak container] in
                        if let container { style(container) }
                    }
                }
                return
            }
            card = found
            misses = 0
            let intercepted = EeveeInterceptBackground(found) { color in
                albumColor = color
                AlbumColor.publish(color)
                if let pane { GlassKit.tint(pane, tint) }
            }
            eeveeLog("[EeveeSpotify][Glass] Now playing card %@ %@, color %@",
                  NSStringFromClass(type(of: found)), NSCoder.string(for: found.frame), intercepted ? "intercepted" : "FAILED")
        }
        guard let card else { return }
        if artwork?.isDescendant(of: card) != true { artwork = findArtwork(in: card) }
        let frame = card.convert(card.bounds, to: host)
        let fit = artwork.flatMap { artworkFit($0, in: card) }
        let now = Styled(frame: frame, artwork: fit?.cached, options: options)
        // `cached` is the placed rect (origin and size). `held` is false when that scale is missing,
        // including after Spotify lays the art back out to the edge without changing bounds.
        if now == styled, fit?.held != false, let pane, pane.superview === host, host.subviews.first === pane, pane.frame == frame,
           card.layer.cornerRadius == card.bounds.height / 2, artwork.map({ $0.layer.cornerRadius == artworkRadius($0) }) != false {
            GlassKit.tint(pane, tint)
            return
        }
        styled = now
        let radius = card.bounds.height / 2
        if card.layer.cornerRadius != radius {
            card.layer.cornerRadius = radius
            card.layer.cornerCurve = .continuous
        }
        // Clipping can't live in the radius check: iPad already ships a capsule corner radius, so the
        // branch is skipped there and the artwork renders straight past the rounded corners.
        card.clipsToBounds = true

        let glass = GlassKit.pane(in: host)
        pane = glass
        if glass.frame != frame {
            glass.frame = frame
            glass.cornerConfiguration = .capsule()
        }
        GlassKit.tint(glass, tint)

        if let artwork {
            if let fit, !fit.held { applyArtworkInset(artwork, fit) }
            artwork.layer.cornerRadius = artworkRadius(artwork)
            artwork.layer.cornerCurve = .continuous
            artwork.clipsToBounds = true
        }
    }

    private static func artworkRadius(_ artwork: UIView) -> CGFloat {
        options.roundArtwork ? artwork.bounds.width / 2 : 12
    }

    // Issue #188, Spotify 9.1 (9.1.84 NowPlaying_BarImpl symbols). Not run in Spotify; no UI harness,
    // and the cover hierarchy was not re-checked on a device. `findArtwork`'s square is scaled about
    // Spotify's center so square and circular modes share one inset — writing the frame would crop it,
    // and the scale is absolute so a repeat does not shrink again. Zero bounds and other transforms wait.
    private struct ArtworkFit {
        let cached: CGRect
        let held: Bool
        let scale: CGFloat?
    }

    private static func artworkFit(_ artwork: UIView, in card: UIView) -> ArtworkFit {
        let live = artwork.convert(artwork.bounds, to: card)
        guard canInset(artwork, card: card), let layout = layoutRect(artwork, in: card),
              let side = fittedArtworkSide(layout, in: card.bounds) else {
            return ArtworkFit(cached: live, held: true, scale: nil)
        }
        let source = max(artwork.bounds.width, artwork.bounds.height)
        let scale = min(1, side / source)
        let visualW = artwork.bounds.width * scale
        let visualH = artwork.bounds.height * scale
        let target = CGRect(
            x: layout.midX - visualW / 2, y: layout.midY - visualH / 2, width: visualW, height: visualH
        )
        // Scale is absolute, so "already applied" survives a repeat pass. A dropped scale fails this
        // even when the fitted rect (and the bounds) did not change.
        let scaleHeld = uniformScale(artwork.transform).map { abs($0 - scale) < 0.002 } ?? false
        return ArtworkFit(cached: target, held: scaleHeld && rectNear(live, target), scale: scale)
    }

    private static func applyArtworkInset(_ artwork: UIView, _ fit: ArtworkFit) {
        guard let scale = fit.scale, scale > 0, scale.isFinite else { return }
        if let current = uniformScale(artwork.transform), abs(current - scale) < 0.002 { return }
        let next: CGAffineTransform = abs(scale - 1) < 0.01 ? .identity : CGAffineTransform(scaleX: scale, y: scale)
        guard artwork.transform != next else { return }
        UIView.performWithoutAnimation { artwork.transform = next }
    }

    private static func canInset(_ artwork: UIView, card: UIView) -> Bool {
        let anchor = artwork.layer.anchorPoint
        guard abs(anchor.x - 0.5) < 0.02, abs(anchor.y - 0.5) < 0.02,
              artwork.bounds.width > 1, artwork.bounds.height > 1,
              card.bounds.width > 1, card.bounds.height > 1,
              artwork.superview != nil,
              uniformScale(artwork.transform) != nil,
              !isAnimatingLayout(artwork) else { return false }
        return true
    }

    // Center and bounds ignore a pure scale, so this stays Spotify's slot across passes.
    private static func layoutRect(_ artwork: UIView, in card: UIView) -> CGRect? {
        guard let superview = artwork.superview else { return nil }
        let center = superview.convert(artwork.center, to: card)
        let size = artwork.bounds.size
        return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }

    private static func fittedArtworkSide(_ layout: CGRect, in card: CGRect) -> CGFloat? {
        let room = artworkBreathingRoom
        guard layout.width > 1, layout.height > 1, card.width > 1, card.height > room * 2 + 16 else { return nil }
        let side = largestArtworkSide(layout, in: card, room: room)
        guard side >= 16 else { return nil }
        return side
    }

    private static func largestArtworkSide(_ layout: CGRect, in card: CGRect, room: CGFloat) -> CGFloat {
        let source = min(layout.width, layout.height)
        let cx = layout.midX
        let cy = layout.midY
        let vertical = min(cy - room, card.height - room - cy) * 2
        let cap = min(source, max(0, vertical), card.height - room * 2)
        guard cap > 0 else { return 0 }
        if artworkFits(cap, center: CGPoint(x: cx, y: cy), in: card, room: room) { return cap }
        var lo: CGFloat = 0
        var hi = cap
        while hi - lo > 0.25 {
            let mid = (lo + hi) / 2
            if artworkFits(mid, center: CGPoint(x: cx, y: cy), in: card, room: room) { lo = mid } else { hi = mid }
        }
        return lo
    }

    private static func artworkFits(_ side: CGFloat, center: CGPoint, in card: CGRect, room: CGFloat) -> Bool {
        let half = side / 2
        let left = center.x - half
        let right = center.x + half
        let top = center.y - half
        let bottom = center.y + half
        if top < room || bottom > card.height - room || left < room || right > card.width - room { return false }
        let radius = card.height / 2
        let inner = radius - room
        guard inner > 0 else { return false }
        let capLeft = radius
        let capRight = card.width - radius
        for x in [left, right] {
            for y in [top, bottom] {
                if x >= capLeft && x <= capRight { continue }
                let capX = x < capLeft ? capLeft : capRight
                let dx = x - capX
                let dy = y - radius
                if dx * dx + dy * dy > inner * inner { return false }
            }
        }
        return true
    }

    private static func uniformScale(_ transform: CGAffineTransform) -> CGFloat? {
        guard abs(transform.b) < 0.001, abs(transform.c) < 0.001,
              abs(transform.tx) < 0.001, abs(transform.ty) < 0.001,
              transform.a > 0, abs(transform.a - transform.d) < 0.001 else { return nil }
        return transform.a
    }

    private static func isAnimatingLayout(_ view: UIView) -> Bool {
        guard let keys = view.layer.animationKeys() else { return false }
        return keys.contains { $0 == "position" || $0 == "bounds" || $0.hasPrefix("transform") }
    }

    private static func rectNear(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1 && abs(a.minY - b.minY) < 1
            && abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
    }

    // The iPad bar is taller than the iPhone one, so a fixed 32...56pt window misses its artwork entirely.
    // The bar's own height is the limit instead, and the leftmost qualifying view wins.
    private static func findArtwork(in card: UIView) -> UIView? {
        let limit = card.bounds.height
        guard limit > 0 else { return nil }
        var best: UIView?
        var bestMinX = CGFloat.greatestFiniteMagnitude
        var queue = card.subviews
        while !queue.isEmpty {
            let view = queue.removeFirst()
            queue += view.subviews
            let size = view.bounds.size
            guard size.width >= 24, size.width <= limit, abs(size.width - size.height) < 1 else { continue }
            let minX = view.convert(view.bounds, to: card).minX
            guard minX < card.bounds.width / 3, minX < bestMinX else { continue }
            bestMinX = minX
            best = view
        }
        return best
    }

    private static func findCard(in root: UIView) -> UIView? {
        var best: UIView?
        var bestArea: CGFloat = 0
        var queue = [root]
        while !queue.isEmpty {
            let view = queue.removeFirst()
            queue += view.subviews
            guard !(view is UIVisualEffectView), let color = view.backgroundColor, color.isOpaqueish else { continue }
            let size = view.bounds.size
            guard size.width >= 200, size.height >= 40, size.height <= 160,
                  root.bounds.contains(view.convert(view.bounds, to: root)) else { continue }
            if size.width * size.height > bestArea {
                bestArea = size.width * size.height
                best = view
            }
        }
        return best
    }
}

class GlassNowPlayingBarContainerHook: ClassHook<UIViewController> {
    typealias Group = GlassNowPlayingBarGroup
    static let targetName = "_TtC18NowPlaying_BarImpl36NowPlayingBarContainerViewController"

    func viewDidLayoutSubviews() {
        orig.viewDidLayoutSubviews()
        guard #available(iOS 26.0, *) else { return }
        GlassNowPlayingBar.meter.measure { GlassNowPlayingBar.style(target) }
    }
}

class GlassNowPlayingBarHook: ClassHook<UIViewController> {
    typealias Group = GlassNowPlayingBarGroup
    static let targetName = "_TtC18NowPlaying_BarImpl27NowPlayingBarViewController"

    func viewDidLayoutSubviews() {
        orig.viewDidLayoutSubviews()
        guard #available(iOS 26.0, *), let container = target.parent,
              NSStringFromClass(type(of: container)).contains("NowPlayingBarContainer") else { return }
        GlassNowPlayingBar.meter.measure { GlassNowPlayingBar.style(container) }
    }
}
