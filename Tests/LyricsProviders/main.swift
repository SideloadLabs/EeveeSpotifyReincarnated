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
}

final class KaraokeLyricsStore {
    static let shared = KaraokeLyricsStore()
    private(set) var publications = 0
    func set(trackId: String, lyrics: KaraokeLyricsDto) { publications += 1 }
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
// Upstream providers create their own sessions; route them to the fixture.
extension URLSessionConfiguration {
    @objc class func fixtureDefault() -> URLSessionConfiguration {
        let configuration = fixtureDefault()
        configuration.protocolClasses = [ProviderFixture.self]
        return configuration
    }
    @objc class func fixtureEphemeral() -> URLSessionConfiguration {
        let configuration = fixtureEphemeral()
        configuration.protocolClasses = [ProviderFixture.self]
        return configuration
    }
}
for (original, fixture) in [("defaultSessionConfiguration", #selector(URLSessionConfiguration.fixtureDefault)),
                            ("ephemeralSessionConfiguration", #selector(URLSessionConfiguration.fixtureEphemeral))] {
    method_exchangeImplementations(class_getClassMethod(URLSessionConfiguration.self, NSSelectorFromString(original))!,
                                   class_getClassMethod(URLSessionConfiguration.self, fixture)!)
}
let options = UserDefaults.lyricsOptions
let query = LyricsSearchQuery(title: "Song", primaryArtist: "Artist", spotifyTrackId: "0000000000000000000001")
let lrc = LrclibLyricsRepository.shared
let petit = PetitLyricsRepository()
let genius = GeniusLyricsRepository()
let spicy = SpicyLyricsRepository.shared

func fetch(_ repo: LyricsRepository, _ replies: [ProviderFixture.Reply]) throws -> LyricsDto {
    ProviderFixture.replies = replies
    defer { precondition(ProviderFixture.replies.isEmpty, "a reply was not requested") }
    return try repo.getLyrics(query, options: options)
}
func download(_ repo: LyricsRepository, _ replies: [ProviderFixture.Reply]) throws -> LyricsDto {
    try LyricsDownloadHTTP.perform(isCancelled: { false }) { try fetch(repo, replies) }
}

// Playback and downloads read the same provider answer the same way.
let lrcBody = #"{"name":"Song","instrumental":false,"plainLyrics":"first\nlast"}"#
let result1 = try fetch(lrc, [.http(200, lrcBody)])
precondition(result1.lines.map(\.content) == ["first"])
let result2 = try download(lrc, [.http(200, lrcBody)])
precondition(result2.lines.map(\.content) == ["first"])
let result3 = try fetch(lrc, [.http(200, #"{"name":"Song","instrumental":true}"#)])
precondition(result3.lines.isEmpty)

// Lrclib: a failed request stays "no such song" in playback, as upstream. A
// download sees the failure, and only LRCLIB's own 404 is a missing song.
do { _ = try fetch(lrc, [.http(500, "{}"), .http(500, "{}")]); fatalError("playback failure changed") } catch LyricsError.noSuchSong {}
do { _ = try download(lrc, [.http(404, "{}"), .http(404, "{}")]); fatalError("missing accepted") } catch LyricsError.noSuchSong {}
do { _ = try download(lrc, [.http(500, "{}"), .http(500, "{}")]); fatalError("server error accepted") }
catch let error as LyricsProviderHTTPError { precondition(error.status == 500) }

// Offline is a transport error for every provider, not a missing song.
for (repository, replies) in [(lrc, 2), (petit, 1), (genius, 1), (spicy, 1)] as [(LyricsRepository, Int)] {
    do { _ = try download(repository, Array(repeating: .offline, count: replies)); fatalError("offline accepted") }
    catch let error as URLError { precondition(error.code == .notConnectedToInternet) }
}

let search = #"{"response":{"sections":[{"hits":[{"result":{"id":12,"title":"Song","artist_names":"Artist"}}]}]}}"#
let song = #"{"response":{"song":{"language":"en","lyrics":{"plain":"[Verse]\nkeep this line"}}}}"#
let result4 = try download(genius, [.http(200, search), .http(200, song)])
precondition(result4.lines.map(\.content) == ["keep this line"])

func petitXML(_ text: String) -> String {
    let data = Data(text.utf8).base64EncodedString()
    return "<response><songs><song><lyricsId>1</lyricsId><title>Song</title><availableLyricsType>1</availableLyricsType><lyricsType>1</lyricsType><lyricsData>\(data)</lyricsData></song></songs></response>"
}
let xml = petitXML("first\nlast")
let result5 = try download(petit, [.http(200, xml), .http(200, xml)])
precondition(result5.lines.map(\.content) == ["first", "last"])

// Spicy publishes karaoke for the playing song only; a download leaves the
// small karaoke store to playback. A queued (503) download is retried later.
let spicyLine = #"{"Type":"Line","Content":[{"Type":"Vocal","Text":"words","StartTime":2.5,"EndTime":3}]}"#
let result6 = try fetch(spicy, [.http(200, spicyLine)])
precondition(result6.lines.first?.offsetMs == 2500 && KaraokeLyricsStore.shared.publications == 1)
let result7 = try download(spicy, [.http(200, spicyLine)])
precondition(result7.lines.first?.content == "words" && KaraokeLyricsStore.shared.publications == 1)
do { _ = try download(spicy, [.http(503, "")]); fatalError("queued accepted") }
catch let error as LyricsProviderHTTPError { precondition(error.status == 503) }
do { _ = try download(spicy, [.http(404, "")]); fatalError("missing accepted") } catch LyricsError.noSuchSong {}
do { _ = try fetch(spicy, [.http(500, "{}")]); fatalError("playback failure changed") } catch LyricsError.noSuchSong {}
print("Providers: playback unchanged; downloads read the same text and keep failures apart from missing songs")
