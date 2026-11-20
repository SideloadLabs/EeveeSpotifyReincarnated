import SwiftUI

// AutoEq's headphones for the output playing now: all of them, or those matching the search, a chunk at a time
// as the list scrolls. picking one downloads its correction, keeps it for that output and turns the equalizer
// on; the page stays open to try another. "No correction" takes it off.
struct EqualizerHeadphonesView: View {
    let output: Equalizer.Output

    @State private var all = [AutoEq.Headphone]()
    @State private var query = ""
    @State private var found: [AutoEq.Headphone]?   // nil while the search is empty: the list is all of them
    @State private var shown = Self.chunk
    @State private var loading = true
    @State private var failure: String?
    @State private var downloading: String?
    @State private var current: HeadphoneCorrection?

    // rows added each time the list is scrolled to its end.
    private static let chunk = 100

    init(output: Equalizer.Output) {
        self.output = output
        _current = State(initialValue: UserDefaults.headphoneCorrections[output.id])
    }

    private static func count(_ number: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: number), number: .decimal)
    }

    var body: some View {
        let listed = found ?? all
        List {
            Section(header: Text(output.name), footer: Text("autoeq_credit".localized)) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                    TextField("autoeq_search".localized, text: $query)
                        .disableAutocorrection(true)
                        .autocapitalization(.none)
                }
                if let current {
                    Button(action: remove) {
                        SettingsLabel(title: "equalizer_no_correction".localized, subtitle: "autoeq_now".localizeWithFormat(current.headphone),
                                      icon: "xmark", color: .gray)
                    }
                }
            }

            if loading {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("autoeq_loading".localized).foregroundColor(.secondary)
                    }
                }
            } else if all.isEmpty {
                Section(footer: Text(failure ?? "")) {
                    Button("autoeq_retry".localized) { load(refresh: true) }
                }
            } else {
                Section(header: Text((found == nil ? "autoeq_all" : "autoeq_found").localizeWithFormat(Self.count(listed.count)))) {
                    if listed.isEmpty {
                        Text("autoeq_no_match".localized).foregroundColor(.secondary)
                    }
                    ForEach(listed.prefix(shown)) { headphone in
                        Button { pick(headphone) } label: { row(headphone) }
                            .disabled(downloading != nil)
                    }
                    if shown < listed.count {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .id(shown)
                            .onAppear { shown = min(listed.count, shown + Self.chunk) }
                    }
                }
            }

            SpacerView()
        }
        .eeveeSettingsStyle()
        .onAppear { if all.isEmpty { load(refresh: false) } }
        .onChange(of: query, perform: search)
    }

    private func row(_ headphone: AutoEq.Headphone) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(headphone.name).foregroundColor(.primary)
                Text(headphone.source).font(.footnote).foregroundColor(.secondary)
            }
            Spacer(minLength: 8)
            if downloading == headphone.path {
                ProgressView()
            } else if current?.path == headphone.path {
                Image(systemName: "checkmark").foregroundColor(EeveeTheme.accent)
            }
        }
        .contentShape(Rectangle())
    }

    private func load(refresh: Bool) {
        loading = true
        AutoEq.loadIndex(refresh: refresh) { headphones, why in
            all = headphones
            failure = why
            loading = false
            search(query)
        }
    }

    // off the main thread, so typing doesn't wait on 8,000 names; a search a later keystroke replaced is dropped.
    private func search(_ query: String) {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            if found != nil {
                found = nil
                shown = Self.chunk
            }
            return
        }
        let all = all
        DispatchQueue.global(qos: .userInitiated).async {
            let headphones = AutoEq.search(all, query)
            DispatchQueue.main.async {
                guard query == self.query else { return }
                found = headphones
                shown = Self.chunk
            }
        }
    }

    private func pick(_ headphone: AutoEq.Headphone) {
        downloading = headphone.path
        AutoEq.download(headphone) { result in
            downloading = nil
            switch result {
            case .success(let filters):
                let correction = HeadphoneCorrection(headphone: headphone.name, source: headphone.source, path: headphone.path,
                                                     filters: filters, output: output.name)
                Equalizer.setCorrection(correction, for: output)
                // picked to be heard.
                if !UserDefaults.equalizerOptions.enabled {
                    UserDefaults.equalizerOptions.enabled = true
                    Equalizer.apply()
                }
                current = correction
            case .failure(let error):
                let alert = UIAlertController(title: "autoeq_failed".localized, message: error.message, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK".uiKitLocalized, style: .default))
                ValuePrompt.present(alert)
            }
        }
    }

    private func remove() {
        Equalizer.setCorrection(nil, for: output)
        current = nil
    }
}
