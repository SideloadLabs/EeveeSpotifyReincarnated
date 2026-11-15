import SwiftUI

extension EeveeLyricsSettingsView {
    private static let spicyTemplateURL = "https://developers.spicylyrics.org/catalog/eeveespotifyreincarnated"

    private func lyricsSourceFooterText() -> String {
        var text = "lyrics_source_description".localized

        text.append("\n\n")
        text.append("spicylyrics_description".localized)

        text.append("\n\n")
        text.append("petitlyrics_description".localized)

        text.append("\n\n")
        text.append("lyrics_additional_info".localized)

        return text
    }

    @ViewBuilder private func lyricsSourceFooter() -> some View {
        let text = lyricsSourceFooterText()

        if #available(iOS 15.0, *) {
            Text(spicyLinkedAttributedString(text))
        } else {
            Text(text)
        }
    }

    // The link text is localized together with spicylyrics_description, so find it by its own key.
    @available(iOS 15.0, *)
    private func spicyLinkedAttributedString(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)

        if let range = attributed.range(of: "spicylyrics_template_link".localized),
           let url = URL(string: Self.spicyTemplateURL) {
            attributed[range].link = url
        }

        return attributed
    }
    
    @ViewBuilder func lyricsSourceSection() -> some View {
        Section {
            Toggle(
                "do_not_replace_lyrics".localized,
                isOn: Binding<Bool>(
                    get: { viewModel.lyricsSource == .notReplaced },
                    set: {
                        viewModel.lyricsSource = $0
                            ? .notReplaced
                            : LyricsSource.defaultSource
                    }
                )
            )
        } footer: {
            Text("restart_is_required_description".localized)
        }
        
        if viewModel.lyricsSource.isReplacingLyrics {
            Section(footer: lyricsSourceFooter()) {
                Picker(
                    "lyrics_source".localized,
                    selection: $viewModel.lyricsSource
                ) {
                    ForEach(LyricsSource.allCases, id: \.self) { lyricsSource in
                        Text(lyricsSource.description).tag(lyricsSource)
                    }
                }

                if viewModel.lyricsSource == .spicylyrics {
                    spicyLyricsApiKeyField()
                }
                
                if viewModel.lyricsSource == .lrclib {
                    lrclibURLField()
                }
            }
        }
    }
    
    @ViewBuilder private func spicyLyricsApiKeyField() -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("spicylyrics_api_key".localized)

            TextField("spicylyrics_api_key_placeholder".localized, text: $spicyLyricsApiKey)
                .foregroundColor(.gray)
                .autocapitalization(.none)
                .disableAutocorrection(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func lrclibURLField() -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("lrclib_api".localized)
            
            TextField(LrclibLyricsRepository.originalApiUrl, text: $viewModel.lyricsOptions.lrclibUrl)
                .foregroundColor(.gray)
        }
        .icon(
            "exclamationmark.circle",
            color: .red,
            when: Binding<Bool>(
                get: {
                    viewModel.lrclibURLState == .invalidURL
                    || viewModel.lrclibURLState == .unreachableURL
                },
                set: { _ in }
            )
        )
        .icon(
            "checkmark.seal",
            color: .green,
            when: Binding<Bool>(
                get: { viewModel.lrclibURLState == .originalURL },
                set: { _ in }
            )
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
