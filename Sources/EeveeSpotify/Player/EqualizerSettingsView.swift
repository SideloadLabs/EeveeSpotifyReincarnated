import SwiftUI

// the equalizer's page, in Listening. it applies as it changes. the dots on the curve drag up and down, a double
// tap puts one back to 0; a tap on a band's value resets it and holding it opens a box to type one.
struct EqualizerSettingsView: View {
    @State private var options = UserDefaults.equalizerOptions
    @State private var userPresets = UserDefaults.equalizerUserPresets
    @State private var corrections = UserDefaults.headphoneCorrections
    @State private var output = Equalizer.output
    @State private var confirmingClipping = false
    private let feedback = UISelectionFeedbackGenerator()

    private var gains: [Double] { Equalizer.normalized(options.gains) }

    private struct Remembered: Identifiable {
        let id: String
        let correction: HeadphoneCorrection
    }

    // the corrections kept for other outputs than this one.
    private var others: [Remembered] {
        corrections.filter { $0.key != output?.id }.map { Remembered(id: $0.key, correction: $0.value) }
            .sorted { $0.correction.output.localizedStandardCompare($1.correction.output) == .orderedAscending }
    }

    private var presetName: String {
        if let preset = Equalizer.presets.first(where: { $0.gains == gains }) { return preset.name }
        if let preset = userPresets.first(where: { $0.gains == gains }) { return preset.name }
        return "equalizer_custom".localized
    }

    private func gain(_ band: Int) -> Binding<Double> {
        Binding(get: { gains[band] }, set: { set(band, $0) })
    }

    // turning it off asks first, every time; the toggle stays on until it's confirmed.
    private var clipping: Binding<Bool> {
        Binding(get: { options.preventClipping }, set: { on in
            if on { options.preventClipping = true } else { confirmingClipping = true }
        })
    }

    private func set(_ band: Int, _ value: Double) {
        var next = gains
        next[band] = ValuePrompt.hundredths(value)
        options.gains = next
    }

    private func refresh() {
        options = UserDefaults.equalizerOptions
        userPresets = UserDefaults.equalizerUserPresets
        corrections = UserDefaults.headphoneCorrections
        output = Equalizer.output
    }

    var body: some View {
        let curve = Equalizer.curve(gains)
        List {
            Section(footer: availability) {
                SettingsToggle(title: "equalizer".localized, icon: "slider.vertical.3", color: Color(hex: "#BF5AF2"), isOn: $options.enabled)
            }

            Section(footer: level(curve)) {
                EqualizerCurveView(curve: curve, gains: gains, active: options.enabled, set: set)
                    .frame(height: 160)
                    .padding(.vertical, 8)
                presetMenu
                SettingsToggle(title: "equalizer_prevent_clipping".localized, icon: "waveform", color: .orange, isOn: clipping)
            }
            .disabled(!options.enabled)

            Section(header: Text("equalizer_headphones".localized), footer: Text("equalizer_headphones_footer".localized)) {
                if let output {
                    Button {
                        SettingsNavigator.push(EqualizerHeadphonesView(output: output), title: "equalizer_headphones".localized)
                    } label: {
                        SettingsLabel(title: output.name, subtitle: corrections[output.id]?.headphone ?? "equalizer_no_correction".localized,
                                      icon: "headphones", color: .blue, chevron: true)
                    }
                }
                ForEach(others) { other in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(other.correction.output)
                        Text(other.correction.headphone).font(.footnote).foregroundColor(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                .onDelete { rows in
                    let gone = rows.map { others[$0].id }
                    gone.forEach(Equalizer.forgetCorrection)
                    corrections = UserDefaults.headphoneCorrections
                }
            }

            Group {
                Section(header: Text("equalizer_bands".localized)) {
                    ForEach(0..<Equalizer.bandCount, id: \.self) { band in
                        EqualizerBandRow(frequency: Equalizer.frequencies[band], gain: gain(band)) { ask(band) }
                    }
                }

                Section(header: Text("equalizer_your_presets".localized)) {
                    ForEach(userPresets, id: \.name) { preset in
                        Button { options.gains = preset.gains } label: {
                            HStack {
                                Text(preset.name).foregroundColor(.primary)
                                Spacer()
                                if preset.gains == gains {
                                    Image(systemName: "checkmark").foregroundColor(EeveeTheme.accent)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                    }
                    .onDelete { rows in
                        let names = Set(rows.map { userPresets[$0].name })
                        UserDefaults.equalizerUserPresets = userPresets.filter { !names.contains($0.name) }
                        userPresets = UserDefaults.equalizerUserPresets
                    }
                    Button(action: savePreset) {
                        SettingsLabel(title: "equalizer_save_preset".localized, icon: "plus", color: .green)
                    }
                }
            }
            .disabled(!options.enabled)

            SettingsResetSection(visible: gains != Equalizer.flat) { options.gains = Equalizer.flat }

            SpacerView()
        }
        .eeveeSettingsStyle()
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: Equalizer.routeChanged)) { _ in
            output = Equalizer.output
            corrections = UserDefaults.headphoneCorrections
        }
        .onChange(of: options) {
            UserDefaults.equalizerOptions = $0
            Equalizer.apply($0)
        }
        .alert(isPresented: $confirmingClipping) {
            Alert(
                title: Text("equalizer_clipping_warning_title".localized),
                message: Text("equalizer_clipping_warning_message".localized),
                primaryButton: .destructive(Text("equalizer_clipping_warning_confirm".localized)) { options.preventClipping = false },
                secondaryButton: .cancel()
            )
        }
    }

    private var presetMenu: some View {
        Menu {
            ForEach(Equalizer.presets.indices, id: \.self) { index in
                let preset = Equalizer.presets[index]
                Button { options.gains = preset.gains } label: { checked(preset.name, preset.gains == gains) }
            }
            if !userPresets.isEmpty {
                Divider()
                ForEach(userPresets, id: \.name) { preset in
                    Button { options.gains = preset.gains } label: { checked(preset.name, preset.gains == gains) }
                }
            }
        } label: {
            HStack {
                SettingsLabel(title: "equalizer_preset".localized, icon: "music.note.list", color: .pink)
                Text(presetName).foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder private func checked(_ name: String, _ on: Bool) -> some View {
        if on {
            Label(name, systemImage: "checkmark")
        } else {
            Text(name)
        }
    }

    @ViewBuilder private var availability: some View {
        if !SpeedPitch.pitchAvailable {
            Text("equalizer_unavailable".localized)
        }
    }

    // how far it's turned down, or with clip prevention off, how far the boosts go over.
    @ViewBuilder private func level(_ curve: Equalizer.Curve) -> some View {
        if options.enabled && curve.peak >= 0.05 {
            let decibels = String(format: "%.1f", curve.peak)
            Text((options.preventClipping ? "equalizer_headroom" : "equalizer_clipping").localizeWithFormat(decibels))
        }
    }

    private func ask(_ band: Int) {
        feedback.selectionChanged()
        ValuePrompt.present(ValuePrompt.make(title: Equalizer.frequencyText(Equalizer.frequencies[band]), value: gains[band],
                                             range: Equalizer.gainRange, text: { "equalizer_db".localizeWithFormat(Equalizer.gainText($0)) },
                                             keyboard: .numbersAndPunctuation) { set(band, $0) })
    }

    private func savePreset() {
        let gains = gains
        ValuePrompt.present(ValuePrompt.name(title: "equalizer_save_preset".localized, message: "equalizer_save_preset_message".localized,
                                             placeholder: "equalizer_preset_name".localized) { name in
            Equalizer.save(name, gains: gains)
            userPresets = UserDefaults.equalizerUserPresets
        })
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

// the bands' response from 20 Hz to 20 kHz over ±15 dB, with a dot where each slider is, and the headphone
// correction as a dashed line. a dot drags up and down; a double tap on it puts it back to 0.
private struct EqualizerCurveView: View {
    let curve: Equalizer.Curve
    let gains: [Double]
    let active: Bool
    let set: (Int, Double) -> Void

    @State private var grabbed: Int?
    @State private var dragging = false
    @State private var offset: CGFloat = 0
    @State private var lastTap: (band: Int, at: Date)?
    private let feedback = UISelectionFeedbackGenerator()

    private static let range = 15.0
    private static let inset: CGFloat = 6
    // how far from a dot, up or down, a finger still takes it.
    private static let grab: CGFloat = 30
    // a touch that stays this close to where it landed is a tap, which changes nothing.
    private static let tapSlop: CGFloat = 6
    private static let marks: [(Double, String)] = [(100, "100"), (1000, "1k"), (10000, "10k")]

    private static func x(_ frequency: Double, _ width: CGFloat) -> CGFloat {
        CGFloat(log(frequency / 20) / log(1000)) * width
    }

    private static func y(_ decibels: Double, _ height: CGFloat) -> CGFloat {
        height / 2 - CGFloat(max(-range, min(range, decibels)) / range) * (height / 2 - inset)
    }

    // a finger's height as a band's gain, on the sliders' half-dB steps.
    private static func gain(_ y: CGFloat, _ height: CGFloat) -> Double {
        let decibels = Double((height / 2 - y) / (height / 2 - inset)) * range
        return (max(Equalizer.gainRange.lowerBound, min(Equalizer.gainRange.upperBound, decibels)) * 2).rounded() / 2
    }

    private static func line(_ values: [Double], _ width: CGFloat, _ height: CGFloat) -> [CGPoint] {
        values.indices.map { CGPoint(x: CGFloat($0) / CGFloat(max(values.count - 1, 1)) * width, y: y(values[$0], height)) }
    }

    private func nearest(_ point: CGPoint, _ width: CGFloat, _ height: CGFloat) -> Int? {
        let band = gains.indices.min { abs(Self.x(Equalizer.frequencies[$0], width) - point.x) < abs(Self.x(Equalizer.frequencies[$1], width) - point.x) }
        guard let band, abs(Self.y(gains[band], height) - point.y) <= Self.grab else { return nil }
        return band
    }

    private func drag(_ width: CGFloat, _ height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if grabbed == nil, let band = nearest(value.startLocation, width, height) {
                    grabbed = band
                    offset = Self.y(gains[band], height) - value.startLocation.y
                    feedback.selectionChanged()
                }
                guard let band = grabbed else { return }
                if !dragging && abs(value.translation.height) >= Self.tapSlop { dragging = true }
                guard dragging else { return }
                let next = Self.gain(value.location.y + offset, height)
                guard next != gains[band] else { return }
                if next == 0 || next == Equalizer.gainRange.lowerBound || next == Equalizer.gainRange.upperBound { feedback.selectionChanged() }
                set(band, next)
            }
            .onEnded { value in
                defer { grabbed = nil; dragging = false }
                guard let band = grabbed, abs(value.translation.width) < Self.tapSlop,
                      abs(value.translation.height) < Self.tapSlop else { return }
                if let last = lastTap, last.band == band, Date().timeIntervalSince(last.at) < 0.4 {
                    lastTap = nil
                    if gains[band] != 0 {
                        feedback.selectionChanged()
                        set(band, 0)
                    }
                } else {
                    lastTap = (band, Date())
                }
            }
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width, height = geometry.size.height
            let bands = Self.line(curve.bands, width, height)
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
                if curve.correction.contains(where: { abs($0) > 0.01 }) {
                    Path { path in path.addLines(Self.line(curve.correction, width, height)) }
                        .stroke(Color.secondary.opacity(active ? 0.8 : 0.35), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 3]))
                }
                Path { path in
                    path.move(to: CGPoint(x: 0, y: height / 2))
                    bands.forEach { path.addLine(to: $0) }
                    path.addLine(to: CGPoint(x: width, y: height / 2))
                    path.closeSubpath()
                }
                .fill(accent.opacity(0.15))
                Path { path in path.addLines(bands) }
                    .stroke(accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                ForEach(gains.indices, id: \.self) { band in
                    Circle()
                        .fill(accent)
                        .frame(width: grabbed == band ? 12 : 7, height: grabbed == band ? 12 : 7)
                        .position(x: Self.x(Equalizer.frequencies[band], width), y: Self.y(gains[band], height))
                }
            }
            .contentShape(Rectangle())
            .gesture(drag(width, height))
        }
        .accessibility(hidden: true)
    }
}
