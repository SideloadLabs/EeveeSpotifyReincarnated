# Pixie Manager 1.4 — EeveeSpotify 7.0.1 / Spotify 9.2.0

Current source tree and companion IPA target. Start with [the build guide](../BUILD-pixie-v1.4.md).

Embedding Pixie in another tweak? See the [integration and file map](docs/INTEGRATION-MAP.md),
including public entry points and the implementation filename migration table.

`targets/spotify-9.2.0.json` owns native identity, the explicit production source list and test dependency groups. `tools/pixie_target.py` is the common reader. Unknown UUIDs or instruction bytes are rejected.

## Source modules

| Directory | Responsibility |
| --- | --- |
| `src/Public` | Existing C/Objective-C API names retained for Eevee and fixtures |
| `src/Runtime` | One bootstrap and app-extension process guard |
| `src/Spotify` | Native adapter, transport registry/hooks, bounded reads and one-shot commands |
| `src/Downloads` | Session, FIFO scheduling, ownership, native observation, cancellation and manual jobs |
| `src/Playlists` | Repository, ordered whole-release workflow and actual item evidence |
| `src/Catalog` | Artist/album metadata |
| `src/Devices` | Offline-device requests and readback |
| `src/Artwork` | Cancellable shared artwork loader and bounded cache |
| `src/UI` | Manager, artist page, picker and reusable components |
| `src/Diagnostics` | Optional trace, journal storage/writer/formatting and support-log export |
| `src/Generated` | Generated guards/target identity and existing embedded assets |

The Eevee UI hooks that belong in its library remain under `Sources/EeveeSpotify*`. Pixie is a separate companion library in this IPA target.

## Checks

```sh
python3 NativeDownloads/tools/validate_eevee_9192.py
python3 NativeDownloads/tools/test.py
```

See [test coverage and limits](tests/README.md), [data and lifetime contracts](docs/CONTRACTS.md). Host fixtures do not prove real Spotify connectivity or device playback.

Use a fresh `outputs/<build-id>/` for every build. Public `SAP`/`SpotifyAudioProbe` symbol and preference names retain compatibility.
