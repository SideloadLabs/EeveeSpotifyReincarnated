import Foundation
import SQLite3

/// The native cache is a projection, not the source of truth. Keep the replaced
/// Spotify row in the same transaction and restore it only while we still own it.
final class NativeOfflineLyricsDatabase {
    private let db: OpaquePointer
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }
    /// Journal mode reported by SQLite after the WAL request ("wal" when it applied).
    let journalMode: String

    private static func pragmaText(_ connection: OpaquePointer, _ sql: String) -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }
    /// Current journal mode; Spotify could switch it back when it opens the store.
    func currentJournalMode() -> String { Self.pragmaText(db, "PRAGMA journal_mode") ?? "unknown" }

    init(url: URL) throws {
        var connection: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let connection else {
            if let connection { sqlite3_close(connection) }
            throw Failure(message: "cannot open native lyrics cache (\(status))")
        }
        db = connection
        // Our own writes wait for Spotify instead of failing immediately.
        sqlite3_busy_timeout(db, 2000)
        // With the native offline-lyrics flag on, Spotify's plugin checks this database
        // for downloaded tracks. build015 showed 17 tracks dropping to Waiting about 2 s
        // after a launch reconcile that committed 131 separate transactions. Most likely
        // a check that hit one of our commits (rollback-journal mode locks readers out
        // while committing) read as "no lyrics". In WAL mode readers never block on a
        // writer. The mode is persistent and applies to Spotify's connection too.
        journalMode = Self.pragmaText(connection, "PRAGMA journal_mode=WAL") ?? "unknown"
        do {
            try execute("CREATE TABLE IF NOT EXISTS lyrics_entities (track_uri TEXT NOT NULL PRIMARY KEY, entity_data BLOB NOT NULL)")
            // Preparing this also checks the native column names before any row changes.
            // Another Spotify version may use another layout: refuse instead of writing.
            do {
                let schema = try prepare("SELECT track_uri, entity_data FROM lyrics_entities LIMIT 0")
                sqlite3_finalize(schema)
            } catch {
                throw Failure(message: "lyrics_entities has another layout: \(error)")
            }
            try execute("CREATE TABLE IF NOT EXISTS eevee_lyrics_projection_v1 (track_uri TEXT NOT NULL PRIMARY KEY, original BLOB, injected BLOB NOT NULL)")
        } catch { sqlite3_close(db); throw error }
    }
    deinit { sqlite3_close(db) }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Failure(message: String(cString: sqlite3_errmsg(db)))
        }
        return statement
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw Failure(message: String(cString: sqlite3_errmsg(db)))
        }
    }
    private func bind(_ text: String, to statement: OpaquePointer, at index: Int32) {
        sqlite3_bind_text(statement, index, text, -1, transient)
    }
    private func bind(_ data: Data?, to statement: OpaquePointer, at index: Int32) {
        guard let data else { sqlite3_bind_null(statement, index); return }
        guard !data.isEmpty else { sqlite3_bind_zeroblob(statement, index, 0); return }
        data.withUnsafeBytes { bytes in
            _ = sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), transient)
        }
    }
    private func blob(_ statement: OpaquePointer, _ index: Int32) -> Data? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return Data() }
        return Data(bytes: bytes, count: count)
    }
    private func finish(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure(message: String(cString: sqlite3_errmsg(db))) }
    }
    private func transaction(_ work: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try work(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }
    private func row(_ uri: String) throws -> Data? {
        let statement = try prepare("SELECT entity_data FROM lyrics_entities WHERE track_uri = ?")
        defer { sqlite3_finalize(statement) }
        bind(uri, to: statement, at: 1)
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return blob(statement, 0)
        case SQLITE_DONE: return nil
        default: throw Failure(message: String(cString: sqlite3_errmsg(db)))
        }
    }
    private func ownership(_ uri: String) throws -> (original: Data?, injected: Data)? {
        let statement = try prepare("SELECT original, injected FROM eevee_lyrics_projection_v1 WHERE track_uri = ?")
        defer { sqlite3_finalize(statement) }
        bind(uri, to: statement, at: 1)
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return (blob(statement, 0), blob(statement, 1) ?? Data())
        case SQLITE_DONE: return nil
        default: throw Failure(message: String(cString: sqlite3_errmsg(db)))
        }
    }
    private func write(_ uri: String, _ data: Data?) throws {
        let statement = try prepare(data == nil
            ? "DELETE FROM lyrics_entities WHERE track_uri = ?"
            : "INSERT OR REPLACE INTO lyrics_entities (track_uri, entity_data) VALUES (?, ?)")
        defer { sqlite3_finalize(statement) }
        bind(uri, to: statement, at: 1)
        if let data { bind(data, to: statement, at: 2) }
        try finish(statement)
    }
    /// Read-only check: would `apply` change anything? Takes no write lock.
    private func needsChange(_ uri: String, _ data: Data?) throws -> Bool {
        let owned = try ownership(uri)
        guard let data else { return owned != nil }
        guard owned?.injected == data else { return true }
        return try row(uri) != data
    }
    private func apply(_ uri: String, _ data: Data?) throws {
        let current = try row(uri)
        let owned = try ownership(uri)
        if let data {
            if owned?.injected == data && current == data { return }
            let original = owned != nil && current == owned?.injected ? owned?.original : current
            let statement = try prepare("INSERT OR REPLACE INTO eevee_lyrics_projection_v1 (track_uri, original, injected) VALUES (?, ?, ?)")
            defer { sqlite3_finalize(statement) }
            bind(uri, to: statement, at: 1)
            bind(original, to: statement, at: 2)
            bind(data, to: statement, at: 3)
            try finish(statement)
            if current != data { try write(uri, data) }
        } else if let owned {
            // A newer write by Spotify must survive cleanup/provider changes.
            if current == owned.injected { try write(uri, owned.original) }
            let statement = try prepare("DELETE FROM eevee_lyrics_projection_v1 WHERE track_uri = ?")
            defer { sqlite3_finalize(statement) }
            bind(uri, to: statement, at: 1)
            try finish(statement)
        }
    }
    /// Returns whether anything was written. An unchanged row causes no write at all.
    @discardableResult
    func update(uri: String, data: Data?) throws -> Bool {
        try update([(uri: uri, data: data)]) > 0
    }
    /// Applies all changed rows in ONE transaction and skips unchanged ones, so a
    /// launch-time reconcile with nothing new never locks the database.
    @discardableResult
    func update(_ changes: [(uri: String, data: Data?)]) throws -> Int {
        let pending = try changes.filter { try needsChange($0.uri, $0.data) }
        guard !pending.isEmpty else { return 0 }
        try transaction { for change in pending { try apply(change.uri, change.data) } }
        return pending.count
    }
    /// Empty rows for tracks with no lyrics anywhere. Never replaces a row we do not
    /// own: a real Spotify row (or one Spotify refreshed) always stays. If we had
    /// replaced a Spotify row earlier, that original is restored instead.
    private func placeholderNeeded(_ uri: String, _ data: Data) throws -> Bool {
        let owned = try ownership(uri)
        guard let current = try row(uri) else { return true }
        guard let owned, current == owned.injected else { return false }
        return owned.original != nil || owned.injected != data
    }
    private func applyPlaceholder(_ uri: String, _ data: Data) throws {
        guard try placeholderNeeded(uri, data) else { return }
        if let owned = try ownership(uri), owned.original != nil { try apply(uri, nil); return }
        let statement = try prepare("INSERT OR REPLACE INTO eevee_lyrics_projection_v1 (track_uri, original, injected) VALUES (?, NULL, ?)")
        defer { sqlite3_finalize(statement) }
        bind(uri, to: statement, at: 1)
        bind(data, to: statement, at: 2)
        try finish(statement)
        try write(uri, data)
    }
    @discardableResult
    func ensurePlaceholders(_ items: [(uri: String, data: Data)]) throws -> Int {
        let pending = try items.filter { try placeholderNeeded($0.uri, $0.data) }
        guard !pending.isEmpty else { return 0 }
        try transaction { for item in pending { try applyPlaceholder(item.uri, item.data) } }
        return pending.count
    }
    /// Read-only: does Spotify's table have a row for `uri` (ours or Spotify's)?
    func hasRow(_ uri: String) throws -> Bool { try row(uri) != nil }
    /// Read-only: is the current row ours with no Spotify original behind it? Removing
    /// such a row would leave the track with no row at all.
    func ownsWithoutOriginal(_ uri: String) throws -> Bool {
        guard let owned = try ownership(uri) else { return false }
        guard owned.original == nil else { return false }
        return try row(uri) == owned.injected
    }
    func ownedTrackURIs() throws -> [String] {
        let statement = try prepare("SELECT track_uri FROM eevee_lyrics_projection_v1")
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                if let text = sqlite3_column_text(statement, 0) { result.append(String(cString: text)) }
            case SQLITE_DONE: return result
            default: throw Failure(message: String(cString: sqlite3_errmsg(db)))
            }
        }
    }
}
