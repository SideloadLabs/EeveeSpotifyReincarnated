import SwiftUI

struct SponsorBlockSettingsView: View {
    @State private var options = UserDefaults.sponsorBlockOptions

    var body: some View {
        List {
            Section(footer: Text("Skips community-marked segments in podcast episodes.")) {
                Toggle("Enable SponsorBlock", isOn: $options.enabled)
                Toggle("Show colored overlay on progress bar", isOn: $options.showOverlay)
                    .disabled(!options.enabled)
                Toggle("Show toast when skipping", isOn: $options.showToast)
                    .disabled(!options.enabled)
                Toggle("Skip-toast action buttons (vote / undo / hide)", isOn: $options.showSkipFeedbackButtons)
                    .disabled(!options.enabled || !options.showToast)
                Toggle("Respect manual seek (don't re-skip)", isOn: $options.respectManualSeek)
                    .disabled(!options.enabled)
            }

            Section(header: Text("Categories"),
                    footer: Text("Off · Show · Manual · Auto. Tap the color circle to change.")) {
                ForEach(SponsorBlockOptions.allCategoryOrder, id: \.self) { key in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(prettyName(key))
                                .font(.body)
                            Spacer()
                            ColorPicker("", selection: bindingForColor(key), supportsOpacity: false)
                                .labelsHidden()
                                .frame(width: 32)
                                .disabled(!options.enabled)
                        }
                        Picker("", selection: bindingForAction(key)) {
                            ForEach(SponsorBlockAction.allCases, id: \.self) { act in
                                Text(actionLabel(act)).tag(act)
                            }
                        }
                        .pickerStyle(SegmentedPickerStyle())
                        .disabled(!options.enabled)
                    }
                    .padding(.vertical, 2)
                }
            }

            Section {
                NavigationLink(destination: SponsorBlockPendingListView()) {
                    HStack {
                        Image(systemName: "tray.and.arrow.up")
                        Text("Reporting & drafts")
                        Spacer()
                        let count = SponsorBlockPendingStore.all().values.reduce(0) { $0 + $1.count }
                        if count > 0 {
                            Text("\(count)")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                Button {
                    let snap = SponsorBlockSkipper.shared.currentPlayhead()
                    guard let episodeID = snap.episodeID else {
                        PopUpHelper.showPopUp(message: "No podcast is currently playing.", buttonText: "OK")
                        return
                    }
                    let active = SponsorBlockPendingStore.segments(for: episodeID).first(where: { $0.end == nil })
                    if let active {
                        var copy = active
                        copy.end = max(snap.position, copy.start + 0.1)
                        SponsorBlockPendingStore.upsert(copy)
                        SponsorBlockReportingUI.presentSubmitForm(pending: copy, duration: snap.duration)
                    } else {
                        let p = SponsorBlockPendingSegment(episodeID: episodeID, start: snap.position)
                        SponsorBlockPendingStore.upsert(p)
                        SponsorBlockToast.shared.show("Start set at \(String(format: "%.1f", snap.position))s · open again to set end")
                    }
                } label: {
                    HStack {
                        Image(systemName: "plus.circle")
                        Text("Mark segment for current episode")
                    }
                }
                NavigationLink(destination: SponsorBlockAdvancedView(options: $options)) {
                    HStack {
                        Image(systemName: "gearshape.2")
                        Text("Advanced")
                    }
                }
                NavigationLink(destination: SponsorBlockHelpView()) {
                    HStack {
                        Image(systemName: "questionmark.circle")
                        Text("How to use")
                    }
                }
            }

            Section(header: Text("Credits"),
                    footer: Text("Segment data from the SponsorBlock community (sponsor.ajay.app). Integration ported from Spot-SponsorBlock-Extension by Spot-SponsorBlock.")) {
                Link("Spot-SponsorBlock-Extension on GitHub",
                     destination: URL(string: "https://github.com/Spot-SponsorBlock/Spot-SponsorBlock-Extension")!)
                Link("SponsorBlock", destination: URL(string: "https://sponsor.ajay.app")!)
            }

            Section {
                Color.clear
                    .frame(height: 90)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
        }
        .listStyle(GroupedListStyle())
        .animation(.default, value: options)
        .onChange(of: options) { newValue in
            UserDefaults.sponsorBlockOptions = newValue
            NotificationCenter.default.post(name: SponsorBlockSkipper.segmentsChangedNotification, object: nil)
        }
    }

    private func bindingForAction(_ key: String) -> Binding<SponsorBlockAction> {
        Binding(
            get: { options.categories[key] ?? .disabled },
            set: { options.categories[key] = $0 }
        )
    }

    private func bindingForColor(_ key: String) -> Binding<Color> {
        Binding(
            get: { Color(hex: options.color(for: key)) },
            set: { newColor in options.colors[key] = "#" + newColor.hexString }
        )
    }

    private func actionLabel(_ a: SponsorBlockAction) -> String {
        switch a {
        case .disabled:   return "Off"
        case .showOnly:   return "Show"
        case .manualSkip: return "Manual"
        case .autoSkip:   return "Auto"
        }
    }

    private func prettyName(_ key: String) -> String {
        switch key {
        case "sponsor":          return "Sponsor"
        case "selfpromo":        return "Unpaid/Self Promotion"
        case "interaction":      return "Interaction Reminder"
        case "intro":            return "Intermission/Intro"
        case "outro":            return "Outro/Credits"
        case "preview":          return "Preview/Recap"
        case "hook":             return "Hook/Greetings"
        case "filler":           return "Tangent/Filler"
        case "exclusive_access": return "Exclusive Access"
        default:                 return key
        }
    }
}
