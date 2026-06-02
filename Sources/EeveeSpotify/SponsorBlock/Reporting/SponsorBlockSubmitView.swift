import SwiftUI

struct SponsorBlockSubmitView: View {
    @Environment(\.presentationMode) private var presentationMode

    @State private var pending: SponsorBlockPendingSegment
    @State private var startValue: Double
    @State private var endValue: Double

    let duration: Double
    var onSubmitted: (() -> Void)?

    @State private var submitting = false
    @State private var errorMessage: String?
    @State private var didSucceed = false

    init(pending: SponsorBlockPendingSegment, duration: Double, onSubmitted: (() -> Void)? = nil) {
        let safeDuration = max(duration, 1)
        let initialStart = min(max(0, pending.start), safeDuration)
        let initialEnd: Double = {
            if let e = pending.end { return min(max(e, initialStart + 0.1), safeDuration) }
            return min(initialStart + 30, safeDuration)
        }()
        _pending = State(initialValue: pending)
        _startValue = State(initialValue: initialStart)
        _endValue = State(initialValue: initialEnd)
        self.duration = safeDuration
        self.onSubmitted = onSubmitted
    }

    var body: some View {
        NavigationView {
            ZStack {
                Color(UIColor.systemBackground).ignoresSafeArea()
                Form {
                Section(header: Text("Times"), footer: Text("Both sliders move independently. Out-of-order values are corrected on submit.")) {
                    timeRow(label: "Start", value: $startValue, isStart: true)
                    timeRow(label: "End",   value: $endValue,   isStart: false)
                    HStack {
                        Text("Duration")
                        Spacer()
                        let d = abs(endValue - startValue)
                        Text(SponsorBlockFormatters.time(d))
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(d < 0.5 ? .red : .secondary)
                    }
                    if endValue < startValue {
                        Text("End is before start — will be swapped on submit.")
                            .font(.footnote)
                            .foregroundColor(.orange)
                    }
                }

                Section(header: Text("Category")) {
                    categoryPicker
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundColor(.red).font(.footnote) }
                }

                Section(footer: Text("Submitted segments get treated as 'skip' on this client. Other clients may treat as mute/highlight per their own rules.")) {
                    Button(action: submit) {
                        HStack {
                            if submitting {
                                ProgressView().padding(.trailing, 6)
                            } else {
                                Image(systemName: didSucceed ? "checkmark.circle.fill" : "paperplane.fill")
                            }
                            Text(didSucceed ? "Submitted" : "Submit segment")
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(submitting || didSucceed || min(startValue, endValue) >= max(startValue, endValue) - 0.3)
                }
            }
            .navigationBarTitle("Report Segment", displayMode: .inline)
            .navigationBarItems(
                leading: Button("Save Draft") {
                    persist()
                    presentationMode.wrappedValue.dismiss()
                },
                trailing: Button(action: {
                    SponsorBlockPendingStore.remove(id: pending.id, episodeID: pending.episodeID)
                    presentationMode.wrappedValue.dismiss()
                }) { Text("Discard").foregroundColor(.red) }
            )
            }
        }
        .preferredColorScheme(.dark)
    }

    private var categoryPicker: some View {
        let cols = [GridItem(.adaptive(minimum: 110), spacing: 8)]
        return LazyVGrid(columns: cols, spacing: 8) {
            ForEach(SponsorBlockOptions.allCategoryOrder, id: \.self) { key in
                let isSel = pending.category == key
                let color = Color(hex: UserDefaults.sponsorBlockOptions.color(for: key))
                Button {
                    pending.category = key
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(color)
                            .frame(width: 10, height: 10)
                        Text(SponsorBlockFormatters.categoryName(key))
                            .font(.footnote.weight(isSel ? .semibold : .regular))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isSel ? color.opacity(0.30) : Color.secondary.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSel ? color : Color.clear, lineWidth: 2)
                    )
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func timeRow(label: String, value: Binding<Double>, isStart: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text(SponsorBlockFormatters.time(value.wrappedValue))
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Slider(value: value, in: 0...duration, step: 0.1)
            HStack(spacing: 6) {
                stepButton(label: "-5s",  value: value, by: -5)
                stepButton(label: "-1s",  value: value, by: -1)
                stepButton(label: "-0.1", value: value, by: -0.1)
                Spacer()
                stepButton(label: "+0.1", value: value, by: 0.1)
                stepButton(label: "+1s",  value: value, by: 1)
                stepButton(label: "+5s",  value: value, by: 5)
            }
            .font(.caption2)
            HStack {
                Button("Set to playhead now") {
                    let live = SponsorBlockSkipper.shared.currentPlayhead()
                    if live.episodeID == pending.episodeID {
                        value.wrappedValue = max(0, min(duration, live.position))
                    } else {
                        SponsorBlockToast.shared.show("Current podcast is different — set manually")
                    }
                }
                .font(.footnote)
                Spacer()
                if !isStart {
                    Button("Set to start +30s") {
                        value.wrappedValue = max(0, min(duration, startValue + 30))
                    }
                    .font(.footnote)
                }
            }
        }
    }

    private func stepButton(label: String, value: Binding<Double>, by delta: Double) -> some View {
        Button(label) {
            value.wrappedValue = max(0, min(duration, value.wrappedValue + delta))
        }
        .buttonStyle(BorderlessButtonStyle())
        .padding(.horizontal, 4)
    }

    private func sortedBounds() -> (start: Double, end: Double) {
        let lo = min(startValue, endValue)
        let hi = max(startValue, endValue)
        return (lo, hi)
    }

    private func persist() {
        let bounds = sortedBounds()
        var copy = pending
        copy.start = bounds.start
        copy.end = bounds.end
        copy.actionType = "skip"
        SponsorBlockPendingStore.upsert(copy)
        pending = copy
    }

    private func submit() {
        persist()
        let bounds = sortedBounds()
        guard bounds.end > bounds.start + 0.3 else { return }
        submitting = true
        errorMessage = nil

        SponsorBlockReporter.submitSegment(
            episodeID: pending.episodeID,
            start: bounds.start,
            end: bounds.end,
            category: pending.category,
            actionType: "skip",
            videoDuration: duration > 0 ? duration : nil
        ) { result in
            DispatchQueue.main.async {
                submitting = false
                switch result {
                case .success:
                    didSucceed = true
                    SponsorBlockPendingStore.remove(id: pending.id, episodeID: pending.episodeID)
                    let local = SponsorBlockLocalSegment(
                        id: UUID().uuidString,
                        episodeID: pending.episodeID,
                        start: bounds.start,
                        end: bounds.end,
                        category: pending.category,
                        createdAt: Date()
                    )
                    SponsorBlockMySubmissionsStore.add(local)
                    onSubmitted?()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        presentationMode.wrappedValue.dismiss()
                    }
                case .failure(let err):
                    errorMessage = err.localizedDescription
                }
            }
        }
    }
}
