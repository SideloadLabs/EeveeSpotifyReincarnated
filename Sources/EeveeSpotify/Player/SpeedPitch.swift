import Foundation
import EeveeSpotifyC

// speed and pitch on Spotify's sound. the engine is C (EeveeSpotifyC/SpeedPitch, see its README.md); this
// installs it at every launch and hands the menu's values to it. speed and pitch themselves are never stored,
// so a launch always plays at normal speed.
struct SpeedPitchOptions: Codable, Equatable {
    var pitchFollowsSpeed = true
}

extension UserDefaults {
    @UserDefault(key: "eeveeSpeedPitchOptions", defaultValue: SpeedPitchOptions())
    static var speedPitchOptions
}

enum SpeedPitch {
    static let speedRange: ClosedRange<Double> = 0.5...2
    static let speedStep = 0.05
    static let pitchRange: ClosedRange<Double> = -12...12
    // a typed value can go past the sliders, as far as the engine goes (EeveeSpeedPitch.h).
    static let typedSpeedRange: ClosedRange<Double> = 0.25...4
    static let typedPitchRange: ClosedRange<Double> = -24...24

    private(set) static var installed = false

    static var speedAvailable: Bool { installed && EeveeSpeedPitchSpeedAvailable() }
    static var pitchAvailable: Bool { installed && EeveeSpeedPitchPitchAvailable() }

    static var speed: Double {
        get { installed ? hundredths(EeveeSpeedPitchSpeed()) : 1 }
        set { if installed { EeveeSpeedPitchSetSpeed(hundredths(newValue)) } }
    }

    static var semitones: Double {
        get { installed ? hundredths(Double(EeveeSpeedPitchSemitones())) : 0 }
        set { if installed { EeveeSpeedPitchSetSemitones(Float(hundredths(newValue))) } }
    }

    // stored with the options; this only hands it to the engine.
    static func applyPitchFollowsSpeed(_ follows: Bool) {
        guard installed, EeveeSpeedPitchPitchFollowsSpeed() != follows else { return }
        EeveeSpeedPitchSetPitchFollowsSpeed(follows)
    }

    // to the slider's step, exactly 1 at normal so the engine can take itself out.
    static func snapped(_ value: Double) -> Double {
        hundredths((value / speedStep).rounded() * speedStep)
    }

    // both values are kept to hundredths, so what the engine holds compares equal to what was shown.
    static func hundredths(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    static func activate() {
        let reached = EeveeSpeedPitchInstall(UserDefaults.speedPitchOptions.pitchFollowsSpeed) { message in
            eeveeLog("[EeveeSpotify][SpeedPitch] %@", message)
        }
        installed = true
        SpeedPitchMenu.activate()
        eeveeLog("[EeveeSpotify][SpeedPitch] Active (output %@)", reached ? "reached" : "not reached")
    }
}

// before Spotify sets up its audio, which it does right after launch. the equalizer runs on the same engine.
func activateSpeedPitch() {
    SpeedPitch.activate()
    Equalizer.activate()
}
