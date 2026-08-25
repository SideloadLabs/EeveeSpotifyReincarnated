import SwiftUI
import UIKit

struct EeveeExperimentsSettingsView: View {
    @State var experimentsOptions = UserDefaults.experimentsOptions

    var body: some View {
        List {
            Section(footer: Text("livecontainer_sharing_description".localized)) {
                Toggle(
                    "livecontainer_sharing".localized,
                    isOn: $experimentsOptions.liveContainerSharing
                )
            }
            
            Section(
                footer: Text("show_instagram_destination_description"
                    .localizeWithFormat("restart_is_required_description".localized))
            ) {
                Toggle(
                    "show_instagram_destination".localized,
                    isOn: $experimentsOptions.showInstagramDestination
                )
            }

        }
        .onChange(of: experimentsOptions) { options in
            UserDefaults.experimentsOptions = options
            
            if options.showInstagramDestination {
                OfflineHelper.resetData()
            }
        }
        
        .listStyle(GroupedListStyle())
        .animation(.default, value: experimentsOptions)
    }
}
