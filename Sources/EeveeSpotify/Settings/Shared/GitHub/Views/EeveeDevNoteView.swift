import SwiftUI

struct EeveeDevNoteView: View {
    @State private var noteText: String?
    @State private var isLoading = true
    @State private var errorMessage: String? = nil
    
    private let devNoteURL = URL(
        string: "https://raw.githubusercontent.com/SideloadLabs/EeveeSpotifyReincarnated/refs/heads/Master/devnote.txt"
    )!
    
    var body: some View {
        NavigationView {
            contentView
                .navigationTitle("developer_note".localized)
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
                    loadDevNote()
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
                Text("Failed to load developer note")
                    .font(.headline)
                Text(error)
                    .font(.caption)
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button("Retry") {
                    isLoading = true
                    errorMessage = nil
                    loadDevNote()
                }
            }
        } else if let text = noteText {
            ScrollView {
                Text(text)
                    .font(.body)
                    .foregroundColor(.white)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text("No developer note found")
                .foregroundColor(.gray)
        }
    }
    
    private func loadDevNote() {
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: devNoteURL)
                noteText = String(data: data, encoding: .utf8)
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}
