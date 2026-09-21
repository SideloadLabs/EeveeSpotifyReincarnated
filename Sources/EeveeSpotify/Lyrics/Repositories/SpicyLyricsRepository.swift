import Foundation

// MARK: - SpicyLyricsRepository
//
// Fetches lyrics from the official Spicy Lyrics API
// (GET /v1/lyrics/{trackId}, Bearer key auth) and converts the response
// into LyricsDto. Replaces the old api.spicylyrics.org /query + SLObjPack
// + spoofed-browser-header flow: no Spotify token, no envelope, no packing —
// the response is plain JSON with the lyrics under "Body".
//
// ── Auth ─────────────────────────────────────────────────────────────────────
// A key the user pastes into EeveeSpotify's lyrics settings
// (UserDefaults.spicyLyricsApiKey) wins; otherwise SpicyLyricsDefaultKey is used.
// The docs want secret keys (sl_sk_...) kept off client code; for a shipped
// native client they intend a publishable key (sl_pk_...) with the dashboard's
// "no origin header" option enabled (per-application limit + per-viewer IP limit).
//
// ── Attribution (binding, per the API's Terms) ───────────────────────────────
// Always show the provider (source: spicy_lyrics / apple_music / spotify).
// For spicy_lyrics also show the uploader and the maker, linked where a url is
// given; those fields are absent for other sources, never render them empty.
// Karaoke path: KaraokeCreditsFooterView. Native path: LyricsDto.providerCredit.
//
// ── iOS 27 crash ─────────────────────────────────────────────────────────────
// The EXC_BREAKPOINT / _swift_task_checkIsolatedSwift crash is fixed in
// DataLoaderServiceHooks.x.swift by dispatching orig.URLSession callbacks
// onto the main queue. No changes needed here for that.

class SpicyLyricsRepository: LyricsRepository {

    static let shared = SpicyLyricsRepository()
    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest  = 15
        config.timeoutIntervalForResource = 15
        config.allowsExpensiveNetworkAccess   = true
        config.allowsConstrainedNetworkAccess = true
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    private let session: URLSession

    // Base URL only — the path is appended in performRequest.
    private static let apiUrl = "https://api.spicylyrics.org"

    // MARK: - Network

    // A 503 used to mean "accepted, lyrics still being generated" on the old
    // API, and the real client polled with backoff (2000ms * 1.5^attempt,
    // capped 10s). The new docs list 503 without saying what it means, so
    // this keeps the same bounded retry (5 retries, ~26s total) on the
    // assumption it still means "try again shortly". This call is synchronous
    // and blocks the calling background thread, so it can't loop forever.
    private static let queuedRetryDelays: [TimeInterval] = {
        (0 ..< 5).map { attempt in min(10.0, 2.0 * pow(1.5, Double(attempt))) }
    }()

    private func performQuery(trackId: String, apiKey: String) throws -> (Data, Int) {
        for (attempt, delay) in ([0.0] + SpicyLyricsRepository.queuedRetryDelays).enumerated() {
            if delay > 0 {
                writeDebugLog("[SpicyLyrics] Track \(trackId) got 503 — retrying in \(delay)s (attempt \(attempt + 1))")
                Thread.sleep(forTimeInterval: delay)
            }
            let (data, httpStatus) = try performRequest(trackId: trackId, apiKey: apiKey)
            if httpStatus != 503 { return (data, httpStatus) }
        }
        writeDebugLog("[SpicyLyrics] Track \(trackId) still 503 after all retries — giving up")
        throw LyricsError.noSuchSong
    }

    private func performRequest(trackId: String, apiKey: String) throws -> (Data, Int) {
        guard let url = URL(string: "\(SpicyLyricsRepository.apiUrl)/v1/lyrics/\(trackId)") else {
            throw LyricsError.decodingError
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)",  forHTTPHeaderField: "Authorization")
        request.setValue("application/json",  forHTTPHeaderField: "Accept")
        request.setValue("EeveeSpotifyReincarnated", forHTTPHeaderField: "User-Agent")

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var responseStatus = 0
        var responseError: Error?

        session.dataTask(with: request) { data, response, error in
            responseData = data
            responseStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
            responseError = error
            semaphore.signal()
        }.resume()

        semaphore.wait()

        if let error = responseError {
            writeDebugLog("[SpicyLyrics] Network error for \(trackId): \(error)")
            throw error
        }
        guard let data = responseData else {
            writeDebugLog("[SpicyLyrics] No data for \(trackId)")
            throw LyricsError.decodingError
        }
        writeDebugLog("[SpicyLyrics] HTTP \(responseStatus), \(data.count) bytes for track \(trackId)")
        return (data, responseStatus)
    }

    // MARK: - Parse

    private func parseLyricsData(_ data: Data, httpStatus: Int, trackId: String, query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        switch httpStatus {
        case 200:
            break
        case 401, 403:
            // 401: missing/invalid key. 403: key valid but not allowed here
            // (e.g. a publishable key without "no origin header" enabled).
            writeDebugLog("[SpicyLyrics] Key rejected (HTTP \(httpStatus)) for \(trackId)")
            throw LyricsError.invalidSpicyKey
        case 404:
            throw LyricsError.noSuchSong
        default:
            // 400 (bad id), 429 (rate limited), 5xx
            let rawBody = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
            writeDebugLog("[SpicyLyrics] Unexpected HTTP \(httpStatus) for \(trackId): \(rawBody)")
            throw LyricsError.noSuchSong
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            let rawBody = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
            writeDebugLog("[SpicyLyrics] Invalid JSON for \(trackId): \(rawBody)")
            throw LyricsError.decodingError
        }

        // Lyrics live under "Body"; tolerate an unwrapped payload just in case.
        let packed = SLObjPackValue(json: (json as? [String: Any])?["Body"] ?? json)

        guard let type = packed["Type"]?.stringValue else {
            writeDebugLog("[SpicyLyrics] Missing Type for \(trackId)")
            throw LyricsError.decodingError
        }

        writeDebugLog("[SpicyLyrics] Lyrics type=\(type) for \(trackId)")

        switch type {
        case "Syllable": return parseSyllableLyrics(packed, trackId: trackId, query: query, options: options)
        case "Line":     return parseLineLyrics(packed)
        case "Static":   return parseStaticLyrics(packed)
        default:
            writeDebugLog("[SpicyLyrics] Unknown type '\(type)' for \(trackId)")
            throw LyricsError.decodingError
        }
    }

    // MARK: Syllable lyrics

    private func parseSyllableLyrics(_ root: SLObjPackValue, trackId: String, query: LyricsSearchQuery, options: LyricsOptions) -> LyricsDto {
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
                // Real client rule (Syllable.ts / tools.ts): IsPartOfWord is a
                // FORWARD-looking flag — a syllable with IsPartOfWord=true means
                // the word continues into the *next* syllable with no gap (e.g.
                // "Lo" (IsPartOfWord=true) + "la" -> "Lola"). So whether a space
                // goes before the *current* syllable depends on the *previous*
                // syllable's flag, not this one's own. (Verified directly against
                // the real client: Syllable.ts's word-grouping gates inclusion on
                // `lead.IsPartOfWord || (prev?.IsPartOfWord && currentWordGroup)`,
                // and tools.ts's convertSyllableToStatic appends a space *after*
                // a syllable only `if (!syllable.IsPartOfWord)`.) Reading this
                // backwards (checking the current syllable's own flag to decide
                // the preceding space, as an earlier version of this file did)
                // is what produced broken spacing like "wasLo la" instead of
                // "was Lola" — plain .joined() (no separator) had the same
                // underlying problem, producing "Doyourecall,notlongago?".
                var text = ""
                var previousIsPartOfWord = false
                for syllable in syllables {
                    guard let syllableText = syllable["Text"]?.stringValue else { continue }
                    let isPartOfWord = syllable["IsPartOfWord"]?.boolValue ?? false
                    if !text.isEmpty && !previousIsPartOfWord {
                        text += " "
                    }
                    text += syllableText
                    previousIsPartOfWord = isPartOfWord

                    let startMs = syllable["StartTime"]?.doubleValue.map { Int($0 * 1000) } ?? 0
                    let endMs   = syllable["EndTime"]?.doubleValue.map { Int($0 * 1000) } ?? startMs
                    karaokeSyllables.append(KaraokeSyllableDto(
                        text: syllableText,
                        startMs: startMs,
                        endMs: endMs,
                        isPartOfWord: isPartOfWord
                    ))
                }
                lineText = text
                if syllables.contains(where: { ($0["TransliteratedText"]?.stringValue ?? "").isEmpty == false }) {
                    hasRomanized = true
                }
            } else if let text = lead["Text"]?.stringValue {
                lineText = text
            } else {
                continue
            }

            if (lead["TransliteratedText"]?.stringValue ?? "").isEmpty == false { hasRomanized = true }

            let lineStartMs = lead["StartTime"]?.doubleValue.map { Int($0 * 1000) } ?? 0
            let lineEndMs   = lead["EndTime"]?.doubleValue.map { Int($0 * 1000) }
                ?? karaokeSyllables.last?.endMs
                ?? lineStartMs

            lines.append(LyricsLineDto(content: lineText.lyricsNoteIfEmpty, offsetMs: lineStartMs))

            if !karaokeSyllables.isEmpty {
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

        if !karaokeLines.isEmpty {
            let songWriters = root["SongWriters"]?.arrayValue?.compactMap { $0.stringValue } ?? []
            let providerCode = root["source"]?.stringValue
            let providerDisplayName = providerCode == "ext" ? root["sourceName"]?.stringValue : nil

            let filledKaraokeLines = LyricsUncensorFill.fillKaraoke(
                lines: karaokeLines,
                query: query,
                options: options
            )
            let normalizedKaraokeLines = SpicyLyricsRepository.normalizeMonotonicTiming(filledKaraokeLines)

            let attribution = root["UploadAttribution"]
            let uploaderName = attribution?["Uploader"]?["username"]?.stringValue
            let uploaderUrl  = attribution?["Uploader"]?["url"]?.stringValue
            let makerName    = attribution?["Maker"]?["username"]?.stringValue
            let makerUrl     = attribution?["Maker"]?["url"]?.stringValue

            KaraokeLyricsStore.shared.set(
                trackId: trackId,
                lyrics: KaraokeLyricsDto(
                    lines: normalizedKaraokeLines,
                    songWriters: songWriters,
                    providerCode: providerCode,
                    providerDisplayName: providerDisplayName,
                    uploaderName: uploaderName,
                    uploaderUrl: uploaderUrl,
                    makerName: makerName,
                    makerUrl: makerUrl
                )
            )
            writeDebugLog("[SpicyLyrics] Stored karaoke data: \(karaokeLines.count) lines for \(trackId)")
        }

        return LyricsDto(lines: lines, timeSynced: true, romanization: romanization, providerCredit: SpicyLyricsRepository.providerCredit(root))
    }

    /// Some SpicyLyrics syllable timing has slight overlaps between
    /// consecutive syllables — observed across a line boundary, where a
    /// later word's startMs lands earlier than an earlier word's endMs. This
    /// is a data quality quirk in the source's algorithmically-derived
    /// timing, not something this parsing step introduces. Left as-is, an
    /// overlap lets a LATER word's highlight progress reach further than an
    /// EARLIER word's at the same playback instant, which reads as the
    /// highlight jumping ahead on one word while lagging behind on another
    /// right next to it — reported as the highlight looking "broken" mid-
    /// line.
    ///
    /// Clamping each syllable's startMs to be at least the previous
    /// syllable's endMs — walked across the ENTIRE track in sung order,
    /// across line boundaries too, not just within one line — guarantees
    /// monotonic progress: a later syllable's window can never start before
    /// an earlier one's has finished, so highlight progress can't visually
    /// jump out of order anymore.
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

    private func parseLineLyrics(_ root: SLObjPackValue) -> LyricsDto {
        guard let content = root["Content"]?.arrayValue else { return emptyDto() }

        var lines        = [LyricsLineDto]()
        let hasRomanized = root["HasTransliterations"]?.boolValue ?? false

        for entry in content {
            guard entry["Type"]?.stringValue == "Vocal" else { continue }
            let text      = SpicyLyricsRepository.leadText(entry)
            let startTime = entry["Lead"]?["StartTime"]?.doubleValue ?? entry["StartTime"]?.doubleValue
            lines.append(LyricsLineDto(content: text.lyricsNoteIfEmpty, offsetMs: startTime.map { Int($0 * 1000) }))
        }

        let romanization: LyricsRomanizationStatus = hasRomanized
            ? .romanized
            : (lines.map(\.content).canBeRomanized ? .canBeRomanized : .original)

        return LyricsDto(lines: lines, timeSynced: true, romanization: romanization, providerCredit: SpicyLyricsRepository.providerCredit(root))
    }

    // MARK: Static lyrics

    private func parseStaticLyrics(_ root: SLObjPackValue) -> LyricsDto {
        // "Lines" is what the old API used for Static; the new docs only show
        // "Content", so accept either.
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
        return LyricsDto(lines: lines, timeSynced: false, romanization: romanization, providerCredit: SpicyLyricsRepository.providerCredit(root))
    }

    /// Text of a Vocal entry: Lead.Text, else entry.Text, else Lead's
    /// syllables stitched together (IsPartOfWord is forward-looking — see the
    /// note in parseSyllableLyrics).
    private static func leadText(_ entry: SLObjPackValue) -> String {
        if let text = entry["Lead"]?["Text"]?.stringValue ?? entry["Text"]?.stringValue {
            return text
        }
        var text = ""
        var previousIsPartOfWord = false
        for syllable in entry["Lead"]?["Syllables"]?.arrayValue ?? [] {
            guard let syllableText = syllable["Text"]?.stringValue else { continue }
            if !text.isEmpty && !previousIsPartOfWord { text += " " }
            text += syllableText
            previousIsPartOfWord = syllable["IsPartOfWord"]?.boolValue ?? false
        }
        return text
    }

    // MARK: Attribution

    /// Display name for the response's `source` field. Unknown future sources
    /// are prettified rather than dropped, since the provider must always show.
    static func providerName(for code: String?) -> String? {
        guard let code = code, !code.isEmpty else { return nil }
        switch code {
        case "spicy_lyrics": return "Spicy Lyrics"
        default:
            return code.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Plain-text credit for surfaces that can't render links (Spotify's
    /// native lyrics screen). Uploader/Maker only exist for spicy_lyrics.
    private static func providerCredit(_ root: SLObjPackValue) -> String? {
        let code = root["source"]?.stringValue
        guard let name = providerName(for: code) else { return nil }
        var parts = [name]
        if code == "spicy_lyrics" {
            let attribution = root["UploadAttribution"]
            if let maker = attribution?["Maker"]?["username"]?.stringValue, !maker.isEmpty {
                parts.append("Made by \(maker)")
            }
            if let uploader = attribution?["Uploader"]?["username"]?.stringValue, !uploader.isEmpty {
                parts.append("Uploaded by \(uploader)")
            }
        }
        return parts.joined(separator: " · ")
    }

    private func emptyDto() -> LyricsDto {
        LyricsDto(lines: [], timeSynced: false, romanization: .original)
    }

    // MARK: - LyricsRepository

    func getLyrics(_ query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        let trackId = query.spotifyTrackId
        // The API only accepts real Spotify track ids (22 base62 chars).
        guard trackId.range(of: "^[A-Za-z0-9]{22}$", options: .regularExpression) != nil else {
            writeDebugLog("[SpicyLyrics] Not a Spotify track id: '\(trackId)'")
            throw LyricsError.noSuchSong
        }

        let userKey = UserDefaults.spicyLyricsApiKey
        let apiKey = userKey.isEmpty ? SpicyLyricsDefaultKey.value : userKey
        writeDebugLog("[SpicyLyrics] Using \(userKey.isEmpty ? "built-in" : "settings") key (\(apiKey.prefix(6))...)")
        guard !apiKey.isEmpty else {
            writeDebugLog("[SpicyLyrics] No API key set")
            throw LyricsError.missingSpicyKey
        }

        let (data, httpStatus) = try performQuery(trackId: trackId, apiKey: apiKey)
        var dto = try parseLyricsData(data, httpStatus: httpStatus, trackId: trackId, query: query, options: options)

        let filledContents = LyricsUncensorFill.fill(
            lines: dto.lines.map(\.content),
            query: query,
            options: options
        )
        for (index, content) in filledContents.enumerated() where index < dto.lines.count {
            dto.lines[index].content = content
        }
        return dto
    }
}

// MARK: - JSON → SLObjPackValue
//
// The new API returns plain JSON, so the parsers above (written against
// SLObjPackValue) are reused by converting JSONSerialization output into it.

extension SLObjPackValue {
    init(json: Any) {
        switch json {
        case is NSNull:
            self = .null
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let array as [Any]:
            self = .array(array.map { SLObjPackValue(json: $0) })
        case let object as [String: Any]:
            self = .object(object.mapValues { SLObjPackValue(json: $0) })
        default:
            self = .null
        }
    }
}
