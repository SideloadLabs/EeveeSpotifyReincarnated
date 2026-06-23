import SwiftUI

/// Animated gradient backdrop behind the karaoke lyrics, using real
/// dominant colors extracted from the currently-displayed album art
/// (AlbumArtColorExtractor) when available, falling back to a fixed
/// placeholder gradient if extraction fails (e.g. album art view not
/// found, or the image couldn't be processed) — extraction is a
/// best-effort heuristic (see AlbumArtColorExtractor's notes on how the
/// art is located), so a graceful fallback matters here, not just a
/// force-unwrap that could leave the view broken.
struct KaraokeBackgroundView: View {
    @State private var colors: [Color] = KaraokeBackgroundView.placeholderColors

    private static let placeholderColors: [Color] = [
        Color(red: 0.07, green: 0.35, blue: 0.45),
        Color(red: 0.10, green: 0.55, blue: 0.40),
        Color(red: 0.05, green: 0.20, blue: 0.55),
    ]

    var body: some View {
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
        .onAppear { extractColors() }
    }

    /// Extraction runs once when the view appears (off the main thread,
    /// since k-means-style bucketing over image pixels is real CPU work
    /// we shouldn't do inline in body) rather than every frame — the
    /// album art doesn't change while this view is open, only when the
    /// track changes, and re-extraction on track change is a reasonable
    /// future enhancement rather than something needed for a first version.
    private func extractColors() {
        // AlbumArtLocator walks UIView/UIImageView, which must happen on
        // the main thread — only the actual pixel-crunching in
        // dominantColors(from:) is heavy enough to warrant a background
        // queue, so the image lookup itself stays on main.
        guard let image = AlbumArtLocator.currentAlbumArt() else {
            writeDebugLog("[Karaoke] no album art view found — using placeholder gradient")
            return
        }

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
