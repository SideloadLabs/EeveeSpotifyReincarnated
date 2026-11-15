"""Build Pixie 1.4 into the assembled EeveeSpotify 7.0.0 / Spotify 9.1.92 IPA.

Input is the preserved assembled IPA that already carries the Pixie 1.3 native
patches and EeveeSpotify. Only the Spotify executable (export observations) and
SpotifyAudioProbe.dylib are replaced; EeveeSpotify and every other file are
preserved byte for byte.
"""
import argparse
import hashlib
import json
import plistlib
import subprocess
import tempfile
from pathlib import Path
from zipfile import ZipFile

from companion_build import build_companion
from export_headers import headers
from export_release_materials import notices, retain_relink_sources
from patch_export import patch as patch_export
from patch_native_restrictions import layout
from pixie_target import PROFILE, PROFILE_PATH, ROOT, validate_sources
from signing_metadata import sign_preserving_entitlements
from strip_stale_signature import strip_stale_signature

MAIN = "Payload/Spotify.app/Spotify"
COMPANION = "Payload/Spotify.app/Frameworks/SpotifyAudioProbe.dylib"
EEVEE = "Payload/Spotify.app/Frameworks/EeveeSpotify.dylib"
UUID = bytes.fromhex(PROFILE["uuid"])


def run(*command):
    subprocess.run([str(part) for part in command], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    sources = validate_sources()
    if args.output.exists():
        parser.error("Choose a fresh output path")
    for name, expected in headers().items():
        if (ROOT / "src/Generated" / name).read_text() != expected:
            raise RuntimeError(f"Stale generated header: {name}")
    with ZipFile(args.ipa) as archive:
        names = archive.namelist()
        info = plistlib.loads(archive.read("Payload/Spotify.app/Info.plist"))
        if info.get("CFBundleShortVersionString") != PROFILE["spotify_version"]:
            raise RuntimeError("Spotify version mismatch")
        if EEVEE not in names or COMPANION not in names:
            raise RuntimeError("Expected the assembled Eevee + Pixie IPA")
        original = archive.read(MAIN)
        if layout(original)[3] != UUID:
            raise RuntimeError("Spotify UUID mismatch")
        patched, observations = patch_export(original)
        patched, stale_bytes = strip_stale_signature(patched)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="pixie14-9192-") as temp:
        temp = Path(temp)
        library, executable = temp / "SpotifyAudioProbe.dylib", temp / "Spotify"
        replacement = build_companion(library, temp)
        executable.write_bytes(patched)
        executable.chmod(0o755)
        signing = sign_preserving_entitlements(executable, original, temp / "entitlements.plist")
        run("codesign", "--verify", "--strict", executable)
        run("xcrun", "dyld_info", "-validate_only", executable)
        patched = executable.read_bytes()
        if b"live.bin" in replacement or b"SAPObserveExportBoundaryV2" not in replacement:
            raise RuntimeError("Research dumping leaked or the export boundary is missing")
        additions = notices()
        with ZipFile(args.ipa) as source, ZipFile(args.output, "w", allowZip64=True) as result:
            for item in source.infolist():
                data = replacement if item.filename == COMPANION else patched if item.filename == MAIN else source.read(item.filename)
                result.writestr(item, data)
            for name, data in additions.items():
                if name in source.namelist():
                    raise RuntimeError("Unexpected preexisting export license path")
                result.writestr(name, data)
        with ZipFile(args.ipa) as source, ZipFile(args.output) as result:
            assert result.testzip() is None
            assert result.namelist() == source.namelist() + list(additions)
            changed = [n for n in source.namelist() if source.getinfo(n).CRC != result.getinfo(n).CRC]
            assert set(changed) == {MAIN, COMPANION}, changed
    snapshot = [*sources, *(ROOT / "src").rglob("*.h"), *(ROOT / "src").rglob("*.swift"),
                *(ROOT / "vendor").iterdir(), PROFILE_PATH]
    report = {"ipa": str(args.output.resolve()), "input": str(args.ipa.resolve()),
              "sha256": hashlib.sha256(args.output.read_bytes()).hexdigest(),
              "input_sha256": hashlib.sha256(args.ipa.read_bytes()).hexdigest(),
              "pixie_version": PROFILE["pixie_version"], "eevee_version": PROFILE["eevee_version"],
              "spotify_version": PROFILE["spotify_version"], "spotify_uuid": UUID.hex(),
              "export_implementation": PROFILE.get("audio_export"), "audio_export_formats": ["m4a", "ogg"],
              "changed_entries": changed, "additional_entries": list(additions),
              "relink_sources": retain_relink_sources(args.output), "native_observations": observations, "stale_signature_bytes_removed": stale_bytes, "signing": signing,
              "research_key_dump_compiled_out": True, "wav_capture": False,
              "source_sha256": {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in snapshot},
              "phone_launched": False, "device_export_verified": False}
    args.output.with_suffix(".build.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({k: report[k] for k in ("ipa", "sha256", "changed_entries", "pixie_version", "device_export_verified")}, indent=2))


if __name__ == "__main__":
    main()
