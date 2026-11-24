import Foundation

func isUsableSavedLyrics(_ entry: OfflineLyricsStore.Entry) -> Bool { true }

func check(_ value: Bool, _ message: String) {
    if !value { fatalError(message) }
}

let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: folder) }
let options = LyricsOptions(romanization: false, lrclibUrl: "https://example.test", geniusFallback: true,
    showFallbackReasons: false, hideOnError: false)
let store = OfflineLyricsStore(directory: folder)
let track = "0123456789ABCDEFGHIJKL"
let payload = Data([1, 2, 3, 4])
try store.save(trackId: track, source: 5, options: options, data: payload)
// Reopen from disk, with no in-memory entries or network access.
let reopened = OfflineLyricsStore(directory: folder)
let entry = reopened.entry(trackId: track, source: 5, options: options)
check(entry?.data == payload, "native lyrics did not survive reopening")
let validatingStore = OfflineLyricsStore(directory: folder, isUsable: { $0.data != payload })
check(validatingStore.entry(trackId: track, source: 5, options: options) == nil, "invalid saved payload was reused")
check(validatingStore.fallbackEntry(trackId: track, sources: [5]) == nil, "invalid saved payload was returned as a fallback")
check(validatingStore.missingTrackIds([track], source: 5, options: options) == [track], "invalid saved payload was not queued for recovery")
// The header fields upstream shows are part of every file.
check(entry?.romanized == false && entry?.fallbackReason == "none", "default header fields were not saved")
let headerFolder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: headerFolder) }
check(try OfflineLyricsStore(directory: headerFolder).save(trackId: track, source: 3, options: options, data: payload,
    romanized: true, fallbackReason: "noSuchSong"), "header fields could not be saved")
let headerEntry = OfflineLyricsStore(directory: headerFolder).entry(trackId: track, source: 3, options: options)
check(headerEntry?.romanized == true && headerEntry?.fallbackReason == "noSuchSong", "header fields did not survive reopening")
// An instrumental is saved without lines: an empty payload is a saved text.
check(try OfflineLyricsStore(directory: headerFolder).save(trackId: "instrumental", source: 3, options: options, data: Data()),
      "an instrumental could not be saved")
check(OfflineLyricsStore(directory: headerFolder).entry(trackId: "instrumental", source: 3, options: options)?.data == Data(),
      "an instrumental did not survive reopening")
// A file without the header fields (an earlier build) is not a saved text: it is downloaded again.
let oldURL = headerFolder.appendingPathComponent("3-\(track).json")
var old = try JSONSerialization.jsonObject(with: Data(contentsOf: oldURL)) as! [String: Any]
old["romanized"] = nil
old["fallbackReason"] = nil
try JSONSerialization.data(withJSONObject: old).write(to: oldURL)
let withOldFile = OfflineLyricsStore(directory: headerFolder)
check(withOldFile.entry(trackId: track, source: 3, options: options) == nil, "a file without header fields was used")
check(withOldFile.missingTrackIds([track], source: 3, options: options) == [track], "a file without header fields was not downloaded again")
check(reopened.entry(trackId: track, source: 1, options: options) == nil, "wrong provider reused")
var changed = options
changed.romanization = true
check(reopened.entry(trackId: track, source: 5, options: changed) == nil, "wrong options reused")
var displayOptions = options
displayOptions.showFallbackReasons = true
displayOptions.hideOnError = true
check(reopened.entry(trackId: track, source: 5, options: displayOptions) != nil, "display preferences discarded offline text")
// Saving more than eight tracks must not evict the first downloaded song.
for index in 0..<12 {
    try store.save(trackId: "track\(index)", source: 5, options: options, data: payload)
}
check(reopened.entry(trackId: track, source: 5, options: options) != nil, "disk cache evicted a download")
try store.save(trackId: "../escape", source: 5, options: options, data: payload)
check(reopened.entry(trackId: "../escape", source: 5, options: options) == nil, "unsafe identity accepted")
try Data("corrupted".utf8).write(to: folder.appendingPathComponent("5-\(track).json"))
check(reopened.entry(trackId: track, source: 5, options: options) == nil, "corrupt record accepted")
try store.save(trackId: track, source: 5, options: options, data: payload)
check(reopened.entry(trackId: track, source: 5, options: options)?.data == payload, "corrupt record could not be replaced")
// Removal must cover every provider and leave unrelated songs intact.
let oldRevision = store.revision(trackId: track)
try store.save(trackId: track, source: 1, options: options, data: payload)
try store.remember(context: "spotify:album:test", trackIds: [track, "other"])
let withContext = OfflineLyricsStore(directory: folder)
check(Set(withContext.tracks(in: "spotify:album:test")) == Set([track, "other"]), "offline context membership did not persist")
check(store.missingTrackIds([track, "absent"], source: 5, options: options) == ["absent"], "backfill did not skip an existing lyric")
check(store.missingTrackIds([track], source: 0, options: options) == [track], "backfill incorrectly reused another provider")
check(store.missingTrackIds([track], source: 5, options: changed) == [track], "backfill incorrectly reused different text options")
check(store.fallbackEntry(trackId: track, sources: [1])?.data == payload, "offline fallback ignored another provider's saved text")
check(store.fallbackEntry(trackId: track, sources: [0, 3]) == nil, "offline fallback invented a provider text")
check(store.fallbackEntry(trackId: "absent", sources: [1, 5]) == nil, "offline fallback returned text for an unsaved track")
let beforeReplacement = store.summary()
let replacement = Data(repeating: 7, count: 128)
try store.save(trackId: track, source: 5, options: options, data: replacement)
let afterReplacement = store.summary()
check(afterReplacement.tracks == beforeReplacement.tracks && afterReplacement.files == beforeReplacement.files
      && afterReplacement.bytes > beforeReplacement.bytes, "Replacing a lyric inflated the track count or lost its size")
let fromDisk = OfflineLyricsStore(directory: folder).summary()
check(afterReplacement.bytes == fromDisk.bytes, "Incremental byte total disagreed with the persisted files")
try store.remove(trackIds: [track])
let afterRemoval = store.summary()
check(afterRemoval.files == afterReplacement.files - 2 && afterRemoval.tracks == afterReplacement.tracks - 1,
      "Removing provider variants changed the lyric track count incorrectly")
check(store.entry(trackId: track, source: 1, options: options) == nil, "alternate provider survived removal")
check(store.missingTrackIds([track], source: 5, options: options) == [track], "deleted lyrics still disabled the download button")
check(store.entry(trackId: "track0", source: 5, options: options) != nil, "unrelated song was removed")
check(!store.isCurrent(oldRevision, trackId: track), "deletion did not invalidate old work")
let staleSave = try store.save(trackId: track, source: 5, options: options, data: payload, revision: oldRevision)
check(!staleSave, "in-flight download resurrected deleted lyrics")
check(store.tracks(in: "spotify:album:test") == ["other"], "removed track stayed in context index")
let fresh = store.revision(trackId: track)
check(!(try store.save(trackId: track, source: 5, options: options, data: payload, revision: fresh)), "viewing an online lyric recreated a removed download")
let persistedDeletion = OfflineLyricsStore(directory: folder)
check(!(try persistedDeletion.save(trackId: track, source: 5, options: options, data: payload)), "deletion protection did not survive reopening")
check(persistedDeletion.automaticallyRetryableTrackIds([track, "absent"]) == ["absent"], "automatic marker recovery undid a persisted deletion")
try store.allowDownloads(trackIds: [track])
check(store.automaticallyRetryableTrackIds([track]) == [track], "explicit redownload did not re-enable automatic recovery")
check(try store.save(trackId: track, source: 5, options: options, data: payload, revision: fresh), "explicit redownload was blocked")
// A removed download that Spotify later reports downloaded (even after a relaunch) gets lyrics again.
let secondTrack = "second"
try store.remove(trackIds: [secondTrack])
check(OfflineLyricsStore(directory: folder).automaticallyRetryableTrackIds([secondTrack]).isEmpty, "a removed download was retried")
try OfflineLyricsStore(directory: folder).downloadsSeen(trackIds: [secondTrack])
let afterRelaunch = OfflineLyricsStore(directory: folder)
check(afterRelaunch.automaticallyRetryableTrackIds([secondTrack]) == [secondTrack], "a re-downloaded track stayed blocked after relaunch")
check(try afterRelaunch.save(trackId: secondTrack, source: 5, options: options, data: payload), "a re-downloaded track could not save lyrics")
let pendingClear = store.revision(trackId: "later")
try store.removeAll(additionallySuppressing: ["missingMarker"])
check(store.summary().files == 0 && store.summary().bytes == 0, "clear left lyric files or incorrect statistics")
check(store.tracks(in: "spotify:album:test").isEmpty, "clear left context index")
check(store.missingTrackIds([track, "track0"], source: 5, options: options).count == 2, "clear left stale all-downloaded metadata")
check(!(try store.save(trackId: "later", source: 5, options: options, data: payload, revision: pendingClear)), "clear allowed an old queued job to recreate files")
check(OfflineLyricsStore(directory: folder).automaticallyRetryableTrackIds([track, "missingMarker"]).isEmpty,
      "clear failed to suppress placeholder recovery without a saved file")
try store.downloadsSeen(trackIds: [track])
check(OfflineLyricsStore(directory: folder).automaticallyRetryableTrackIds([track]).isEmpty,
      "seeing a still-downloaded track undid Delete saved lyrics")
// Word timing rides along in the same file and does not change the native payload.
let timed = KaraokeLyricsDto(lines: [KaraokeLineDto(syllables: [
    KaraokeSyllableDto(text: "Hel", startMs: 1000, endMs: 1200, isPartOfWord: true),
    KaraokeSyllableDto(text: "lo", startMs: 1200, endMs: 1500, isPartOfWord: false)],
    startMs: 1000, endMs: 1500)], songWriters: ["W"], providerCode: "spicy")
let timedFolder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: timedFolder) }
check(try OfflineLyricsStore(directory: timedFolder).save(trackId: track, source: 5, options: options, data: payload,
    karaoke: JSONEncoder().encode(timed)), "lyrics with word timing were not saved")
let timedEntry = OfflineLyricsStore(directory: timedFolder).entry(trackId: track, source: 5, options: options)
let decoded = timedEntry?.karaoke.flatMap { try? JSONDecoder().decode(KaraokeLyricsDto.self, from: $0) }
check(timedEntry?.data == payload, "word timing changed the native lyrics payload")
check(decoded?.lines.first?.syllables.map(\.text) == ["Hel", "lo"] && decoded?.lines.first?.syllables.last?.endMs == 1500
      && decoded?.songWriters == ["W"], "word timing did not survive reopening")
check(OfflineLyricsStore(directory: folder).entry(trackId: secondTrack, source: 5, options: options)?.karaoke == nil,
      "a file without word timing reported some")
print("OfflineLyricsStore tests passed")
