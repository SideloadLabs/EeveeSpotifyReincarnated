import Foundation

let japanese = LyricsRomanization.prefersJapaneseReadings(["走る新幹線", "さくら"])
precondition(japanese)
let train = LyricsRomanization.romanizeLine("走る新幹線", japanese: japanese).lowercased()
precondition(train.contains("shinkansen") && !train.contains("xin"))
precondition(LyricsRomanization.romanizeLine("「さくら」", japanese: japanese) == "「sakura」")
precondition(LyricsRomanization.romanizeLine("Hello", japanese: japanese) == "Hello")
precondition(LyricsRomanization.romanizeLine("", japanese: japanese).isEmpty)

let chinese = LyricsRomanization.prefersJapaneseReadings(["北京", "你好"])
precondition(!chinese)
let beijing = LyricsRomanization.romanizeLine("北京", japanese: chinese)
    .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
precondition(beijing.contains("bei") && beijing.contains("jing"))

precondition(LyricsRomanization.romanizeLine("さくら髙﨑", japanese: true) == "sakura髙﨑")
precondition(!LyricsRomanization.prefersJapaneseReadings(["北京・上海"]))
precondition(LyricsRomanization.prefersJapaneseReadings(["新幹線ﾃﾞ"]))

let oversized = String(repeating: "さ", count: 6000)
precondition(!LyricsRomanization.prefersJapaneseReadings([oversized]))
precondition(LyricsRomanization.romanizeLine(oversized, japanese: true) == oversized)
