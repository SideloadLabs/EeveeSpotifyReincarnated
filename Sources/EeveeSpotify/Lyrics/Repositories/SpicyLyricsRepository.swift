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

    // ── Developer API ────────────────────────────────────────────────────
    // /query above is the Spicetify extension's internal API: without the
    // desktop-browser headers faked below it answers 418 and asks third
    // parties to use the developer API instead, and with them it hands out
    // inconsistent fidelity (the same track Syllable one day, Static the
    // next). The developer API (https://developers.spicylyrics.org) is the
    // supported route: plain JSON, no Spotify token, consistent results.
    //
    // It needs a *client* key (sl_pk_…) created with "Allow requests with
    // no Origin header" — never a secret sl_sk_ key, which must not ship in
    // a client. The bundled key's rate limit is shared by every install, so
    // users can set their own key in Lyrics settings. With no key at all,
    // the legacy /query path below is still used.
    private static let developerApiUrl = "https://api.spicylyrics.org/v1/lyrics"
    static let bundledClientKey = ""

    private static var developerApiKey: String? {
        let userKey = UserDefaults.spicyLyricsApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !userKey.isEmpty { return userKey }
        return bundledClientKey.isEmpty ? nil : bundledClientKey
    }
    private static let authHeaderKey = "SpicyLyrics-WebAuth"
    // Bumped to match the real client's shipped ProjectVersion
    // (project/config.ts). Version alone was a dead end for the
    // Static/Line-vs-Syllable discrepancy — see the "X-mode" header below,
    // added alongside this bump, which is the actual missing piece.
    private static let clientVersion = "6.3.20"

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
        if let key = SpicyLyricsRepository.developerApiKey {
            let (data, status) = try withQueuedRetries(trackId: trackId) {
                try performDeveloperRequest(trackId: trackId, key: key)
            }
            if status != 401 && status != 403 { return data }
            // A rejected key shouldn't take lyrics down with it.
            writeDebugLog("[SpicyLyrics] Developer API rejected the key (\(status)) — falling back to /query")
        }
        return try withQueuedRetries(trackId: trackId) {
            try performQueryOnce(trackId: trackId)
        }.0
    }

    private func withQueuedRetries(trackId: String, _ attempt: () throws -> (Data, Int)) throws -> (Data, Int) {
        for (index, delay) in ([0.0] + SpicyLyricsRepository.queuedRetryDelays).enumerated() {
            if delay > 0 {
                writeDebugLog("[SpicyLyrics] Track \(trackId) queued (503) — retrying in \(delay)s (attempt \(index + 1))")
                Thread.sleep(forTimeInterval: delay)
            }
            let result = try attempt()
            if result.1 != 503 { return result }
        }
        writeDebugLog("[SpicyLyrics] Track \(trackId) still queued after all retries — giving up")
        throw LyricsError.noSuchSong
    }

    /// GET /v1/lyrics/{trackId}. Returns the raw response and its status —
    /// the body's own `Status` field, which mirrors the HTTP one.
    private func performDeveloperRequest(trackId: String, key: String) throws -> (Data, Int) {
        guard let url = URL(string: "\(SpicyLyricsRepository.developerApiUrl)/\(trackId)") else {
            throw LyricsError.decodingError
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

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
            writeDebugLog("[SpicyLyrics] Developer API network error for \(trackId): \(error)")
            throw error
        }
        guard let data = responseData else { throw LyricsError.decodingError }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let status = json?["Status"] as? Int ?? responseStatus
        writeDebugLog("[SpicyLyrics] Developer API \(status), \(data.count) bytes for \(trackId)")
        return (data, status)
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

    // MARK: - Fidelity cache
    //
    // The API doesn't return the same thing for a track every time: the same
    // track id comes back as Syllable, then Line, then Static hours later
    // (seen in debug logs — e.g. one track Syllable on two days, Static on two
    // others, identical request each time). The real client never notices,
    // because it keeps every successful response in its LyricsStore cache and
    // serves that before asking the API again (fetchLyrics.ts). Without a
    // cache here, every play gambled on whatever the server felt like
    // returning, which is what showed up as "lyrics not synced yet" for
    // tracks that are word-synced in the desktop extension.
    //
    // So: remember the best response per track on disk, serve a cached
    // Syllable response straight away, and never let a fresh response
    // downgrade a better cached one.

    private static let syllableFidelity = 3

    private func bestAvailableData(trackId: String) throws -> Data {
        let cached = SpicyLyricsCache.load(trackId: trackId)
        let cachedFidelity = cached.map(SpicyLyricsRepository.fidelity(of:)) ?? 0

        if let cached = cached, cachedFidelity == SpicyLyricsRepository.syllableFidelity {
            writeDebugLog("[SpicyLyrics] Serving cached Syllable response for \(trackId)")
            return cached
        }

        let fresh: Data
        do {
            fresh = try performQuery(trackId: trackId)
        } catch {
            if let cached = cached, cachedFidelity > 0 {
                writeDebugLog("[SpicyLyrics] Query failed for \(trackId) (\(error)) — serving cached response")
                return cached
            }
            throw error
        }

        let freshFidelity = SpicyLyricsRepository.fidelity(of: fresh)
        if let cached = cached, cachedFidelity > freshFidelity {
            writeDebugLog("[SpicyLyrics] Server downgraded \(trackId) (fidelity \(freshFidelity) < cached \(cachedFidelity)) — serving cached response")
            return cached
        }
        if freshFidelity > 0 {
            SpicyLyricsCache.save(fresh, trackId: trackId)
        }
        return fresh
    }

    /// Syllable 3, Line 2, Static 1; 0 for anything that isn't a usable 200.
    private static func fidelity(of data: Data) -> Int {
        switch (try? lyricsRoot(from: data, trackId: nil))?["Type"]?.stringValue {
        case "Syllable": return syllableFidelity
        case "Line":     return 2
        case "Static":   return 1
        default:         return 0
        }
    }

    // MARK: - Parse

    /// Unwraps either response format into the lyrics object itself:
    /// the developer API's `{Body, Status}` JSON, or /query's envelope with
    /// its SLObjPack-encoded `data`. Throws for anything but a usable 200.
    /// `trackId` is only for logging; nil keeps it quiet.
    private static func lyricsRoot(from data: Data, trackId: String?) throws -> SLObjPackValue {
        func log(_ message: String) {
            if let trackId = trackId { writeDebugLog("[SpicyLyrics] \(message) for \(trackId)") }
        }
        let rawBody = { String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>" }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log("Malformed response: \(rawBody())")
            throw LyricsError.decodingError
        }

        let httpStatus: Int
        let body: SLObjPackValue?
        if let developerBody = json["Body"] {
            httpStatus = json["Status"] as? Int ?? 0
            body = SLObjPackValue(json: developerBody)
        } else {
            // The server may prepend extra entries ahead of the real query
            // result (e.g. a "_notice" block with no "operationId"/"result").
            // The real Spicetify client never assumes index 0 — it looks
            // results up by operationId via queries.get("0") — so we match
            // that instead of blindly taking queriesRaw.first.
            guard
                let queriesRaw = json["queries"] as? [[String: Any]],
                let matchedQuery = queriesRaw.first(where: { $0["operationId"] as? String == "0" }),
                let result = matchedQuery["result"] as? [String: Any]
            else {
                log("No matching operationId 0: \(rawBody())")
                throw LyricsError.decodingError
            }
            httpStatus = result["httpStatus"] as? Int ?? 0
            if httpStatus == 200, let rawData = result["data"] {
                do {
                    body = try SLObjPack.unpack(rawData)
                } catch {
                    log("SLObjPack error \(error)")
                    throw LyricsError.decodingError
                }
            } else {
                body = nil
            }
        }

        log("API status \(httpStatus)")

        switch httpStatus {
        case 200:
            break
        case 401, 403:
            // /query: the Spotify token was stale or rejected. Clear it so
            // the next attempt re-waits for a fresh one.
            log("Auth error \(httpStatus) — clearing cached token")
            spotifyAccessToken = nil
            throw LyricsError.noSuchSong
        default:
            throw LyricsError.noSuchSong
        }

        guard let body = body else { throw LyricsError.decodingError }
        return body
    }

    private func parseLyricsData(_ data: Data, trackId: String, query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        let packed = try SpicyLyricsRepository.lyricsRoot(from: data, trackId: trackId)

        guard let type = packed["Type"]?.stringValue else {
            writeDebugLog("[SpicyLyrics] Missing Type for \(trackId)")
            throw LyricsError.decodingError
        }

        writeDebugLog("[SpicyLyrics] Lyrics type=\(type) for \(trackId)")

        var dto: LyricsDto
        switch type {
        case "Syllable": dto = parseSyllableLyrics(packed, trackId: trackId, query: query, options: options)
        case "Line":     dto = parseLineLyrics(packed)
        case "Static":   dto = parseStaticLyrics(packed)
        default:
            writeDebugLog("[SpicyLyrics] Unknown type '\(type)' for \(trackId)")
            throw LyricsError.decodingError
        }
        dto.providerName = SpicyLyricsAttribution(root: packed).nativeProviderLine
        return dto
    }

    // MARK: Syllable lyrics

    private func parseSyllableLyrics(_ root: SLObjPackValue, trackId: String, query: LyricsSearchQuery, options: LyricsOptions) -> LyricsDto {
        guard let content = root["Content"]?.arrayValue else { return emptyDto() }

        var lines        = [LyricsLineDto]()
        var karaokeLines = [KaraokeLineDto]()
        var hasRomanized = root["HasTransliterations"]?.boolValue ?? false

        for entry in content {
            guard entry["Type"]?.stringValue == "Vocal" else { continue }
            let lead = entry["Lead"]

            let karaokeSyllables = SpicyLyricsRepository.karaokeSyllables(from: lead?["Syllables"]?.arrayValue ?? [])

            // Background vocals — one or more groups, each with its own
            // syllable timing. Groups are joined in order; the view renders
            // them as one smaller row under the lead, same as Syllable.ts.
            var backgroundSyllables = [KaraokeSyllableDto]()
            for group in entry["Background"]?.arrayValue ?? [] {
                let groupSyllables = SpicyLyricsRepository.karaokeSyllables(from: group["Syllables"]?.arrayValue ?? [])
                guard !groupSyllables.isEmpty else { continue }
                if var last = backgroundSyllables.popLast() {
                    last.isPartOfWord = false
                    backgroundSyllables.append(last)
                }
                backgroundSyllables.append(contentsOf: groupSyllables)
            }

            let lineText: String
            if !karaokeSyllables.isEmpty {
                lineText = SpicyLyricsRepository.flattenedText(karaokeSyllables)
            } else if let text = lead?["Text"]?.stringValue, !text.isEmpty {
                lineText = text
            } else if !backgroundSyllables.isEmpty {
                // Background-only line (the real client's IsEmptyLyricsLine
                // keeps these) — the native screen gets the background text.
                lineText = "(\(SpicyLyricsRepository.flattenedText(backgroundSyllables)))"
            } else {
                continue
            }

            let transliterated = (lead?["Syllables"]?.arrayValue ?? []).contains {
                ($0["TransliteratedText"]?.stringValue ?? "").isEmpty == false
            }
            if transliterated || (lead?["TransliteratedText"]?.stringValue ?? "").isEmpty == false {
                hasRomanized = true
            }

            let firstSyllableMs = (karaokeSyllables.first ?? backgroundSyllables.first)?.startMs ?? 0
            let lastSyllableMs = max(karaokeSyllables.last?.endMs ?? 0, backgroundSyllables.last?.endMs ?? 0)
            let lineStartMs = lead?["StartTime"]?.doubleValue.map { Int($0 * 1000) } ?? firstSyllableMs
            let lineEndMs = max(
                lead?["EndTime"]?.doubleValue.map { Int($0 * 1000) } ?? lineStartMs,
                lastSyllableMs
            )

            lines.append(LyricsLineDto(
                content: lineText.lyricsNoteIfEmpty,
                offsetMs: lineStartMs,
                syllables: karaokeSyllables.isEmpty ? nil : karaokeSyllables,
                endMs: lineEndMs
            ))

            if !karaokeSyllables.isEmpty || !backgroundSyllables.isEmpty {
                karaokeLines.append(KaraokeLineDto(
                    syllables: karaokeSyllables,
                    startMs: lineStartMs,
                    endMs: lineEndMs,
                    background: backgroundSyllables,
                    oppositeAligned: entry["OppositeAligned"]?.boolValue ?? false
                ))
            }
        }

        let romanization: LyricsRomanizationStatus = hasRomanized
            ? .romanized
            : (lines.map(\.content).canBeRomanized ? .canBeRomanized : .original)

        if !karaokeLines.isEmpty {
            let songWriters = root["SongWriters"]?.arrayValue?.compactMap { $0.stringValue } ?? []
            let attribution = SpicyLyricsAttribution(root: root)

            let filledKaraokeLines = LyricsUncensorFill.fillKaraoke(
                lines: karaokeLines,
                query: query,
                options: options
            )
            // Interludes are inserted last: LyricsUncensorFill matches
            // karaoke lines against other providers' lines by index, so the
            // synthesized dot lines must not exist yet at that point.
            let normalizedKaraokeLines = SpicyLyricsRepository.insertInterludes(
                SpicyLyricsRepository.normalizeMonotonicTiming(filledKaraokeLines)
            )

            KaraokeLyricsStore.shared.set(
                trackId: trackId,
                lyrics: KaraokeLyricsDto(
                    lines: normalizedKaraokeLines,
                    songWriters: songWriters,
                    providerCode: attribution.providerCode,
                    providerDisplayName: attribution.providerDisplayName,
                    uploader: attribution.uploader,
                    maker: attribution.maker
                )
            )
            writeDebugLog("[SpicyLyrics] Stored karaoke data: \(karaokeLines.count) lines for \(trackId)")
        }

        return LyricsDto(lines: lines, timeSynced: true, romanization: romanization)
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
            // Background vocals legitimately overlap the lead, so they're
            // only clamped against themselves, within the line.
            var previousBackgroundEndMs = Int.min
            for syllableIndex in result[lineIndex].background.indices {
                var syllable = result[lineIndex].background[syllableIndex]
                syllable.startMs = max(syllable.startMs, previousBackgroundEndMs)
                syllable.endMs = max(syllable.endMs, syllable.startMs)
                previousBackgroundEndMs = syllable.endMs
                result[lineIndex].background[syllableIndex] = syllable
            }
        }
        return result
    }

    // MARK: Syllable helpers

    private static func karaokeSyllables(from values: [SLObjPackValue]) -> [KaraokeSyllableDto] {
        values.compactMap { syllable in
            guard let text = syllable["Text"]?.stringValue, !text.isEmpty else { return nil }
            let startMs = syllable["StartTime"]?.doubleValue.map { Int($0 * 1000) } ?? 0
            let endMs   = syllable["EndTime"]?.doubleValue.map { Int($0 * 1000) } ?? startMs
            return KaraokeSyllableDto(
                text: text,
                startMs: startMs,
                endMs: endMs,
                isPartOfWord: syllable["IsPartOfWord"]?.boolValue ?? false
            )
        }
    }

    /// Joins syllables into running text. Real client rule (Syllable.ts /
    /// tools.ts): IsPartOfWord is a FORWARD-looking flag — a syllable with
    /// IsPartOfWord=true glues onto the *next* one ("Lo" + "la" -> "Lola"),
    /// so the space before a syllable depends on the *previous* syllable's
    /// flag. Same rule as KaraokeLineDto.plainText.
    private static func flattenedText(_ syllables: [KaraokeSyllableDto]) -> String {
        KaraokeLineDto(syllables: syllables, startMs: 0, endMs: 0).plainText
    }

    /// Matches getLyricsBetweenShow() in the real extension's lyrics.ts —
    /// a gap this long (or a first line starting this late) gets a
    /// "• • •" musical line.
    private static let interludeThresholdMs = 3000
    /// Matches getInterludeTimePadding() (preHiddenDotLineMs + 50): the
    /// dots finish filling this long before the next line starts, so the
    /// dot line has time to fade out instead of vanishing mid-fill.
    private static let interludePaddingMs = 550

    private static func insertInterludes(_ lines: [KaraokeLineDto]) -> [KaraokeLineDto] {
        guard let first = lines.first else { return lines }

        func interlude(from startMs: Int, to endMs: Int, oppositeAligned: Bool) -> KaraokeLineDto {
            let fillEndMs = max(startMs, endMs - interludePaddingMs)
            let dotMs = (fillEndMs - startMs) / 3
            let dots = (0 ..< 3).map { index in
                KaraokeSyllableDto(
                    text: "•",
                    startMs: startMs + dotMs * index,
                    endMs: index == 2 ? fillEndMs : startMs + dotMs * (index + 1),
                    isPartOfWord: false
                )
            }
            return KaraokeLineDto(
                syllables: dots,
                startMs: startMs,
                endMs: endMs,
                oppositeAligned: oppositeAligned,
                isInterlude: true
            )
        }

        var result = [KaraokeLineDto]()
        if first.startMs >= interludeThresholdMs {
            result.append(interlude(from: 0, to: first.startMs, oppositeAligned: first.oppositeAligned))
        }
        for (index, line) in lines.enumerated() {
            result.append(line)
            guard index + 1 < lines.count else { continue }
            let next = lines[index + 1]
            if next.startMs - line.endMs >= interludeThresholdMs {
                result.append(interlude(from: line.endMs, to: next.startMs, oppositeAligned: next.oppositeAligned))
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
        let data = try bestAvailableData(trackId: trackId)
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

// MARK: - SpicyLyricsCache

/// On-disk store of the best SpicyLyrics API response seen per track — the
/// iOS counterpart of the real extension's LyricsStore — kept for at most
/// 30 days per the developer API terms. Raw response bytes are
/// kept as-is so a cache hit goes through exactly the same parse path as a
/// fresh response. Lives in Caches, so iOS may purge it under storage
/// pressure; that only costs a refetch.
enum SpicyLyricsCache {
    private static let maxEntries = 1000

    private static let directory: URL? = {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let url = caches.appendingPathComponent("EeveeSpicyLyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private static func fileURL(trackId: String) -> URL? {
        // Spotify track ids are base62; anything else is not a cache key.
        guard !trackId.isEmpty, trackId.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            return nil
        }
        return directory?.appendingPathComponent("\(trackId).json")
    }

    /// The developer API's terms: refetch or discard every stored response
    /// within 30 days.
    private static let maxAge: TimeInterval = 30 * 24 * 60 * 60

    static func load(trackId: String) -> Data? {
        guard let url = fileURL(trackId: trackId) else { return nil }
        let written = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let written = written, Date().timeIntervalSince(written) > maxAge {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return try? Data(contentsOf: url)
    }

    static func save(_ data: Data, trackId: String) {
        guard let url = fileURL(trackId: trackId) else { return }
        try? data.write(to: url, options: .atomic)
        pruneIfNeeded()
    }

    /// Drops the least recently written entries once the cache grows past
    /// maxEntries, so it can't grow without bound.
    private static func pruneIfNeeded() {
        guard
            let directory = directory,
            let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey]
            ),
            files.count > maxEntries
        else { return }

        let sorted = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a < b
        }
        for file in sorted.prefix(files.count - maxEntries) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

// MARK: - Attribution

/// Who to credit for a response, read from the response itself as the
/// developer API's attribution rules require: always the provider, and for
/// community syncs (`source == "spicy_lyrics"`) the uploader and maker too.
struct SpicyLyricsAttribution {
    let providerCode: String?
    let providerDisplayName: String?
    let uploader: KaraokeCreditDto?
    let maker: KaraokeCreditDto?

    init(root: SLObjPackValue) {
        providerCode = root["source"]?.stringValue
        providerDisplayName = providerCode == "ext" ? root["sourceName"]?.stringValue : nil
        let upload = root["UploadAttribution"]
        uploader = KaraokeCreditDto(upload?["Uploader"])
        maker = KaraokeCreditDto(upload?["Maker"])
    }

    /// Spotify's native lyrics screen only has the one "provided by" string,
    /// so everything owed goes into it.
    var nativeProviderLine: String {
        let provider = KaraokeCreditDto.providerLabel(code: providerCode, displayName: providerDisplayName)
        var parts = [provider.map { $0 == "Spicy Lyrics" ? $0 : "\($0) via Spicy Lyrics" } ?? "Spicy Lyrics"]
        if let maker = maker { parts.append("synced by \(maker.name)") }
        if let uploader = uploader, uploader.name != maker?.name { parts.append("uploaded by \(uploader.name)") }
        return parts.joined(separator: ", ")
    }
}

extension KaraokeCreditDto {
    init?(_ value: SLObjPackValue?) {
        guard let value = value,
              let name = value["username"]?.stringValue ?? value["name"]?.stringValue,
              !name.isEmpty else { return nil }
        self.init(name: name, url: value["url"]?.stringValue.flatMap(URL.init(string:)))
    }
}

// MARK: - JSON bridge

extension SLObjPackValue {
    /// Bridges a JSONSerialization value (developer API responses) into the
    /// same value type /query responses unpack to, so both share one parser.
    init(json: Any) {
        switch json {
        case let number as NSNumber:
            self = CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(array.map(SLObjPackValue.init(json:)))
        case let object as [String: Any]:
            self = .object(object.mapValues(SLObjPackValue.init(json:)))
        default:
            self = .null
        }
    }
}
