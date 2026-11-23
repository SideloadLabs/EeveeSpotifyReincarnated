# DeadCode

Code taken out of the build because nothing runs it. Kept here for reference only:
no build, test or tool reads this folder. Paths mirror the original locations.
Whole files keep their history (`git log --follow`); cut-out blocks are in `snippets/`.
To bring something back, move it to its original path and re-add any source list or
provenance entry named below.

## Spotify 9.1.x (only 9.2.x+ is supported now)

| File | Why |
|---|---|
| `NativeDownloads/targets/spotify-9.1.92.json`, `spotify-9.1.98.json` | Pixie profiles for 9.1.92/9.1.98. Builds default to 9.2.0; CI builds 9.2.0 and 9.2.2 only. |
| `NativeDownloads/tools/build_pixie14_9192.py`, `verify_pixie14_9192.py` | Builder/verifier for the EeveeSpotify 7.0.0 / Spotify 9.1.92 IPA. Nothing called them. |
| `NativeDownloads/tools/port/make_profile.py` | Built the 9.2.0 profile from the 9.1.98 one. `make_profile_922.py` (9.2.0 → 9.2.2) stays as the template for new versions. |

## Never reached

| What | Why |
|---|---|
| `NativeDownloads/src/Diagnostics/EncodedAudio.m`, `src/Public/EncodedAudio.h` | `SpotifyAudioProbeObserveOfflineKey` was never called by any patch, and its image check matched only the Spotify 9.1.88 UUID. The key table stayed empty, so `observed_audio_keys` in the download report was always 0. The cache probe inside was compiled out (`SAP_PROBE_MEDIA_CACHE=0`). |
| `NativeDownloads/tests/cache_envelope.c` | Not listed in `tools/test.py` or anywhere else. |
| `NativeDownloads/tools/patch_offline.py` | Renamed one class name inside `EeveeSpotify.dylib` at IPA build time to switch off Eevee's "playlist downloading is server-sided" popup. Eevee now skips that popup itself when Pixie is loaded, so a plain `EeveeSpotify.dylib` can be injected as is. |
| `snippets/src/**/*.removed.txt` (`SAP_RUNTIME_TESTING`) | Test hooks behind a flag that no build or test ever defined. |
| `snippets/src/Export/TrackCacheExport.m.removed.txt` (`SAP_RESEARCH_DUMP`) | Research dump of decoded media and key records to Documents; the flag was forced to 0. |
| `snippets/src/Export/CacheStorageKey.*.removed.txt`, `ExportObservation.m.removed.txt` | AES/CommonCrypto capture buffers read only by that research dump. `SAPObserveAesCtr`, `SAPObserveAesBlock` and `SAPCaptureCCCrypto` had no caller. `captureAesKey` ran on every cache-key boundary and kept keys in memory for no reader. |

Also removed in the same change: the unused `-DSAP_RESEARCH_DUMP=0 -DSAP_ENABLE_WAV_CAPTURE=0`
compiler flags, the `EncodedAudio.m` entries in the 9.2.0/9.2.2 source lists and the
provenance entries of the moved files.

Deliberately kept: `SAP_JAILBREAK` code (a jailbreak build may come back), the audio
probe (`AudioProbe.c` / `patch_imports.py`, it patches the playback path and needs a
device check before removal), and `SAP_TESTING` hooks used by the tests.
