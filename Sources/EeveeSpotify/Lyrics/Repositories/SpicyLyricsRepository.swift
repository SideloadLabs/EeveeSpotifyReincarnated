import Foundation

class SpicyLyricsRepository: LyricsRepository {

    static let shared = SpicyLyricsRepository()
    init(configuration config: URLSessionConfiguration = .ephemeral) {
        config.timeoutIntervalForRequest  = 15
        config.timeoutIntervalForResource = 15
        config.allowsExpensiveNetworkAccess   = true
        config.allowsConstrainedNetworkAccess = true
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    private let session: URLSession

    private static let apiUrl = "https://api.spicylyrics.org/v1/lyrics/"

    // MARK: - Network

    // 503 means the lyrics are still being generated.
    private static let queuedRetryDelays: [TimeInterval] = {
        (0 ..< 5).map { attempt in min(10.0, 2.0 * pow(1.5, Double(attempt))) }
    }()

    private func performQuery(trackId: String, apiKey: String) throws -> (Data, Int) {
        for (attempt, delay) in ([0.0] + SpicyLyricsRepository.queuedRetryDelays).enumerated() {
            if delay > 0 {
                eeveeLog("[EeveeSpotify][SpicyLyrics] %@ queued (503), retrying in %.1fs (attempt %d)", trackId, delay, attempt + 1)
                try LyricsDownloadHTTP.waitForRetry(delay)
            }
            let (data, httpStatus) = try performRequest(trackId: trackId, apiKey: apiKey)
            if httpStatus != 503 { return (data, httpStatus) }
        }
        eeveeLog("[EeveeSpotify][SpicyLyrics] %@ still queued after all retries", trackId)
        throw URLError(.resourceUnavailable)
    }

    private func performRequest(trackId: String, apiKey: String) throws -> (Data, Int) {
        guard let url = URL(string: SpicyLyricsRepository.apiUrl + trackId) else {
            throw LyricsError.decodingError
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("EeveeSpotify", forHTTPHeaderField: "User-Agent")
        try LyricsDownloadHTTP.prepare(request)

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var responseStatus = 0
        var responseError: Error?
        var httpResponse: URLResponse?

        let task = session.dataTask(with: request) { data, response, error in
            responseData = data
            responseStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
            responseError = error
            httpResponse = response
            semaphore.signal()
        }
        try LyricsDownloadHTTP.start(task)
        try LyricsDownloadHTTP.waitForResponse(semaphore, task: task)

        if let error = responseError {
            eeveeLog("[EeveeSpotify][SpicyLyrics] %@ network error: %@", trackId, String(describing: error))
            throw error
        }
        try LyricsDownloadHTTP.validate(httpResponse, request: request, handlesQueuedResponse: true)
        guard let data = responseData else {
            eeveeLog("[EeveeSpotify][SpicyLyrics] %@ returned no data", trackId)
            throw LyricsError.decodingError
        }
        return (data, responseStatus)
    }

    // MARK: - Parse

    private func parseLyricsData(_ data: Data, httpStatus: Int, trackId: String, query: LyricsSearchQuery, options: LyricsOptions, start: CFAbsoluteTime) throws -> LyricsDto {
        switch httpStatus {
        case 200:
            break
        case 401, 403:
            eeveeLog("[EeveeSpotify][SpicyLyrics] %@ key rejected (HTTP %d)", trackId, httpStatus)
            throw LyricsError.invalidSpicyKey
        case 404:
            eeveeLog("[EeveeSpotify][SpicyLyrics] %@: HTTP 404, no lyrics (%.0f ms)", trackId, (CFAbsoluteTimeGetCurrent() - start) * 1000)
            throw LyricsError.noSuchSong
        default:
            let rawBody = String(data: data, encoding: .utf8).map { String($0.prefix(200)) } ?? "<non-utf8 \(data.count) bytes>"
            eeveeLog("[EeveeSpotify][SpicyLyrics] %@ unexpected HTTP %d: %@", trackId, httpStatus, rawBody)
            throw URLError(.badServerResponse)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            eeveeLog("[EeveeSpotify][SpicyLyrics] %@ invalid JSON", trackId)
            throw LyricsError.decodingError
        }

        let root = SpicyLyricsJSON((json as? [String: Any])?["Body"] ?? json)

        guard let type = root["Type"]?.stringValue else {
            eeveeLog("[EeveeSpotify][SpicyLyrics] %@ missing Type", trackId)
            throw LyricsError.decodingError
        }

        let dto: LyricsDto
        switch type {
        case "Syllable": dto = parseSyllableLyrics(root, trackId: trackId, query: query, options: options)
        case "Line":     dto = parseLineLyrics(root, trackId: trackId, query: query, options: options)
        case "Static":   dto = parseStaticLyrics(root)
        default:
            eeveeLog("[EeveeSpotify][SpicyLyrics] %@ unknown type '%@'", trackId, type)
            throw LyricsError.decodingError
        }
        guard !dto.lines.isEmpty else { throw LyricsError.decodingError }
        eeveeLog("[EeveeSpotify][SpicyLyrics] %@: HTTP %d, %@, %d lines (%.0f ms)",
                 trackId, httpStatus, type, dto.lines.count, (CFAbsoluteTimeGetCurrent() - start) * 1000)
        return dto
    }

    // MARK: Syllable lyrics

    private func parseSyllableLyrics(_ root: SpicyLyricsJSON, trackId: String, query: LyricsSearchQuery, options: LyricsOptions) -> LyricsDto {
        guard let content = root["Content"]?.arrayValue else { return emptyDto() }

        var lines        = [LyricsLineDto]()
        var karaokeLines = [KaraokeLineDto]()
        var hasRomanized = root["HasTransliterations"]?.boolValue ?? false

        for entry in content {
            guard entry["Type"]?.stringValue == "Vocal",
                  let lead = entry["Lead"] else { continue }

            let lineText: String
            var karaokeSyllables = [KaraokeSyllableDto]()

            if let syllables = lead["Syllables"]?.arrayValue, !syllables.isEmpty {
                karaokeSyllables = SpicyLyricsRepository.syllables(syllables)
                lineText = karaokeSyllables.plainText
                if syllables.contains(where: { ($0["TransliteratedText"]?.stringValue ?? "").isEmpty == false }) {
                    hasRomanized = true
                }
            } else if let text = lead["Text"]?.stringValue {
                lineText = text
            } else {
                continue
            }

            if (lead["TransliteratedText"]?.stringValue ?? "").isEmpty == false { hasRomanized = true }

            let lineStartMs = lead["StartTime"]?.milliseconds ?? 0
            let lineEndMs   = lead["EndTime"]?.milliseconds
                ?? karaokeSyllables.last?.endMs
                ?? lineStartMs

            lines.append(LyricsLineDto(content: lineText.lyricsNoteIfEmpty, offsetMs: lineStartMs))

            if !LyricsDownloadHTTP.isDownloading && !karaokeSyllables.isEmpty {
                karaokeLines.append(KaraokeLineDto(
                    syllables: karaokeSyllables,
                    startMs: lineStartMs,
                    endMs: lineEndMs
                ))
            }
        }

        let romanization: LyricsRomanizationStatus = hasRomanized
            ? .romanized
            : (lines.map(\.content).canBeRomanized ? .canBeRomanized : .original)

        var karaoke: KaraokeLyricsDto?
        if !karaokeLines.isEmpty {
            let songWriters = root["SongWriters"]?.arrayValue?.compactMap { $0.stringValue } ?? []
            let attribution = root["UploadAttribution"]

            karaoke = KaraokeLyricsDto(
                lines: karaokeLines,
                songWriters: songWriters,
                providerCode: root["source"]?.stringValue,
                uploaderName: attribution?["Uploader"]?["username"]?.stringValue,
                uploaderUrl: attribution?["Uploader"]?["url"]?.stringValue,
                makerName: attribution?["Maker"]?["username"]?.stringValue,
                makerUrl: attribution?["Maker"]?["url"]?.stringValue
            )
        }

        return LyricsDto(
            lines: lines,
            timeSynced: true,
            romanization: romanization,
            providerCredit: SpicyLyricsRepository.providerCredit(root), karaoke: karaoke
        )
    }

    // Source timing sometimes overlaps across lines; clamp so the highlight never runs out of order.
    private static func normalizeMonotonicTiming(_ lines: [KaraokeLineDto]) -> [KaraokeLineDto] {
        var result = lines
        var previousEndMs = Int.min
        for lineIndex in result.indices {
            for syllableIndex in result[lineIndex].syllables.indices {
                var syllable = result[lineIndex].syllables[syllableIndex]
                if syllable.startMs < previousEndMs {
                    syllable.startMs = previousEndMs
                }
                if syllable.endMs < syllable.startMs {
                    syllable.endMs = syllable.startMs
                }
                previousEndMs = syllable.endMs
                result[lineIndex].syllables[syllableIndex] = syllable
            }
        }
        return result
    }

    // MARK: Line lyrics

    private func parseLineLyrics(_ root: SpicyLyricsJSON, trackId: String, query: LyricsSearchQuery, options: LyricsOptions) -> LyricsDto {
        guard let content = root["Content"]?.arrayValue else { return emptyDto() }

        var lines        = [LyricsLineDto]()
        var karaokeLines = [KaraokeLineDto]()
        let hasRomanized = root["HasTransliterations"]?.boolValue ?? false

        for entry in content {
            guard entry["Type"]?.stringValue == "Vocal" else { continue }
            let text      = SpicyLyricsRepository.leadText(entry)
            let startMs = entry["Lead"]?["StartTime"]?.milliseconds ?? entry["StartTime"]?.milliseconds
            let endMs = entry["Lead"]?["EndTime"]?.milliseconds ?? entry["EndTime"]?.milliseconds
            lines.append(LyricsLineDto(content: text.lyricsNoteIfEmpty, offsetMs: startMs))

            // Line-synced songs still get the custom lyrics view: every word lights up with its line.
            guard !LyricsDownloadHTTP.isDownloading, let lineStartMs = startMs, !text.isEmpty else { continue }
            let words = text.split(separator: " ", omittingEmptySubsequences: true)
            guard !words.isEmpty else { continue }

            let lineEndMs = max(endMs ?? lineStartMs, lineStartMs)
            karaokeLines.append(KaraokeLineDto(
                syllables: words.map {
                    KaraokeSyllableDto(text: String($0), startMs: lineStartMs, endMs: lineStartMs, isPartOfWord: false)
                },
                startMs: lineStartMs,
                endMs: lineEndMs
            ))
        }

        let romanization: LyricsRomanizationStatus = hasRomanized
            ? .romanized
            : (lines.map(\.content).canBeRomanized ? .canBeRomanized : .original)

        var karaoke: KaraokeLyricsDto?
        if !karaokeLines.isEmpty {
            let attribution = root["UploadAttribution"]
            karaoke = KaraokeLyricsDto(
                lines: karaokeLines,
                songWriters: root["SongWriters"]?.arrayValue?.compactMap { $0.stringValue } ?? [],
                providerCode: root["source"]?.stringValue,
                uploaderName: attribution?["Uploader"]?["username"]?.stringValue,
                uploaderUrl: attribution?["Uploader"]?["url"]?.stringValue,
                makerName: attribution?["Maker"]?["username"]?.stringValue,
                makerUrl: attribution?["Maker"]?["url"]?.stringValue
            )
        }

        return LyricsDto(
            lines: lines,
            timeSynced: true,
            romanization: romanization,
            providerCredit: SpicyLyricsRepository.providerCredit(root), karaoke: karaoke
        )
    }

    // MARK: Static lyrics

    private func parseStaticLyrics(_ root: SpicyLyricsJSON) -> LyricsDto {
        let texts: [String]
        if let rawLines = root["Lines"]?.arrayValue {
            texts = rawLines.compactMap { $0["Text"]?.stringValue }
        } else {
            texts = (root["Content"]?.arrayValue ?? [])
                .filter { $0["Type"]?.stringValue == "Vocal" }
                .map { SpicyLyricsRepository.leadText($0) }
        }
        let lines = texts.map { LyricsLineDto(content: $0.lyricsNoteIfEmpty, offsetMs: nil) }
        let romanization: LyricsRomanizationStatus = lines.map(\.content).canBeRomanized
            ? .canBeRomanized : .original
        return LyricsDto(
            lines: lines,
            timeSynced: false,
            romanization: romanization,
            providerCredit: SpicyLyricsRepository.providerCredit(root)
        )
    }

    private static func leadText(_ entry: SpicyLyricsJSON) -> String {
        if let text = entry["Lead"]?["Text"]?.stringValue ?? entry["Text"]?.stringValue {
            return text
        }
        return syllables(entry["Lead"]?["Syllables"]?.arrayValue ?? []).plainText
    }

    private static func syllables(_ raw: [SpicyLyricsJSON]) -> [KaraokeSyllableDto] {
        raw.compactMap { syllable -> KaraokeSyllableDto? in
            guard let text = syllable["Text"]?.stringValue else { return nil }
            let startMs = syllable["StartTime"]?.milliseconds ?? 0
            return KaraokeSyllableDto(
                text: text,
                startMs: startMs,
                endMs: syllable["EndTime"]?.milliseconds ?? startMs,
                isPartOfWord: syllable["IsPartOfWord"]?.boolValue ?? false
            )
        }
    }

    private func emptyDto() -> LyricsDto {
        LyricsDto(lines: [], timeSynced: false, romanization: .original)
    }

    // MARK: Attribution

    static let providerName = "Spicy Lyrics"

    private static func providerCredit(_ root: SpicyLyricsJSON) -> String? {
        guard let code = root["source"]?.stringValue, !code.isEmpty else { return nil }
        var parts = [providerName]
        if code == "spicy_lyrics" {
            let attribution = root["UploadAttribution"]
            if let maker = attribution?["Maker"]?["username"]?.stringValue, !maker.isEmpty {
                parts.append("\("lyrics_made_by".localized) \(maker)")
            }
            if let uploader = attribution?["Uploader"]?["username"]?.stringValue, !uploader.isEmpty {
                parts.append("\("lyrics_uploaded_by".localized) \(uploader)")
            }
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - LyricsRepository

    func getLyrics(_ query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        let trackId = query.spotifyTrackId
        guard trackId.range(of: "^[A-Za-z0-9]{22}$", options: .regularExpression) != nil else {
            eeveeLog("[EeveeSpotify][SpicyLyrics] Not a Spotify track id: '%@'", trackId)
            throw LyricsError.noSuchSong
        }

        let start = CFAbsoluteTimeGetCurrent()
        let apiKey = UserDefaults.effectiveSpicyLyricsApiKey
        let (data, httpStatus) = try performQuery(trackId: trackId, apiKey: apiKey)
        var dto = try parseLyricsData(data, httpStatus: httpStatus, trackId: trackId, query: query, options: options, start: start)

        let filledContents = LyricsUncensorFill.fill(
            lines: dto.lines.map(\.content),
            query: query,
            options: options
        )
        if var karaoke = dto.karaoke {
            karaoke.lines = Self.normalizeMonotonicTiming(LyricsUncensorFill.fillKaraoke(
                lines: karaoke.lines, original: dto.lines.map(\.content), resolved: filledContents))
            dto.karaoke = karaoke
        }
        for (index, content) in filledContents.enumerated() where index < dto.lines.count {
            dto.lines[index].content = content
        }
        return dto
    }
}
