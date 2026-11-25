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
    /// Prepared statements by SQL text, reused: a launch reconcile checks every downloaded
    /// track. Used from one queue only (NativeOfflineLyrics), like the connection.
    private var statements: [String: OpaquePointer] = [:]

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
        // A throw below still runs deinit, which closes the connection.
        try execute("CREATE TABLE IF NOT EXISTS lyrics_entities (track_uri TEXT NOT NULL PRIMARY KEY, entity_data BLOB NOT NULL)")
        // Preparing this also checks the native column names before any row changes.
        // Another Spotify version may use another layout: refuse instead of writing.
        do {
            let schema = try prepare("SELECT track_uri, entity_data FROM lyrics_entities LIMIT 0")
            sqlite3_finalize(schema)
        } catch {
            throw Failure(message: "lyrics_entities has another layout: \(error)")
        }
        // source_digest: the saved text and format an injected row was built from, so a
        // launch skips re-encoding rows whose input did not change.
        try execute("CREATE TABLE IF NOT EXISTS eevee_lyrics_projection_v1 (track_uri TEXT NOT NULL PRIMARY KEY, original BLOB, injected BLOB NOT NULL, source_digest TEXT)")
    }
    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        sqlite3_close(db)
    }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Failure(message: String(cString: sqlite3_errmsg(db)))
        }
        return statement
    }
    /// Runs `body` with the cached statement for `sql`, reset and unbound afterwards.
    private func withStatement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        let statement: OpaquePointer
        if let cached = statements[sql] { statement = cached }
        else { statement = try prepare(sql); statements[sql] = statement }
        defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
        return try body(statement)
    }
    /// Whether a one-row query finds a row whose first column is true. `uri` is bound to
    /// the last parameter, `bindings` binds the others.
    private func exists(_ sql: String, _ uri: String, bindings: (OpaquePointer) -> Void = { _ in }) throws -> Bool {
        try withStatement(sql) { statement in
            bindings(statement)
            bind(uri, to: statement, at: sqlite3_bind_parameter_count(statement))
            switch sqlite3_step(statement) {
            case SQLITE_ROW: return sqlite3_column_int(statement, 0) == 1
            case SQLITE_DONE: return false
            default: throw Failure(message: String(cString: sqlite3_errmsg(db)))
            }
        }
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
        try withStatement("SELECT entity_data FROM lyrics_entities WHERE track_uri = ?") { statement in
            bind(uri, to: statement, at: 1)
            switch sqlite3_step(statement) {
            case SQLITE_ROW: return blob(statement, 0)
            case SQLITE_DONE: return nil
            default: throw Failure(message: String(cString: sqlite3_errmsg(db)))
            }
        }
    }
    private func ownership(_ uri: String) throws -> (original: Data?, injected: Data, digest: String?)? {
        try withStatement("SELECT original, injected, source_digest FROM eevee_lyrics_projection_v1 WHERE track_uri = ?") { statement in
            bind(uri, to: statement, at: 1)
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                let digest = sqlite3_column_text(statement, 2).map { String(cString: $0) }
                return (blob(statement, 0), blob(statement, 1) ?? Data(), digest)
            case SQLITE_DONE: return nil
            default: throw Failure(message: String(cString: sqlite3_errmsg(db)))
            }
        }
    }
    /// Read-only: is our row for `uri` still in place and built from `digest`? One query,
    /// compared inside SQLite: a launch asks this for every downloaded track.
    func isProjected(_ uri: String, digest: String) throws -> Bool {
        try exists("""
            SELECT p.source_digest = ? AND CAST(e.entity_data AS BLOB) = p.injected
            FROM eevee_lyrics_projection_v1 p JOIN lyrics_entities e ON e.track_uri = p.track_uri
            WHERE p.track_uri = ?
            """, uri) { self.bind(digest, to: $0, at: 1) }
    }
    private func write(_ uri: String, _ data: Data?) throws {
        try withStatement(data == nil
            ? "DELETE FROM lyrics_entities WHERE track_uri = ?"
            : "INSERT OR REPLACE INTO lyrics_entities (track_uri, entity_data) VALUES (?, ?)") { statement in
            bind(uri, to: statement, at: 1)
            if let data { bind(data, to: statement, at: 2) }
            try finish(statement)
        }
    }
    /// Read-only check: would `apply` change anything? Takes no write lock.
    /// A nil `digest` leaves the stored digest out of the comparison.
    private func needsChange(_ uri: String, _ data: Data?, _ digest: String?) throws -> Bool {
        let owned = try ownership(uri)
        guard let data else { return owned != nil }
        guard owned?.injected == data else { return true }
        if let digest, owned?.digest != digest { return true }
        return try row(uri) != data
    }
    private func apply(_ uri: String, _ data: Data?, _ digest: String?) throws {
        let current = try row(uri)
        let owned = try ownership(uri)
        if let data {
            if owned?.injected == data && current == data && (digest == nil || owned?.digest == digest) { return }
            let original = owned != nil && current == owned?.injected ? owned?.original : current
            try withStatement("INSERT OR REPLACE INTO eevee_lyrics_projection_v1 (track_uri, original, injected, source_digest) VALUES (?, ?, ?, ?)") { statement in
                bind(uri, to: statement, at: 1)
                bind(original, to: statement, at: 2)
                bind(data, to: statement, at: 3)
                if let digest = digest ?? owned?.digest { bind(digest, to: statement, at: 4) } else { sqlite3_bind_null(statement, 4) }
                try finish(statement)
            }
            if current != data { try write(uri, data) }
        } else if let owned {
            // A newer write by Spotify must survive cleanup/provider changes.
            if current == owned.injected { try write(uri, owned.original) }
            try withStatement("DELETE FROM eevee_lyrics_projection_v1 WHERE track_uri = ?") { statement in
                bind(uri, to: statement, at: 1)
                try finish(statement)
            }
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
        try update(changes.map { (uri: $0.uri, data: $0.data, digest: String?.none) })
    }
    /// `digest` records which saved text and format a row was built from.
    @discardableResult
    func update(_ changes: [(uri: String, data: Data?, digest: String?)]) throws -> Int {
        let pending = try changes.filter { try needsChange($0.uri, $0.data, $0.digest) }
        guard !pending.isEmpty else { return 0 }
        try transaction { for change in pending { try apply(change.uri, change.data, change.digest) } }
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
        if let owned = try ownership(uri), owned.original != nil { try apply(uri, nil, nil); return }
        try withStatement("INSERT OR REPLACE INTO eevee_lyrics_projection_v1 (track_uri, original, injected) VALUES (?, NULL, ?)") { statement in
            bind(uri, to: statement, at: 1)
            bind(data, to: statement, at: 2)
            try finish(statement)
        }
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
    func hasRow(_ uri: String) throws -> Bool {
        try exists("SELECT 1 FROM lyrics_entities WHERE track_uri = ?", uri)
    }
    /// Read-only: is the current row ours with no Spotify original behind it? Removing
    /// such a row would leave the track with no row at all.
    func ownsWithoutOriginal(_ uri: String) throws -> Bool {
        try exists("""
            SELECT 1 FROM eevee_lyrics_projection_v1 p JOIN lyrics_entities e ON e.track_uri = p.track_uri
            WHERE p.original IS NULL AND CAST(e.entity_data AS BLOB) = p.injected AND p.track_uri = ?
            """, uri)
    }
    /// Every row of ours in one query: whether it holds lyrics (not an empty marker),
    /// whether Spotify's row is still the one we wrote, and the digest it was built from.
    func projectedRows() throws -> [String: (lyrics: Bool, intact: Bool, digest: String?)] {
        try withStatement("""
            SELECT p.track_uri, length(p.injected) > 0,
                   e.track_uri IS NOT NULL AND CAST(e.entity_data AS BLOB) = p.injected, p.source_digest
            FROM eevee_lyrics_projection_v1 p LEFT JOIN lyrics_entities e ON e.track_uri = p.track_uri
            """) { statement in
            var result: [String: (lyrics: Bool, intact: Bool, digest: String?)] = [:]
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW:
                    guard let uri = sqlite3_column_text(statement, 0) else { continue }
                    result[String(cString: uri)] = (sqlite3_column_int(statement, 1) != 0,
                        sqlite3_column_int(statement, 2) != 0, sqlite3_column_text(statement, 3).map { String(cString: $0) })
                case SQLITE_DONE: return result
                default: throw Failure(message: String(cString: sqlite3_errmsg(db)))
                }
            }
        }
    }
    func ownedTrackURIs() throws -> [String] {
        try withStatement("SELECT track_uri FROM eevee_lyrics_projection_v1") { statement in
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
}
