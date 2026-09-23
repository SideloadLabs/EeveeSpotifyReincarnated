import Foundation

// Port of the real Spicy Lyrics extension's animation model
// (src/utils/Lyrics/Animator/Lyrics/LyricsAnimator.ts, Shared.ts,
// modules/Spring.ts, css/Lyrics/Mixed.css), so the karaoke view moves
// the way the desktop one does: every syllable is driven by damped
// springs chasing targets sampled from cubic splines, long syllables
// split into per-letter animation, and inactive lines fade and blur by
// their distance from the active one. Constants are copied verbatim;
// where a CSS length is involved the conversion is noted inline.

// MARK: - Spring

/// Port of modules/Spring.ts (itself a port of Fraktality's spr, MIT):
/// an analytic damped spring, stepped with the real frame delta.
struct KaraokeSpring {
    private var d: Double  // damping ratio
    private var f: Double  // frequency, Hz
    private var g: Double  // goal
    private var p: Double  // position
    private var v: Double = 0

    init(_ start: Double, frequency: Double, damping: Double) {
        d = damping
        f = frequency
        g = start
        p = start
    }

    mutating func setGoal(_ goal: Double) { g = goal }

    mutating func step(_ dt: Double) -> Double {
        let f = self.f * 2 * .pi
        let eps = 1e-5
        let o = p - g

        if d == 1 {
            let q = exp(-f * dt)
            let w = dt * q
            let c0 = q + w * f
            let c2 = q - w * f
            let c3 = w * f * f
            p = o * c0 + v * w + g
            v = v * c2 - o * c3
        } else if d < 1 {
            let q = exp(-d * f * dt)
            let c = (1 - d * d).squareRoot()
            let i = cos(dt * f * c)
            let j = sin(dt * f * c)

            let z: Double
            if c > eps {
                z = j / c
            } else {
                let a = dt * f
                z = a + ((a * a) * (c * c) * (c * c) / 20 - c * c) * (a * a * a) / 6
            }

            let y: Double
            if f * c > eps {
                y = j / (f * c)
            } else {
                let b = f * c
                y = dt + ((dt * dt) * (b * b) * (b * b) / 20 - b * b) * (dt * dt * dt) / 6
            }

            p = (o * (i + z * d) + v * y) * q + g
            v = (v * (i - z * d) - o * (z * f)) * q
        } else {
            let c = (d * d - 1).squareRoot()
            let r1 = -f * (d + c)
            let r2 = -f * (d - c)
            let ec1 = exp(r1 * dt)
            let ec2 = exp(r2 * dt)
            let co2 = (v - o * r1) / (2 * f * c)
            let co1 = ec1 * (o - co2)
            p = co1 + co2 * ec2 + g
            v = co1 * r1 + co2 * ec2 * r2
        }
        return p
    }
}

// MARK: - Cubic spline

/// Port of the `cubic-spline` npm package the extension samples its
/// animation curves with: a natural cubic spline through the keyframes.
struct KaraokeSpline {
    private let xs: [Double]
    private let ys: [Double]
    private let ks: [Double]

    init(_ points: [(time: Double, value: Double)]) {
        xs = points.map(\.time)
        ys = points.map(\.value)
        ks = KaraokeSpline.naturalKs(xs: xs, ys: ys)
    }

    func at(_ x: Double) -> Double {
        var i = 1
        while i < xs.count - 1 && xs[i] < x { i += 1 }
        let dx = xs[i] - xs[i - 1]
        let dy = ys[i] - ys[i - 1]
        let t = (x - xs[i - 1]) / dx
        let a = ks[i - 1] * dx - dy
        let b = -ks[i] * dx + dy
        return (1 - t) * ys[i - 1] + t * ys[i] + t * (1 - t) * (a * (1 - t) + b * t)
    }

    private static func naturalKs(xs: [Double], ys: [Double]) -> [Double] {
        let n = xs.count - 1
        var m = Array(repeating: Array(repeating: 0.0, count: n + 2), count: n + 1)

        for i in 1 ..< n {
            let l = xs[i] - xs[i - 1]
            let r = xs[i + 1] - xs[i]
            m[i][i - 1] = 1 / l
            m[i][i] = 2 * (1 / l + 1 / r)
            m[i][i + 1] = 1 / r
            m[i][n + 1] = 3 * ((ys[i] - ys[i - 1]) / (l * l) + (ys[i + 1] - ys[i]) / (r * r))
        }
        let first = xs[1] - xs[0]
        m[0][0] = 2 / first
        m[0][1] = 1 / first
        m[0][n + 1] = 3 * (ys[1] - ys[0]) / (first * first)
        let last = xs[n] - xs[n - 1]
        m[n][n - 1] = 1 / last
        m[n][n] = 2 / last
        m[n][n + 1] = 3 * (ys[n] - ys[n - 1]) / (last * last)

        // Gaussian elimination with partial pivoting, as the package does.
        for k in 0 ... n {
            let pivot = (k ... n).max { abs(m[$0][k]) < abs(m[$1][k]) } ?? k
            m.swapAt(k, pivot)
            for i in (k + 1) ..< (n + 1) where m[k][k] != 0 {
                let factor = m[i][k] / m[k][k]
                for j in k ..< (n + 2) { m[i][j] -= m[k][j] * factor }
            }
        }
        var ks = Array(repeating: 0.0, count: n + 1)
        for i in stride(from: n, through: 0, by: -1) {
            let value = m[i][i] == 0 ? 0 : m[i][n + 1] / m[i][i]
            ks[i] = value
            for j in stride(from: i - 1, through: 0, by: -1) {
                m[j][n + 1] -= m[j][i] * value
                m[j][i] = 0
            }
        }
        return ks
    }
}

// MARK: - Constants (LyricsAnimator.ts / Mixed.css)

enum KaraokeCurves {
    static let scale = KaraokeSpline([(0, 0.95), (0.7, 1.0505), (1, 1)])
    static let letterScale = KaraokeSpline([(0, 0.95), (0.7, 1.175), (1, 1)])
    /// Fractions of the lyrics font size.
    static let yOffset = KaraokeSpline([(0, 1.0 / 100), (0.9, -(1.0 / 60)), (1, 0)])
    static let letterYOffset = KaraokeSpline([(0, 1.0 / 100), (0.9, -(1.0 / 56)), (1, 0)])
    static let glow = KaraokeSpline([(0, 0), (0.15, 1), (0.6, 1), (1, 0)])

    static let dotScale = KaraokeSpline([(0, 0.75), (0.7, 1.05), (1, 1)])
    static let dotYOffset = KaraokeSpline([(0, 0), (0.9, -0.12), (1, 0)])
    static let dotGlow = KaraokeSpline([(0, 0), (0.6, 1), (1, 1)])
    static let dotOpacity = KaraokeSpline([(0, 0.35), (0.6, 1), (1, 1)])
    /// Line mode: whole-line glow (LineGlowRange).
    static let lineGlow = KaraokeSpline([(0, 0), (0.5, 1), (1, 0)])
    static let lineGlowFrequency = 1.0, lineGlowDamping = 0.5

    // Word springs
    static let yOffsetFrequency = 1.45, yOffsetDamping = 0.4
    static let scaleFrequency = 0.88, scaleDamping = 0.64
    static let glowFrequency = 1.18, glowDamping = 0.56
    // Dot springs
    static let dotYOffsetFrequency = 1.25, dotYOffsetDamping = 0.4
    static let dotScaleFrequency = 0.7, dotScaleDamping = 0.6
    static let dotGlowFrequency = 1.0, dotGlowDamping = 0.5
    static let dotOpacityFrequency = 1.0, dotOpacityDamping = 0.5

    /// Sung letters in a finished letter group keep a faint glow.
    static let sungLetterGlow = 0.2
    static let letterGlowOpacityMultiplier = 1.85

    /// IsLetterCapable: a syllable sung for at least this long animates
    /// letter by letter.
    static let letterGroupMinDurationMs = 1000
    /// Emphasize.ts: letters share the syllable's time minus this tail.
    static let letterGroupEndTrimMs = 250

    // Line states (Mixed.css --Vocal-*-opacity, Shared.ts BlurMultiplier)
    static let notSungLineOpacity = 0.51
    static let sungLineOpacity = 0.497
    static let blurMultiplier = 1.25
    static var maxBlur: Double { blurMultiplier * 5 + blurMultiplier * 0.465 }

    // Gradient fill (Mixed.css): a 20%-wide soft edge sweeping -20% → 100%.
    static let gradientAlpha = 0.85
    static let gradientAlphaEnd = 0.5
    static let backgroundGradientAlpha = 0.6
    static let backgroundGradientAlphaEnd = 0.3

    /// d3-ease easeSinOut, used for the active letter's sweep.
    static func easeSinOut(_ t: Double) -> Double { sin(t * .pi / 2) }
}

enum KaraokeElementState {
    case notSung, active, sung

    init(ms: Int, start: Int, end: Int) {
        if ms < start { self = .notSung }
        else if ms >= end { self = .sung }
        else { self = .active }
    }
}

func karaokeProgress(ms: Int, start: Int, end: Int) -> Double {
    if ms <= start { return 0 }
    if ms >= end || end <= start { return 1 }
    return Double(ms - start) / Double(end - start)
}

// MARK: - Animator

/// Values a syllable, letter or dot is drawn with this frame.
struct KaraokeElementStyle {
    var scale: Double
    /// Fraction of the font size (positive = down).
    var yOffset: Double
    var glow: Double
    /// Fill sweep position, percent of the element's width.
    var gradientPosition: Double
    var opacity: Double = 1

    static let notSung = KaraokeElementStyle(
        scale: KaraokeCurves.scale.at(0),
        yOffset: KaraokeCurves.yOffset.at(0),
        glow: 0,
        gradientPosition: -20
    )
    static let sung = KaraokeElementStyle(scale: 1, yOffset: 0, glow: 0, gradientPosition: 100)
}

/// Owns every spring for one lyrics view. Springs live across frames, so
/// this is a reference type the view keeps for its lifetime; views ask it
/// for an element's style each frame and it steps that element's springs
/// once per frame (repeat body evaluations within a frame reuse the
/// cached result instead of stepping twice).
final class KaraokeAnimator {
    private struct Springs {
        var scale: KaraokeSpring
        var yOffset: KaraokeSpring
        var glow: KaraokeSpring
        var opacity: KaraokeSpring?
        var frame = -1
        var cached = KaraokeElementStyle.notSung
    }

    private var springs: [String: Springs] = [:]
    private var lastTime: TimeInterval?
    private var dt = 1.0 / 60
    private(set) var frame = 0

    func beginFrame(at time: TimeInterval) {
        if let last = lastTime {
            // A stalled or backgrounded view shouldn't make springs leap.
            dt = min(max(time - last, 0), 0.1)
        }
        lastTime = time
        frame += 1
    }

    /// Syllable ("word" in the extension's terms) on the active line.
    func syllable(_ key: String, state: KaraokeElementState, progress: Double) -> KaraokeElementStyle {
        let t: Double
        let gradient: Double
        switch state {
        case .active: t = progress; gradient = -20 + 120 * progress
        case .notSung: t = 0; gradient = -20
        case .sung: t = 1; gradient = 100
        }
        var style = step(
            key,
            make: {
                Springs(
                    scale: KaraokeSpring(KaraokeCurves.scale.at(0), frequency: KaraokeCurves.scaleFrequency, damping: KaraokeCurves.scaleDamping),
                    yOffset: KaraokeSpring(KaraokeCurves.yOffset.at(0), frequency: KaraokeCurves.yOffsetFrequency, damping: KaraokeCurves.yOffsetDamping),
                    glow: KaraokeSpring(KaraokeCurves.glow.at(0), frequency: KaraokeCurves.glowFrequency, damping: KaraokeCurves.glowDamping)
                )
            },
            scale: KaraokeCurves.scale.at(t),
            yOffset: KaraokeCurves.yOffset.at(t),
            glow: KaraokeCurves.glow.at(t)
        )
        style.gradientPosition = gradient
        return style
    }

    /// One letter of a letter-group syllable. `activeIndex`/`activeProgress`
    /// describe whichever letter of the group is being sung right now.
    func letter(
        _ key: String,
        index: Int,
        state: KaraokeElementState,
        wordActive: Bool,
        activeIndex: Int?,
        activeProgress: Double
    ) -> KaraokeElementStyle {
        var scale = KaraokeCurves.letterScale.at(0)
        var yOffset = KaraokeCurves.letterYOffset.at(0)
        var glow = KaraokeCurves.glow.at(0)

        if wordActive, let activeIndex = activeIndex {
            // Proximity falloff around the active letter.
            let distance = Double(abs(index - activeIndex))
            let falloff = max(0, 1 / (1 + pow(distance, 2.8)))
            let glowFalloff = max(0, 1 / (1 + distance * 0.9))
            scale += (KaraokeCurves.letterScale.at(activeProgress) - scale) * falloff
            yOffset += (KaraokeCurves.letterYOffset.at(activeProgress) - yOffset) * falloff
            glow += (KaraokeCurves.glow.at(activeProgress) - glow) * glowFalloff
        }
        if state == .notSung {
            scale = KaraokeCurves.letterScale.at(0)
            yOffset = KaraokeCurves.letterYOffset.at(0)
            glow = KaraokeCurves.glow.at(0)
        } else if state == .sung && activeIndex == nil {
            glow = KaraokeCurves.glow.at(KaraokeCurves.sungLetterGlow)
        }

        let gradient: Double
        switch state {
        case .notSung: gradient = -20
        case .sung: gradient = 100
        case .active:
            gradient = index == activeIndex ? -20 + 120 * KaraokeCurves.easeSinOut(activeProgress) : -20
        }

        var style = step(
            key,
            make: {
                Springs(
                    scale: KaraokeSpring(KaraokeCurves.letterScale.at(0), frequency: KaraokeCurves.scaleFrequency, damping: KaraokeCurves.scaleDamping),
                    yOffset: KaraokeSpring(KaraokeCurves.letterYOffset.at(0), frequency: KaraokeCurves.yOffsetFrequency, damping: KaraokeCurves.yOffsetDamping),
                    glow: KaraokeSpring(KaraokeCurves.glow.at(0), frequency: KaraokeCurves.glowFrequency, damping: KaraokeCurves.glowDamping)
                )
            },
            scale: scale,
            yOffset: yOffset,
            glow: glow
        )
        style.gradientPosition = gradient
        return style
    }

    /// A whole line-synced line: gradient sweeps 0% -> 100% with the line's
    /// progress, glow follows LineGlowRange through a spring.
    func line(_ key: String, state: KaraokeElementState, progress: Double) -> KaraokeElementStyle {
        let t: Double
        let gradient: Double
        switch state {
        case .active: t = progress; gradient = progress * 100
        case .notSung: t = 0; gradient = -20
        case .sung: t = 1; gradient = 100
        }
        var style = step(
            key,
            make: {
                Springs(
                    scale: KaraokeSpring(1, frequency: 1, damping: 1),
                    yOffset: KaraokeSpring(0, frequency: 1, damping: 1),
                    glow: KaraokeSpring(KaraokeCurves.lineGlow.at(0), frequency: KaraokeCurves.lineGlowFrequency, damping: KaraokeCurves.lineGlowDamping)
                )
            },
            scale: 1,
            yOffset: 0,
            glow: KaraokeCurves.lineGlow.at(t)
        )
        style.gradientPosition = gradient
        return style
    }

    /// One "•" of an interlude line.
    func dot(_ key: String, state: KaraokeElementState, progress: Double) -> KaraokeElementStyle {
        let t: Double
        switch state {
        case .active: t = progress
        case .notSung: t = 0
        case .sung: t = 1
        }
        return step(
            key,
            make: {
                Springs(
                    scale: KaraokeSpring(KaraokeCurves.dotScale.at(0), frequency: KaraokeCurves.dotScaleFrequency, damping: KaraokeCurves.dotScaleDamping),
                    yOffset: KaraokeSpring(KaraokeCurves.dotYOffset.at(0), frequency: KaraokeCurves.dotYOffsetFrequency, damping: KaraokeCurves.dotYOffsetDamping),
                    glow: KaraokeSpring(KaraokeCurves.dotGlow.at(0), frequency: KaraokeCurves.dotGlowFrequency, damping: KaraokeCurves.dotGlowDamping),
                    opacity: KaraokeSpring(KaraokeCurves.dotOpacity.at(0), frequency: KaraokeCurves.dotOpacityFrequency, damping: KaraokeCurves.dotOpacityDamping)
                )
            },
            scale: KaraokeCurves.dotScale.at(t),
            yOffset: KaraokeCurves.dotYOffset.at(t),
            glow: KaraokeCurves.dotGlow.at(t),
            opacity: KaraokeCurves.dotOpacity.at(t)
        )
    }

    private func step(
        _ key: String,
        make: () -> Springs,
        scale: Double,
        yOffset: Double,
        glow: Double,
        opacity: Double? = nil
    ) -> KaraokeElementStyle {
        var entry = springs[key] ?? make()
        if entry.frame == frame { return entry.cached }

        entry.scale.setGoal(scale)
        entry.yOffset.setGoal(yOffset)
        entry.glow.setGoal(glow)
        var style = KaraokeElementStyle(
            scale: entry.scale.step(dt),
            yOffset: entry.yOffset.step(dt),
            glow: entry.glow.step(dt),
            gradientPosition: 0
        )
        if let opacity = opacity, entry.opacity != nil {
            entry.opacity!.setGoal(opacity)
            style.opacity = entry.opacity!.step(dt)
        }
        entry.frame = frame
        entry.cached = style
        springs[key] = entry
        return style
    }
}
