import Foundation

class PetitLyricsRepository: LyricsRepository {
    static let shared = PetitLyricsRepository()
    private let url = "https://p1.petitlyrics.com/api/GetPetitLyricsData.php"
    private let session: URLSession

    init(configuration: URLSessionConfiguration = .default) {
        configuration.httpAdditionalHeaders = [
            "Content-Type": "application/x-www-form-urlencoded"
        ]

        session = URLSession(configuration: configuration)
    }

    private func perform(_ data: [String: Any]) throws -> PetitResponse {
        var finalData = data

        finalData["clientAppId"] = "p1110417"
        finalData["terminalType"] = 10

        var request = URLRequest(url: URL(string: url)!)

        request.httpMethod = "POST"
        request.httpBody = finalData.queryString.data(using: .utf8)
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

        if let error = error {
            throw error
        }
        try LyricsDownloadHTTP.validate(httpResponse, request: request)

        if let http = httpResponse as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw LyricsProviderHTTPError(status: http.statusCode)
        }
        guard let data,
              let response = try? XMLDecoder().decode(PetitResponse.self, from: data) else {
            throw LyricsError.decodingError
        }

        return response
    }


    private func searchSong(_ title: String, artist: String) throws -> PetitSong {
        let response = try perform(
            ["key_title": title, "key_artist": artist, "max_count": 1]
        )
        
        guard let song = response.songs.first else {
            throw LyricsError.noSuchSong
        }
        
        return song
    }
    
    
    private func getSong(_ lyricsId: Int, availableLyricsType: PetitLyricsType) throws -> PetitSong {
        var lyricsType: PetitLyricsType
        
        if availableLyricsType == .linesSynced {
            lyricsType = .plain
        }
        else {
            lyricsType = availableLyricsType
        }
        
        let response = try perform(
            ["key_lyricsId": lyricsId, "lyricsType": lyricsType.rawValue]
        )
        
        guard let song = response.songs.first else {
            throw LyricsError.noSuchSong
        }
        
        return song
    }
    
    
    func getLyrics(_ query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        let searchResult = try searchSong(query.title, artist: query.primaryArtist)
        let song = try getSong(
            searchResult.lyricsId,
            availableLyricsType: searchResult.availableLyricsType
        )
        
        guard let lyricsData = Data(base64Encoded: song.lyricsData) else {
            throw LyricsError.decodingError
        }
        
        switch song.lyricsType {
            
        case .wordsSynced:
            guard let lyrics = try? XMLDecoder().decode(PetitLyricsData.self, from: lyricsData) 
            else {
                throw LyricsError.decodingError
            }
            
            guard lyrics.lines.contains(where: { !$0.linestring.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw LyricsError.decodingError
            }
            return LyricsDto(
                lines: lyrics.lines.map {
                    LyricsLineDto(
                        content: $0.linestring,
                        offsetMs: $0.words.first?.starttime ?? 0
                    )
                },
                timeSynced: true,
                romanization: lyrics.lines.map { $0.linestring }.canBeRomanized
                    ? .canBeRomanized
                    : .original
            )
            
        case .plain:
            guard let stringLyrics = String(data: lyricsData, encoding: .utf8),
                  !stringLyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LyricsError.decodingError
            }
            let lines = stringLyrics.components(separatedBy: "\n")
            
            return LyricsDto(
                lines: lines.map { LyricsLineDto(content: $0) },
                timeSynced: false,
                romanization: lines.canBeRomanized ? .canBeRomanized : .original
            )
            
        default:
            throw LyricsError.decodingError
        }
    }
}
