import SwiftUI
import Combine

extension EeveeLyricsSettingsViewModel {
    func setupBindings() {
        $lyricsOptions
            .map(\.lrclibUrl)
            .map { urlString -> AnyPublisher<LrclibURLState, Never> in
                guard let url = URL(string: urlString) else {
                    return Just(.invalidURL).eraseToAnyPublisher()
                }
                
                if url.host == "lrclib.net" {
                    return Just(.originalURL).eraseToAnyPublisher()
                }
                
                return URLSession.shared.dataTaskPublisher(for: url)
                    .map { _ in
                        LrclibLyricsRepository.shared.apiUrl = urlString
                        return LrclibURLState.ok
                    }
                    .catch { _ in Just(LrclibURLState.unreachableURL) }
                    .eraseToAnyPublisher()
            }
            .switchToLatest()
            .receive(on: DispatchQueue.main)
            .assign(to: &$lrclibURLState)

        // Saved lyrics belong to the options they were fetched with.
        $lyricsOptions
            .map(\.downloadOptions)
            .removeDuplicates()
            .dropFirst()
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { _ in
                LyricsNotFoundStore.shared.resetForLookupOptionsChange()
                NativeOfflineLyrics.shared.reconcileAll()
                EeveeOfflineLyricsDownloader.shared.refreshForCurrentSource(userInitiated: true)
            }
            .store(in: &cancellables)

        $lyricsSource
            .dropFirst()
            .sink { [weak self] newSource in
                guard let self = self else { return }
                
                if newSource == .lrclib {
                    self.lyricsOptions.lrclibUrl = LrclibLyricsRepository.originalApiUrl
                }
                
                UserDefaults.lyricsSource = newSource

                // Everything cached for the old provider (prefetch, custom lyrics
                // view data) must go, or revisiting a song
                // would keep serving the old provider's lyrics.
                invalidateLyricsForSourceChange()

                // Queue the new provider's text for every saved track; offline the
                // old provider's text stays visible until each one is replaced.
                NativeOfflineLyrics.shared.reconcileAll()
                EeveeOfflineLyricsDownloader.shared.refreshForCurrentSource(userInitiated: true)

                // Spotify keeps its own copy of lyrics it already loaded, which the tweak
                // can't clear, so the new source is only used everywhere after a restart.
                if newSource != LyricsLaunchSource.value {
                    PopUpHelper.showPopUp(
                        message: "lyrics_source_restart_popup".localized,
                        buttonText: "restart_now".localized,
                        secondButtonText: "restart_later".localized,
                        onPrimaryClick: { exitApplication() }
                    )
                }
            }
            .store(in: &cancellables)
    }
}
