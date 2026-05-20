import Foundation

class LrclibLyricsRepository: LyricsRepository {
    var apiUrl: String
    private let session: URLSession

    // MARK: - 1. 静态预编译正则表达式 (性能优化的关键)
    // 将正则提升为静态常量，确保整个生命周期只编译一次，避免在循环中重复编译造成的巨大开销
    private static let lrcLineRegex = try? NSRegularExpression(pattern: "\\[(\\d+):(\\d+)\\.(\\d+)\\](.*)")
    private static let yrcLineRegex = try? NSRegularExpression(pattern: #"\\[(\d+),(\d+)\](.*)"#)
    
    // 普通 YRC 格式: text(100,200) 或 (text)(100,200)
    private static let yrcWordRegex = try? NSRegularExpression(pattern: #"(?:\(*([^\(\)]+?)\)*)?\((\d+),(\d+)\)"#)
    
    // 特殊 YRC 格式: ((100,200)text) - 通常用于和声或特殊标注
    private static let yrcSpecialRegex = try? NSRegularExpression(pattern: #"\(\((\d+),(\d+)\)([^\(\)]+)\)"#)

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
        
        guard let url = URL(string: stringUrl) else {
            throw LyricsError.noSuchSong // 简单的 URL 错误处理
        }
        
        let request = URLRequest(url: url)

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
        
        guard let resultData = data else {
            throw LyricsError.noSuchSong
        }

        return resultData
    }
    
    private func getSong(trackName: String, artistName: String) throws -> LrclibSong {
        let data: Data = try perform("/get", query: [
            "track_name": trackName,
            "artist_name": artistName
        ])
        return try JSONDecoder().decode(LrclibSong.self, from: data)
    }
    
    // MARK: - 优化后的 LRC 解析
    private func parseLrcLyrics(_ lrcContent: String) -> [LyricsLineDto] {
        var lines: [LyricsLineDto] = []
        guard let regex = LrclibLyricsRepository.lrcLineRegex else { return [] }
        
        let nsString = lrcContent as NSString
        let matches = regex.matches(in: lrcContent, range: NSRange(location: 0, length: nsString.length))
        
        lines.reserveCapacity(matches.count)
        
        for match in matches {
            let minute = Int(nsString.substring(with: match.range(at: 1))) ?? 0
            let second = Int(nsString.substring(with: match.range(at: 2))) ?? 0
            let millisecond = Int(nsString.substring(with: match.range(at: 3))) ?? 0
            let text = nsString.substring(with: match.range(at: 4))
            
            let totalMs = (minute * 60 + second) * 1000 + millisecond * 10
            
            lines.append(LyricsLineDto(
                words: text,
                startTimeMs: Int64(totalMs),
                syllables: nil
            ))
        }
        
        lines.sort { ($0.startTimeMs ?? 0) < ($1.startTimeMs ?? 0) }
        return lines
    }
    
    // MARK: - 优化后的 YRC (逐字) 解析
    private func parseYrcLyrics(_ yrcContent: String) -> [LyricsLineDto] {
        var lines: [LyricsLineDto] = []
        
        // 确保正则可用
        guard let lineRegex = LrclibLyricsRepository.yrcLineRegex,
              let wordRegex = LrclibLyricsRepository.yrcWordRegex,
              let specialRegex = LrclibLyricsRepository.yrcSpecialRegex else { return [] }
        
        let lineStrings = yrcContent.components(separatedBy: "\n")
        lines.reserveCapacity(lineStrings.count)
        
        for lineString in lineStrings {
            let nsString = lineString as NSString
            let fullRange = NSRange(location: 0, length: nsString.length)
            
            // 1. 解析行整体 [start, duration]
            guard let match = lineRegex.firstMatch(in: lineString, options: [], range: fullRange) else { continue }
            
            let lineStartMs = Int(nsString.substring(with: match.range(at: 1))) ?? 0
            let contentRange = match.range(at: 3)
            let lineContent = nsString.substring(with: contentRange)
            
            var syllables: [SyllableDto] = []
            var fullLineText = ""
            
            let nsLineContent = lineContent as NSString
            let contentLen = nsLineContent.length
            let contentFullRange = NSRange(location: 0, length: contentLen)
            
            // MARK: 特殊格式分流处理
            // 优先检查是否存在特殊格式 ((t,d)text)，如果存在则优先处理。
            // 这避免了在每一行普通歌词中都重复扫描特殊格式，大幅提升速度，同时保留了特殊格式支持。
            let specialMatches = specialRegex.matches(in: lineContent, options: [], range: contentFullRange)
            
            if !specialMatches.isEmpty {
                // === 路径 A: 特殊格式处理 (如和声) ===
                for specialMatch in specialMatches {
                    // 提取时间 (特殊格式时间在前: range at 1)
                    let wordStartMs = Int64(nsLineContent.substring(with: specialMatch.range(at: 1))) ?? 0
                    // 提取文字 (range at 3)
                    let rawWord = nsLineContent.substring(with: specialMatch.range(at: 3))
                    
                    // 按照原逻辑，加上括号
                    let finalWord = "(\(rawWord))"
                    
                    fullLineText += finalWord
                    syllables.append(SyllableDto(
                        startTimeMs: wordStartMs,
                        numChars: Int64(finalWord.count)
                    ))
                }
            } else {
                // === 路径 B: 普通格式处理 ===
                // 只有没发现特殊格式时才跑普通正则
                let wordMatches = wordRegex.matches(in: lineContent, options: [], range: contentFullRange)
                syllables.reserveCapacity(wordMatches.count)
                
                for wordMatch in wordMatches {
                    let wordTextRange = wordMatch.range(at: 1)
                    let wordStartMsRange = wordMatch.range(at: 2)
                    
                    let wordStartMs = Int64(nsLineContent.substring(with: wordStartMsRange)) ?? 0
                    
                    if wordTextRange.location != NSNotFound {
                        let wordText = nsLineContent.substring(with: wordTextRange)
                        fullLineText += wordText
                        
                        syllables.append(SyllableDto(
                            startTimeMs: wordStartMs,
                            numChars: Int64(wordText.count)
                        ))
                    }
                }
            }
            
            lines.append(LyricsLineDto(
                words: fullLineText,
                startTimeMs: Int64(lineStartMs),
                syllables: syllables.isEmpty ? nil : syllables
            ))
        }
        
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
        
        // 处理翻译歌词
        if let translatedLyrics = song.translatedLyrics, !translatedLyrics.isEmpty {
            let translationLines = parseLrcLyrics(translatedLyrics)
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
        
        // 优化：不必遍历全部歌词，只检查前几行即可判断是否包含中文
        if !lyricsLines.isEmpty {
            let checkCount = min(5, lyricsLines.count)
            for i in 0..<checkCount {
                if lyricsLines[i].words.range(of: "\\p{Han}", options: .regularExpression) != nil {
                    romanization = .canBeRomanized
                    break
                }
            }
        }
        
        return LyricsDto(
            lines: lyricsLines,
            timeSynced: timeSynced,
            isSyllableSynced: isSyllableSynced,
            romanization: romanization,
            translation: translation
        )
    }
}
