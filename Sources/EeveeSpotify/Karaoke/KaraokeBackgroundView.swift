import SwiftUI
import MetalKit

/// Animated backdrop behind the karaoke lyrics. Prefers the real
/// Metal-based domain-warp renderer (KaraokeMetalBackgroundView, the
/// native analog of the real extension's Kawarp WebGL warp/blur) when the
/// album art image itself is available and Metal is supported on-device.
/// Falls back to a simpler animated gradient using extracted dominant
/// colors (AlbumArtColorExtractor) — or fixed placeholder colors if even
/// that fails, e.g. if Spotify hasn't published artwork to
/// MPNowPlayingInfoCenter yet and the UIView-walking fallback also comes
/// up empty, or if Metal itself is unavailable (e.g. simulator).
@available(iOS 15.0, *)
struct KaraokeBackgroundView: View {
    @State private var albumArtImage: UIImage?
    @State private var colors: [Color] = KaraokeBackgroundView.placeholderColors

    private static let placeholderColors: [Color] = [
        Color(red: 0.07, green: 0.35, blue: 0.45),
        Color(red: 0.10, green: 0.55, blue: 0.40),
        Color(red: 0.05, green: 0.20, blue: 0.55),
    ]

    /// Whether the Metal background renderer actually works on this build —
    /// computed once and cached (Swift `static let` initializes lazily on
    /// first access). This used to be approximated as just
    /// `MTLCreateSystemDefaultDevice() != nil` (i.e. "is Metal supported on
    /// this device at all"), which is true on essentially any real iPhone
    /// — it said nothing about whether KaraokeBackgroundRenderer's shader
    /// library actually loaded. That matters here because the renderer
    /// loads its .metallib from a fixed path that a Makefile step has to
    /// produce at build time (see the UNTESTED note in
    /// KaraokeBackgroundRenderer's init) — if that step didn't run or
    /// staged the file somewhere else, `KaraokeBackgroundRenderer(device:)`
    /// returns nil, but the previous code had *already* committed to
    /// showing KaraokeMetalBackgroundView's MTKView by that point. An
    /// MTKView with a device but no delegate still runs its normal render
    /// loop and presents its default clear color every frame — solid
    /// black — instead of falling back to anything. This is what was
    /// actually producing the black background, and why it only appeared
    /// once album art started being found at all: before that, albumArtImage
    /// was always nil and this branch was never reached, so the gradient
    /// fallback (which doesn't depend on the .metallib loading) was always
    /// shown instead. Testing renderer construction up front, before
    /// deciding which view to show, fixes that.
    private static let metalRendererSupported: Bool = {
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        return KaraokeBackgroundRenderer(device: device) != nil
    }()

    var body: some View {
        Group {
            if let albumArtImage = albumArtImage,
               albumArtImage.size.width > 1, albumArtImage.size.height > 1,
               MTLCreateSystemDefaultDevice() != nil {
                KaraokeMetalBackgroundView(albumArt: albumArtImage)
                    .ignoresSafeArea()
            } else {
                gradientFallback
            }
        }
        .onAppear { loadAlbumArt() }
    }

    @available(iOS 15.0, *)
    private var gradientFallback: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 12.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            RadialGradient(
                colors: colors,
                center: animatedCenter(t: t),
                startRadius: 20,
                endRadius: 500
            )
            .ignoresSafeArea()
            .background(Color.black)
            .animation(.linear(duration: 1.0 / 12.0), value: t)
        }
    }

    /// AlbumArtLocator now checks MPNowPlayingInfoCenter's published artwork
    /// first (reliable, no view-hierarchy timing concerns) and only falls
    /// back to walking the Now Playing UIView tree if that's unavailable.
    /// Reading NowPlayingInfo must happen on the main thread, which
    /// AlbumArtLocator itself already handles — this call stays on
    /// .onAppear's (main-thread) caller for that reason. If found, we both
    /// keep the raw image (for the Metal path) and kick off color
    /// extraction in the background (for the gradient fallback path, in
    /// case Metal setup fails downstream even though the image itself was
    /// found).
    private func loadAlbumArt() {
        guard let image = AlbumArtLocator.currentAlbumArt() else {
            writeDebugLog("[Karaoke] no album art view found — using placeholder gradient")
            return
        }
        albumArtImage = image
        extractColors(from: image)
    }

    private func extractColors(from image: UIImage) {
        DispatchQueue.global(qos: .userInitiated).async {
            let extracted = AlbumArtColorExtractor.dominantColors(from: image, count: 3)
            guard extracted.count >= 2 else {
                writeDebugLog("[Karaoke] album art color extraction returned too few colors (\(extracted.count)) — using placeholder gradient")
                return
            }
            let swiftUIColors = extracted.map { Color($0) }
            DispatchQueue.main.async {
                colors = swiftUIColors
            }
        }
    }

    private func animatedCenter(t: TimeInterval) -> UnitPoint {
        // Slow Lissajous-style drift so the gradient feels alive without
        // being distracting behind moving text.
        let x = 0.5 + 0.3 * sin(t * 0.13)
        let y = 0.5 + 0.3 * cos(t * 0.09)
        return UnitPoint(x: x, y: y)
    }
}
