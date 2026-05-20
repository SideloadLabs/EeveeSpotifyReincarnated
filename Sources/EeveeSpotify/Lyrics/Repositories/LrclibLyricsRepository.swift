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
    // 🧪 测试逐字歌词 - 验证 Protobuf 构建与客户端支持
    let testSyllables = [
        SyllableDto(startTimeMs: 0, numChars: 1),   // 第一个字符从 0ms 开始
        SyllableDto(startTimeMs: 200, numChars: 1), // 第二个字符 200ms
        SyllableDto(startTimeMs: 400, numChars: 3)  // 剩余三个字符 400ms
    ]
    let testLine = LyricsLineDto(
        words: "Hello",
        startTimeMs: 0,
        syllables: testSyllables
    )
    return LyricsDto(
        lines: [testLine],
        timeSynced: true,
        isSyllableSynced: true,
        romanization: .original,
        translation: nil
    )
}
}
