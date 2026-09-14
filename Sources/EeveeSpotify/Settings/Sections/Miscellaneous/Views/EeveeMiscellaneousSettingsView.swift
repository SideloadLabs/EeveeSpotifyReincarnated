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

            Section(footer: Text("hide_jam_from_menu_description".localized)) {
                Toggle(
                    "hide_jam_from_menu".localized,
                    isOn: Binding<Bool>(
                        get: { UserDefaults.hideJamFromMenu },
                        set: { UserDefaults.hideJamFromMenu = $0 }
                    )
                )
            }

            Section(footer: Text("block_rating_dialogs_description".localized)) {
                Toggle(
                    "block_rating_dialogs".localized,
                    isOn: Binding<Bool>(
                        get: { UserDefaults.blockRatingDialogs },
                        set: { UserDefaults.blockRatingDialogs = $0 }
                    )
                )
            }
        }
        .listStyle(GroupedListStyle())
    }
}
