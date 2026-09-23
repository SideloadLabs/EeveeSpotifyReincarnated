import Foundation

struct LyricsDto {
    var lines: [LyricsLineDto]
    var timeSynced: Bool
    var romanization: LyricsRomanizationStatus
    var translation: LyricsTranslationDto?
    /// Overrides the "provided by" label on Spotify's lyrics screen, for
    /// sources whose terms require naming the real provider and credits.
    var providerName: String? = nil
    
    func toSpotifyLyricsData(source: String) -> LyricsData {
        var lyricsData = LyricsData.with {
            $0.timeSynchronized = timeSynced
            $0.restriction = .unrestricted
            $0.providedBy = "\(source) (EeveeSpotify)"
        }
        
        let shouldRomanize = UserDefaults.lyricsOptions.romanization
        
        if lines.isEmpty {
            lyricsData.lines = [
                LyricsLine.with {
                    $0.content = "song_is_instrumental".localized
                },
                LyricsLine.with {
                    $0.content = "let_the_music_play".localized
                },
                LyricsLine.with {
                    $0.content = ""
                }
            ]
        }
        else {
            let sortedLines = lines.sorted { 
                ($0.offsetMs ?? 0) < ($1.offsetMs ?? 0)
            }
            let romanizing = shouldRomanize && romanization == .canBeRomanized
            let richSync = timeSynced && !romanizing && UserDefaults.nativeRichSync
            lyricsData.lines = sortedLines.map { line in
                LyricsLine.with {
                    $0.content = romanizing
                        ? line.content.applyingTransform(.toLatin, reverse: false)!
                        : line.content
                    $0.offsetMs = Int32(line.offsetMs ?? 0)
                    if richSync, let syllables = Self.nativeSyllables(for: line) {
                        $0.syllables = syllables
                        $0.endTimeMs = Int32(line.endMs ?? 0)
                    }
                }
            }
            lyricsData.richSynchronized = lyricsData.lines.contains { !$0.syllables.isEmpty }
        }
        
        if let translation = translation {
            lyricsData.translation = LyricsTranslation.with {
                $0.languageCode = translation.languageCode
                $0.lines = translation.lines
            }
        }
        
        return lyricsData
    }

    /// Spotify's native syllables don't carry text: each one claims the next
    /// `numChars` characters of the line. A syllable owns the space that
    /// follows it (none when IsPartOfWord glues it to the next one), so the
    /// counts add up to the whole line. Counted in UTF-16 units, like the
    /// NSRange-based UIKit text the lyrics view renders into. Returns nil
    /// when the syllables no longer spell the line exactly — e.g. after an
    /// uncensor fill rewrote a word — rather than highlight the wrong span.
    private static func nativeSyllables(for line: LyricsLineDto) -> [LyricsSyllable]? {
        guard let syllables = line.syllables, !syllables.isEmpty else { return nil }
        var spelled = ""
        var result = [LyricsSyllable]()
        for (index, syllable) in syllables.enumerated() {
            let separator = (index < syllables.count - 1 && !syllable.isPartOfWord) ? " " : ""
            spelled += syllable.text + separator
            result.append(LyricsSyllable.with {
                $0.startTimeMs = Int32(syllable.startMs)
                $0.numChars = Int32((syllable.text + separator).utf16.count)
            })
        }
        return spelled == line.content ? result : nil
    }
}
