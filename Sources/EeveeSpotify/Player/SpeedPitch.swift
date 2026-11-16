import Foundation
import EeveeSpotifyC

// speed and pitch on Spotify's sound. the engine is C (EeveeSpotifyC/SpeedPitch, see its README.md); this
// keeps the switch that installs it and hands the sliders to it. speed and pitch themselves are never stored,
// so a launch always plays at normal speed.
struct SpeedPitchOptions: Codable, Equatable {
    var enabled = false
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

    static let launchOptions = UserDefaults.speedPitchOptions
    private(set) static var installed = false

    static var speedAvailable: Bool { installed && EeveeSpeedPitchSpeedAvailable() }
    static var pitchAvailable: Bool { installed && EeveeSpeedPitchPitchAvailable() }

    static var speed: Double {
        get { installed ? EeveeSpeedPitchSpeed() : 1 }
        set { if installed { EeveeSpeedPitchSetSpeed(snapped(newValue)) } }
    }

    static var semitones: Double {
        get { installed ? Double(EeveeSpeedPitchSemitones()) : 0 }
        set { if installed { EeveeSpeedPitchSetSemitones(Float(newValue.rounded())) } }
    }

    // stored with the options; this only hands it to the engine.
    static func applyPitchFollowsSpeed(_ follows: Bool) {
        guard installed, EeveeSpeedPitchPitchFollowsSpeed() != follows else { return }
        EeveeSpeedPitchSetPitchFollowsSpeed(follows)
    }

    // to the slider's step, and exactly 1 near it so the engine can take itself out.
    static func snapped(_ value: Double) -> Double {
        let speed = (value / speedStep).rounded() * speedStep
        return abs(speed - 1) < speedStep * 0.6 ? 1 : speed
    }

    static func activate() {
        guard launchOptions.enabled else { return }
        let reached = EeveeSpeedPitchInstall(launchOptions.pitchFollowsSpeed) { message in
            eeveeLog("[EeveeSpotify][SpeedPitch] %@", message)
        }
        installed = true
        SpeedPitchMenu.activate()
        eeveeLog("[EeveeSpotify][SpeedPitch] Active (output %@)", reached ? "reached" : "not reached")
    }
}

// before Spotify sets up its audio, which it does right after launch.
func activateSpeedPitch() {
    SpeedPitch.activate()
}
