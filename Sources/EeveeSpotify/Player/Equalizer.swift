import AVFoundation
import Foundation
import EeveeSpotifyC

// a 15 band equalizer on Spotify's sound, after speed and pitch, with a headphone correction from AutoEq under
// it, kept per output. the filters are C (EeveeSpotifyC/Equalizer, see its README.md); this keeps the settings
// and hands them over at launch, whenever they change, and whenever the sound moves to another output.
struct EqualizerOptions: Codable, Equatable {
    var enabled = false
    var gains = Equalizer.flat
    var preventClipping = true

    init() {}

    private enum CodingKeys: String, CodingKey {
        case enabled, gains, preventClipping
    }

    // options saved before a field existed keep decoding.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        gains = try container.decodeIfPresent([Double].self, forKey: .gains) ?? Equalizer.flat
        preventClipping = try container.decodeIfPresent(Bool.self, forKey: .preventClipping) ?? true
    }
}

struct EqualizerUserPreset: Codable, Equatable {
    var name: String
    var gains: [Double]
}

// one filter of an AutoEq parametric correction.
struct ParametricFilter: Codable, Equatable {
    enum Kind: String, Codable {
        case peak, lowShelf, highShelf
    }

    var kind: Kind
    var frequency: Double
    var gain: Double
    var q: Double
}

// a headphone's correction, kept for the output it was picked on.
struct HeadphoneCorrection: Codable, Equatable {
    var headphone: String           // AutoEq's name for it
    var source: String              // who measured it: "oratory1990", "crinacle on 711"
    var path: String                // its folder in AutoEq's results, as the index writes it
    var filters: [ParametricFilter]
    var output: String              // the output's name when it was picked: "AirPods Pro"
}

extension UserDefaults {
    @UserDefault(key: "eeveeEqualizerOptions", defaultValue: EqualizerOptions())
    static var equalizerOptions

    @UserDefault(key: "eeveeEqualizerUserPresets", defaultValue: [EqualizerUserPreset]())
    static var equalizerUserPresets

    // by the output's port UID, which stays the same for a device across connections.
    @UserDefault(key: "eeveeHeadphoneCorrections", defaultValue: [String: HeadphoneCorrection]())
    static var headphoneCorrections
}

// the Swift side's debug log lines, prefixed like the C side's.
func equalizerLog(_ format: String, _ args: CVarArg...) {
    eeveeLog("[EeveeSpotify][Equalizer] %@", String(format: format, arguments: args))
}

enum Equalizer {
    static let bandCount = Int(EeveeEqualizerBandCount)
    static let flat = [Double](repeating: 0, count: bandCount)
    static let gainRange: ClosedRange<Double> = -12...12
    static let frequencies = (0..<bandCount).map { EeveeEqualizerFrequency($0) }
    static let routeChanged = Notification.Name("EeveeEqualizerRouteChanged")

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

    // a stored list of another length is padded or cut, so the C side always gets every band.
    static func normalized(_ gains: [Double]) -> [Double] {
        Array((gains + flat).prefix(bandCount))
    }

    static func apply(_ options: EqualizerOptions = UserDefaults.equalizerOptions) {
        EeveeEqualizerSet(options.enabled, normalized(options.gains), options.preventClipping)
    }

    // MARK: - your presets

    // saved under a name already taken, it replaces that one.
    static func save(_ name: String, gains: [Double]) {
        var presets = UserDefaults.equalizerUserPresets.filter { $0.name != name }
        presets.append(EqualizerUserPreset(name: name, gains: normalized(gains)))
        UserDefaults.equalizerUserPresets = presets.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - the output and its correction

    struct Output: Equatable {
        let id: String
        let name: String
    }

    // where Spotify's sound goes now, nil without an output (the session not set up yet).
    static var output: Output? {
        guard let port = AVAudioSession.sharedInstance().currentRoute.outputs.first else { return nil }
        return Output(id: port.uid, name: port.portName)
    }

    static var correction: HeadphoneCorrection? {
        output.flatMap { UserDefaults.headphoneCorrections[$0.id] }
    }

    static func setCorrection(_ correction: HeadphoneCorrection?, for output: Output) {
        UserDefaults.headphoneCorrections[output.id] = correction
        applyCorrection()
    }

    static func forgetCorrection(for id: String) {
        UserDefaults.headphoneCorrections[id] = nil
        applyCorrection()
    }

    // the current output's correction, or none, to the C side. the log leaves the output's UID out: for Bluetooth
    // it's the device's address.
    static func applyCorrection() {
        let correction = correction
        equalizerLog("output %@, correction %@", output?.name ?? "none", correction?.headphone ?? "none")
        let filters = correction?.filters ?? []
        let kinds = filters.map { filter -> EeveeEqualizerFilter in
            switch filter.kind {
            case .peak: return .peak
            case .lowShelf: return .lowShelf
            case .highShelf: return .highShelf
            }
        }
        EeveeEqualizerSetCorrection(kinds, filters.map(\.frequency), filters.map(\.gain), filters.map(\.q), filters.count)
    }

    // MARK: - drawing and text

    struct Curve {
        var bands: [Double]         // from 20 Hz to 20 kHz, log spaced
        var correction: [Double]    // the same points, the current output's correction alone
        var peak: Double            // dB, the two together at their highest: what clip prevention turns down
    }

    static func curve(_ gains: [Double], points: Int = 128) -> Curve {
        var frequencies = [Double](repeating: 0, count: points), bands = frequencies, correction = frequencies
        let down = EeveeEqualizerCurve(normalized(gains), points, &frequencies, &bands, &correction)
        return Curve(bands: bands, correction: correction, peak: max(0, -down))
    }

    static func frequencyText(_ frequency: Double) -> String {
        frequency < 1000
            ? "equalizer_hz".localizeWithFormat(ValuePrompt.plain(frequency))
            : "equalizer_khz".localizeWithFormat(ValuePrompt.plain(frequency / 1000))
    }

    static func gainText(_ gain: Double) -> String {
        gain == 0 ? "0" : (gain < 0 ? "" : "+") + ValuePrompt.plain(gain)
    }

    // MARK: - launch

    static func activate() {
        EeveeEqualizerSetLog { message in
            equalizerLog("%@", message)
        }
        apply()
        applyCorrection()
        // posted on the audio session's own thread; handed to main without waiting for it.
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { _ in
            DispatchQueue.main.async {
                applyCorrection()
                NotificationCenter.default.post(name: routeChanged, object: nil)
            }
        }
    }
}
