import SwiftUI

struct SponsorBlockAdvancedView: View {
    @Binding var options: SponsorBlockOptions
    @State private var showingResetSheet = false

    var body: some View {
        List {
            Section(header: Text("Skipping behavior")) {
                Toggle("Auto-skip my own submissions", isOn: $options.autoSkipMySubmissions)
                Toggle("Log only (don't actually seek)", isOn: $options.logOnly)
            }

            Section(header: Text("Server")) {
                HStack {
                    Text("URL")
                    Spacer()
                    TextField("https://sponsor.ajay.app", text: $options.serverURL)
                        .multilineTextAlignment(.trailing)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                }
            }

            Section(header: Text("Tuning")) {
                Stepper(
                    "Min segment duration: \(String(format: "%.1f", options.minSegmentDuration))s",
                    value: $options.minSegmentDuration,
                    in: 0.0...30.0,
                    step: 0.5
                )
                Stepper(
                    "Toast duration: \(String(format: "%.1f", options.toastDuration))s",
                    value: $options.toastDuration,
                    in: 1.0...8.0,
                    step: 0.2
                )
            }

            Section(footer: Text("Dumps podcast track metadata (URI, isPodcast, isVideo, etc.) to the debug log on each new track. Enable only when SponsorBlock isn't detecting a podcast you expect.")) {
                Toggle("Diagnostic track log", isOn: $options.verboseLogging)
            }

            Section {
                Button {
                    showingResetSheet = true
                } label: {
                    HStack {
                        Image(systemName: "arrow.counterclockwise")
                        Text("Reset…")
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
        .navigationTitle("Advanced")
        .actionSheet(isPresented: $showingResetSheet) { resetSheet() }
    }

    private func resetSheet() -> ActionSheet {
        let draftCount  = SponsorBlockPendingStore.all().values.reduce(0) { $0 + $1.count }
        let hiddenCount = SponsorBlockHiddenStore.all().count
        let votedCount  = SponsorBlockVotedStore.count
        let mineCount   = SponsorBlockMySubmissionsStore.totalCount

        return ActionSheet(
            title: Text("Reset what?"),
            message: Text("Each is independent."),
            buttons: [
                .destructive(Text("Settings (toggles + categories + colors)")) {
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
                .destructive(Text("Drafts (\(draftCount))")) {
                    for (id, _) in SponsorBlockPendingStore.all() {
                        SponsorBlockPendingStore.clear(episodeID: id)
                    }
                },
                .destructive(Text("Hidden segments (\(hiddenCount))")) {
                    SponsorBlockHiddenStore.clear()
                },
                .destructive(Text("Voted records (\(votedCount))")) {
                    SponsorBlockVotedStore.clear()
                },
                .destructive(Text("My local submissions (\(mineCount))")) {
                    SponsorBlockMySubmissionsStore.clear()
                },
                .destructive(Text("Regenerate user ID")) {
                    UserDefaults.sponsorBlockUserID = SponsorBlockReporter.makeUserID()
                },
                .destructive(Text("Everything (all of the above)")) {
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
