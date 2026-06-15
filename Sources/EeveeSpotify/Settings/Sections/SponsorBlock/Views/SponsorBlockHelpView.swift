import SwiftUI

struct SponsorBlockHelpView: View {
    var body: some View {
        List {
            Section(header: Text("playerGesturesTitle".localized)) {
                row(symbol: "hand.tap",
                    title: "gesturesTitle1".localized,
                    detail: "gesturesDeps1".localized)
                row(symbol: "hand.point.up.left.fill",
                    title: "gesturesTitle2".localized,
                    detail: "gesturesDeps2".localized)
            }

            Section(header: Text("submittingTitle".localized)) {
                row(symbol: "square.and.pencil",
                    title: "submittingSectionTitle1".localized,
                    detail: "submittingSectionDeps1".localized)
                row(symbol: "lock.shield",
                    title: "submittingSectionTitle2".localized,
                    detail: "submittingSectionDeps2".localized)
            }

            Section(header: Text("skipToastTitle".localized)) {
                row(symbol: "arrow.uturn.backward",
                    title: "skipToastSectionTitle1".localized,
                    detail: "skipToastSectionDeps1".localized)
                row(symbol: "hand.thumbsup.fill",
                    title: "skipToastSectionTitle2".localized,
                    detail: "skipToastSectionDeps2".localized)
                row(symbol: "ellipsis",
                    title: "skipToastSectionTitle3".localized,
                    detail: "skipToastSectionDeps3".localized)
            }

            Section(header: Text("managingSegmentsTitle".localized)) {
                row(symbol: "list.bullet.rectangle.portrait",
                    title: "managingSegmentsSectionTitle1".localized,
                    detail: "managingSegmentsSectionDeps1".localized)
                row(symbol: "tray.full",
                    title: "managingSegmentsSectionTitle2".localized,
                    detail: "managingSegmentsSectionDeps2".localized)
            }

            Section(header: Text("categoriesTitle".localized)) {
                row(symbol: "list.bullet.rectangle",
                    title: "categoriesSectionTitle1".localized,
                    detail: "categoriesSectionDeps1".localized)
            }

            Section {
                Color.clear
                    .frame(height: 90)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle("howToUseTitle".localized)
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