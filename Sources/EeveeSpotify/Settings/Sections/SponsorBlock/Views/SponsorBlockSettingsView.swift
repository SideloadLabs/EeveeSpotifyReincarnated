import SwiftUI

struct SponsorBlockSettingsView: View {
    @State private var options = UserDefaults.sponsorBlockOptions

    var body: some View {
        List {
            Section(footer: Text("categoryOneFooter".localized)) {
                Toggle("enableSponsorblock".localized, isOn: $options.enabled)
                Toggle("showColoredOverlay".localized, isOn: $options.showOverlay)
                    .disabled(!options.enabled)
                Toggle("showToast".localized, isOn: $options.showToast)
                    .disabled(!options.enabled)
                Toggle("skipToast".localized, isOn: $options.showSkipFeedbackButtons)
                    .disabled(!options.enabled || !options.showToast)
                Toggle("respectManualSeek".localized, isOn: $options.respectManualSeek)
                    .disabled(!options.enabled)
            }

            Section(header: Text("categoriesHeader".localized),
                    footer: Text("categoriesFooter".localized)) {
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
                        Text("draftsTitle".localized)
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
                        PopUpHelper.showPopUp(message: "errorNoPodcats".localized, buttonText: "OK")
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
                        Text("markSegment".localized)
                    }
                }
                NavigationLink(destination: SponsorBlockAdvancedView(options: $options)) {
                    HStack {
                        Image(systemName: "gearshape.2")
                        Text("advancedTitle".localized)
                    }
                }
                NavigationLink(destination: SponsorBlockHelpView()) {
                    HStack {
                        Image(systemName: "questionmark.circle")
                        Text("howToUseTitle".localized)
                    }
                }
            }

            Section(header: Text("creditsTitle".localized),
                    footer: Text("creditsSubtitle".localized)) {
                Link("linkButtonTitle".localized,
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
            case .disabled: return "action_disabled".localized
            case .showOnly: return "action_show".localized
            case .manualSkip: return "action_manual".localized
            case .autoSkip: return "action_auto".localized
        }
    }

    private func prettyName(_ key: String) -> String {
        switch key {
            case "sponsor": return "sponsor_category".localized
            case "selfpromo": return "selfpromo_category".localized
            case "interaction": return "interaction_category".localized
            case "intro": return "intro_category".localized
            case "outro": return "outro_category".localized
            case "preview": return "preview_category".localized
            case "hook": return "hook_category".localized
            case "filler": return "filler_category".localized
            case "exclusive_access": return "exclusive_access_category".localized
            default: return key
        }
    }
}
