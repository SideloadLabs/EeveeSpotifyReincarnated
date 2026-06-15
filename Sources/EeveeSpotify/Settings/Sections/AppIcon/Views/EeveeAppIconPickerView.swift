import SwiftUI
import UIKit

private let primaryIconKey = "__primary__"
private let selectedKeyDefault = "EeveeSelectedAppIconName"

private struct AppIconEntry: Identifiable, Hashable {
    let id: String
    let title: String
    let alternateName: String?
    let iconFiles: [String]
}

struct EeveeAppIconPickerView: View {
    @State private var icons: [AppIconEntry] = []
    @State private var selectedKey: String = primaryIconKey
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section(
                header: Text("appIconTitle".localized),
                footer: Text("appIconSubtitle".localized)
            ) {
                ForEach(icons) { icon in
                    Button { apply(icon) } label: { row(icon) }
                        .buttonStyle(PlainButtonStyle())
                }
            }
            
            SpacerView()
        }
        .listStyle(InsetGroupedListStyle())
        .onAppear(perform: load)
        .alert(item: Binding<AlertWrapper?>(
            get: { errorMessage.map(AlertWrapper.init) },
            set: { errorMessage = $0?.message }
        )) { wrapped in
            Alert(title: Text("App Icon"),
                  message: Text(wrapped.message),
                  dismissButton: .default(Text("OK".uiKitLocalized)))
        }
    }

    private func row(_ icon: AppIconEntry) -> some View {
        HStack(spacing: 14) {
            preview(icon)
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(icon.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.primary)
                Text(icon.id == selectedKey ? "iconSelected".localized : "iconTapToApply".localized)
                    .font(.system(size: 13))
                    .foregroundColor(icon.id == selectedKey
                                     ? EeveeSettingsView.spotifyAccentColor
                                     : .secondary)
            }
            Spacer()
            if icon.id == selectedKey {
                Image(systemName: "checkmark")
                    .foregroundColor(EeveeSettingsView.spotifyAccentColor)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func preview(_ icon: AppIconEntry) -> some View {
        if let image = Self.image(for: icon) {
            Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color(white: 0.18))
                Image(systemName: "app.fill").foregroundColor(.secondary)
            }
        }
    }

    private func load() {
        let bundleIcons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any]
        let primary = bundleIcons?["CFBundlePrimaryIcon"] as? [String: Any]
        let primaryFiles = primary?["CFBundleIconFiles"] as? [String] ?? ["AppIcon60x60"]

        var entries: [AppIconEntry] = [
            AppIconEntry(id: primaryIconKey,
                         title: "Default",
                         alternateName: nil,
                         iconFiles: primaryFiles)
        ]
        let alternates = bundleIcons?["CFBundleAlternateIcons"] as? [String: Any] ?? [:]
        for key in alternates.keys.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }) {
            let info = alternates[key] as? [String: Any]
            let files = info?["CFBundleIconFiles"] as? [String] ?? [key]
            entries.append(AppIconEntry(id: key, title: key, alternateName: key, iconFiles: files))
        }
        icons = entries
        selectedKey = currentSelectedKey()
    }

    // iOS's alternateIconName getter returns nil on resigned bundles even after a successful set — trust our pref.
    private func currentSelectedKey() -> String {
        if let saved = UserDefaults.standard.string(forKey: selectedKeyDefault), !saved.isEmpty {
            return saved
        }
        if let current = UIApplication.shared.alternateIconName, !current.isEmpty {
            return current
        }
        return primaryIconKey
    }

    private func apply(_ icon: AppIconEntry) {
        guard UIApplication.shared.supportsAlternateIcons else {
            errorMessage = "Alternate icons are not supported on this device."
            return
        }
        let previous = selectedKey
        selectedKey = icon.id
        UserDefaults.standard.set(icon.id, forKey: selectedKeyDefault)

        UIApplication.shared.setAlternateIconName(icon.alternateName) { error in
            DispatchQueue.main.async {
                guard let error = error else { return }
                NSLog("[EeveeSpotify][AppIcon] setAlternateIconName(%@) failed: %@",
                      icon.alternateName ?? "nil", error.localizedDescription)
                selectedKey = previous
                UserDefaults.standard.set(previous, forKey: selectedKeyDefault)
                errorMessage = error.localizedDescription
            }
        }
    }

    private static func image(for icon: AppIconEntry) -> UIImage? {
        let scale = Int(UIScreen.main.scale)
        let stems = icon.iconFiles + [icon.alternateName].compactMap { $0 }
        let bundlePath = Bundle.main.bundlePath as NSString

        for stem in stems {
            let candidates = [
                "\(stem)@\(scale)x.png",
                "\(stem)@3x.png",
                "\(stem)@2x.png",
                "\(stem).png"
            ]
            for c in candidates {
                let path = bundlePath.appendingPathComponent(c)
                if FileManager.default.fileExists(atPath: path),
                   let img = UIImage(contentsOfFile: path) {
                    return img
                }
            }
        }
        return nil
    }
}

private struct AlertWrapper: Identifiable {
    let message: String
    var id: String { message }
}
