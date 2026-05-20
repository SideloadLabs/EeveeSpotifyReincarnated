import Foundation

struct LyricsDto {
    var lines: [LyricsLineDto]
    var timeSynced: Bool
    var isSyllableSynced: Bool
    var romanization: LyricsRomanizationStatus
    var translation: LyricsTranslationDto?
    
    func toSpotifyLyricsData(source: String) -> LyricsResponse {
        var lyricsResponse = LyricsResponse()
        
        // 设置同步类型
        if isSyllableSynced {
            lyricsResponse.syncType = .syllableSynced
        } else if timeSynced {
            lyricsResponse.syncType = .lineSynced
        } else {
            lyricsResponse.syncType = .unsynced
        }
        
        lyricsResponse.provider = source
        lyricsResponse.providerDisplayName = "CharlesL"
        lyricsResponse.language = "en"
        
        let shouldRomanize = UserDefaults.lyricsOptions.romanization
        
        if lines.isEmpty {
            // 处理无歌词情况（纯音乐）
            lyricsResponse.lines = [
                LyricsLine.with {
                    $0.startTimeMs = 0
                    $0.words = "song_is_instrumental".localized
                },
                LyricsLine.with {
                    $0.startTimeMs = 3000
                    $0.words = "let_the_music_play".localized
                },
                LyricsLine.with {
                    $0.startTimeMs = 6000
                    $0.words = ""
                }
            ]
        } else {
            let sortedLines = lines.sorted { 
                ($0.startTimeMs ?? 0) < ($1.startTimeMs ?? 0)
            }
            
            lyricsResponse.lines = sortedLines.map { line in
                var lyricsLine = LyricsLine()
                
                // 设置歌词文本（应用罗马化）
                let words = (shouldRomanize && romanization == .canBeRomanized)
                    ? line.words.applyingTransform(.toLatin, reverse: false) ?? line.words
                    : line.words
                
                lyricsLine.words = words
                lyricsLine.startTimeMs = line.startTimeMs ?? 0
                
                // 设置音节（逐字歌词）
                if let syllables = line.syllables {
                    lyricsLine.syllables = syllables.map { syllableDto in
                        var syllable = Syllable()
                        syllable.startTimeMs = syllableDto.startTimeMs
                        syllable.numChars = syllableDto.numChars
                        return syllable
                    }
                }
                
                return lyricsLine
            }
        }
        
        // 设置翻译
        if let translation = translation {
            var alternative = AlternativeLanguages()
            alternative.language = translation.languageCode
            alternative.lines = translation.lines
            lyricsResponse.alternatives = [alternative]
        }
        
        return lyricsResponse
    }
}
