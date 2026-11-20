import Foundation

class GeniusLyricsRepository: LyricsRepository {
    static let shared = GeniusLyricsRepository()
    private let jsonDecoder: JSONDecoder
    private let apiUrl = "https://api.genius.com"
    private let session: URLSession

    init(configuration: URLSessionConfiguration = .default) {
        configuration.httpAdditionalHeaders = [
            "X-Genius-iOS-Version": "6.21.0",
            "X-Genius-Logged-Out": "true",
            "User-Agent": "Genius/1109 \(URLSessionHelper.CFNetworkVersion) \(URLSessionHelper.DarwinVersion)"
        ]

        session = URLSession(configuration: configuration)

        jsonDecoder = JSONDecoder()
        jsonDecoder.keyDecodingStrategy = .convertFromSnakeCase
    }

    private func perform(
        _ path: String,
        query: [String:Any] = [:]
    ) throws -> GeniusDataResponse? {
        var stringUrl = "\(apiUrl)\(path)"

        if !query.isEmpty {
            let queryString = query.queryString
            stringUrl += "?\(queryString)"
        }

        guard let url = URL(string: stringUrl) else { throw LyricsError.decodingError }
        let request = URLRequest(url: url)
        try LyricsDownloadHTTP.prepare(request)

        let semaphore = DispatchSemaphore(value: 0)
        var data: Data?
        var error: Error?
        var httpResponse: URLResponse?

        let task = session.dataTask(with: request) { response, urlResponse, err in
            error = err
            data = response
            httpResponse = urlResponse
            semaphore.signal()
        }

        try LyricsDownloadHTTP.start(task)
        try LyricsDownloadHTTP.waitForResponse(semaphore, task: task)

        if let error {
            throw error
        }
        try LyricsDownloadHTTP.validate(httpResponse, request: request)

        if let http = httpResponse as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw LyricsProviderHTTPError(status: http.statusCode)
        }
        guard let data,
              let rootResponse = try? jsonDecoder.decode(GeniusRootResponse.self, from: data) else {
            throw LyricsError.decodingError
        }
        return rootResponse.response
    }


    private func searchSong(_ query: String) throws -> [GeniusHit] {
        let data = try perform("/search/song", query: ["q": query])
        
        guard
            case .sections(let sectionsResponse) = data
        else {
            throw LyricsError.decodingError
        }
        
        return sectionsResponse.sections.flatMap(\.hits)
    }

    private func getSongInfo(_ songId: Int) throws -> GeniusSong {
        let data = try perform("/songs/\(songId)", query: ["text_format": "plain"])
        
        guard case .song(let songResponse) = data else {
            throw LyricsError.decodingError
        }
        
        return songResponse.song
    }
    
    
    private func mostRelevantHitResult(
        hits: [GeniusHit],
        strippedTitle: String,
        primaryArtist: String,
        romanized: Bool,
        hasFoundRomanizedLyrics: inout Bool
    ) -> GeniusHitResult {
        let results = hits.map { $0.result }

        let matchingByTitle = results.filter {
            $0.title.containsInsensitive(strippedTitle)
        }

        let strippedArtist = primaryArtist.strippedTrackTitle
        let matchingByBoth = matchingByTitle.filter {
            $0.artistNames.containsInsensitive(strippedArtist)
                || $0.artistNames.containsInsensitive(primaryArtist)
        }

        // Best match: title+artist → title only → first result
        let pool = !matchingByBoth.isEmpty ? matchingByBoth
                 : !matchingByTitle.isEmpty ? matchingByTitle
                 : results

        if romanized, let romanizedSong = pool.first(
            where: { $0.artistNames == "Genius Romanizations" }
        ) {
            hasFoundRomanizedLyrics = true
            return romanizedSong
        }

        return pool.first!
    }
    
    private func mapLyricsLines(_ rawLines: [String]) -> [String] {
        var lines = rawLines
            .map { $0.trimmingCharacters(in: .whitespaces) }
        
        lines.removeAll { $0 ~= "^\\[[^\\]]*\\]$" }

        lines = Array(
            lines
                .drop(while: { $0.isEmpty })
                .dropLast(while: { $0.isEmpty })
        )
        
        return lines
    }
    
    func getLyrics(_ query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        let strippedTitle = query.title.strippedTrackTitle
        let searchTitle = strippedTitle.isEmpty ? query.title : strippedTitle
        var hits = try searchSong("\(searchTitle) \(query.primaryArtist)")
        if hits.isEmpty, searchTitle != query.title {
            hits = try searchSong("\(query.title) \(query.primaryArtist)")
        }
    
        guard !hits.isEmpty else {
            throw LyricsError.noSuchSong
        }
        
        var hasFoundRomanizedLyrics = false
        
        let song = mostRelevantHitResult(
            hits: hits,
            strippedTitle: searchTitle,
            primaryArtist: query.primaryArtist,
            romanized: options.romanization,
            hasFoundRomanizedLyrics: &hasFoundRomanizedLyrics
        )
        
        let songInfo = try getSongInfo(song.id)
        let plainLines = mapLyricsLines(songInfo.lyrics.plain.components(separatedBy: "\n"))
        guard !plainLines.isEmpty else { throw LyricsError.noSuchSong }
        
        var romanization = LyricsRomanizationStatus.original
        
        if hasFoundRomanizedLyrics {
            romanization = .romanized
        }
        else if songInfo.language.isCanBeRomanizedLanguage {
            romanization = .canBeRomanized
        }
    
        return LyricsDto(
            lines: plainLines.map { line in LyricsLineDto(content: line) },
            timeSynced: false,
            romanization: romanization
        )
    }
}
