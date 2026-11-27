import SwiftUI

/// Keeps the open custom lyrics view in step with the playing track. When a song ends and the
/// next one starts, it swaps in that song's lyrics (fetching them if Spotify hasn't), and gives up
/// — closing the view — only if none turn up.
@available(iOS 15.0, *)
final class KaraokeLyricsViewModel: ObservableObject {
    @Published private(set) var trackId: String?
    @Published private(set) var lyrics: KaraokeLyricsDto?
    @Published private(set) var layouts: [KaraokeLineLayout] = []

    private let onNoLyrics: () -> Void
    private var observer: NSObjectProtocol?
    private var retryWork: DispatchWorkItem?
    private var attempts = 0

    private let maxAttempts = 4
    private let retryInterval: TimeInterval = 2.0

    init(trackId: String?, lyrics: KaraokeLyricsDto, onNoLyrics: @escaping () -> Void) {
        self.trackId = trackId
        self.onNoLyrics = onNoLyrics
        apply(lyrics)
        observer = NotificationCenter.default.addObserver(
            forName: .eeveeKaraokeLyricsChanged, object: nil, queue: .main
        ) { [weak self] _ in self?.sync() }
    }

    deinit {
        retryWork?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func apply(_ lyrics: KaraokeLyricsDto?) {
        self.lyrics = lyrics
        let songIsRTL = lyrics?.isRTL ?? false
        layouts = lyrics?.lines.map { line in
            let direction = line.strongDirection
            return KaraokeLineLayout(words: line.words, isRTL: direction.map { $0 == .rightToLeft } ?? songIsRTL)
        } ?? []
    }

    private func sync() {
        guard let playing = KaraokePlaybackTracker.shared.currentTrackId() else { return }

        let stored = KaraokeLyricsStore.shared.lyrics(forTrackId: playing)
        if playing != trackId {
            retryWork?.cancel()
            retryWork = nil
            attempts = 0
            trackId = playing
            apply(stored)
        } else if lyrics == nil, let stored {
            apply(stored)
        }

        if lyrics == nil {
            fetchMissingLyrics()
        } else {
            retryWork?.cancel()
            retryWork = nil
        }
    }

    private func fetchMissingLyrics() {
        guard retryWork == nil, let trackId else { return }
        guard attempts < maxAttempts else {
            writeDebugLog("[Karaoke] no lyrics for \(trackId) after \(attempts) attempts, closing custom lyrics view")
            onNoLyrics()
            return
        }
        attempts += 1
        writeDebugLog("[Karaoke] track changed to \(trackId) with the custom lyrics view open, fetching lyrics (attempt \(attempts))")
        prefetchLyricsIfNeeded(trackId: trackId)

        let work = DispatchWorkItem { [weak self] in
            self?.retryWork = nil
            self?.sync()
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + retryInterval, execute: work)
    }
}
