import SwiftUI
import UIKit

struct EeveePatchingSettingsView: View {
    @State var patchType = UserDefaults.patchType
    @State var overwriteConfiguration = UserDefaults.overwriteConfiguration
    @State var trueShuffleEnabled = UserDefaults.trueShuffleEnabled

    var body: some View {
        List {
            Section(
                footer: patchType == .disabled
                    ? nil
                    : Text(
                        "patching_description"
                            .localizeWithFormat("restart_is_required_description".localized)
                    )
            ) {
                Toggle(
                    "do_not_patch_premium".localized,
                    isOn: Binding<Bool>(
                        get: { patchType == .disabled },
                        set: { patchType = $0 ? .disabled : .requests }
                    )
                )
            }
            
            .onChange(of: patchType) { newPatchType in
                UserDefaults.patchType = newPatchType
                OfflineHelper.resetData()
            }
            
            .onChange(of: overwriteConfiguration) { overwriteConfiguration in
                UserDefaults.overwriteConfiguration = overwriteConfiguration
                OfflineHelper.resetData()
            }

            .onChange(of: trueShuffleEnabled) { isEnabled in
                UserDefaults.trueShuffleEnabled = isEnabled
            }

            if patchType == .requests {
                Section(
                    footer: Text("overwrite_configuration_description".localized)
                ) {
                    Toggle(
                        "overwrite_configuration".localized,
                        isOn: $overwriteConfiguration
                    )
                }

                Section(
                    footer: Text(
                        "Blocks Spotify's free-tier Smart Shuffle from mixing recommended tracks into your queue. Shuffle stays inside the playlist. "
                        + "restart_is_required_description".localized
                    )
                ) {
                    Toggle("True Shuffle", isOn: $trueShuffleEnabled)
                }
            }

            NonIPadSpacerView()
        }
        .listStyle(GroupedListStyle())
        .animation(.default, value: patchType)
    }
}
