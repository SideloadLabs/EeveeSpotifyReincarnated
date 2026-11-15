import SwiftUI
import UIKit

public struct OfflineLibraryView: View {
    @State private var tracks: [OfflineTrack] = []
    @State private var currentlyPlayingId: String?
    @State private var isPlaying = false
    @State private var statusMessage = ""

    public init() {}

    public var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.edgesIgnoringSafeArea(.all)

            List {
                Section {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 16) {
                            ZStack {
                                LinearGradient(
                                    gradient: Gradient(colors: [Color(hex: "#1ed760"), Color(hex: "#0e5e2a")]),
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.system(size: 38, weight: .bold))
                                    .foregroundColor(.black)
                            }
                            .frame(width: 80, height: 80)
                            .cornerRadius(10)
                            .shadow(color: .black.opacity(0.4), radius: 6, x: 0, y: 3)

                            VStack(alignment: .leading, spacing: 5) {
                                Text("offline_downloaded_tracks".localized)
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundColor(.white)
                                Text(String(format: "offline_library_row_count".localized, tracks.count))
                                    .font(.system(size: 13))
                                    .foregroundColor(.gray)
                            }
                        }

                        if !tracks.isEmpty {
                            HStack {
                                Button(action: {
                                    let player = OfflinePlaybackController.shared
                                    if player.currentTrack != nil {
                                        if player.isPlaying { player.pause() }
                                        else if !player.resume() { statusMessage = OfflinePlayerError.playbackFailed.localizedDescription }
                                    } else if !player.setQueue(tracks) {
                                        statusMessage = OfflinePlayerError.playbackFailed.localizedDescription
                                    }
                                }) {
                                    HStack(spacing: 8) {
                                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                        Text(isPlaying ? "offline_pause".localized : "offline_play_all".localized)
                                    }
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundColor(.black)
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 10)
                                    .background(Color(hex: "#1ed760"))
                                    .cornerRadius(22)
                                }

                                Spacer()
                            }
                            .padding(.top, 4)
                        }
                    }
                    .padding(.vertical, 8)
                    .listRowBackground(Color(white: 0.12))
                }

                Section(header: Text("offline_device_tracks".localized).foregroundColor(Color(white: 0.6))) {
                    if tracks.isEmpty {
                        VStack(alignment: .center, spacing: 12) {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 44))
                                .foregroundColor(Color(hex: "#1ed760"))
                            Text("offline_no_tracks".localized)
                                .font(.headline)
                                .foregroundColor(.white)
                            Text("offline_download_hint".localized)
                                .font(.footnote)
                                .foregroundColor(.gray)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                        .listRowBackground(Color(white: 0.12))
                    } else {
                        ForEach(tracks) { track in
                            Button(action: {
                                playTrack(track)
                            }) {
                                HStack(spacing: 12) {
                                    let coverFile = OfflineLibraryStore.storesDirectory.appendingPathComponent("\(track.id).jpg")
                                    if let img = UIImage(contentsOfFile: coverFile.path) {
                                        Image(uiImage: img)
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                            .frame(width: 46, height: 46)
                                            .cornerRadius(6)
                                    } else {
                                        ZStack {
                                            Color(white: 0.22)
                                            Image(systemName: "music.note")
                                                .foregroundColor(.white)
                                        }
                                        .frame(width: 46, height: 46)
                                        .cornerRadius(6)
                                    }

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(track.title)
                                            .font(.system(size: 15, weight: currentlyPlayingId == track.id ? .bold : .medium))
                                            .foregroundColor(currentlyPlayingId == track.id ? Color(hex: "#1ed760") : .white)
                                            .lineLimit(1)
                                        Text(track.artist)
                                            .font(.system(size: 13))
                                            .foregroundColor(Color(white: 0.7))
                                            .lineLimit(1)
                                    }

                                    Spacer()

                                    if track.downloadState == .downloading {
                                        ProgressView()
                                            .progressViewStyle(CircularProgressViewStyle(tint: Color(hex: "#1ed760")))
                                    } else if currentlyPlayingId == track.id && isPlaying {
                                        Image(systemName: "waveform")
                                            .font(.title3)
                                            .foregroundColor(Color(hex: "#1ed760"))
                                    } else {
                                        Image(systemName: "play.circle.fill")
                                            .font(.title3)
                                            .foregroundColor(Color(white: 0.5))
                                    }
                                }
                                .padding(.vertical, 3)
                            }
                            .listRowBackground(Color(white: 0.12))
                        }
                        .onDelete(perform: deleteTrack)
                    }
                }

                if !statusMessage.isEmpty {
                    Section {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundColor(.green)
                            .listRowBackground(Color(white: 0.12))
                    }
                }

                Section {
                    Color.clear.frame(height: 75)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(InsetGroupedListStyle())
            .hideScrollBackground()
            .background(Color.black)
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .navigationBarTitle("offline_downloaded_tracks".localized, displayMode: .inline)
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: OfflineLibraryStore.changed)) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: OfflinePlaybackController.changed)) { _ in reload() }
    }

    private func reload() {
        tracks = OfflineLibraryStore.shared.downloadedTracks()
        currentlyPlayingId = OfflinePlaybackController.shared.currentTrack?.id
        isPlaying = OfflinePlaybackController.shared.isPlaying
    }

    private func playTrack(_ track: OfflineTrack) {
        guard OfflineLibraryStore.shared.isDownloaded(track.id) else { return }
        statusMessage = ""
        let player = OfflinePlaybackController.shared
        if player.currentTrack?.id == track.id {
            if player.isPlaying { player.pause() }
            else if !player.resume() { statusMessage = OfflinePlayerError.playbackFailed.localizedDescription }
        } else if let index = tracks.firstIndex(where: { $0.id == track.id }),
                  !player.setQueue(tracks, startIndex: index) {
            statusMessage = OfflinePlayerError.playbackFailed.localizedDescription
        }
    }

    private func deleteTrack(at offsets: IndexSet) {
        let ids = offsets.compactMap { tracks.indices.contains($0) ? tracks[$0].id : nil }
        do {
            for id in ids { try OfflineLibraryStore.shared.removeDownloaded(id: id) }
        } catch {
            statusMessage = error.localizedDescription
        }
        reload()
    }
}

private extension View {
    @ViewBuilder
    func hideScrollBackground() -> some View {
        if #available(iOS 16.0, *) {
            self.scrollContentBackground(.hidden)
        } else {
            self
        }
    }
}
