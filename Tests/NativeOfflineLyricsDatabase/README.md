Native offline lyrics adapter
============================

The inspected Spotify 9.2.0 executable (UUID b49e7578-1d86-35d3-8bb5-7daf68fed8a8)
uses `Library/Application Support/lyrics_offline.sqlite3`, with
`lyrics_entities(track_uri TEXT PRIMARY KEY, entity_data BLOB NOT NULL)`.
`entity_data` is JSONEncoder output for
`Lyrics_OfflineImpl.LyricsOfflineDatabaseEntity`, not the color-lyrics protobuf.
The native Line reflection descriptor omits startTime, but the actual Codable
implementation requires Int64 startTime, text and syllables. This was confirmed
by the build011 device decoder error and native encode/decode disassembly.
Reflection descriptors alone are not a complete serialization schema.

The adapter resolves native Decodable types, validates the native color archive
and unknown sync enum, then round-trips every entity through Spotify's decoder
and encoder. It enables only the client flag `ios-feature-lyrics.lyrics_offline_enabled`;
account entitlements and network reachability are unchanged. The bridge is
limited to the inspected version and skips projection when validation fails.

External plain lyrics use native **unsynced** mode. Genuine line-synced lyrics
preserve their millisecond offsets with **lineSynced**. Invalid, negative or
unordered offsets fall back to unsynced rather than faking synchronization.
Word timing remains available in custom karaoke. Startup validates complete
plain and timed entities using Spotify's own decoder/encoder, including exact
round trips of each startTime, before enabling the client feature or writing.

Saved files are projected on startup/save/removal/provider/options changes.
Native rows replaced by Eevee are backed up transactionally in
`eevee_lyrics_projection_v1`. Cleanup restores the original only if the current
row still equals Eevee's projection, preserving newer Spotify writes. Audio
storage is never opened by this adapter.

The host suite covers restart restoration, repeated provider replacement,
Spotify refreshes, empty native BLOBs, unrelated rows, cleanup, and rollback
after a failed native write. Device validation must additionally check:

1. Open a downloaded track online, then lose connectivity without restarting.
2. Check its stock lyrics block, switch to another downloaded track offline,
   and open the custom lyrics button for synced and plain providers.
3. Remove an audio download or clear saved lyrics in Pixie; revisit that track.
4. Inspect `[Lyrics][NativeOffline]` in Eevee debug logs for decoder/projection
   failures. Host/build/IPA audits alone do not verify the native UI lifecycle.

Locking (build016): the database is switched to WAL so Spotify's offline-lyrics
plugin, which reads it while the native flag is on, is never locked out by our
writes. A reconcile skips rows that would not change (a steady launch writes
nothing) and commits all real changes in one transaction. build015 had dropped
17 tracks to Waiting right after a launch reconcile that committed 131 separate
transactions in rollback-journal mode.
