import SwiftUI

extension EeveeLyricsSettingsView {
    private func lyricsSourceFooter() -> some View {
        var text = "lyrics_source_description".localized

        text.append("\n\n")
        text.append("spicylyrics_description".localized)

        text.append("\n\n")
        text.append("petitlyrics_description".localized)

        text.append("\n\n")
        text.append("lyrics_additional_info".localized)

        return Text(text)
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

                if viewModel.lyricsSource == .musixmatch {
                    musixmatchTokenField()
                }
                
                if viewModel.lyricsSource == .lrclib {
                    lrclibURLField()
                }
            }
        }
    }
    
    @ViewBuilder private func musixmatchTokenField() -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("musixmatch_user_token".localized)
            
            TextField("user_token_placeholder".localized, text: $viewModel.musixmatchToken)
                .foregroundColor(.gray)
        }
        .icon(
            "exclamationmark.circle",
            color: .red,
            when: Binding<Bool>(
                get: { !viewModel.isMusixmatchTokenValid },
                set: { _ in }
            )
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        
        Button {
            viewModel.requestAnonymousMusixmatchToken()
        } label: {
            if viewModel.isRequestingMusixmatchToken {
                HStack {
                    ProgressView()
                    Text("request_anonymous_token".localized)
                        .padding(.leading, 8)
                }
            } else {
                Text("request_anonymous_token".localized)
            }
        }
        .disabled(viewModel.isRequestingMusixmatchToken)
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
