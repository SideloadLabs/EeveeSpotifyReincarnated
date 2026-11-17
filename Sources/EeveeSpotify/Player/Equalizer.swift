import Foundation
import EeveeSpotifyC

// a 15 band equalizer on Spotify's sound, after speed and pitch. the filters are C (EeveeSpotifyC/Equalizer, see
// its README.md); this keeps the sliders and hands them over at launch and whenever they change.
struct EqualizerOptions: Codable, Equatable {
    var enabled = false
    var gains = Equalizer.flat
}

extension UserDefaults {
    @UserDefault(key: "eeveeEqualizerOptions", defaultValue: EqualizerOptions())
    static var equalizerOptions
}

enum Equalizer {
    static let bandCount = Int(EeveeEqualizerBandCount)
    static let flat = [Double](repeating: 0, count: bandCount)
    static let gainRange: ClosedRange<Double> = -12...12
    static let frequencies = (0..<bandCount).map { EeveeEqualizerFrequency($0) }

    struct Preset {
        let key: String
        let gains: [Double]

        var name: String { "equalizer_preset_\(key)".localized }
    }

    // spoti.pw's, at the same bands.
    static let presets = [
        Preset(key: "flat", gains: flat),
        Preset(key: "bass", gains: [6, 6, 5, 4, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        Preset(key: "loudness", gains: [5, 5, 4, 2, 1, 0, 0, 0, 0, 0, 1, 2, 3, 4, 4]),
        Preset(key: "treble", gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 5]),
        Preset(key: "vocal", gains: [-2, -2, -2, -1, -1, 0, 1, 2, 3, 3, 2, 1, 0, -1, -1]),
        Preset(key: "warm", gains: [2, 2, 2, 2, 1, 1, 0, 0, 0, -1, -1, -2, -2, -2, -2]),
        Preset(key: "bright", gains: [-1, -1, -1, 0, 0, 0, 0, 0, 1, 2, 3, 3, 3, 3, 3]),
        Preset(key: "rock", gains: [4, 4, 3, 1, -1, -2, -2, -1, 0, 1, 2, 3, 3, 3, 2]),
        Preset(key: "electronic", gains: [5, 5, 4, 2, 0, -1, -2, -1, 0, 1, 1, 2, 3, 4, 4]),
        Preset(key: "acoustic", gains: [2, 2, 2, 1, 1, 0, 0, 1, 1, 2, 2, 2, 2, 1, 1]),
        Preset(key: "classical", gains: [3, 3, 2, 1, 0, 0, 0, 0, 0, 0, 0, 1, 2, 2, 3]),
        Preset(key: "podcast", gains: [-6, -6, -4, -2, -1, 0, 1, 2, 2, 2, 1, 0, -1, -2, -3]),
    ]

    static func preset(matching gains: [Double]) -> Preset? {
        presets.first { $0.gains == normalized(gains) }
    }

    // a stored list of another length is padded or cut, so the C side always gets every band.
    static func normalized(_ gains: [Double]) -> [Double] {
        Array((gains + flat).prefix(bandCount))
    }

    static func apply(_ options: EqualizerOptions = UserDefaults.equalizerOptions) {
        EeveeEqualizerSet(options.enabled, normalized(options.gains))
    }

    struct Curve {
        var decibels: [Double]      // from 20 Hz to 20 kHz, log spaced
        var turnDown: Double        // dB the sound is lowered by so the boosts can't clip
    }

    static func curve(_ gains: [Double], points: Int = 128) -> Curve {
        var frequencies = [Double](repeating: 0, count: points), decibels = frequencies
        let down = EeveeEqualizerCurve(normalized(gains), points, &frequencies, &decibels)
        return Curve(decibels: decibels, turnDown: -down)
    }

    static func frequencyText(_ frequency: Double) -> String {
        frequency < 1000
            ? "equalizer_hz".localizeWithFormat(ValuePrompt.plain(frequency))
            : "equalizer_khz".localizeWithFormat(ValuePrompt.plain(frequency / 1000))
    }

    static func gainText(_ gain: Double) -> String {
        gain == 0 ? "0" : (gain < 0 ? "" : "+") + ValuePrompt.plain(gain)
    }

    static func activate() {
        apply()
    }
}
