import SwiftUI

// only the switch: the sliders are in the full-screen player's ⋯ menu (SpeedPitchMenu.x.swift).
struct SpeedPitchSettingsView: View {
    @State private var options = UserDefaults.speedPitchOptions

    var body: some View {
        List {
            Section(footer: Text("speed_pitch_enable_footer".localized)) {
                SettingsToggle(title: "speed_pitch".localized, subtitle: "speed_pitch_subtitle".localized, icon: "speedometer", color: .orange, isOn: $options.enabled)
            }

            RestartSection(visible: options.enabled != SpeedPitch.launchOptions.enabled)

            SpacerView()
        }
        .eeveeSettingsStyle()
        // the ⋯ menu may have changed pitch follows speed since this page was opened.
        .onAppear { options = UserDefaults.speedPitchOptions }
        .onChange(of: options.enabled) { enabled in
            UserDefaults.speedPitchOptions.enabled = enabled
        }
    }
}
