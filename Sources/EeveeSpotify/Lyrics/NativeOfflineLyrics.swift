import Foundation
import UIKit
import SwiftUI
import CryptoKit

/// Spotify's native offline lyrics repository bypasses URLSession. Project saved lyrics
/// into its own Codable model, validating with Spotify's decoder before writing.
/// Native Line reflection omits startTime, but its Codable schema requires it.
/// Preserve line timing from the saved protobuf, and mark plain text unsynced.
final class NativeOfflineLyrics {
    static let shared = NativeOfflineLyrics()
    private let queue = DispatchQueue(label: "EeveeSpotify.NativeOfflineLyrics", qos: .utility)
    private var observer: NSObjectProtocol?
    private var database: NativeOfflineLyricsDatabase?
    private var codec: Codec?
    private var enabled = false
    /// Track IDs whose provider lyrics are projected into the native table. Read from
    /// any thread (track metadata hook); written on `queue` by reconcile.
    private let withLyricsLock = NSLock()
    private var withLyrics = Set<String>()
    func hasProviderLyrics(trackId: String) -> Bool {
        withLyricsLock.lock(); defer { withLyricsLock.unlock() }
        return withLyrics.contains(trackId)
    }
    /// Downloaded tracks with no lyrics row of their own: Spotify's offline-lyrics
    /// download failed (it answers 403 here) and the provider found nothing, or our
    /// lyrics were removed while the track stayed downloaded. With the native flag on, Spotify's
    /// plugin keeps such a track Waiting offline until a lyrics row exists, so we
    /// keep an empty row for it (only where no row exists; real lyrics always win).
    private static let noLyricsKey = "EeveeNativeOfflineNoLyricsTracks"
    private var noLyrics = Set(UserDefaults.standard.stringArray(forKey: NativeOfflineLyrics.noLyricsKey) ?? [])
    private func saveNoLyrics() { UserDefaults.standard.set(Array(noLyrics).sorted(), forKey: Self.noLyricsKey) }

    /// Markers protect the audio queue; they are not definitive provider misses.
    /// The downloader filters genuine misses and explicitly deleted lyrics.
    static func placeholderTrackIdsForRetry() -> [String] {
        guard shared.enabled else { return [] }
        return UserDefaults.standard.stringArray(forKey: noLyricsKey) ?? []
    }

    /// Called when Spotify's offline-lyrics plugin got a non-2xx answer for `trackId`
    /// and the provider had no lyrics. Safe on any thread.
    func markNoLyrics(trackId: String, reason: String) {
        guard enabled, trackId.count == 22 else { return }
        queue.async { self.keepMarker(trackId: trackId, reason: reason) }
    }

    private func keepMarker(trackId: String, reason: String) {
        guard noLyrics.insert(trackId).inserted else { return }
        saveNoLyrics()
        writeDebugLog("[Lyrics][NativeOffline] keeping an empty native row for \(trackId) (\(reason))")
        reconcile([trackId])
    }
    /// Called when the selected provider has no lyrics for a downloaded track. If
    /// Spotify's plugin has not written its own row within a minute either (it does
    /// when Spotify itself has lyrics), keep an empty row so the track is not
    /// held Waiting offline. Covers tracks whose plugin request never reached us.
    func providerHasNoLyrics(trackId: String) {
        guard enabled, trackId.count == 22 else { return }
        let revision = OfflineLyricsStore.shared.revision(trackId: trackId)
        queue.asyncAfter(deadline: .now() + 60) {
            guard OfflineLyricsStore.shared.isCurrent(revision, trackId: trackId), !self.noLyrics.contains(trackId) else { return }
            guard let database = self.database, (try? database.hasRow("spotify:track:\(trackId)")) == false else { return }
            self.keepMarker(trackId: trackId, reason: "provider found none and no native row after 60 s")
        }
    }
    /// Downloads that were removed: their rows may really be deleted. Every other
    /// track keeps at least a marker row, so removing lyrics (button, provider switch,
    /// "not replaced") never sends a downloaded track back to Waiting offline.
    private var removedDownloads = Set<String>()
    private var allDownloadsRemoved = false
    /// Called when downloads are removed. `nil` means every download was removed.
    func forgetNoLyrics(trackIds: [String]?) {
        queue.async {
            let ids: Set<String>
            if let trackIds { ids = Set(trackIds); self.removedDownloads.formUnion(ids) }
            else { ids = self.noLyrics; self.allDownloadsRemoved = true }
            self.noLyrics.subtract(ids)
            self.saveNoLyrics()
            if self.enabled { self.reconcile(trackIds == nil ? nil : Array(ids)) }
        }
    }

    /// The integration runs only if Spotify's native model, colors and database match
    /// what we write (checked in start(), not by version number). Otherwise it stays
    /// off and Spotify is left untouched. Nothing else depends on it: online lyrics,
    /// karaoke and downloads work the same either way. The outcome is only logged.
    var isActive: Bool { enabled }
    private static let spotifyIdentity = "\(EeveeSpotify.spotifyVersion) (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))"

    private func publish(active: Bool, reason: String) {
        writeDebugLog("[Lyrics][NativeOffline] \(active ? "active" : "disabled") on Spotify \(Self.spotifyIdentity): \(reason)")
    }

    func start() {
        guard observer == nil, !enabled else { return }
        // 1. Spotify's own Codable model, sync types and colors must round-trip.
        do { codec = try Codec() }
        catch { publish(active: false, reason: "native lyrics model is different: \(error)"); return }
        // Validate storage before publishing locally saved lyrics to the viewer.
        var failure: Error?
        queue.sync {
            do { _ = try openDatabase() } catch { failure = error }
        }
        if let failure {
            codec = nil
            publish(active: false, reason: "native lyrics database is different or unavailable: \(failure)")
            return
        }
        enabled = true
        observer = NotificationCenter.default.addObserver(forName: .eeveeOfflineLyricsFilesChanged,
            object: nil, queue: nil) { [weak self] note in
            let ids = note.userInfo?["tracks"] as? [String]
            self?.queue.async { self?.reconcile(ids) }
        }
        publish(active: true, reason: "native projection verified; Spotify controls its download configuration")
        reconcileAll()
    }
    /// Opens (once) and verifies the native database. Runs on `queue`.
    private func openDatabase() throws -> NativeOfflineLyricsDatabase {
        if let database { return database }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let opened = try NativeOfflineLyricsDatabase(url: support.appendingPathComponent("lyrics_offline.sqlite3"))
        writeDebugLog("[Lyrics][NativeOffline] database opened, journal=\(opened.journalMode)")
        database = opened
        return opened
    }
    func reconcileAll() {
        guard enabled else { return }
        queue.async { self.reconcile(nil) }
    }
    private func reconcile(_ requested: [String]?) {
        do {
            guard let codec else { return }
            let database = try openDatabase()
            let ids: Set<String>
            if let requested { ids = Set(requested) }
            else {
                let owned = try database.ownedTrackURIs().compactMap { uri -> String? in
                    guard uri.hasPrefix("spotify:track:") else { return nil }
                    return String(uri.dropFirst("spotify:track:".count))
                }
                ids = Set(OfflineLyricsStore.shared.savedTrackIds()).union(owned).union(noLyrics)
            }
            var changes: [(uri: String, data: Data?, digest: String?)] = []
            var placeholders: [(uri: String, data: Data)] = []
            var have = Set<String>()
            let oldMarkerCount = noLyrics.count
            let settings = codec.settingsKey()
            for id in ids {
                let uri = "spotify:track:\(id)"
                // Read the CURRENT selection/files on this queue. Never project a
                // captured result from a download deleted or switched meanwhile.
                // Spotify reads this table only offline (online it fetches, and our
                // hook answers with the selected provider). Until the selected
                // provider's text is downloaded, keep the previous provider's text.
                if let entry = savedOfflineLyricsEntry(trackId: id, allowOtherProvider: true),
                   let lyrics = try? Lyrics(serializedBytes: entry.data), !lyrics.data.lines.isEmpty {
                    have.insert(id)
                    let digest = codec.digest(of: entry.data, settings: settings)
                    // Our row is intact and built from this very text: nothing to encode.
                    if try database.isProjected(uri, digest: digest) { continue }
                    changes.append((uri: uri, data: try codec.encode(trackId: id, lyrics: lyrics), digest: digest))
                    continue
                }
                let removed = allDownloadsRemoved || removedDownloads.contains(id)
                if !removed, !noLyrics.contains(id), (try? database.ownsWithoutOriginal(uri)) == true {
                    // Lyrics removed but the track is still downloaded: keep a marker row.
                    noLyrics.insert(id)
                }
                if !removed, noLyrics.contains(id) {
                    // Zero-length marker: Spotify's offline plugin only checks that a row
                    // exists (track stays downloaded), while the lyrics view cannot decode
                    // it and shows nothing. A decodable empty entity showed an empty block.
                    placeholders.append((uri: uri, data: Data()))
                } else {
                    changes.append((uri: uri, data: nil, digest: nil))
                }
            }
            if noLyrics.count != oldMarkerCount { saveNoLyrics() }
            let written = try database.update(changes)
            let empties = try database.ensurePlaceholders(placeholders)
            // Advertise a text to the native UI only after its SQLite commit.
            withLyricsLock.lock()
            if requested == nil { withLyrics = have }
            else { withLyrics.subtract(ids); withLyrics.formUnion(have) }
            withLyricsLock.unlock()
            removedDownloads.subtract(ids)
            if requested == nil { allDownloadsRemoved = false }
            let encoded = changes.filter { $0.data != nil }.count
            writeDebugLog("[Lyrics][NativeOffline] reconciled \(ids.count) tracks, encoded \(encoded), wrote \(written), empty rows \(empties)/\(placeholders.count), journal=\(database.currentJournalMode())")
        } catch { writeDebugLog("[Lyrics][NativeOffline] cache projection failed: \(error)") }
    }

    private struct Codec {
        private let type: Decodable.Type
        private let colorType: Decodable.Type
        private let colorCache = ColorCache()
        private struct Unavailable: Error, CustomStringConvertible {
            let reason: String
            var description: String { reason }
        }
        private final class ColorCache {
            let lock = NSLock()
            var values: [UInt32: Any] = [:]
        }
        /// Digest of the validation encodings: changes whenever Spotify's model or
        /// our projection changes, so rows built by an older format are re-encoded.
        private var formatDigest = ""

        private static func sha256(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        /// Settings that enter `encode` without being part of the saved text.
        func settingsKey() -> String {
            let settings = UserDefaults.lyricsColors
            return "\(settings.useStaticColor):\(settings.staticColor)"
        }
        /// What a row is built from: format, color settings and the saved text itself.
        func digest(of saved: Data, settings: String) -> String {
            "\(formatDigest):\(settings):\(Self.sha256(saved))"
        }

        init() throws {
            guard let type = _typeByName("18Lyrics_OfflineImpl27LyricsOfflineDatabaseEntityV") as? Decodable.Type,
                  let sync = _typeByName("18Lyrics_OfflineImpl27LyricsOfflineDatabaseEntityV8SyncTypeO") as? Decodable.Type,
                  let color = _typeByName("14Lyrics_DataKit12CodableColorV") as? Decodable.Type else {
                throw Unavailable(reason: "native offline types are unavailable")
            }
            self.type = type
            self.colorType = color
            _ = try NativeOfflineLyricsFormat.validateUnsynced(sync)
            _ = try NativeOfflineLyricsFormat.validate(sync, rawValue: NativeOfflineLyricsFormat.lineSynced)
            writeDebugLog("[Lyrics][NativeOffline] native sync types validated: unsynced, lineSynced")

            _ = try colors(for: Lyrics())
            writeDebugLog("[Lyrics][NativeOffline] native color archive validated")

            let probe = Lyrics.with { $0.data.lines = [LyricsLine.with { $0.content = "Eevee offline validation" }] }
            let plain = try encode(trackId: "validation", lyrics: probe)
            let timedProbe = Lyrics.with {
                $0.data.timeSynchronized = true
                $0.data.lines = [LyricsLine.with { $0.content = "First"; $0.offsetMs = 1234 },
                    LyricsLine.with { $0.content = "Second"; $0.offsetMs = 5678 }]
            }
            let timed = try encode(trackId: "timedvalidation", lyrics: timedProbe)
            formatDigest = Self.sha256(plain + timed)
        }

        /// Native CodableColor encodes a single Data value containing a secure
        /// UIColor archive. Verify the decoder returns that color.
        private func nativeColor(_ argb: UInt32) throws -> Any {
            colorCache.lock.lock(); defer { colorCache.lock.unlock() }
            if let cached = colorCache.values[argb] { return cached }
            let channel = { (shift: UInt32) in CGFloat((argb >> shift) & 0xFF) / 255 }
            let value = UIColor(red: channel(16), green: channel(8), blue: channel(0), alpha: channel(24))
            let archive = try NSKeyedArchiver.archivedData(withRootObject: value, requiringSecureCoding: true)
            let bytes = try JSONEncoder().encode(archive)
            let decoded = try JSONDecoder().decode(colorType, from: bytes)
            guard let wrapped = Mirror(reflecting: decoded).children.first(where: { $0.label == "wrappedValue" })?.value as? UIColor,
                  wrapped.isEqual(value), let encodable = decoded as? Encodable else {
                throw Unavailable(reason: "native color round trip failed")
            }
            let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(encodable), options: [.fragmentsAllowed])
            colorCache.values[argb] = json
            return json
        }

        /// Same colors the online response carries (CustomLyrics), mapped to
        /// native fields as Spotify maps them. Without saved colors the background
        /// follows cachedOfflineLyrics: the static color setting or gray.
        private func colors(for lyrics: Lyrics) throws -> [String: Any] {
            let settings = UserDefaults.lyricsColors
            let fallback = (settings.useStaticColor ? Color(hex: settings.staticColor) : Color.gray).uInt32
            let saved = lyrics.hasColors ? lyrics.colors : nil
            let palette = NativeOfflineLyricsFormat.palette(background: saved?.backgroundColor,
                line: saved?.lineColor, activeLine: saved?.activeLineColor, fallbackBackground: fallback)
            let background = try nativeColor(palette.background)
            return ["backgroundBaseColor": background, "backgroundTintedColor": background,
                    "textBaseColor": try nativeColor(palette.textBase),
                    "textSubduedColor": try nativeColor(palette.textSubdued),
                    "textBrightAccentColor": try nativeColor(palette.textBrightAccent),
                    "isDynamicColor": false]
        }

        func encode(trackId: String, lyrics: Lyrics) throws -> Data {
            let uri = "spotify:track:\(trackId)"
            let text = lyrics.data.lines.map(\.content)
            let projected = try NativeOfflineLyricsFormat.project(text: text,
                offsetsMs: lyrics.data.lines.map { Int64($0.offsetMs) }, timeSynced: lyrics.data.timeSynchronized)
            let object: [String: Any] = [
                "trackURI": uri,
                "lyricsLines": projected.lines,
                "syncType": projected.sync, "translations": [], "language": "und",
                "isRtlLanguage": false,
                "provider": ["provider": "EeveeSpotify", "providerDisplayName": lyrics.data.providedBy, "providerLyricsID": ""],
                "colors": try colors(for: lyrics), "isVocalRemovalAvailable": false
            ]
            let nativeType = self.type
            let json = try JSONSerialization.data(withJSONObject: object)
            let decoded: Decodable = try JSONDecoder().decode(nativeType, from: json)
            let fields = Mirror(reflecting: decoded).children
            let decodedURI = fields.first(where: { $0.label == "trackURI" })?.value as? String
            guard decodedURI == uri, let encodable = decoded as? Encodable else {
                throw Unavailable(reason: "native offline entity round trip failed")
            }
            // Store native encoder output, not our guessed JSON. Assert that no
            // lines were lost by custom native decoding/encoding.
            // Sorted keys: identical lyrics give identical bytes on every launch, so an
            // unchanged row is never rewritten.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let canonical = try encoder.encode(encodable)
            guard let root = try JSONSerialization.jsonObject(with: canonical) as? [String: Any],
                  root["syncType"] as? String == projected.sync,
                  let lines = root["lyricsLines"] as? [[String: Any]],
                  lines.compactMap({ $0["text"] as? String }) == text,
                  lines.compactMap({ ($0["startTime"] as? NSNumber)?.int64Value }) == projected.times else {
                throw Unavailable(reason: "native offline line validation failed")
            }
            return canonical
        }
    }
}
