import SwiftUI

struct SponsorBlockEpisodeSegmentsView: View {
    @Environment(\.presentationMode) private var presentationMode

    let episodeID: String
    @State private var segments: [SponsorBlockSegment] = []
    @State private var hiddenUUIDs: Set<String> = Set(SponsorBlockHiddenStore.all())
    @State private var votedMap: [String: SponsorBlockVotedStore.Direction] = SponsorBlockVotedStore.all()
    @State private var voteStatus: [String: String] = [:]

    var body: some View {
        NavigationView {
            ZStack {
                Color(UIColor.systemBackground).ignoresSafeArea()
                List {
                Section(
                    header: Text("Episode \(episodeID) · \(segments.count) segment\(segments.count == 1 ? "" : "s")"),
                    footer: segments.isEmpty ? nil : Text("Tap a row to jump the player to that segment.")
                ) {
                    if segments.isEmpty {
                        Text("No segments yet for this episode.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(segments, id: \.uuid) { seg in
                            row(seg)
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
            .navigationBarTitle("Segments", displayMode: .inline)
            .navigationBarItems(trailing: Button("Done") {
                presentationMode.wrappedValue.dismiss()
            })
            .onAppear(perform: reload)
            .onReceive(NotificationCenter.default.publisher(for: SponsorBlockSkipper.segmentsChangedNotification)) { _ in
                reload()
            }
            .onReceive(NotificationCenter.default.publisher(for: SponsorBlockHiddenStore.changedNotification)) { _ in
                hiddenUUIDs = Set(SponsorBlockHiddenStore.all())
            }
            .onReceive(NotificationCenter.default.publisher(for: SponsorBlockVotedStore.changedNotification)) { _ in
                votedMap = SponsorBlockVotedStore.all()
            }
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func row(_ seg: SponsorBlockSegment) -> some View {
        let isHidden = hiddenUUIDs.contains(seg.uuid)
        let isLocal  = SponsorBlockLocalSegment.isLocalUUID(seg.uuid)
        let voted    = votedMap[seg.uuid]
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(hex: UserDefaults.sponsorBlockOptions.color(for: seg.category)))
                    .frame(width: 10, height: 10)
                Text(SponsorBlockFormatters.categoryName(seg.category))
                    .font(.subheadline.weight(.semibold))
                if isLocal {
                    badge(text: "MINE", color: .accentColor)
                }
                if let voted {
                    badge(text: voted == .up ? "▲ UPVOTED" : "▼ DOWNVOTED",
                          color: voted == .up ? .green : .red)
                }
                if isHidden {
                    badge(text: "HIDDEN", color: .orange)
                }
                Spacer()
                if let status = voteStatus[seg.uuid] {
                    Text(status)
                        .font(.caption2)
                        .foregroundColor(.green)
                }
            }
            Text("\(SponsorBlockFormatters.time(seg.start)) → \(SponsorBlockFormatters.time(seg.end))  ·  \(Int(seg.duration))s")
                .font(.system(.footnote, design: .monospaced))
                .foregroundColor(.secondary)
            HStack(spacing: 10) {
                iconButton(systemImage: "hand.thumbsup.fill",   tint: .green, highlighted: voted == .up, disabled: isLocal) {
                    vote(uuid: seg.uuid, type: voted == .up ? .undo : .up)
                }
                iconButton(systemImage: "hand.thumbsdown.fill", tint: .red,   highlighted: voted == .down, disabled: isLocal) {
                    vote(uuid: seg.uuid, type: voted == .down ? .undo : .down)
                }
                iconButton(systemImage: "tag.fill",             tint: .blue,  highlighted: false, disabled: isLocal) {
                    pickCategory(for: seg)
                }
                Spacer()
                Button(action: {
                    if isHidden {
                        SponsorBlockHiddenStore.remove(seg.uuid)
                    } else {
                        SponsorBlockHiddenStore.add(seg.uuid)
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: isHidden ? "eye.fill" : "eye.slash.fill")
                        Text(isHidden ? "Unhide" : "Hide")
                            .font(.footnote.weight(.medium))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.15)))
                }
                .buttonStyle(PlainButtonStyle())
            }
            if isLocal {
                Text("Your submission — voting unavailable until the server publishes it.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { jumpTo(seg) }
    }

    private func badge(text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundColor(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.15)))
    }

    private func jumpTo(_ seg: SponsorBlockSegment) {
        let snap = SponsorBlockSkipper.shared.currentPlayhead()
        guard snap.episodeID == episodeID else {
            SponsorBlockToast.shared.show("Different episode is playing — can't jump")
            return
        }
        let ok = SponsorBlockSkipper.shared.seekTo(seconds: seg.start)
        if ok {
            SponsorBlockToast.shared.show("Jumped to \(SponsorBlockFormatters.shortTime(seg.start))")
        } else {
            SponsorBlockToast.shared.show("No active player to jump")
        }
    }

    private func iconButton(systemImage: String, tint: Color, highlighted: Bool, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(disabled ? .secondary : (highlighted ? .white : tint))
                .frame(width: 36, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(disabled ? Color.secondary.opacity(0.10)
                                       : (highlighted ? tint : tint.opacity(0.15)))
                )
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(disabled)
    }

    private func vote(uuid: String, type: SponsorBlockVote) {
        voteStatus[uuid] = "Sending…"
        SponsorBlockReporter.vote(uuid: uuid, type: type) { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    SponsorBlockVotedStore.record(uuid: uuid, vote: type)
                    voteStatus[uuid] = {
                        switch type {
                        case .up:   return "Upvoted ✓"
                        case .down: return "Downvoted ✓"
                        case .undo: return "Vote cleared ✓"
                        }
                    }()
                case .failure(let err):
                    voteStatus[uuid] = "Failed: \(err.localizedDescription)"
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if voteStatus[uuid]?.hasPrefix("Sending") == false { voteStatus.removeValue(forKey: uuid) }
                }
            }
        }
    }

    private func pickCategory(for seg: SponsorBlockSegment) {
        // Delegate to UIKit action sheet via top VC since SwiftUI confirmationDialog
        // is iOS 15+.
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let win = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first,
              var top = win.rootViewController else { return }
        while let p = top.presentedViewController { top = p }
        let alert = UIAlertController(title: "Change category", message: nil, preferredStyle: .actionSheet)
        for key in SponsorBlockOptions.allCategoryOrder where key != seg.category {
            alert.addAction(UIAlertAction(title: SponsorBlockFormatters.categoryName(key), style: .default) { _ in
                voteStatus[seg.uuid] = "Sending…"
                SponsorBlockReporter.categoryVote(uuid: seg.uuid, category: key) { result in
                    DispatchQueue.main.async {
                        switch result {
                        case .success: voteStatus[seg.uuid] = "Category vote sent ✓"
                        case .failure(let err): voteStatus[seg.uuid] = "Failed: \(err.localizedDescription)"
                        }
                    }
                }
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let pop = alert.popoverPresentationController {
            pop.sourceView = top.view
            pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        top.present(alert, animated: true)
    }

    private func reload() {
        let snap = SponsorBlockSkipper.shared.snapshot()
        segments = snap.segments.sorted { $0.start < $1.start }
        hiddenUUIDs = Set(SponsorBlockHiddenStore.all())
    }
}
