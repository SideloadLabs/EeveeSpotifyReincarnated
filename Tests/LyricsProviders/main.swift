import Foundation

// Host substitutes for the app's localized UI and protobuf payload.
enum EeveeSpotify { static let version = "test" }
enum URLSessionHelper { static let CFNetworkVersion = "test", DarwinVersion = "test" }
func writeDebugLog(_ value: String) {}
func eeveeLog(_ format: String, _ args: CVarArg...) {}
extension String {
    var localized: String { self }
    var strippedTrackTitle: String { components(separatedBy: " (").first ?? self }
    var lyricsNoteIfEmpty: String { isEmpty ? "♪" : self }
    var isCanBeRomanizedLanguage: Bool { false }
    func firstMatch(_ pattern: String) -> NSTextCheckingResult? {
        try! NSRegularExpression(pattern: pattern).firstMatch(in: self, range: NSRange(startIndex..., in: self))
    }
    static func ~= (lhs: String, rhs: String) -> Bool { lhs.firstMatch(rhs) != nil }
    func containsInsensitive(_ other: String) -> Bool { localizedCaseInsensitiveContains(other) }
}
extension Array where Element == String { var canBeRomanized: Bool { false } }
extension UserDefaults {
    static let lyricsOptions = LyricsOptions(romanization: false, lrclibUrl: "https://127.0.0.1/api",
        geniusFallback: false, showFallbackReasons: false, hideOnError: false)
    static let effectiveSpicyLyricsApiKey = "test"
}
struct LyricsDto {
    var lines: [LyricsLineDto]
    var timeSynced: Bool
    var romanization: LyricsRomanizationStatus
    var providerCredit: String?
    var karaoke: KaraokeLyricsDto?
}

final class ProviderFixture: URLProtocol {
    enum Reply { case http(Int, String), offline }
    static var replies: [Reply] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        precondition(!Self.replies.isEmpty, "unexpected extra request to \(String(describing: request.url))")
        switch Self.replies.removeFirst() {
        case .offline: client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        case .http(let status, let body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
func configuration() -> URLSessionConfiguration {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ProviderFixture.self]
    return config
}
let options = UserDefaults.lyricsOptions
let query = LyricsSearchQuery(title: "Song", primaryArtist: "Artist", spotifyTrackId: "0000000000000000000001")
let lrc = LrclibLyricsRepository(apiUrl: options.lrclibUrl, configuration: configuration())
let petit = PetitLyricsRepository(configuration: configuration())
let genius = GeniusLyricsRepository(configuration: configuration())
let spicy = SpicyLyricsRepository(configuration: configuration())
for repository: LyricsRepository in [lrc, petit, genius, spicy] {
    ProviderFixture.replies = [.offline]
    do {
        _ = try repository.getLyrics(query, options: options)
        fatalError("offline response accepted")
    } catch let error as URLError { precondition(error.code == .notConnectedToInternet) }
    precondition(ProviderFixture.replies.isEmpty)
}

func fetch(_ repo: LyricsRepository, _ replies: [ProviderFixture.Reply]) throws -> LyricsDto {
    ProviderFixture.replies = replies
    defer { precondition(ProviderFixture.replies.isEmpty) }
    return try repo.getLyrics(query, options: options)
}
let plain = try fetch(lrc, [.http(200, #"{"name":"Song","instrumental":false,"plainLyrics":"first\nlast"}"#)])
precondition(plain.lines.map(\.content) == ["first", "last"])
let synced = try fetch(lrc, [.http(200, #"{"name":"Song","instrumental":false,"syncedLyrics":"[:33]broken\n[9999999999:02]huge\n[01:02.50]last"}"#)])
precondition(synced.lines.map(\.offsetMs) == [62500])
do { _ = try fetch(lrc, [.http(404, "{}")]); fatalError("missing accepted") } catch LyricsError.noSuchSong {}
do { _ = try fetch(lrc, [.http(500, "{}")]); fatalError("error accepted") } catch is LyricsProviderHTTPError {}
let instrumental = try fetch(lrc, [.http(200, #"{"name":"Song","instrumental":true}"#)])
precondition(instrumental.lines.isEmpty)

let search = #"{"response":{"sections":[{"hits":[]},{"hits":[{"result":{"id":12,"title":"Song","artist_names":"Artist"}}]}]}}"#
let song = #"{"response":{"song":{"language":"en","lyrics":{"plain":"[Verse]\nkeep [this] line"}}}}"#
let geniusResult = try fetch(genius, [.http(200, search), .http(200, song)])
precondition(geniusResult.lines.map(\.content) == ["keep [this] line"])

func petitXML(_ text: String) -> String {
    let data = Data(text.utf8).base64EncodedString()
    return "<response><songs><song><lyricsId>1</lyricsId><title>Song</title><availableLyricsType>1</availableLyricsType><lyricsType>1</lyricsType><lyricsData>\(data)</lyricsData></song></songs></response>"
}
let xml = petitXML("first\nlast")
let petitResult = try fetch(petit, [.http(200, xml), .http(200, xml)])
precondition(petitResult.lines.map(\.content) == ["first", "last"])
do { _ = try fetch(petit, [.http(200, xml), .http(200, petitXML(" "))]); fatalError("blank saved") } catch LyricsError.decodingError {}

let spicyLine = #"{"Type":"Line","Content":[{"Type":"Vocal","Text":"words","StartTime":2.5,"EndTime":1e30}]}"#
let live = try fetch(spicy, [.http(200, spicyLine)])
precondition(live.karaoke?.lines.first?.startMs == 2500 && live.karaoke?.lines.first?.endMs == 2500)
let saved = try LyricsDownloadHTTP.perform(isCancelled: { false }) {
    try fetch(spicy, [.http(503, ""), .http(200, spicyLine)])
}
precondition(saved.lines.first?.content == "words" && saved.karaoke == nil)
do { _ = try fetch(spicy, [.http(200, #"{"Type":"Line","Content":[]}"#)]); fatalError("blank saved") } catch LyricsError.decodingError {}
print("All four provider adapters passed offline, response parsing and status regression fixtures")
