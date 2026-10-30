import SwiftUI
import UIKit

struct FlagBrowserView: View {
    @State private var catalog: [FlagInfo] = []
    @State private var loaded = false
    @State private var overrides = RemoteFlags.overrides
    @State private var query = ""
    @State private var changedOnly = false

    private let forced = RemoteFlags.shared.forced

    private var visible: [FlagInfo] {
        catalog.filter { flag in
            (!changedOnly || overrides[flag.key] != nil || forced[flag.key] != nil)
                && (query.isEmpty || flag.key.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        List {
            Section(footer: Text("flags_count".localizeWithFormat(catalog.count, RemoteFlags.shared.spotifyVersion))) {
                TextField("flags_search".localized, text: $query)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                Toggle("flags_changed_only".localized, isOn: $changedOnly)
            }

            actions

            if loaded && catalog.isEmpty {
                Text("flags_empty".localized).foregroundColor(.secondary)
            }

            Section {
                ForEach(visible) { flag in
                    FlagRow(flag: flag, override: overrides[flag.key], forced: forced[flag.key]) {
                        set(flag.key, $0)
                    }
                }
            }

            SpacerView()
        }
        .eeveeSettingsStyle()
        .onAppear(perform: load)
    }

    private var actions: some View {
        Section {
            if RemoteFlags.needsRestart {
                Button("flags_restart".localized, action: exitApplication)
                    .foregroundColor(EeveeTheme.accent)
            }
            if !overrides.isEmpty {
                Button("flags_reset".localized) {
                    overrides = [:]
                    RemoteFlags.overrides = [:]
                }
                .foregroundColor(.red)
            }
            Button("flags_rescan".localized) {
                RemoteFlags.requestCapture()
                exitApplication()
            }

            Button("Export flags.json") {
                exportCatalog()
            }
        }
    }

    private func exportCatalog() {
        let source = RemoteFlags.shared.catalogFileURL
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("Spotify-Flags-\(RemoteFlags.shared.spotifyVersion).json")

        guard FileManager.default.fileExists(atPath: source.path) else {
            showExportError("The flag catalog does not exist yet. Try rescanning first.")
            return
        }

        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)

            let share = UIActivityViewController(
                activityItems: [destination],
                applicationActivities: nil
            )
            WindowHelper.shared.present(share)
        } catch {
            showExportError(error.localizedDescription)
        }
    }

    private func showExportError(_ message: String) {
        let alert = UIAlertController(
            title: "Export failed",
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        WindowHelper.shared.present(alert)
    }

    private func load() {
        guard !loaded else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let start = CFAbsoluteTimeGetCurrent()
            let flags = RemoteFlags.shared.loadCatalog()
            eeveeLog("[EeveeSpotify][Flags] Browser loaded %d flags in %.1f ms", flags.count, (CFAbsoluteTimeGetCurrent() - start) * 1000)
            DispatchQueue.main.async {
                catalog = flags
                loaded = true
            }
        }
    }

    private func set(_ key: String, _ value: Any?) {
        overrides[key] = value
        RemoteFlags.overrides = overrides
        eeveeLog("[EeveeSpotify][Flags] %@ = %@", key, value.map { "\($0)" } ?? "auto")
    }
}

private struct FlagRow: View {
    let flag: FlagInfo
    let override: Any?
    let forced: Any?
    let onSet: (Any?) -> Void

    var body: some View {
        if forced != nil {
            row
        } else {
            switch flag.kind {
            case .bool:
                picker([("flags_on".localized, true), ("flags_off".localized, false)])
            case .choice:
                picker((flag.options ?? []).map { ($0, $0) })
            case .int:
                Button(action: editInt) { row }
            }
        }
    }

    private var row: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(flag.property)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                Text(flag.component)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let forced {
                Label(display(forced), systemImage: "lock.fill")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else {
                valueLabel
            }
        }
        .contentShape(Rectangle())
    }

    private func picker(_ options: [(String, AnyHashable)]) -> some View {
        let current = override.map { display($0) }
        return Menu {
            Button("flags_auto".localized) { onSet(nil) }
            ForEach(options, id: \.0) { option in
                Button {
                    onSet(option.1)
                } label: {
                    if current == display(option.1) {
                        Label(option.0, systemImage: "checkmark")
                    } else {
                        Text(option.0)
                    }
                }
            }
        } label: {
            row
        }
    }

    private var valueLabel: some View {
        Text(display(override ?? flag.value))
            .font(.footnote.weight(override == nil ? .regular : .semibold))
            .foregroundColor(override == nil ? .secondary : EeveeTheme.accent)
            .lineLimit(1)
    }

    private func display(_ value: Any) -> String {
        if flag.kind == .bool {
            let on = (value as? Bool) ?? (value as? String == "true")
            return (on ? "flags_on" : "flags_off").localized
        }
        return "\(value)"
    }

    private func editInt() {
        let alert = UIAlertController(
            title: String(flag.property),
            message: "\(flag.lower ?? Int.min) – \(flag.upper ?? Int.max)",
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.keyboardType = .numbersAndPunctuation
            field.text = "\(override ?? flag.value)"
        }
        alert.addAction(UIAlertAction(title: "flags_auto".localized, style: .default) { _ in onSet(nil) })
        alert.addAction(UIAlertAction(title: "Cancel".uiKitLocalized, style: .cancel))
        alert.addAction(UIAlertAction(title: "OK".uiKitLocalized, style: .default) { [weak alert] _ in
            guard let text = alert?.textFields?.first?.text, let number = Int(text) else { return }
            onSet(min(max(number, flag.lower ?? .min), flag.upper ?? .max))
        })
        WindowHelper.shared.present(alert)
    }
}
