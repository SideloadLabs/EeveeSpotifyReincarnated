import Foundation

// MARK: - SpicyLyricsRepository
//
// Fetches lyrics from api.spicylyrics.org and converts the response into LyricsDto.
//
// ── Token availability ───────────────────────────────────────────────────────
// spotifyAccessToken is captured lazily from Spotify's outgoing requests.
// On first track load it may be nil. The Spicetify extension uses
// Platform.GetSpotifyAccessToken() which awaits the token asynchronously.
// We replicate that by polling spotifyAccessToken for up to 5 seconds before
// giving up — this prevents an immediate 401 from the API triggering Genius fallback.
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

    private static let apiUrl        = "https://api.spicylyrics.org"
    private static let authHeaderKey = "SpicyLyrics-WebAuth"
    // Bumped to match the real client's shipped ProjectVersion
    // (project/config.ts). Version alone was a dead end for the
    // Static/Line-vs-Syllable discrepancy — see the "X-mode" header below,
    // added alongside this bump, which is the actual missing piece.
    private static let clientVersion = "6.3.1"

    // MARK: - Token wait
    //
    // Poll for spotifyAccessToken up to `timeout` seconds.
    // Returns the token or nil if not available in time.
    private func waitForToken(timeout: TimeInterval = 5.0) -> String? {
        if let token = spotifyAccessToken { return token }

        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
            if let token = spotifyAccessToken { return token }
        }
        return nil
    }

    // MARK: - Network

    // Real client behavior (fetchLyrics.ts / LyricsQueueRetry.ts): a 503 means
    // the server accepted the request but the track's lyrics are still being
    // generated — it's queued, not missing. The real client shows a "hang
    // tight" loader and keeps polling indefinitely with backoff
    // (base=2000ms, factor=1.5x per attempt, capped at 10s) until it
    // resolves or the track changes. This was previously funneled into
    // `default` below, which threw .noSuchSong immediately on 503 — that's
    // what fell straight through to Genius/Musixmatch/Lrclib fallback
    // (lower-fidelity Line/Static/plain data) instead of getting the real
    // Syllable data a few seconds later, explaining songs that "sometimes"
    // come back word-synced and sometimes don't.
    //
    // Mirrors the real formula (2000 * 1.5^attempt, capped 10s) but bounded
    // to 5 retries (~26s total) rather than running indefinitely — this call
    // is synchronous and blocks the calling background thread, so it can't
    // loop forever the way the real client's independent setTimeout-driven
    // controller can. If the track is still queued after that, fall back
    // like before rather than hanging.
    private static let queuedRetryDelays: [TimeInterval] = {
        (0 ..< 5).map { attempt in min(10.0, 2.0 * pow(1.5, Double(attempt))) }
    }()

    private func performQuery(trackId: String) throws -> Data {
        for (attempt, delay) in ([0.0] + SpicyLyricsRepository.queuedRetryDelays).enumerated() {
            if delay > 0 {
                writeDebugLog("[SpicyLyrics] Track \(trackId) queued (503) — retrying in \(delay)s (attempt \(attempt + 1))")
                Thread.sleep(forTimeInterval: delay)
            }
            let (data, httpStatus) = try performQueryOnce(trackId: trackId)
            if httpStatus != 503 { return data }
        }
        writeDebugLog("[SpicyLyrics] Track \(trackId) still queued after all retries — giving up")
        throw LyricsError.noSuchSong
    }

    /// Single request attempt. Returns the raw envelope bytes alongside the
    /// query's own httpStatus (peeked out of the envelope here, ahead of
    /// parseLyricsData's own real parse of it) purely so performQuery can
    /// decide whether to retry — parseLyricsData still does the real
    /// envelope parsing and status handling on whichever attempt succeeds.
    private func performQueryOnce(trackId: String) throws -> (Data, Int) {
        let data = try performRequest(trackId: trackId)
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let queriesRaw = json["queries"] as? [[String: Any]],
            let matchedQuery = queriesRaw.first(where: { $0["operationId"] as? String == "0" }),
            let result = matchedQuery["result"] as? [String: Any]
        else {
            // Malformed envelope — let parseLyricsData handle (and log) this
            // properly rather than duplicating that error path here.
            return (data, 0)
        }
        let httpStatus = result["httpStatus"] as? Int ?? 0
        return (data, httpStatus)
    }

    private func performRequest(trackId: String) throws -> Data {
        guard let url = URL(string: "\(SpicyLyricsRepository.apiUrl)/query") else {
            throw LyricsError.decodingError
        }

        let body: [String: Any] = [
            "queries": [
                [
                    "operation": "lyrics",
                    "variables": [
                        "id":   trackId,
                        "auth": SpicyLyricsRepository.authHeaderKey
                    ]
                ]
            ],
            "client": ["version": SpicyLyricsRepository.clientVersion]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json",                   forHTTPHeaderField: "Content-Type")
        request.setValue(SpicyLyricsRepository.clientVersion, forHTTPHeaderField: "SpicyLyrics-Version")
        // Confirmed against the real client's Query.ts: every request sends
        // this alongside SpicyLyrics-Version, unconditionally, with no
        // branching logic elsewhere in that file — it isn't a device/UA
        // signal, it's a flat request flag. This was missing here entirely,
        // which is the actual explanation for the Static/Line-vs-Syllable
        // discrepancy the sec-ch-ua/Client-Hints headers below were guessed
        // at fixing and didn't: the server was very possibly falling back to
        // a lower-fidelity response format without it.
        request.setValue("2", forHTTPHeaderField: "X-mode")

        // Spoofed browser identity headers (Origin/Referer/User-Agent/Client
        // Hints/Sec-Fetch), captured via mitmproxy from a real desktop
        // session. These aren't things the extension's own JS sets — inside
        // Spotify's actual Chromium runtime the browser sets them
        // automatically from the page context — so a native URLSession
        // needs to fake them to look like that same environment. Confirmed
        // via the real client's Query.ts that they play no role in the
        // Static/Line-vs-Syllable discrepancy specifically (that was
        // X-mode, above); kept here for general request realism.
        request.setValue("https://xpui.app.spotify.com",  forHTTPHeaderField: "Origin")
        request.setValue("https://xpui.app.spotify.com/", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.7680.179 Spotify/1.2.92.148 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("\"Windows\"",                      forHTTPHeaderField: "sec-ch-ua-platform")
        request.setValue("\"Not-A.Brand\";v=\"24\", \"Chromium\";v=\"146\"", forHTTPHeaderField: "sec-ch-ua")
        request.setValue("?0",                                forHTTPHeaderField: "sec-ch-ua-mobile")
        request.setValue("*/*",                               forHTTPHeaderField: "Accept")
        request.setValue("cross-site",                        forHTTPHeaderField: "sec-fetch-site")
        request.setValue("cors",                              forHTTPHeaderField: "sec-fetch-mode")
        request.setValue("empty",                             forHTTPHeaderField: "sec-fetch-dest")
        request.setValue("gzip, deflate, br, zstd",           forHTTPHeaderField: "Accept-Encoding")
        request.setValue("en-Latn-US,en-US;q=0.9,en-Latn;q=0.8,en;q=0.7", forHTTPHeaderField: "Accept-Language")
        request.setValue("u=1, i",                            forHTTPHeaderField: "priority")

        // Wait for the Spotify Bearer token — mirrors Platform.GetSpotifyAccessToken()
        // in the Spicetify extension. Without a valid token the API returns non-200
        // immediately, which falsely triggers Genius fallback.
        if let token = waitForToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: SpicyLyricsRepository.authHeaderKey)
            writeDebugLog("[SpicyLyrics] Using captured token for \(trackId)")
        } else {
            writeDebugLog("[SpicyLyrics] No token available for \(trackId) — proceeding unauthenticated")
        }

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var responseError: Error?

        session.dataTask(with: request) { data, _, error in
            responseData = data
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
        writeDebugLog("[SpicyLyrics] Received \(data.count) bytes for track \(trackId)")
        return data
    }

    // MARK: - Parse

    private func parseLyricsData(_ data: Data, trackId: String, query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let queriesRaw = json["queries"] as? [[String: Any]]
        else {
            let rawBody = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
            writeDebugLog("[SpicyLyrics] Malformed envelope for \(trackId): \(rawBody)")
            throw LyricsError.decodingError
        }

        // The server may prepend extra entries ahead of the real query result
        // (e.g. a "_notice" block with no "operationId"/"result"). The real
        // Spicetify client never assumes index 0 — it looks results up by
        // operationId via queries.get("0") — so we match that instead of
        // blindly taking queriesRaw.first.
        guard
            let matchedQuery = queriesRaw.first(where: { $0["operationId"] as? String == "0" }),
            let result = matchedQuery["result"] as? [String: Any]
        else {
            let rawBody = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
            writeDebugLog("[SpicyLyrics] No matching operationId 0 for \(trackId): \(rawBody)")
            throw LyricsError.decodingError
        }

        let httpStatus = result["httpStatus"] as? Int ?? 0
        writeDebugLog("[SpicyLyrics] API status \(httpStatus) for \(trackId)")

        switch httpStatus {
        case 404:
            throw LyricsError.noSuchSong
        case 200:
            break
        case 401, 403:
            // Auth failure — token was stale or rejected. Clear it so the next
            // attempt re-waits for a fresh one.
            writeDebugLog("[SpicyLyrics] Auth error \(httpStatus) for \(trackId) — clearing cached token")
            spotifyAccessToken = nil
            throw LyricsError.noSuchSong
        default:
            writeDebugLog("[SpicyLyrics] Unexpected status \(httpStatus) for \(trackId)")
            throw LyricsError.noSuchSong
        }

        guard let rawData = result["data"] else { throw LyricsError.decodingError }

        let packed: SLObjPackValue
        do {
            packed = try SLObjPack.unpack(rawData)
        } catch {
            writeDebugLog("[SpicyLyrics] SLObjPack error for \(trackId): \(error)")
            throw LyricsError.decodingError
        }

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

            KaraokeLyricsStore.shared.set(
                trackId: trackId,
                lyrics: KaraokeLyricsDto(
                    lines: filledKaraokeLines,
                    songWriters: songWriters,
                    providerCode: providerCode,
                    providerDisplayName: providerDisplayName
                )
            )
            writeDebugLog("[SpicyLyrics] Stored karaoke data: \(karaokeLines.count) lines for \(trackId)")
        }

        return LyricsDto(lines: lines, timeSynced: true, romanization: romanization)
    }

    // MARK: Line lyrics

    private func parseLineLyrics(_ root: SLObjPackValue) -> LyricsDto {
        guard let content = root["Content"]?.arrayValue else { return emptyDto() }

        var lines        = [LyricsLineDto]()
        let hasRomanized = root["HasTransliterations"]?.boolValue ?? false

        for entry in content {
            guard entry["Type"]?.stringValue == "Vocal" else { continue }
            let text      = entry["Lead"]?["Text"]?.stringValue ?? entry["Text"]?.stringValue ?? ""
            let startTime = entry["Lead"]?["StartTime"]?.doubleValue ?? entry["StartTime"]?.doubleValue
            lines.append(LyricsLineDto(content: text.lyricsNoteIfEmpty, offsetMs: startTime.map { Int($0 * 1000) }))
        }

        let romanization: LyricsRomanizationStatus = hasRomanized
            ? .romanized
            : (lines.map(\.content).canBeRomanized ? .canBeRomanized : .original)

        return LyricsDto(lines: lines, timeSynced: true, romanization: romanization)
    }

    // MARK: Static lyrics

    private func parseStaticLyrics(_ root: SLObjPackValue) -> LyricsDto {
        let rawLines = root["Lines"]?.arrayValue ?? []
        let lines = rawLines.compactMap { entry -> LyricsLineDto? in
            guard let text = entry["Text"]?.stringValue else { return nil }
            return LyricsLineDto(content: text.lyricsNoteIfEmpty, offsetMs: nil)
        }
        let romanization: LyricsRomanizationStatus = lines.map(\.content).canBeRomanized
            ? .canBeRomanized : .original
        return LyricsDto(lines: lines, timeSynced: false, romanization: romanization)
    }

    private func emptyDto() -> LyricsDto {
        LyricsDto(lines: [], timeSynced: false, romanization: .original)
    }

    // MARK: - LyricsRepository

    func getLyrics(_ query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        let trackId = query.spotifyTrackId
        guard !trackId.isEmpty else {
            writeDebugLog("[SpicyLyrics] Empty track ID")
            throw LyricsError.noSuchSong
        }
        let data = try performQuery(trackId: trackId)
        var dto = try parseLyricsData(data, trackId: trackId, query: query, options: options)

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
