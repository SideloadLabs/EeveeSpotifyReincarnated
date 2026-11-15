import SwiftUI

@available(iOS 16.0, *)
public struct EeveeOfflineSettingsView: View {
    @State private var quality = UserDefaults.offlineQuality
    @State private var region = UserDefaults.offlineRegion
    @State private var showingClearAlert = false
    @State private var tracksCount = OfflineLibraryStore.shared.allTracks().count

    public init() {}

    public var body: some View {
        List {
            Section(header: Text("offline_audio_quality".localized),
                    footer: Text((quality == 1 ? "offline_hifi_details" : "offline_fast_details").localized)) {
                Picker("offline_audio_quality".localized, selection: $quality) {
                    Text("offline_fast".localized).tag(0)
                    Text("offline_hifi".localized).tag(1)
                }
                .onChange(of: quality) { UserDefaults.offlineQuality = $0 }
            }
            if quality != 1 {
                Section(footer: Text("offline_region_details".localized)) {
                    Picker("offline_region".localized, selection: $region) {
                        ForEach(OfflineSearchRegion.allCases, id: \.self) { option in
                            Text(option.localizationKey.localized).tag(option)
                        }
                    }
                    .onChange(of: region) { UserDefaults.offlineRegion = $0 }
                }
            }
            Section(header: Text("offline_library".localized), footer: Text("offline_library_details".localized)) {
                Button("offline_collection_by_link".localized) {
                    PlaylistDownloaderHelper.promptForCollectionLink()
                }
                HStack {
                    Text("offline_device_tracks".localized)
                    Spacer()
                    Text(String(format: "offline_track_count".localized, tracksCount))
                        .foregroundColor(.gray)
                }
                Button("offline_delete_all".localized, role: .destructive) { showingClearAlert = true }
                    .alert("offline_delete_all".localized, isPresented: $showingClearAlert) {
                        Button("offline_delete".localized, role: .destructive, action: clear)
                        Button("offline_cancel".localized, role: .cancel) {}
                    } message: {
                        Text("offline_delete_all_message".localized)
                    }
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationBarTitle("offline".localized, displayMode: .inline)
        .onReceive(NotificationCenter.default.publisher(for: OfflineLibraryStore.changed)) { _ in
            tracksCount = OfflineLibraryStore.shared.allTracks().count
        }
    }

    private func clear() {
        do {
            try OfflineDownloadManager.shared.cancelAll()
            OfflinePlaybackController.shared.stop()
            try OfflineLibraryStore.shared.clearAll()
            OfflineDownloadPillHUD.shared.completeSuccess(
                title: "offline_library".localized, message: "offline_library_cleared".localized
            )
        } catch {
            OfflineDownloadPillHUD.shared.completeError(title: "offline_library".localized, errorMessage: error.localizedDescription)
        }
    }
}
