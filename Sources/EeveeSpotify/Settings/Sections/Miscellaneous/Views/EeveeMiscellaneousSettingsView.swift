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
        }
        .listStyle(GroupedListStyle())
    }
}
