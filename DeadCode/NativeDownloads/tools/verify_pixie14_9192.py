"""Independently check a Pixie 1.4 build against its assembled 9.1.92 input IPA."""
import argparse
import hashlib
import json
import plistlib
import subprocess
import tempfile
from pathlib import Path
from zipfile import ZipFile

import patch_export as export
import patch_native_restrictions as quota
from export_release_materials import notices
from pixie_target import PROFILE
from strip_stale_signature import strip_stale_signature

APP = "Payload/Spotify.app/"
MAIN = APP + "Spotify"
COMPANION = APP + "Frameworks/SpotifyAudioProbe.dylib"
EEVEE = APP + "Frameworks/EeveeSpotify.dylib"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    with ZipFile(args.input) as source, ZipFile(args.output) as result:
        require(result.testzip() is None, "IPA ZIP integrity check failed")
        info = plistlib.loads(result.read(APP + "Info.plist"))
        require(info["CFBundleShortVersionString"] == PROFILE["spotify_version"], "Wrong Spotify version")
        original = source.read(MAIN)
        require(quota.layout(original)[3] == quota.UUID, "Wrong input Spotify UUID")
        expected, manifest = export.patch(original)
        added = set(result.namelist()) - set(source.namelist())
        require(added == set(notices()), f"Unexpected added entries: {added}")
        require(not set(source.namelist()) - set(result.namelist()), "Removed IPA entries")
        require(len(result.namelist()) == len(set(result.namelist())), "Duplicate IPA entries")
        changed = [e.filename for e in source.infolist()
                   if (e.CRC, e.file_size) != (result.getinfo(e.filename).CRC, result.getinfo(e.filename).file_size)]
        require(set(changed) == {MAIN, COMPANION}, f"Unexpected changed entries: {changed}")
        require(result.read(EEVEE) == source.read(EEVEE), "EeveeSpotify.dylib changed")
        packaged = result.read(MAIN)
        _, first, segments, _ = quota.layout(expected)
        text = next(s for s in segments if s[0] == b"__TEXT")
        require(packaged[first:text[3] + text[4]] == expected[first:text[3] + text[4]],
                "Packaged executable code differs from the verified patches")
        spans = []
        for name, entry, cave, displaced, kind in export.ALL_POINTS:
            code = export.trampoline((name, entry, cave, displaced, kind))
            start = text[3] + cave - text[1]
            require(packaged[start:start + len(code)] == code, f"{name} cave differs")
            at = text[3] + entry - text[1]
            require(packaged[at:at + 4] == export.branch(entry, cave).to_bytes(4, "little"), f"{name} entry branch differs")
            spans.append((name, hex(entry), hex(cave), len(code)))
        # ldid (AltStore) asserts the string table ends within 0x10 bytes of the code signature.
        _, stale = strip_stale_signature(packaged)
        require(stale == 0, f"Executable keeps {stale} dead bytes in front of its code signature")
        companion = result.read(COMPANION)
        require(b"SAPObserveExportBoundaryV2" in companion, "Companion lacks the export boundary helper")
        require(b"live.bin" not in companion, "Research dump path compiled in")
        require(f"{PROFILE['spotify_version']}-v{PROFILE['pixie_version']}".encode() in companion, "Companion build label missing")
        with tempfile.TemporaryDirectory() as temp:
            executable, library = Path(temp) / "Spotify", Path(temp) / "SpotifyAudioProbe.dylib"
            executable.write_bytes(packaged)
            library.write_bytes(companion)
            for binary in (executable, library):
                subprocess.run(["codesign", "--verify", "--strict", binary], check=True)
                subprocess.run(["xcrun", "dyld_info", "-validate_only", binary], check=True)
            imports = subprocess.check_output(["xcrun", "dyld_info", "-imports", str(executable)], text=True)
        for symbol in ("_AudioComponentInstanceDispose", "_AudioOutputUnitStart", "_AudioOutputUnitStop",
                       "_AudioUnitGetProperty", "_AudioUnitSetProperty"):
            lines = [line for line in imports.splitlines() if symbol in line]
            require(lines and all("SpotifyAudioProbe" in line for line in lines), f"Audio import not redirected: {symbol}")
        report = {"input_sha256": hashlib.sha256(args.input.read_bytes()).hexdigest(),
                  "output_sha256": hashlib.sha256(args.output.read_bytes()).hexdigest(),
                  "pixie_version": PROFILE["pixie_version"], "spotify_version": PROFILE["spotify_version"],
                  "changed_entries": changed, "added_entries": sorted(added), "eevee_dylib_unchanged": True,
                  "export_boundaries": spans, "packaged_text_matches_verified_patches": True,
                  "audio_imports_redirected": True, "no_dead_bytes_before_signature": True, "phone_runtime_tested": False}
    if args.report:
        args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
