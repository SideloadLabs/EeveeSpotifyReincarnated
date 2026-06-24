import Foundation

/// A keyframe-based curve, matching the real SpicyLyrics extension's
/// AnimationPoint arrays (LyricsAnimator.ts) — e.g. scale goes from 0.95
/// at progress=0, up to 1.0505 at progress=0.7, back to 1.0 at progress=1.
///
/// The original uses a cubic spline (the `cubic-spline` npm package) for
/// smooth interpolation between points. This uses simple piecewise linear
/// interpolation between the same keyframes instead — for curves with
/// only 3-4 points and fairly close Y-values, the visual difference
/// between a cubic spline and linear segments is subtle, and avoids
/// needing a spline implementation/dependency in Swift. If the linear
/// approximation looks too "kinked" once visible on a real device, the
/// fix is adding more intermediate keyframe points here — not switching
/// interpolation methods.
struct KaraokeAnimationCurve {
    let points: [(time: Double, value: Double)]

    /// progress should be 0...1. Values outside that range clamp to the
    /// first/last keyframe.
    func value(at progress: Double) -> Double {
        let p = min(1, max(0, progress))
        guard points.count > 1 else { return points.first?.value ?? 0 }

        for i in 0..<(points.count - 1) {
            let a = points[i]
            let b = points[i + 1]
            if p >= a.time && p <= b.time {
                guard b.time > a.time else { return a.value }
                let localT = (p - a.time) / (b.time - a.time)
                return a.value + (b.value - a.value) * localT
            }
        }
        return points.last?.value ?? 0
    }

    // Matches ScaleRange in LyricsAnimator.ts — word-level scale pop.
    static let wordScale = KaraokeAnimationCurve(points: [
        (0, 0.95), (0.7, 1.0505), (1, 1.0),
    ])

    // Matches GlowRange — ramps to full glow quickly, holds, fades by end.
    static let glow = KaraokeAnimationCurve(points: [
        (0, 0), (0.15, 1), (0.6, 1), (1, 0),
    ])

    // Matches YOffsetRange — a tiny upward bob during the syllable.
    static let yOffset = KaraokeAnimationCurve(points: [
        (0, 1.0 / 100), (0.9, -(1.0 / 60)), (1, 0),
    ])
}
