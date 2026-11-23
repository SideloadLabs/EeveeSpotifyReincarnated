import Foundation

final class NativeOfflineLyrics {
    static let shared = NativeOfflineLyrics()
    var saved: Set<String> = []
    func hasProviderLyrics(trackId: String) -> Bool { saved.contains(trackId) }
}
var logged: [String] = []
func writeDebugLog(_ message: String) { logged.append(message) }

func check(_ value: Bool, _ message: String) {
    if !value { fatalError(message) }
}
func bytes(_ base64: String) -> Data { Data(base64Encoded: base64)! }

// Real /scrollsita/v1/scroll responses from Spotify 9.2.2.
// GONE.Fludd "Высоко": Spotify has no lyrics of its own, so no lyrics card.
let withoutCard = bytes("Cq8CCmEaNAoyCjBHT05FLkZsdWRkOiDQtdGJ0LUg0LHQvtC70YzRiNC1INC60L7QvdGC0LXQvdGC0LC6ASgKJnNwb3RpZnk6c2VjdGlvbjowSlE1REFCUnRGV0FwY3k2MVhKRXd0CskBIpsBCiRzcG90aWZ5OnRyYWNrOjJDV0VrOE5LM2FCSWE5MWVVcUZmazASJXNwb3RpZnk6YXJ0aXN0OjBvaFV2VnNrRVJ6SzE4YnZXWEZFcWkSJXNwb3RpZnk6YXJ0aXN0OjY4VFBNdElCMmlwd0Q0ZEtNblE0S1ESJXNwb3RpZnk6YXJ0aXN0OjNDMm9XblZONVdEMU5wQ2M1TmxZSXq6ASgKJnNwb3RpZnk6c2VjdGlvbjowSlE1REI2czNjc3NXNUJvNmNHcTFPEiYKJGFhOTk0Y2NmLTZlY2YtMmU1ZS0zMzUzLTliMjliZjc5MWZkOA==")
// A CUPSIZE song: Spotify has lyrics, and its lyrics card comes first.
let withCard = bytes("CtkCClMqJgokc3BvdGlmeTp0cmFjazo1ckdIYmhiUnFMTkxITVA2YzhkbDFiugEoCiZzcG90aWZ5OnNlY3Rpb246MEpRNURCNnMzY3NzVzVCbzZjR3EyMQqhASJ0CiRzcG90aWZ5OnRyYWNrOjVyR0hiaGJScUxOTEhNUDZjOGRsMWISJXNwb3RpZnk6YXJ0aXN0OjZwaWFSQlNrNzloZm9ISU55N0RNR08SJXNwb3RpZnk6YXJ0aXN0OjFtZUFra0F0d3lBZnFDYU5UWmxKRTK6ASgKJnNwb3RpZnk6c2VjdGlvbjowSlE1REI2czNjc3NXNUJvNmNHcTFPCl4aMQovCi1DVVBTSVpFOiDQtdGJ0LUg0LHQvtC70YzRiNC1INC60L7QvdGC0LXQvdGC0LC6ASgKJnNwb3RpZnk6c2VjdGlvbjowSlE1REFCUnRGV0FwY3k2MVhKRXd0EiYKJDk1ZTdjMGUzLTMxNTgtMGY5OS1jMTVhLThjMjZiMDBhZTA4Zg==")
// "Высоко" with the server's own CUPSIZE lyrics card (track id swapped) placed first.
let expected = bytes("CoQDClMqJgokc3BvdGlmeTp0cmFjazoyQ1dFazhOSzNhQklhOTFlVXFGZmswugEoCiZzcG90aWZ5OnNlY3Rpb246MEpRNURCNnMzY3NzVzVCbzZjR3EyMQphGjQKMgowR09ORS5GbHVkZDog0LXRidC1INCx0L7Qu9GM0YjQtSDQutC+0L3RgtC10L3RgtCwugEoCiZzcG90aWZ5OnNlY3Rpb246MEpRNURBQlJ0RldBcGN5NjFYSkV3dArJASKbAQokc3BvdGlmeTp0cmFjazoyQ1dFazhOSzNhQklhOTFlVXFGZmswEiVzcG90aWZ5OmFydGlzdDowb2hVdlZza0VSeksxOGJ2V1hGRXFpEiVzcG90aWZ5OmFydGlzdDo2OFRQTXRJQjJpcHdENGRLTW5RNEtREiVzcG90aWZ5OmFydGlzdDozQzJvV25WTjVXRDFOcENjNU5sWUl6ugEoCiZzcG90aWZ5OnNlY3Rpb246MEpRNURCNnMzY3NzVzVCbzZjR3ExTxImCiRhYTk5NGNjZi02ZWNmLTJlNWUtMzM1My05YjI5YmY3OTFmZDg=")

let track = "2CWEk8NK3aBIa91eUqFfk0"
check(NativeLyricsCard.adding(trackId: track, to: withoutCard) == expected,
      "the added card differs from the server's own lyrics card, or other cards changed")
check(NativeLyricsCard.adding(trackId: "5rGHbhbRqLNLHMP6c8dl1b", to: withCard) == nil,
      "a second lyrics card was added to a song that has one")
check(NativeLyricsCard.adding(trackId: track, to: Data([0xff, 0xff, 0xff])) == nil, "malformed bytes were rewritten")
check(NativeLyricsCard.adding(trackId: track, to: Data()) == nil, "an empty response was rewritten")
check(NativeLyricsCard.adding(trackId: track, to: withoutCard.prefix(withoutCard.count - 5)) == nil,
      "a truncated response was rewritten")

let url = URL(string: "https://spclient.wg.spotify.com/scrollsita/v1/scroll/spotify:track:\(track)")!
check(NativeLyricsCard.insert(into: withoutCard, url: url) == nil, "a card was added without saved lyrics")
NativeOfflineLyrics.shared.saved = [track]
check(NativeLyricsCard.insert(into: withoutCard, url: url) == expected, "saved lyrics did not add the card")
check(NativeLyricsCard.insert(into: withoutCard, url: URL(string: "https://spclient.wg.spotify.com/casita/v1/home")!) == nil,
      "a card was added to another feed")
print("NativeLyricsCard: server-identical card, existing card kept, malformed and unsaved responses untouched passed")
