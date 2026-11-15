"""Rebuild Pixie inside an assembled target IPA without repatching Spotify/Eevee."""
import argparse
import hashlib
import json
import plistlib
from pathlib import Path
import subprocess
import tempfile
from zipfile import ZipFile

from companion_build import build_companion
from pixie_target import PROFILE, ROOT, validate_sources
from patch_native_restrictions import layout

ENTRY = "Payload/Spotify.app/Frameworks/SpotifyAudioProbe.dylib"


def run(*args):
    subprocess.run(list(map(str, args)), check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    validate_sources()
    if args.output.exists():
        parser.error("Choose a fresh output path")
    with ZipFile(args.ipa) as archive:
        archive.getinfo(ENTRY)
        info = plistlib.loads(archive.read("Payload/Spotify.app/Info.plist"))
        if info.get("CFBundleShortVersionString") != PROFILE["spotify_version"]:
            raise RuntimeError("Input Spotify version does not match the target")
        if layout(archive.read("Payload/Spotify.app/Spotify"))[3] != bytes.fromhex(PROFILE["uuid"]):
            raise RuntimeError("Input Spotify UUID does not match the target")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="pixie-companion-") as temporary:
        library = Path(temporary) / "SpotifyAudioProbe.dylib"
        replacement = build_companion(library, temporary)
        with ZipFile(args.ipa) as source, ZipFile(args.output, "w", allowZip64=True) as output:
            for member in source.infolist():
                output.writestr(member, replacement if member.filename == ENTRY else source.read(member.filename))
    with ZipFile(args.ipa) as source, ZipFile(args.output) as output:
        if output.testzip() is not None:
            raise RuntimeError("IPA ZIP integrity check failed")
        changed = [member.filename for member in source.infolist()
                   if (member.CRC, member.file_size) != (output.getinfo(member.filename).CRC,
                                                        output.getinfo(member.filename).file_size)]
        if changed != [ENTRY]:
            raise RuntimeError(f"Unexpected changed entries: {changed}")
    report = {"ipa": str(args.output.resolve()), "input": str(args.ipa.resolve()),
              "sha256": hashlib.sha256(args.output.read_bytes()).hexdigest(),
              "input_sha256": hashlib.sha256(args.ipa.read_bytes()).hexdigest(),
              "changed_entries": changed, "real_device_tested": False,
              "source_provenance_sha256": hashlib.sha256((ROOT / f"provenance-pixie-v{PROFILE['pixie_version']}.json").read_bytes()).hexdigest()}
    args.output.with_suffix(".build.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
