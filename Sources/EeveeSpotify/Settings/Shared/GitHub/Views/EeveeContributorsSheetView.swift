import SwiftUI

struct ContributorRow: View {
    let contributor: EeveeContributor

    var body: some View {
        if contributor.usernames.count > 1 {
            // Multiple main contributors: inline [pfp] name & [pfp] name
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    ForEach(Array(contributor.usernames.enumerated()), id: \.offset) { index, username in
                        if index > 0 {
                            Text("&")
                                .font(.headline)
                                .foregroundColor(.white)
                        }
                        HStack(spacing: 4) {
                            ImageView(urlString: "https://github.com/\(username).png")
                                .frame(width: 20, height: 20)
                                .clipShape(Circle())
                            Text(nameFor(index: index, username: username))
                                .font(.headline)
                        }
                    }
                }
                Text(contributor.roles.joined(separator: ", "))
                    .font(.subheadline)
                    .foregroundColor(.gray)
            }
            .padding(.vertical, 4)
        } else {
            // Single contributor: pfp on left, name + roles on right
            HStack(alignment: .top, spacing: 12) {
                ImageView(urlString: "https://github.com/\(contributor.usernames[0]).png")
                    .frame(width: 40, height: 40)
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(contributor.displayName ?? contributor.usernames[0])
                        .font(.headline)

                    if let richRoles = contributor.richRoles {
                        ForEach(richRoles, id: \.name) { role in
                            HStack(spacing: 6) {
                                Text(role.name)
                                    .font(.subheadline)
                                    .foregroundColor(.gray)

                                if let coUsernames = role.coUsernames, !coUsernames.isEmpty {
                                    ForEach(Array(coUsernames.enumerated()), id: \.offset) { index, username in
                                        HStack(spacing: 4) {
                                            ImageView(urlString: "https://github.com/\(username).png")
                                                .frame(width: 16, height: 16)
                                                .clipShape(Circle())
                                            Text(role.coDisplayNames?[safe: index] ?? username)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    } else {
                        HStack(spacing: 0) {
                            ForEach(Array(contributor.roles.enumerated()), id: \.offset) { index, role in
                                if index > 0 {
                                    Text(", ")
                                        .font(.subheadline)
                                        .foregroundColor(.gray)
                                }
                                Text(role)
                                    .font(.subheadline)
                                    .foregroundColor(.gray)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func nameFor(index: Int, username: String) -> String {
        guard let displayName = contributor.displayName else { return username }
        if contributor.usernames.count == 1 { return displayName }
        let parts = displayName.components(separatedBy: " & ")
        return index < parts.count ? parts[index] : username
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private struct FullWidthSeparatorModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        } else {
            content
        }
    }
}

struct EeveeContributorsSheetView: View {
    @State private var sections: [EeveeContributorSection] = []
    @State private var isLoading = true
    @State private var errorMessage: String? = nil

    var body: some View {
        NavigationView {
            contentView
                .navigationTitle("contributors".localized)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    Button {
                        WindowHelper.shared.dismissCurrentViewController()
                    } label: {
                        Text("Done".uiKitLocalized)
                            .font(.headline)
                    }
                }
                .onAppear {
                    loadContributors()
                }
        }
    }

    @ViewBuilder
    private var contentView: some View {
        if isLoading {
            ProgressView("Loading".uiKitLocalized)
        } else if let error = errorMessage {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundColor(.orange)
                Text("Failed to load contributors")
                    .font(.headline)
                Text(error)
                    .font(.caption)
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button("Retry") {
                    isLoading = true
                    errorMessage = nil
                    loadContributors()
                }
            }
        } else if sections.isEmpty {
            Text("No contributors found")
                .foregroundColor(.gray)
        } else {
            contributorsList
        }
    }

    private var contributorsList: some View {
        List {
            ForEach(sections, id: \.title) { section in
                Section(header: Text(section.title)) {
                    let contributors = section.shuffled ? section.contributors.shuffled() : section.contributors
                    ForEach(contributors, id: \.usernames) { contributor in
                        ContributorRow(contributor: contributor)
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                            .modifier(FullWidthSeparatorModifier())
                    }
                }
            }
        }
    }

    private func loadContributors() {
        Task {
            do {
                sections = try await GitHubHelper.shared.getEeveeContributorSections()
            } catch {
                print("Failed to load contributors: \(error)")
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}
