import SwiftUI

struct SponsorBlockAdvancedView: View {
    @Binding var options: SponsorBlockOptions
    @State private var showingResetSheet = false

    var body: some View {
        List {
            Section(header: Text("skipBehaviourTitle".localized)) {
                Toggle("autoSkipSubmissionsTitle".localized, isOn: $options.autoSkipMySubmissions)
                Toggle("logOnlyToggle".localized, isOn: $options.logOnly)
            }

            Section(header: Text("serverHeader".localized)) {
                HStack {
                    Text("urlText".localized)
                    Spacer()
                    TextField("https://sponsor.ajay.app", text: $options.serverURL)
                        .multilineTextAlignment(.trailing)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                }
            }

            Section(header: Text("tuningTitle".localized)) {
                Stepper(
                    String(format: "minSegmentDuration".localized, options.minSegmentDuration),
                    value: $options.minSegmentDuration,
                    in: 0.0...30.0,
                    step: 0.5
                )
                Stepper(
                    String(format: "toastDuration".localized, options.toastDuration),
                    value: $options.toastDuration,
                    in: 1.0...8.0,
                    step: 0.2
                )
            }

            Section(footer: Text("trackLogSubtitle".localized)) {
                Toggle("trackLogToggle".localized, isOn: $options.verboseLogging)
            }

            Section {
                Button {
                    showingResetSheet = true
                } label: {
                    HStack {
                        Image(systemName: "arrow.counterclockwise")
                        Text("resetButtonTrackLog".localized)
                    }
                    .foregroundColor(.red)
                }
            }

            Section {
                Color.clear
                    .frame(height: 90)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle("advancedTitle".localized)
        .actionSheet(isPresented: $showingResetSheet) { resetSheet() }
    }

    private func resetSheet() -> ActionSheet {
        let draftCount  = SponsorBlockPendingStore.all().values.reduce(0) { $0 + $1.count }
        let hiddenCount = SponsorBlockHiddenStore.all().count
        let votedCount  = SponsorBlockVotedStore.count
        let mineCount   = SponsorBlockMySubmissionsStore.totalCount

        return ActionSheet(
            title: Text("resetTitle".localized),
            message: Text("resetSubtitle".localized),
            buttons: [
                .destructive(Text("settingsResetSB".localized)) {
                    options = SponsorBlockOptions(
                        enabled: options.enabled,
                        logOnly: false,
                        showOverlay: true,
                        showToast: false,
                        respectManualSeek: false,
                        serverURL: "https://sponsor.ajay.app",
                        minSegmentDuration: 1.0,
                        categories: SponsorBlockOptions.defaultCategories,
                        colors: SponsorBlockOptions.defaultColors
                    )
                },
                .destructive(Text(String(format: "draftsCountSB".localized, draftCount))) {
                    for (id, _) in SponsorBlockPendingStore.all() {
                        SponsorBlockPendingStore.clear(episodeID: id)
                    }
                },
                .destructive(Text(String(format: "hiddenSegmentsSB".localized, hiddenCount))) {
                    SponsorBlockHiddenStore.clear()
                },
                .destructive(Text(String(format: "votedRecordsSB".localized, votedCount))) {
                    SponsorBlockVotedStore.clear()
                },
                .destructive(Text(String(format: "localSubmissionsSB".localized, mineCount))) {
                    SponsorBlockMySubmissionsStore.clear()
                },
                .destructive(Text("regenerateIDSB".localized)) {
                    UserDefaults.sponsorBlockUserID = SponsorBlockReporter.makeUserID()
                },
                .destructive(Text("allResetSB".localized)) {
                    options = SponsorBlockOptions(
                        enabled: false,
                        logOnly: false,
                        showOverlay: true,
                        showToast: false,
                        respectManualSeek: false,
                        serverURL: "https://sponsor.ajay.app",
                        minSegmentDuration: 1.0,
                        categories: SponsorBlockOptions.defaultCategories,
                        colors: SponsorBlockOptions.defaultColors
                    )
                    for (id, _) in SponsorBlockPendingStore.all() {
                        SponsorBlockPendingStore.clear(episodeID: id)
                    }
                    SponsorBlockHiddenStore.clear()
                    SponsorBlockVotedStore.clear()
                    SponsorBlockMySubmissionsStore.clear()
                    UserDefaults.sponsorBlockUserID = SponsorBlockReporter.makeUserID()
                },
                .cancel()
            ]
        )
    }
}
