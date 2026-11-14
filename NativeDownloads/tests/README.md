# Pixie host regression tests

Run from the project root:

```sh
python3 NativeDownloads/tools/test.py
python3 NativeDownloads/tools/test.py --suite transport --suite session --suite playlists
python3 NativeDownloads/tools/test.py --fixture offline_devices_eevee_auth
python3 NativeDownloads/tools/test.py --list
```

The runner uses the current production target groups from `tools/pixie_target.py`.
Each fixture declares its own dependencies; doubles are not linked with their real
counterparts. Production file moves are resolved by exact basename, including on
case-insensitive APFS volumes.

Every invocation creates a fresh `outputs/host-tests-<timestamp>` directory, or the
empty directory supplied using `--build-dir`. `results.json` records PASS, FAIL,
and SKIP, durations, sanitizer configuration and paths to full compiler/runtime
logs. Failed commands do not prevent independent fixtures from running. A run
with failures or with no executed passing fixture exits unsuccessfully.

The native host fixtures require Apple Silicon macOS and full Xcode. Their
Objective-C/C code uses AddressSanitizer and UndefinedBehaviorSanitizer by default.
Use `--no-sanitize` only to diagnose sanitizer-specific issues; that choice is
recorded in the result. No simulator or iPhone is launched.

## Suites

- **library**: downloaded membership validation, cached metadata reuse, cancelled
  and superseded scans, empty/error snapshots, selected deletion, packaging and
  export. `offline_library_refresh` executes the actual controller state/lifecycle
  methods with Foundation-only presentation boundaries, including immediate
  cached entry, preserved selection and child pages after metadata recovery.
  It does not render UIKit or verify physical-device scrolling.
- **audio**: production callback forwarding, PCM/mute behavior and AV hooks with
  diagnostics toggled. WAV recording sources were removed; the obsolete capture
  fixture is not an active target.
- **config**: offline flags, bootstrap/customize handling, local readiness and
  request-mode policy, extension process exclusion and English localization.
- **transport**: real production bridge hooks, lifetime acquire/cancel, read-only
  fallback, one-shot mutations, late responses and manual download completion.
- **session**: actual artist scheduler and ownership, the pair of one-track
  releases, FIFO admission, shared releases, stop/cancel/recovery races.
- **catalog**: album parsing plus artist edition grouping, hydration limits,
  cancellation, partial results, progressive publication and metadata diagnostics.
- **playlists**: production reader/workflow/item observation with a controlled
  native service; ordering, incremental additions, duplicate URI exclusion,
  artist-scoped stop/cancel and observation cleanup.
- **native download quality**: exact stock download enum, loaded-preference
  deferral, persisted Normal offer/High suppression and one-time tap navigation;
  isolated child processes verify that later entries do not reread preferences.
- **extendable exports**: unique URI append during preparation/conversion/package,
  stable output order, unchanged packaging choice, stale package cancellation,
  preserved in-flight progress and selected artists gaining a new native track.
- **devices**: source comparison, reviewed enable/remove operations, malformed
  HTTP and readback. The extra `offline_devices_eevee_auth` fixture compiles the
  actual Swift `SpriteAuthentication` bridge; its seed contains test-only values.
  Every management HTTP request is intercepted by NSURLProtocol.
- **diagnostics**: player trace, journal state/reset/off behavior, trace rotation,
  bounded queue loss, write failure and single support-log packaging.
- **packaging**: executable ARM64 restriction and observation fixtures, entitlement
  preservation and dyld dependency resolution. Native patch fixture scripts honor
  `PIXIE_TEST_BUILD_DIR` when invoked by the runner.

These are controlled local regressions. They do not prove live Spotify service
availability, a user's device registration, installation signing, widget refresh,
network download speed or offline playback on an iPhone. Real-binary tests that
need a separately supplied IPA must explicitly report their missing fixture.
The UIKit fixture remains a separate opt-in development tool and is not run here.

## Additional contracts and compile-only UIKit checks

`export_artwork_cache` executes the actual export-artwork loader function with
Foundation queues/cache and host doubles only for native images and UIKit JPEG.
It covers repeated immutable album covers, distinct identities, cached/uncached
cancellation, failure retry and mutable/malformed URI bypass under ASan/UBSan.
It does not launch a device or measure native image-service/JPEG performance.

`journal_lazy_payload` verifies that the production optional journal macro does
not evaluate event names or facts while diagnostics are off, evaluates them once
while on, and retains the direct function ABI. `download_evidence` verifies unknown
context state, context/item separation, recovery removal and trusted-total bounds.
These bring the current host runner to 27 explicit fixture targets.

Compile/link the current UI without querying or launching a simulator:

```sh
python3 NativeDownloads/tools/test_settings_ui.py --compile-only --fixture all
python3 Tests/PlaylistActionRow/test.py --compile-only
```

Both commands default to compile-only and produce fresh root `outputs` folders.
The settings command builds both settings and artist/playlist-picker fixtures
using the target's full `artist_ui` group. The action-row fixture compiles the
actual Eevee artist-download bridge and identity adapter; follow state is supplied
by an explicitly unavailable test provider. It does not prove native Spotify
follow-provider behavior. Runtime access requires explicit `--run`.

Remaining device-only checks include real playlist permissions and service schema
changes, two-artist service timing, actual offline audio, widget/extension refresh,
signer-specific behavior and coexistence with additional installed hooks. Current
UI runtime behavior, gesture hit testing, scrolling and delayed image display have
not been exercised by compile-only checks.
