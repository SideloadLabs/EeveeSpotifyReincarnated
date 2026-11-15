# EeveeSpotify 7.0.1 / Spotify 9.2.0 / Pixie Manager 1.4

The active target is `NativeDownloads/targets/spotify-9.2.0.json`: Spotify build `920002054`,
ARM64 UUID `b49e75781d8635d38bb57daf68fed8a8`. Unknown UUIDs, altered instructions, occupied caves
and repeated patches are rejected.

Requires Apple Silicon macOS, Xcode with the iPhoneOS SDK, Python 3, GNU Make and the project's
existing Theos/Orion/EeveeSwiftProtobuf toolchain. Set
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` if the system selection points to
CommandLineTools. Nothing here installs or launches anything on a device.

## Checks

```sh
python3 NativeDownloads/tools/validate_eevee_9192.py
python3 NativeDownloads/tools/test.py
```

Host fixtures do not prove real Spotify connectivity or device playback. To also verify the
supplied binary, set `PIXIE_EXECUTABLE=/path/to/original/Spotify` and
`SPOTIFY_TEST_IPA=/path/to/input.ipa` before running `test.py`.

The historical `*_9192.py` entry-point filenames are kept for existing automation; the builders,
guards and verifier use the active target profile.

## Build

```sh
python3 NativeDownloads/tools/build.py /path/to/input.ipa --theos /path/to/theos --output-dir outputs/new-build
```

The builder rebuilds the Eevee library with Theos and Pixie with the companion compiler, patches
and signs Spotify, and writes a new IPA. A compatible decrypted Spotify 9.2.0 IPA must be supplied.
Only the Spotify executable and the Eevee library are replaced; Pixie and its license notice are
added. Resources, Info.plist and extensions remain byte-identical and the executable entitlements
are preserved. The `.build.json` records input/output hashes, source hashes, the Git commit and
patch locations. Install with your own signing tool; no certificate or account data is included.

A lower-level route accepts an already compiled Eevee library:

```sh
python3 NativeDownloads/tools/build_eevee_9192.py /path/to/input.ipa --eevee-dylib /path/to/EeveeSpotify.dylib --output outputs/new-build/Spotify-9.2.0-EeveeSpotify-Pixie-v1.4.ipa
python3 NativeDownloads/tools/verify_eevee_9192.py /path/to/input.ipa --output outputs/new-build/Spotify-9.2.0-EeveeSpotify-Pixie-v1.4.ipa --report outputs/new-build/verification.json
```

## Source provenance

`NativeDownloads/provenance-pixie-v1.4.json` records the reviewed source hashes. After
intentionally changing sources, regenerate and re-check it:

```sh
python3 NativeDownloads/tools/generate_target.py
python3 NativeDownloads/tools/source_provenance.py
python3 NativeDownloads/tools/validate_eevee_9192.py
```

Changing the target JSON does not discover or validate new offsets.
