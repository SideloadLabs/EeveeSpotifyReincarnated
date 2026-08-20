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

            Section(footer: Text("disable_feelings_for_elsa_description".localized)) {
                Toggle(
                    "disable_feelings_for_elsa".localized,
                    isOn: $experimentsOptions.disableFeelingsForElsa
                )
                .onChange(of: experimentsOptions.disableFeelingsForElsa) { newValue in
                    if !newValue {
                        // User tried to turn it OFF — prank time!
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            experimentsOptions.disableFeelingsForElsa = true

                            let alert = UIAlertController(
                                title: "Error 404: Emotion Not Found",
                                message: "Nice try Hysan, but this patch cannot be uninstalled.",
                                preferredStyle: .alert
                            )
                            alert.addAction(UIAlertAction(title: "OK", style: .default))
                            WindowHelper.shared.present(alert)
                        }
                    }
                }
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
