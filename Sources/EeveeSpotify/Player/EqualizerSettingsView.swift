import SwiftUI

// the equalizer's page, under Player. it applies as it changes. a tap on a band's value resets it; holding it
// opens a box to type one, like speed & pitch.
struct EqualizerSettingsView: View {
    @State private var options = UserDefaults.equalizerOptions
    private let feedback = UISelectionFeedbackGenerator()

    private var gains: [Double] { Equalizer.normalized(options.gains) }

    private var presetIndex: Int? {
        Equalizer.presets.firstIndex { $0.gains == gains }
    }

    private var presetSelection: Binding<Int> {
        Binding(get: { presetIndex ?? -1 }, set: { if $0 >= 0 { options.gains = Equalizer.presets[$0].gains } })
    }

    private func gain(_ band: Int) -> Binding<Double> {
        Binding(get: { gains[band] }, set: { set(band, $0) })
    }

    private func set(_ band: Int, _ value: Double) {
        var next = gains
        next[band] = (value * 100).rounded() / 100
        options.gains = next
    }

    var body: some View {
        let curve = Equalizer.curve(gains)
        List {
            Section(footer: availability) {
                SettingsToggle(title: "equalizer".localized, icon: "slider.vertical.3", color: .orange, isOn: $options.enabled)
            }

            Group {
                Section(footer: turnDown(curve)) {
                    EqualizerCurveView(decibels: curve.decibels, gains: gains, active: options.enabled)
                        .frame(height: 150)
                        .padding(.vertical, 8)
                    Picker(selection: presetSelection, label: SettingsLabel(title: "equalizer_preset".localized, icon: "music.note.list", color: .pink)) {
                        ForEach(Equalizer.presets.indices, id: \.self) { Text(Equalizer.presets[$0].name).tag($0) }
                        if presetIndex == nil { Text("equalizer_custom".localized).tag(-1) }
                    }
                }

                Section(header: Text("equalizer_bands".localized)) {
                    ForEach(0..<Equalizer.bandCount, id: \.self) { band in
                        EqualizerBandRow(frequency: Equalizer.frequencies[band], gain: gain(band)) { ask(band) }
                    }
                }
            }
            .disabled(!options.enabled)

            SettingsResetSection(visible: gains != Equalizer.flat) { options.gains = Equalizer.flat }

            SpacerView()
        }
        .eeveeSettingsStyle()
        .onChange(of: options) {
            UserDefaults.equalizerOptions = $0
            Equalizer.apply($0)
        }
    }

    @ViewBuilder private var availability: some View {
        if !SpeedPitch.pitchAvailable {
            Text("equalizer_unavailable".localized)
        }
    }

    @ViewBuilder private func turnDown(_ curve: Equalizer.Curve) -> some View {
        if options.enabled && curve.turnDown >= 0.05 {
            Text("equalizer_headroom".localizeWithFormat(String(format: "%.1f", curve.turnDown)))
        }
    }

    private func ask(_ band: Int) {
        feedback.selectionChanged()
        let alert = ValuePrompt.make(title: Equalizer.frequencyText(Equalizer.frequencies[band]), value: gains[band], range: Equalizer.gainRange,
                                     text: { "equalizer_db".localizeWithFormat(Equalizer.gainText($0)) },
                                     keyboard: .numbersAndPunctuation) { set(band, $0) }
        var host = WindowHelper.shared.rootViewController
        while let presented = host.presentedViewController, !presented.isBeingDismissed { host = presented }
        host.present(alert, animated: true)
    }
}

private struct EqualizerBandRow: View {
    let frequency: Double
    @Binding var gain: Double
    let ask: () -> Void

    private var name: String { Equalizer.frequencyText(frequency) }
    private var value: String { "equalizer_db".localizeWithFormat(Equalizer.gainText(gain)) }

    var body: some View {
        HStack(spacing: 10) {
            Text(name)
                .font(.footnote.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 54, alignment: .leading)
                .accessibility(hidden: true)
            Slider(value: $gain, in: Equalizer.gainRange, step: 0.5)
                .accessibility(label: Text(name))
                .accessibility(value: Text(value))
            Text(Equalizer.gainText(gain))
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .frame(width: 46, alignment: .trailing)
                .contentShape(Rectangle())
                .onTapGesture { if gain != 0 { gain = 0 } }
                .onLongPressGesture(perform: ask)
                .accessibility(label: Text(name))
                .accessibility(value: Text(value))
                .accessibility(hint: Text(gain != 0 ? "speed_pitch_reset_hint".localized : ""))
                .accessibility(addTraits: .isButton)
                .accessibilityAction(named: Text("speed_pitch_type".localized), ask)
        }
    }
}

// the response from 20 Hz to 20 kHz over ±15 dB, with a dot where each slider is.
private struct EqualizerCurveView: View {
    let decibels: [Double]
    let gains: [Double]
    let active: Bool

    private static let range = 15.0
    private static let marks: [(Double, String)] = [(100, "100"), (1000, "1k"), (10000, "10k")]

    private static func x(_ frequency: Double, _ width: CGFloat) -> CGFloat {
        CGFloat(log(frequency / 20) / log(1000)) * width
    }

    private static func y(_ decibels: Double, _ height: CGFloat) -> CGFloat {
        height / 2 - CGFloat(max(-range, min(range, decibels)) / range) * (height / 2 - 4)
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width, height = geometry.size.height
            let points = decibels.indices.map { CGPoint(x: CGFloat($0) / CGFloat(max(decibels.count - 1, 1)) * width, y: Self.y(decibels[$0], height)) }
            let accent = EeveeTheme.accent.opacity(active ? 1 : 0.35)
            ZStack(alignment: .topLeading) {
                Path { path in
                    for (frequency, _) in Self.marks {
                        path.move(to: CGPoint(x: Self.x(frequency, width), y: 0))
                        path.addLine(to: CGPoint(x: Self.x(frequency, width), y: height))
                    }
                    for level in [-12.0, 12] {
                        path.move(to: CGPoint(x: 0, y: Self.y(level, height)))
                        path.addLine(to: CGPoint(x: width, y: Self.y(level, height)))
                    }
                }
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                Path { path in
                    path.move(to: CGPoint(x: 0, y: height / 2))
                    path.addLine(to: CGPoint(x: width, y: height / 2))
                }
                .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
                ForEach(Self.marks.indices, id: \.self) { index in
                    Text(Self.marks[index].1)
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundColor(.secondary)
                        .position(x: Self.x(Self.marks[index].0, width) + 12, y: height - 6)
                }
                Path { path in
                    path.move(to: CGPoint(x: 0, y: height / 2))
                    points.forEach { path.addLine(to: $0) }
                    path.addLine(to: CGPoint(x: width, y: height / 2))
                    path.closeSubpath()
                }
                .fill(accent.opacity(0.15))
                Path { path in path.addLines(points) }
                    .stroke(accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                ForEach(gains.indices, id: \.self) { band in
                    Circle()
                        .fill(accent)
                        .frame(width: 6, height: 6)
                        .position(x: Self.x(Equalizer.frequencies[band], width), y: Self.y(gains[band], height))
                }
            }
        }
        .accessibility(hidden: true)
    }
}
