# Pixie integration map

Current target: EeveeSpotify 7.0.1, Spotify 9.2.0, Pixie 1.4.
This map describes the existing implementation; it does not introduce a new API.

## Start here

1. [Build guide](../../BUILD-pixie-v1.4.md): supported companion-library packaging.
2. [Target manifest](../targets/spotify-9.2.0.json): exact Spotify identity,
   guarded native addresses, all production translation units and dependency groups.
   Use `tools/pixie_target.py` to resolve sources and include directories.
3. [Bootstrap](../src/Runtime/PixieBootstrap.m): initialization order and process scope.
4. [Public headers](../src/Public): callable integration surface. Existing `SAP` and
   `SpotifyAudioProbe` symbol names, headers and dylib name retain compatibility.
5. [Contracts](CONTRACTS.md): thread ownership, cancellation and download evidence.

Do not copy only the UI files or compile every `.m` recursively. Use the explicit
manifest.
Native offsets are specific to the manifest's Spotify UUID, not to the host tweak.
This target packages a companion IPA; a working jailbreak adapter is not supplied
by this source layout alone.

## Where to change what

Paths below are relative to `src/`.

| Concern | Implementation / entry point |
| --- | --- |
| Settings entry, manager screens, offline-device table | `UI/PixieManagerSettings.m` |
| Manager button actions and diagnostic reports | `UI/PixieManagerActions.m`; API: `Public/AudioProbeUI.h` |
| Artist release list and selection | `UI/ArtistDownloadsUI.m`, `UI/ArtistDownloadComponents.m` |
| Existing-playlist picker | `UI/PlaylistPickerController.m` |
| Host artist-header buttons | Eevee integration under `Sources/EeveeSpotify*`; not owned by the manager table |
| Single-track action from the manager | `Downloads/ManualTrackDownload.m`; API: `Public/TrackDownload.h` |
| Artist queue and release lifecycle | `Downloads/ArtistDownloadSession.m`, `ArtistSession*.m`, `ReleaseDownloadOperation.m` |
| Shared playlist tasks and scheduling | `Playlists/PlaylistTaskRegistry.m`; API: `Public/PlaylistDownloads.h` |
| Create/read/update playlists | `Playlists/PlaylistRepository.m` |
| Whole-release batches into a playlist | `Playlists/IncrementalPlaylistTask.m`, `PlaylistDownloadTask.m` |
| Playlist track-state observation | `Playlists/ReleaseItemObservation.m` |
| Artist and album metadata | `Catalog/ArtistMetadata.m`, `Catalog/AlbumMetadata.m` |
| Artwork loading and cache | `Artwork/ArtistArtworkLoader.m`, `Artwork/PlaylistArtwork.h` |
| Offline devices and removal | `Devices/OfflineDeviceManager.m`; API: `Public/OfflineDevices.h` |
| Quota/license compatibility checks | `Devices/OfflineCompatibilityChecks.m`; API: `Public/DownloadCompatibility.h` |
| Guarded native manager integration | `Spotify/NativeOfflineAdapter.m`; API: `Public/NativeOffline.h` |
| Transport lifetime, hooks, reads, commands | `Spotify/SpotifyTransportRegistry.m`, `SpotifyTransportHooks.m`, `SpotifyServiceCalls.m`, `SpotifyCommands.m` |
| Protobuf wire helpers | `Spotify/WireProto.h`, `Spotify/WireProto.m` |
| Diagnostics enabled preference | `Diagnostics/DiagnosticsPreferences.m`; API: `Public/Diagnostics.h` |
| Journal state, observation and files | `Diagnostics/TrackJournal.m`, `Journal*.m` |
| Combined support-log format | `Diagnostics/SupportLogSerializer.m`; API: `Public/SupportLog.h` |
| Background log export orchestration | `Diagnostics/SupportLogExporter.m` |
| Audio/player/native tracing | Remaining named modules under `Diagnostics/` |
| Generated guards and build identity | `Generated/`; regenerate with the matching tools, not manual edits |

## File-name compatibility

Only nine implementation filenames were renamed. Public header names, exported
functions, Objective-C classes/selectors, preference keys, log event names and
runtime data paths were not renamed. Implementation file contents are unchanged.
Build and fixture source lists use the new filenames. External build scripts that
enumerate old implementation filenames must update them using
[the exact rename map](FILE-RENAMES.json).

## Historical material noticed during this pass

- `Diagnostics/EncodedAudio.m` still contains an old hard-coded Spotify UUID and a
  `SAP_PROBE_MEDIA_CACHE` branch disabled by default. It remains a production source
  with compatibility entry points, so it was not removed or enabled. Its old image
  guard does not match the current target. Review separately before reusing it.

This was a naming and reference pass, not a deep correctness or dead-code audit.
