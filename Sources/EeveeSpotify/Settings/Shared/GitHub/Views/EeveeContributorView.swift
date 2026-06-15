import SwiftUI

struct EeveeContributorView: View {
    var contributor: EeveeContributor
    var githubUser: GitHubUser

    var body: some View {
        VStack {
            Link(destination: URL(string: githubUser.htmlUrl)!) {
                HStack(spacing: 10) {
                    if contributor.usernames.count > 1 {
                        // Multiple users: inline [pfp] name & [pfp] name at text size
                        ForEach(Array(contributor.usernames.enumerated()), id: \.offset) { index, username in
                            if index > 0 {
                                Text("&")
                                    .font(.subheadline)
                                    .foregroundColor(.gray)
                            }
                            HStack(spacing: 4) {
                                ImageView(urlString: "https://github.com/\(username).png")
                                    .frame(width: 20, height: 20)
                                    .clipShape(Circle())
                                Text(nameFor(index: index, username: username))
                                    .foregroundColor(.white)
                                    .font(.headline)
                            }
                        }
                    } else {
                        // Single user: normal large avatar
                        ImageView(urlString: githubUser.avatarUrl)
                            .frame(width: 48, height: 48)
                            .clipShape(Circle())

                        VStack(alignment: .leading, spacing: 0) {
                            Text(contributor.displayName ?? contributor.usernames[0])
                                .foregroundColor(.white)
                                .font(.headline)

                            ForEach(contributor.roles, id: \.self) { role in
                                Text(role)
                                    .foregroundColor(.gray)
                            }
                        }
                    }

                    Spacer()

                    ChevronRightView()
                }
            }
        }
    }

    private func nameFor(index: Int, username: String) -> String {
        guard let displayName = contributor.displayName else {
            return username
        }
        if contributor.usernames.count == 1 {
            return displayName
        }
        let parts = displayName.components(separatedBy: " & ")
        if index < parts.count {
            return parts[index]
        }
        return username
    }
}
