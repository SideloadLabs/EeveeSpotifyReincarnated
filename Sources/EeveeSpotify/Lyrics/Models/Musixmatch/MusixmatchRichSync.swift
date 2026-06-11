import Foundation

// Musixmatch RichSync 逐字歌词模型
struct MusixmatchRichSync: Decodable {
    let ts: Double      // 行开始时间（秒）
    let te: Double      // 行结束时间（秒）
    let l: [Word]       // 单词/字符列表
    let x: String       // 完整行文本
    
    struct Word: Decodable {
        let c: String    // 字符内容
        let o: Double    // 相对于行开始的偏移时间（秒）
    }
}