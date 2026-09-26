import SwiftUI
import UIKit

struct EeveeMiscellaneousSettingsView: View {
    var body: some View {
        List {
            Section(footer: Text("clean_share_links_description".localized)) {
                Toggle(
                    "clean_share_links".localized,
                    isOn: Binding<Bool>(
                        get: { UserDefaults.cleanShareLinks },
                        set: { UserDefaults.cleanShareLinks = $0 }
                    )
                )
            }

            if #available(iOS 26.0, *) {
                Section(footer: Text("Shows the playing track's Spotify Canvas as a looping video behind the lock screen controls, the way Apple Music plays an animated cover. Only tracks with a Canvas are affected.")) {
                    Toggle(
                        "Animated lock screen artwork",
                        isOn: Binding<Bool>(
                            get: { UserDefaults.animatedLockScreenArtwork },
                            set: { UserDefaults.animatedLockScreenArtwork = $0 }
                        )
                    )
                }
            }
        }
        .listStyle(GroupedListStyle())
    }
}
