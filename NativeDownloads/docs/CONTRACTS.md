# Pixie data and lifetime contracts

## Thread ownership

- Artist session, playlist registries and user-facing observers belong to main.
- Native manual jobs and transport-owned reads use the original serial download worker.
- Artwork has its own serial queue; consumers are delivered on main.
- Journal storage and its file writer share the journal queue. The writer adds no queue.
- Report formatting/export uses the serial report queue; UIKit/native snapshots are taken on main.
- Hook callbacks can arrive from Spotify threads. The existing atomic/generation and queue handoff rules remain required.

## Release and owner identity

Release dictionaries retain the compatibility schema: `uri`, optional `name`, `category`, `type`, `artist_uri`, `owner_token`, `track_count_verified`, `verified_track_count`. URI is Spotify identity; a title or cover is not identity. Edition metadata is not a license to merge different Spotify URIs.

Owner identity is artist URI, or artist URI plus task token for a playlist feed. One native release may have multiple owners. Removing one owner only stops an exclusive native operation; another artist's owner is preserved. Reservation rank/ordinal is fixed before metadata completion so fast new work cannot jump the queue.

## State and evidence

Raw session state has native evidence (`native_state`, totals/progress and observation generation) and local intent (`local_phase`, active/stopping/reserved). These meanings are separate. `DownloadEvidence.h` exposes the existing context completion/totals rules as a typed read-only value without changing the wire schema.

Native **context** state 3 completes the context. Native **item** state 3 completes one track; it does not prove a containing album or playlist context is offline-enabled. Cached stopped visuals preserve presentation only. A fresh request for an inactive context obtains fresh native evidence.

Unknown/missing state is not a confirmed state zero. A successful transport response or Add ACK is not completed audio availability. Library membership and playlist membership do not establish download state.

## Commands versus reads

Read-only calls/subscriptions can try bounded verified candidates. A mutation is sent once to a proven endpoint. `SAPCommandNotInvoked` is only returned before native entry; `SAPCommandInvoked` includes timeout, exception, malformed reply and other unconfirmed outcomes. These must not trigger blind mutation replay.

Every native lifetime is acquired and released/cancelled by its owner. Cancel blocks are idempotent. Epoch/generation checks suppress stale completions; separating files does not permit removing them.

## Playlist workflow

The target playlist preserves existing items/order. Whole releases are appended in selected category/release order, preserving track order and excluding identical URIs already present. Releases advance incrementally after the existing confirmation rules. Stop/Continue preserves intent; Cancel removes that artist's pending intent and stops its exclusive in-progress work. A created playlist and confirmed additions remain.

## Diagnostics

`SAPDiagnosticsEnabled` is the atomic source of the switch. `SAP_JOURNAL_ACTION` and `SAP_TRACE` check it before preparing optional facts. Original callable APIs remain available. Reset invalidates old queued diagnostic work through generation checks, clears files/state and continues recording only if enabled.

Working download observations are required even with diagnostics off. File names, log schema, public `SAP` names, settings identifiers and dylib install name retain compatibility. The support log honestly records observation times and unavailable sections; it is not an atomic server snapshot.

## Bounded preparation and single-track groups

Selected playlist metadata is read with a window of three requests and assembled
in selection order before any playlist mutation. At most two playlist tasks may
prepare concurrently; writes to one destination and global native admissions
retain their existing FIFO ownership. Cancel invalidates every metadata read.

Up to three adjacent releases with one verified, distinct track each may form one batch.
Their tracks are appended in release order and each album receives its own native
registration. Every native context completion and every item state are required
before the next batch. Multi-track releases remain whole batches.

A next-release Contains read may overlap the current batch's final track. Its
result is task-scoped and expires after five seconds. A positive verification may
be consumed once by the shared session, avoiding a duplicate Contains read; it
never substitutes for native context or file evidence. Stop, Cancel and task exit
invalidate these verifications and all lookahead work.

Stop state-read failures retry read-only at most three times (1, 2, 4 seconds).
Uncertain Remove outcomes are reconciled without replaying Remove. Exhaustion
retains pending cancellation and ownership, reports the failure and permits an
explicit Stop retry; it does not announce successful cancellation.

The shared native scheduler allows at most three submitted contexts only when all
three are verified one-track releases. A single group retains its total admission
count until its remaining members finish, so fast members cannot admit a fourth
release ahead of a slow or uncertain member. Albums retain their original two
ownership slots and trusted near-tail admission. A third metadata preparation
behind two verified singles cannot submit a multi-track release into that group.
