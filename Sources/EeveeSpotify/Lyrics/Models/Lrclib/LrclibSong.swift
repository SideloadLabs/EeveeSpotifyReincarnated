import Foundation

struct LrclibSong: Decodable {
    var name: String
    var plainLyrics: String?
    var syncedLyrics: String?
    var yrcLyrics: String?  // 逐字歌词字段
    var instrumental: Bool
    var translatedLyrics: String?
}
