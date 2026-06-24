import SwiftUI
import MetalKit

/// Animated backdrop behind the karaoke lyrics. Prefers the real
/// Metal-based domain-warp renderer (KaraokeMetalBackgroundView, the
/// native analog of the real extension's Kawarp WebGL warp/blur) when the
/// album art image itself is available and Metal is supported on-device.
/// Falls back to a simpler animated gradient using extracted dominant
/// colors (AlbumArtColorExtractor) — or fixed placeholder colors if even
/// that fails — since the album art lookup is a best-effort UIView-walking
/// heuristic that won't always succeed, and Metal itself could
/// theoretically be unavailable (e.g. simulator).
struct KaraokeBackgroundView: View {
    @State private var albumArtImage: UIImage?
    @State private var colors: [Color] = KaraokeBackgroundView.placeholderColors

    private static let placeholderColors: [Color] = [
        Color(red: 0.07, green: 0.35, blue: 0.45),
        Color(red: 0.10, green: 0.55, blue: 0.40),
        Color(red: 0.05, green: 0.20, blue: 0.55),
    ]

    var body: some View {
        Group {
            if let albumArtImage = albumArtImage, MTLCreateSystemDefaultDevice() != nil {
                KaraokeMetalBackgroundView(albumArt: albumArtImage)
                    .ignoresSafeArea()
            } else {
                gradientFallback
            }
        }
        .onAppear { loadAlbumArt() }
    }

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

    /// AlbumArtLocator walks UIView/UIImageView, which must happen on the
    /// main thread. If found, we both keep the raw image (for the Metal
    /// path) and kick off color extraction in the background (for the
    /// gradient fallback path, in case Metal setup fails downstream even
    /// though the image itself was found).
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
