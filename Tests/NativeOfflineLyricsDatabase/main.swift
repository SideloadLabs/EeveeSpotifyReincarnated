import Foundation
import SQLite3

let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder) }
let url = folder.appendingPathComponent("lyrics.sqlite3")
var raw: OpaquePointer?
precondition(sqlite3_open(url.path, &raw) == SQLITE_OK)
defer { sqlite3_close(raw) }
func sql(_ query: String) {
    precondition(sqlite3_exec(raw, query, nil, nil, nil) == SQLITE_OK, String(cString: sqlite3_errmsg(raw)))
}
func value(_ id: String) -> Data? {
    var statement: OpaquePointer?
    precondition(sqlite3_prepare_v2(raw, "SELECT entity_data FROM lyrics_entities WHERE track_uri = ?", -1, &statement, nil) == SQLITE_OK)
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_text(statement, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    let count = Int(sqlite3_column_bytes(statement, 0))
    guard count > 0 else { return Data() }
    return Data(bytes: sqlite3_column_blob(statement, 0)!, count: count)
}
let original = Data("spotify".utf8), first = Data("external-a".utf8), second = Data("external-b".utf8)
var database: NativeOfflineLyricsDatabase? = try NativeOfflineLyricsDatabase(url: url)
sql("INSERT INTO lyrics_entities VALUES ('existing', CAST('spotify' AS BLOB))")
try database!.update(uri: "existing", data: first)
precondition(value("existing") == first)
try database!.update(uri: "existing", data: second)
// Provider replacement must retain the original Spotify row across a process restart.
database = nil
database = try NativeOfflineLyricsDatabase(url: url)
try database!.update(uri: "existing", data: nil)
precondition(value("existing") == original)
let afterRestore = try database!.ownedTrackURIs()
precondition(afterRestore.isEmpty)
try database!.update(uri: "new", data: first)
try database!.update(uri: "new", data: nil)
precondition(value("new") == nil)
// Spotify writing a fresher native row while our projection exists takes precedence on removal.
try database!.update(uri: "existing", data: first)
sql("UPDATE lyrics_entities SET entity_data = CAST('fresh' AS BLOB) WHERE track_uri = 'existing'")
try database!.update(uri: "existing", data: nil)
precondition(value("existing") == Data("fresh".utf8))
// A source change after that refresh must back up the fresher row, not an old snapshot.
try database!.update(uri: "existing", data: first)
sql("UPDATE lyrics_entities SET entity_data = CAST('newer' AS BLOB) WHERE track_uri = 'existing'")
try database!.update(uri: "existing", data: second)
try database!.update(uri: "existing", data: nil)
precondition(value("existing") == Data("newer".utf8))
// Simulate a write failure after the ownership journal was written: the whole transaction rolls back.
sql("CREATE TRIGGER reject_projection BEFORE INSERT ON lyrics_entities WHEN NEW.track_uri = 'failure' BEGIN SELECT RAISE(ABORT, 'fixture failure'); END")
do { try database!.update(uri: "failure", data: first); fatalError("expected write failure") } catch {}
precondition(value("failure") == nil)
let afterFailure = try database!.ownedTrackURIs()
precondition(!afterFailure.contains("failure"))
// An unrelated Spotify row and a valid empty BLOB survive a complete cleanup.
sql("INSERT INTO lyrics_entities VALUES ('unrelated', CAST('keep' AS BLOB))")
sql("INSERT INTO lyrics_entities VALUES ('empty', zeroblob(0))")
try database!.update(uri: "empty", data: first)
try database!.update(uri: "second", data: second)
for uri in try database!.ownedTrackURIs() { try database!.update(uri: uri, data: nil) }
precondition(value("empty") == Data())
precondition(value("unrelated") == Data("keep".utf8))
precondition(value("second") == nil)
// Readers (Spotify's plugin) must never be locked out by our writes: WAL mode.
func pragma(_ query: String) -> String {
    var statement: OpaquePointer?
    precondition(sqlite3_prepare_v2(raw, query, -1, &statement, nil) == SQLITE_OK)
    defer { sqlite3_finalize(statement) }
    precondition(sqlite3_step(statement) == SQLITE_ROW)
    return String(cString: sqlite3_column_text(statement, 0))
}
precondition(database!.journalMode == "wal" && pragma("PRAGMA journal_mode") == "wal")
// An unchanged projection must not write at all (no lock, no commit seen by others).
try database!.update(uri: "steady", data: first)
let versionBefore = pragma("PRAGMA data_version")
let steadyWrote = try database!.update(uri: "steady", data: first)
let steadyBatch = try database!.update([(uri: "steady", data: first), (uri: "absent", data: nil)])
precondition(!steadyWrote && steadyBatch == 0)
precondition(pragma("PRAGMA data_version") == versionBefore)
// Several real changes are committed as ONE transaction.
let batchWritten = try database!.update([(uri: "batch-a", data: first), (uri: "batch-b", data: second), (uri: "steady", data: first)])
precondition(batchWritten == 2)
precondition(Int(pragma("PRAGMA data_version"))! == Int(versionBefore)! + 1)
precondition(value("batch-a") == first && value("batch-b") == second)
for uri in ["steady", "batch-a", "batch-b"] { try database!.update(uri: uri, data: nil) }
// Empty rows for tracks with no lyrics anywhere: only where no row exists.
let empty = Data("empty-entity".utf8)
let placed1 = try database!.ensurePlaceholders([(uri: "nolyrics", data: empty)])
precondition(placed1 == 1)
precondition(value("nolyrics") == empty)
let placed2 = try database!.ensurePlaceholders([(uri: "nolyrics", data: empty)])
precondition(placed2 == 0)
// A real Spotify row is never replaced by an empty one.
sql("INSERT INTO lyrics_entities VALUES ('native', CAST('real' AS BLOB))")
let placed3 = try database!.ensurePlaceholders([(uri: "native", data: empty)])
precondition(placed3 == 0)
precondition(value("native") == Data("real".utf8))
// If we had replaced a Spotify row with provider lyrics, the original comes back.
try database!.update(uri: "native", data: first)
let placed4 = try database!.ensurePlaceholders([(uri: "native", data: empty)])
precondition(placed4 == 1)
precondition(value("native") == Data("real".utf8))
// Spotify replacing our empty row later keeps Spotify's row on cleanup.
sql("UPDATE lyrics_entities SET entity_data = CAST('later' AS BLOB) WHERE track_uri = 'nolyrics'")
let placed5 = try database!.ensurePlaceholders([(uri: "nolyrics", data: empty)])
precondition(placed5 == 0)
try database!.update(uri: "nolyrics", data: nil)
precondition(value("nolyrics") == Data("later".utf8))
// Real provider lyrics replace our empty row; removal deletes it entirely.
let placed6 = try database!.ensurePlaceholders([(uri: "gone", data: empty)])
precondition(placed6 == 1)
try database!.update(uri: "gone", data: second)
precondition(value("gone") == second)
try database!.update(uri: "gone", data: nil)
precondition(value("gone") == nil)
// A zero-length marker row is a valid placeholder and is not rewritten.
let marker1 = try database!.ensurePlaceholders([(uri: "marker", data: Data())])
let marker2 = try database!.ensurePlaceholders([(uri: "marker", data: Data())])
precondition(marker1 == 1 && marker2 == 0 && value("marker") == Data())
// An older decodable empty entity is upgraded to the marker.
let upgrade = try database!.ensurePlaceholders([(uri: "nolyrics-old", data: empty)])
let upgraded = try database!.ensurePlaceholders([(uri: "nolyrics-old", data: Data())])
precondition(upgrade == 1 && upgraded == 1 && value("nolyrics-old") == Data())
try database!.update(uri: "marker", data: nil)
try database!.update(uri: "nolyrics-old", data: nil)
precondition(value("marker") == nil && value("nolyrics-old") == nil)
// ownsWithoutOriginal: only our row with no Spotify original behind it.
try database!.update(uri: "solo", data: first)
let soloOwned = try database!.ownsWithoutOriginal("solo")
sql("INSERT INTO lyrics_entities VALUES ('backed', CAST('spotify' AS BLOB))")
try database!.update(uri: "backed", data: first)
let backedOwned = try database!.ownsWithoutOriginal("backed")
let foreignOwned = try database!.ownsWithoutOriginal("unrelated")
precondition(soloOwned && !backedOwned && !foreignOwned)
try database!.update(uri: "solo", data: nil)
try database!.update(uri: "backed", data: nil)
print("NativeOfflineLyricsDatabase: transactional projection, restart restoration, native refresh preservation, rollback, cleanup, WAL, no-op skip and single-transaction batch, empty-row placeholders passed")
