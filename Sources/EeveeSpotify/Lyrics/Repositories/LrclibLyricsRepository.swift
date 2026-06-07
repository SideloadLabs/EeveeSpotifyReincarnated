import Foundation

class LrclibLyricsRepository: LyricsRepository {
    var apiUrl: String
    private let session: URLSession

    private init(apiUrl: String) {
        self.apiUrl = apiUrl
        
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = [
            "User-Agent": "EeveeSpotify v\(EeveeSpotify.version) https://github.com/whoeevee/EeveeSpotify"
        ]
        
        session = URLSession(configuration: configuration)
    }
    
    static let originalApiUrl = "https://charlesl.qzz.io/api"
    
    static let shared = LrclibLyricsRepository(
        apiUrl: UserDefaults.lyricsOptions.lrclibUrl
    )
    
    private func perform(
        _ path: String, 
        query: [String:Any] = [:]
    ) throws -> Data {
        var stringUrl = "\(apiUrl)\(path)"

        if !query.isEmpty {
            let queryString = query.queryString
            stringUrl += "?\(queryString)"
        }
        
        let request = URLRequest(url: URL(string: stringUrl)!)

        let semaphore = DispatchSemaphore(value: 0)
        var data: Data?
        var error: Error?

        let task = session.dataTask(with: request) { response, _, err in
            error = err
            data = response
            semaphore.signal()
        }

        task.resume()
        semaphore.wait()

        if let error = error {
            throw error
        }

        return data!
    }
    
    private func getSong(trackName: String, artistName: String) throws -> LrclibSong {
        let data: Data = try perform("/get", query: [
            "track_name": trackName,
            "artist_name": artistName
        ])
        return try JSONDecoder().decode(LrclibSong.self, from: data)
    }
    
    // 解析 LRC 格式歌词
    private func parseLrcLyrics(_ lrcContent: String) -> [LyricsLineDto] {
        var lines: [LyricsLineDto] = []
        let pattern = "\\[(\\d+):(\\d+)\\.(\\d+)\\](.*)"
        
        do {
            let regex = try NSRegularExpression(pattern: pattern)
            let nsString = lrcContent as NSString
            let matches = regex.matches(in: lrcContent, range: NSRange(location: 0, length: nsString.length))
            
            for match in matches {
                let minuteRange = match.range(at: 1)
                let secondRange = match.range(at: 2)
                let millisecondRange = match.range(at: 3)
                let textRange = match.range(at: 4)
                
                let minute = Int(nsString.substring(with: minuteRange)) ?? 0
                let second = Int(nsString.substring(with: secondRange)) ?? 0
                let millisecond = Int(nsString.substring(with: millisecondRange)) ?? 0
                let text = nsString.substring(with: textRange)
                
                let totalMs = (minute * 60 + second) * 1000 + millisecond * 10
                
                lines.append(LyricsLineDto(
                    words: text,
                    startTimeMs: Int64(totalMs),
                    syllables: nil
                ))
            }
            
            // 按时间排序
            lines.sort { ($0.startTimeMs ?? 0) < ($1.startTimeMs ?? 0) }
            
        } catch {
        }
        
        return lines
    }
    
    // 解析逐字歌词 (YRC格式)
    private func parseYrcLyrics(_ yrcContent: String) -> [LyricsLineDto] {
        var lines: [LyricsLineDto] = []
        
        // 按行分割
        let lineStrings = yrcContent.components(separatedBy: "\n")
        
        for lineString in lineStrings {
            // 匹配整行时间戳格式: [start,duration]后面跟着内容
            let linePattern = #"\[(\d+),(\d+)\](.*)"#
            
            do {
                let regex = try NSRegularExpression(pattern: linePattern)
                let nsString = lineString as NSString
                let matches = regex.matches(in: lineString, range: NSRange(location: 0, length: nsString.length))
                
                guard let match = matches.first else { continue }
                
                let lineStartMsRange = match.range(at: 1)
                let lineContentRange = match.range(at: 3)
                
                let lineStartMs = Int(nsString.substring(with: lineStartMsRange)) ?? 0
                let lineContent = nsString.substring(with: lineContentRange)
                
                var syllables: [SyllableDto] = []
                var fullLineText = ""
                
                // 匹配 "单词 (start,duration)" 模式，处理被额外括号包围的情况
                let wordPattern = #"(?:\(*([^\(\)]+?)\)*)?\((\d+),(\d+)\)"#
                
                do {
                    let wordRegex = try NSRegularExpression(pattern: wordPattern)
                    let wordMatches = wordRegex.matches(in: lineContent, range: NSRange(location: 0, length: lineContent.count))
                    let nsLineContent = lineContent as NSString
                    
                    for wordMatch in wordMatches {
                        let wordTextRange = wordMatch.range(at: 1)
                        let wordStartMsRange = wordMatch.range(at: 2)
                        
                        let wordStartMs = Int64(nsLineContent.substring(with: wordStartMsRange)) ?? 0
                        
                        // 如果找到单词文本
                        if wordTextRange.location != NSNotFound {
                            var wordText = nsLineContent.substring(with: wordTextRange)
                            
                            // 检查是否是特殊格式：((时间戳)单词)
                            // 如果是，则添加括号使其显示为(单词)
                            let specialPattern = #"\(\((\d+),(\d+)\)([^\(\)]+)\)"#
                            let specialRegex = try NSRegularExpression(pattern: specialPattern)
                            let specialMatches = specialRegex.matches(in: lineContent, range: NSRange(location: 0, length: lineContent.count))
                            
                            if !specialMatches.isEmpty {
                                // 找到特殊格式，提取单词并添加括号
                                for specialMatch in specialMatches {
                                    let specialWordRange = specialMatch.range(at: 3)
                                    let specialWord = nsLineContent.substring(with: specialWordRange)
                                    wordText = "(\(specialWord))"
                                    break // 只处理第一个匹配的特殊格式
                                }
                            }
                            
                            fullLineText += wordText
                            
                            let syllable = SyllableDto(
                                startTimeMs: wordStartMs,
                                numChars: Int64(wordText.count)
                            )
                            syllables.append(syllable)
                        }
                    }
                } catch {
                    continue
                }
                
                let lineDto = LyricsLineDto(
                    words: fullLineText,
                    startTimeMs: Int64(lineStartMs),
                    syllables: syllables.isEmpty ? nil : syllables
                )
                lines.append(lineDto)
            } catch {
                continue
            }
        }
        
        // 按时间排序
        lines.sort { ($0.startTimeMs ?? 0) < ($1.startTimeMs ?? 0) }
        
        return lines
    }
        
    // 解析纯文本歌词
    private func parsePlainLyrics(_ plainLyrics: String) -> [LyricsLineDto] {
        return plainLyrics
            .components(separatedBy: "\n")
            .map { LyricsLineDto(words: $0, startTimeMs: nil, syllables: nil) }
    }
    
    // 对齐翻译歌词和原歌词
    private func alignTranslations(originalLines: [LyricsLineDto], translationLines: [LyricsLineDto]) -> [String] {
        var alignedTranslations: [String] = Array(repeating: "", count: originalLines.count)
        
        for translation in translationLines {
            // 找到时间戳最接近的原歌词行
            var closestIndex = -1
            var minTimeDiff = Int.max
            
            for (index, originalLine) in originalLines.enumerated() {
                guard let originalStartTimeMs = originalLine.startTimeMs,
                      let translationStartTimeMs = translation.startTimeMs else { continue }
                
                let timeDiff = abs(Int(originalStartTimeMs) - Int(translationStartTimeMs))
                if timeDiff < minTimeDiff {
                    minTimeDiff = timeDiff
                    closestIndex = index
                }
            }
            
            if closestIndex >= 0 && closestIndex < alignedTranslations.count {
                alignedTranslations[closestIndex] = translation.words
            }
        }
        
        return alignedTranslations
    }

    func getLyrics(_ query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        let song: LrclibSong

        do {
            song = try getSong(trackName: query.title, artistName: query.primaryArtist)
        } catch {
            let strippedTitle = query.title.strippedTrackTitle
            do {
                song = try getSong(trackName: strippedTitle, artistName: query.primaryArtist)
            } catch {
                throw LyricsError.noSuchSong
            }
        }

        if song.instrumental {
            return LyricsDto(
                lines: [], 
                timeSynced: false, 
                isSyllableSynced: false,
                romanization: .original,
                translation: nil
            )
        }

        var lyricsLines: [LyricsLineDto] = []
        var timeSynced = false
        var isSyllableSynced = false
        var translation: LyricsTranslationDto? = nil
        
        // 优先使用逐字歌词 (yrcLyrics)
        if let yrcLyrics = song.yrcLyrics, !yrcLyrics.isEmpty {
            lyricsLines = parseYrcLyrics(yrcLyrics)
            timeSynced = true
            isSyllableSynced = true
        }
        // 其次使用时间轴歌词 (syncedLyrics)
        else if let syncedLyrics = song.syncedLyrics, !syncedLyrics.isEmpty {
            lyricsLines = parseLrcLyrics(syncedLyrics)
            timeSynced = true
        }
        // 最后使用纯文本歌词 (plainLyrics)
        else if let plainLyrics = song.plainLyrics, !plainLyrics.isEmpty {
            lyricsLines = parsePlainLyrics(plainLyrics)
            timeSynced = false
        }
        
        // 处理翻译歌词 - 使用对齐方法
        if let translatedLyrics = song.translatedLyrics, !translatedLyrics.isEmpty {
            // 解析翻译歌词
            let translationLines = parseLrcLyrics(translatedLyrics)
            
            // 使用时间戳对齐翻译和原歌词
            let alignedTranslations = alignTranslations(
                originalLines: lyricsLines,
                translationLines: translationLines
            )
            
            translation = LyricsTranslationDto(
                languageCode: "zh",
                lines: alignedTranslations
            )
        }
        
        // 处理罗马化歌词
        var romanization = LyricsRomanizationStatus.original
        
        // 简单判断：如果有中文歌词，则认为可以罗马化
        let hasChinese = lyricsLines.contains { line in
            line.words.range(of: "[\\u4e00-\\u9fff]", options: .regularExpression) != nil
        }
        romanization = hasChinese ? .canBeRomanized : .original
        
        return LyricsDto(
            lines: lyricsLines,
            timeSynced: timeSynced,
            isSyllableSynced: isSyllableSynced,
            romanization: romanization,
            translation: translation
        )
    }
}