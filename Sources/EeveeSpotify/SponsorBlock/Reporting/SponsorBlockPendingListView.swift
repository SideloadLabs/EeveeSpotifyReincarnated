import SwiftUI
import UIKit

struct SponsorBlockPendingListView: View {
    @State private var groups: [(episodeID: String, drafts: [SponsorBlockPendingSegment])] = []
    @State private var hiddenUUIDs: [String] = []
    @State private var userID: String = UserDefaults.sponsorBlockUserID
    @State private var showingRegenConfirm = false
    @State private var showingHiddenClearConfirm = false
    @State private var presentingSubmit: SponsorBlockPendingSegment?

    var body: some View {
        List {
            Section(header: Text("Your SponsorBlock ID"),
                    footer: Text("Used to attribute your submissions and votes. Treat as a private password — don't share it.")) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(userID)
                        .font(.system(.footnote, design: .monospaced))
                        .lineLimit(2)
                        .truncationMode(.middle)
                    HStack {
                        Button {
                            UIPasteboard.general.string = userID
                            SponsorBlockToast.shared.show("User ID copied")
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(BorderlessButtonStyle())
                        Spacer()
                        Button(action: { showingRegenConfirm = true }) {
                            Label("Regenerate", systemImage: "arrow.triangle.2.circlepath")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(BorderlessButtonStyle())
                    }
                    .font(.footnote)
                }
                .padding(.vertical, 4)
            }

            if groups.isEmpty {
                Section(header: Text("Drafts")) {
                    Text("No drafts. Long-press the podcast progress bar to start marking a segment.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            } else {
                ForEach(groups, id: \.episodeID) { group in
                    Section(header: Text("Episode \(group.episodeID)")) {
                        ForEach(group.drafts) { d in
                            draftRow(d)
                        }
                    }
                }
            }

            Section(header: Text("Hidden locally (\(hiddenUUIDs.count))"),
                    footer: Text("Segments here are never auto-skipped on this device. They still exist on the SponsorBlock server.")) {
                if hiddenUUIDs.isEmpty {
                    Text("No hidden segments.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(hiddenUUIDs, id: \.self) { uuid in
                        HStack {
                            Text(String(uuid.prefix(8)) + "…")
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundColor(.secondary)
                            Spacer()
                            Button(action: {
                                SponsorBlockHiddenStore.remove(uuid)
                                reload()
                            }) {
                                Text("Unhide").font(.footnote)
                            }
                            .buttonStyle(BorderlessButtonStyle())
                        }
                    }
                    Button(action: { showingHiddenClearConfirm = true }) {
                        Label("Clear all hidden", systemImage: "trash")
                            .foregroundColor(.red)
                    }
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
        .navigationTitle("SponsorBlock Reports")
        .onAppear(perform: reload)
        .alert(isPresented: $showingRegenConfirm) {
            Alert(
                title: Text("Regenerate user ID?"),
                message: Text("Your existing submissions and votes will no longer be linked to you."),
                primaryButton: .destructive(Text("Regenerate")) {
                    let fresh = SponsorBlockReporter.makeUserID()
                    UserDefaults.sponsorBlockUserID = fresh
                    userID = fresh
                },
                secondaryButton: .cancel()
            )
        }
        .actionSheet(isPresented: $showingHiddenClearConfirm) {
            ActionSheet(
                title: Text("Clear all hidden segments?"),
                message: Text("They will skip again according to your category rules."),
                buttons: [
                    .destructive(Text("Clear all")) {
                        SponsorBlockHiddenStore.clear()
                        reload()
                    },
                    .cancel()
                ]
            )
        }
        .sheet(item: $presentingSubmit, onDismiss: reload) { item in
            SponsorBlockSubmitView(
                pending: item,
                duration: SponsorBlockSkipper.shared.currentPlayhead().duration,
                onSubmitted: reload
            )
        }
    }

    @ViewBuilder
    private func draftRow(_ d: SponsorBlockPendingSegment) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle()
                    .fill(Color(hex: UserDefaults.sponsorBlockOptions.color(for: d.category)))
                    .frame(width: 10, height: 10)
                Text(SponsorBlockFormatters.categoryName(d.category))
                    .font(.body)
                Spacer()
                Text(d.isReadyToSubmit ? "Ready" : "Incomplete")
                    .font(.caption2)
                    .foregroundColor(d.isReadyToSubmit ? .green : .orange)
            }
            Text("\(SponsorBlockFormatters.time(d.start)) → \(d.end.map(SponsorBlockFormatters.time) ?? "—")")
                .font(.footnote)
                .foregroundColor(.secondary)
            HStack {
                Button(action: { presentingSubmit = d }) {
                    Label("Edit / Submit", systemImage: "square.and.pencil")
                        .font(.footnote)
                }
                .buttonStyle(BorderlessButtonStyle())
                Spacer()
                Button(action: {
                    SponsorBlockPendingStore.remove(id: d.id, episodeID: d.episodeID)
                    reload()
                }) {
                    Label("Discard", systemImage: "trash")
                        .font(.footnote)
                        .foregroundColor(.red)
                }
                .buttonStyle(BorderlessButtonStyle())
            }
        }
        .padding(.vertical, 2)
    }

    private func reload() {
        groups = SponsorBlockPendingStore.all()
            .map { (episodeID: $0.key, drafts: $0.value.sorted { $0.createdAt < $1.createdAt }) }
            .sorted { $0.episodeID < $1.episodeID }
        hiddenUUIDs = SponsorBlockHiddenStore.all().sorted()
    }
}
