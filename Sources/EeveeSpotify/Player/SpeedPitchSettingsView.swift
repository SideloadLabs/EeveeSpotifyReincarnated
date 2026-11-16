import SwiftUI
import Combine

struct SpeedPitchSettingsView: View {
    @State private var options = UserDefaults.speedPitchOptions
    @State private var speed = SpeedPitch.speed
    @State private var semitones = SpeedPitch.semitones
    @State private var speedAvailable = SpeedPitch.speedAvailable
    @State private var pitchAvailable = SpeedPitch.pitchAvailable

    // speed becomes available once Spotify connects its output, which can happen while this page is open.
    private let availability = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    // the slider's steps can land a hair off 1, so compare what the engine plays.
    private var normalSpeed: Bool { SpeedPitch.snapped(speed) == 1 }

    private var following: Bool { speedAvailable && options.pitchFollowsSpeed && !normalSpeed }

    private var speedText: String { String(format: "%.2f×", SpeedPitch.snapped(speed)) }

    private var pitchText: String {
        if following { return "speed_pitch_follows_value".localized }
        if semitones == 0 { return "0" }
        return "speed_pitch_semitones".localizeWithFormat(String(format: "%+.0f", semitones))
    }

    private var footer: String {
        var lines = ["speed_pitch_footer".localized]
        if !pitchAvailable { lines.insert("speed_pitch_unreachable".localized, at: 0) }
        else if !speedAvailable { lines.insert("speed_pitch_speed_waiting".localized, at: 0) }
        return lines.joined(separator: " ")
    }

    var body: some View {
        List {
            Section(footer: Text("speed_pitch_enable_footer".localized)) {
                SettingsToggle(title: "speed_pitch".localized, subtitle: "speed_pitch_subtitle".localized, icon: "speedometer", color: .orange, isOn: $options.enabled)
            }

            if SpeedPitch.installed {
                Section(footer: Text(footer)) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("speed_pitch_speed".localized)
                            Spacer()
                            Text(speedText).foregroundColor(.secondary)
                        }
                        Slider(value: $speed, in: SpeedPitch.speedRange, step: SpeedPitch.speedStep)
                    }
                    .disabled(!speedAvailable)
                    .opacity(speedAvailable ? 1 : 0.4)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("speed_pitch_pitch".localized)
                            Spacer()
                            Text(pitchText).foregroundColor(.secondary)
                        }
                        Slider(value: $semitones, in: SpeedPitch.pitchRange, step: 1)
                    }
                    .disabled(!pitchAvailable || following)
                    .opacity(pitchAvailable && !following ? 1 : 0.4)

                    // resampling needs the chain, which the pitch-only fallback does not have.
                    SettingsToggle(title: "speed_pitch_follows".localized, subtitle: "speed_pitch_follows_subtitle".localized, icon: "waveform", color: .purple, isOn: $options.pitchFollowsSpeed)
                        .disabled(!speedAvailable)

                    if !normalSpeed || semitones != 0 {
                        Button {
                            speed = 1
                            semitones = 0
                        } label: {
                            SettingsLabel(title: "speed_pitch_reset".localized, icon: "arrow.counterclockwise", color: .gray)
                        }
                    }
                }
            }

            RestartSection(visible: options.enabled != SpeedPitch.launchOptions.enabled)

            SpacerView()
        }
        .eeveeSettingsStyle()
        .onAppear(perform: refresh)
        .onReceive(availability) { _ in
            speedAvailable = SpeedPitch.speedAvailable
            pitchAvailable = SpeedPitch.pitchAvailable
        }
        .onChange(of: speed) { value in
            SpeedPitch.speed = value
            // the engine refuses a speed it cannot play; show what it kept.
            if abs(SpeedPitch.speed - SpeedPitch.snapped(value)) > 0.001 { speed = SpeedPitch.speed }
        }
        .onChange(of: semitones) { SpeedPitch.semitones = $0 }
        .onChange(of: options) { value in
            UserDefaults.speedPitchOptions = value
            SpeedPitch.applyPitchFollowsSpeed(value.pitchFollowsSpeed)
        }
    }

    private func refresh() {
        speed = SpeedPitch.speed
        semitones = SpeedPitch.semitones
        speedAvailable = SpeedPitch.speedAvailable
        pitchAvailable = SpeedPitch.pitchAvailable
    }
}
