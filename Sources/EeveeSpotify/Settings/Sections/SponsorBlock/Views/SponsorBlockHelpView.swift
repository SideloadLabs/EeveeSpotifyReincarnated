import SwiftUI

struct SponsorBlockHelpView: View {
    var body: some View {
        List {
            Section(header: Text("Gestures on the player")) {
                row(symbol: "hand.tap",
                    title: "Long-press the progress bar",
                    detail: "Mark a segment start. Long-press again at the end of the segment to set END and open the submission form.")
                row(symbol: "hand.point.up.left.fill",
                    title: "Tap a segment on the bar",
                    detail: "Vote, change category, or hide a segment on this device only.")
            }

            Section(header: Text("Submitting")) {
                row(symbol: "square.and.pencil",
                    title: "Submission form",
                    detail: "Sliders + nudge buttons fine-tune start/end. Pick a category. Submit posts to sponsor.ajay.app.")
                row(symbol: "lock.shield",
                    title: "Your local submissions",
                    detail: "Auto-skipped on this device immediately. Voting unlocks once the server publishes them. The 'MINE' badge marks them.")
            }

            Section(header: Text("Skip toast")) {
                row(symbol: "arrow.uturn.backward",
                    title: "Undo",
                    detail: "Seeks back to segment start. The segment plays through this once. Forward + back resets it so it re-skips.")
                row(symbol: "hand.thumbsup.fill",
                    title: "Upvote / Downvote",
                    detail: "👍 records your vote on the server. 👎 opens a menu to downvote, hide locally, or change category.")
                row(symbol: "ellipsis",
                    title: "Full segment menu",
                    detail: "Same options as tapping the segment on the progress bar.")
            }

            Section(header: Text("Managing segments")) {
                row(symbol: "list.bullet.rectangle.portrait",
                    title: "Manage segments…",
                    detail: "Long-press the bar → 'Manage segments' lists every segment for the current episode. Vote, hide, change category, or tap a row to jump the player.")
                row(symbol: "tray.full",
                    title: "Reporting & drafts",
                    detail: "Settings → 'Reporting & drafts' holds your in-progress drafts (unfinished marks) and your hidden segments. Drafts persist across launches.")
            }

            Section(header: Text("Categories")) {
                row(symbol: "list.bullet.rectangle",
                    title: "Per-category actions",
                    detail: "Off = ignore. Show = draw on the bar only. Manual = prompt before skipping. Auto = skip silently.")
            }

            Section {
                Color.clear
                    .frame(height: 90)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle("How to use")
    }

    private func row(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(.accentColor)
                .frame(width: 28, alignment: .center)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
