import SwiftUI

/// Animated gradient backdrop behind the karaoke lyrics.
///
/// Spicetify's real lyrics view derives this gradient from the track's
/// album art (dominant/accent colors, blurred and slowly animated). That
/// requires real album-art color extraction, which doesn't exist anywhere
/// in this codebase yet (Velora's Android Palette-API-based theming is a
/// different project/platform and doesn't carry over) — building real
/// extraction is a separate, sizeable piece of work on its own.
///
/// For now this is a placeholder: a slowly-drifting multi-color gradient
/// using fixed colors, so the view doesn't look broken/empty while that
/// real feature is pending. Swapping in real album-art colors later is a
/// drop-in replacement — only the `colors` array needs to come from a real
/// extractor instead of this fixed placeholder set.
struct KaraokeBackgroundView: View {
    private let colors: [Color] = [
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
    }

    private func animatedCenter(t: TimeInterval) -> UnitPoint {
        // Slow Lissajous-style drift so the gradient feels alive without
        // being distracting behind moving text.
        let x = 0.5 + 0.3 * sin(t * 0.13)
        let y = 0.5 + 0.3 * cos(t * 0.09)
        return UnitPoint(x: x, y: y)
    }
}
