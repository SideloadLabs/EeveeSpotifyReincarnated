import SwiftUI

struct PlayerSettingsView: View {
    @State private var options = UserDefaults.playerOptions
    @State private var glass = UserDefaults.liquidGlassOptions
    @State private var flagsVersion = 0
    @State private var flagsDefault = FlagOverrides.areDefault(PlayerSettingsView.flags.map(\.1))
    @State private var resetHidden = false
    @State private var extras = UserDefaults.playerExtrasOptions
    private let launchOptions = UserDefaults.playerOptions
    private let launchExtras = UserDefaults.playerExtrasOptions

    private static let flags: [(String, String)] = [
        ("player_flag_canvas", "ios-feature-canvas.canvas_enabled"),
        ("player_flag_sheet", "ios-feature-nowplaying.sheet_style_npv"),
        ("player_flag_header", "ios-feature-nowplaying.new_redesign_header_with_context_menu_enabled"),
        ("player_flag_slider", "ios-feature-encoreexperiments.new_npv_slider_enabled"),
        ("player_flag_sticky", "ios-feature-nowplaying.expand_sticky_header_on_tap"),
        ("player_flag_queue_sheet", "ios-feature-nowplaying.bottom_sheet_queue_enabled"),
        ("player_flag_connect_sheet", "ios-feature-nowplaying-elements.enable_connect_bottom_sheet"),
        ("player_flag_queue_flip", "ios-feature-nowplaying.queue_flip_transition_enabled"),
        ("player_flag_play_next", "ios-feature-queue.is_play_next_context_menu_enabled"),
    ]

    private var isDefault: Bool {
        var base = PlayerOptions()
        base.hidden = options.hidden
        return options == base && options.hiddenParts.isEmpty && !glass.newPlayerDesign && flagsDefault && extras == PlayerExtrasOptions()
    }

    private func refreshFlags() {
        flagsDefault = FlagOverrides.areDefault(Self.flags.map(\.1))
    }

    private var hiddenSummary: String {
        let count = UserDefaults.playerOptions.hiddenParts.count
        return count == 0 ? "player_hide_none".localized : "player_hide_count".localizeWithFormat(count)
    }

    var body: some View {
        List {
            Section(header: Text("glass_style".localized)) {
                SettingsToggle(title: "player_backdrop".localized, subtitle: "player_backdrop_subtitle".localized, icon: "photo.fill", color: .purple, isOn: $options.backdrop)
                SettingsToggle(title: "player_glass_lyrics".localized, icon: "quote.bubble.fill", color: .pink, isOn: $options.glassLyricsCard)
            }

            Section {
                SettingsLink(title: "player_hide_parts".localized, subtitle: hiddenSummary, icon: "eye.slash.fill", color: .gray) {
                    PlayerHideSettingsView()
                }
            }

            Section(header: Text("player_gestures".localized), footer: Text("restart_is_required_description".localized)) {
                Picker(selection: $extras.doubleTap, label: SettingsLabel(title: "player_double_tap".localized, icon: "hand.tap.fill", color: .blue)) {
                    ForEach(PlayerDoubleTap.allCases, id: \.self) { Text("player_double_tap_\($0.rawValue)".localized).tag($0) }
                }
                if extras.doubleTap != .off {
                    Picker(selection: $extras.threeZones, label: SettingsLabel(title: "player_zones".localized, icon: "rectangle.split.3x1.fill", color: .gray)) {
                        Text("player_zones_two".localized).tag(false)
                        Text("player_zones_three".localized).tag(true)
                    }
                }
                SettingsToggle(title: "player_haptics".localized, subtitle: "player_haptics_subtitle".localized, icon: "iphone.radiowaves.left.and.right", color: .green, isOn: $extras.haptics)
            }

            Section(footer: Text("new_player_design_footer".localized)) {
                SettingsToggle(title: "new_player_design".localized, icon: "play.circle.fill", color: .orange, isOn: $glass.newPlayerDesign)
            }

            Section(header: Text("spotify_flags".localized), footer: Text("restart_is_required_description".localized)) {
                ForEach(Self.flags, id: \.1) { FlagOverrideRow(title: $0.0.localized, key: $0.1) { flagsVersion += 1 } }
            }
            .id(flagsVersion)

            SettingsResetSection(visible: !isDefault) {
                options = PlayerOptions()
                resetHidden = true
                glass.newPlayerDesign = false
                extras = PlayerExtrasOptions()
                FlagOverrides.clear(Self.flags.map(\.1))
                flagsVersion += 1
            }

            if options != launchOptions || glass != LiquidGlass.launchOptions || extras != launchExtras {
                Section {
                    Button(action: exitApplication) {
                        Text("restart_now".localized).fontWeight(.semibold).frame(maxWidth: .infinity)
                    }
                    .foregroundColor(EeveeTheme.accent)
                }
            }

            SpacerView()
        }
        .eeveeSettingsStyle()
        .onChange(of: options) {
            var saved = $0
            if resetHidden {
                resetHidden = false
            } else {
                saved.hidden = UserDefaults.playerOptions.hidden
            }
            UserDefaults.playerOptions = saved
        }
        .onAppear {
            options = UserDefaults.playerOptions
            refreshFlags()
        }
        .onChange(of: flagsVersion) { _ in refreshFlags() }
        .onChange(of: glass) { UserDefaults.liquidGlassOptions = $0 }
        .onChange(of: extras) { UserDefaults.playerExtrasOptions = $0 }
    }
}

struct PlayerHideSettingsView: View {
    @State private var options = UserDefaults.playerOptions
    private let launchHidden = UserDefaults.playerOptions.hiddenParts

    var body: some View {
        List {
            Section(header: Text("player_hide_buttons".localized)) {
                ForEach(PlayerPart.buttons, id: \.self, content: toggle)
            }
            Section(header: Text("player_hide_cards".localized), footer: Text("restart_is_required_description".localized)) {
                toggle(.allCards)
                if !options.hiddenParts.contains(.allCards) {
                    ForEach(PlayerPart.cards.filter { $0 != .allCards }, id: \.self, content: toggle)
                }
            }
            SettingsResetSection(visible: !options.hiddenParts.isEmpty) { options.hiddenParts = [] }

            if Set(options.hiddenParts) != Set(launchHidden) {
                Section {
                    Button(action: exitApplication) {
                        Text("restart_now".localized).fontWeight(.semibold).frame(maxWidth: .infinity)
                    }
                    .foregroundColor(EeveeTheme.accent)
                }
            }
            SpacerView()
        }
        .eeveeSettingsStyle()
        .onChange(of: options) { UserDefaults.playerOptions = $0 }
    }

    private func toggle(_ part: PlayerPart) -> some View {
        Toggle("player_part_\(part.rawValue)".localized, isOn: Binding(
            get: { options.hiddenParts.contains(part) },
            set: { hide in
                options.hiddenParts.removeAll { $0 == part }
                if hide { options.hiddenParts.append(part) }
            }
        ))
    }
}
