import Foundation

extension KaraokeLyricsDto {
    /// Builds custom-lyrics-view data from any source that only has line-level timing
    /// (LRCLIB, PetitLyrics, ...). Every word of a line lights up together
    /// when the line starts, the same way SpicyLyrics' line-synced songs already behave.
    ///
    /// Word-synced sources should build a `KaraokeLyricsDto` with real syllable timing
    /// themselves and publish it to `KaraokeLyricsStore`, like `SpicyLyricsRepository` does.
    static func lineSynced(from dto: LyricsDto, providerName: String?) -> KaraokeLyricsDto? {
        guard dto.timeSynced else { return nil }

        let romanize = UserDefaults.lyricsOptions.romanization && dto.romanization == .canBeRomanized
        let timed = dto.lines
            .compactMap { line -> (text: String, startMs: Int)? in
                guard let offset = line.offsetMs else { return nil }
                return (line.content.trimmingCharacters(in: .whitespacesAndNewlines), offset)
            }
            .sorted { $0.startMs < $1.startMs }

        var lines = [KaraokeLineDto]()
        for (index, entry) in timed.enumerated() {
            // Some sources end the song with an empty line that only marks when the last lyric stops.
            guard !entry.text.isEmpty else { continue }

            let text = romanize ? (entry.text.applyingTransform(.toLatin, reverse: false) ?? entry.text) : entry.text
            let words = text.split(whereSeparator: { $0.isWhitespace })
            guard !words.isEmpty else { continue }

            let nextStartMs = timed[(index + 1)...].first { $0.startMs > entry.startMs }?.startMs
            lines.append(KaraokeLineDto(
                syllables: words.map {
                    KaraokeSyllableDto(text: String($0), startMs: entry.startMs, endMs: entry.startMs, isPartOfWord: false)
                },
                startMs: entry.startMs,
                endMs: nextStartMs ?? entry.startMs + 4000
            ))
        }

        guard !lines.isEmpty else { return nil }
        return KaraokeLyricsDto(lines: lines, songWriters: [], providerCode: nil, providerName: providerName)
    }
}
