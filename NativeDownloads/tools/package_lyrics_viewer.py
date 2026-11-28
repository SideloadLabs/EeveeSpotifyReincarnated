"""Apply the local offline lyrics viewer patch to an assembled IPA."""
import argparse
import json
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path
from zipfile import ZipFile

from patch_lyrics_offline_cache import patch
from signing_metadata import sign_preserving_entitlements


def patch_ipa(source, output):
    """Run the same pass on an assembled IPA outside the Pixie profiles."""
    if output.exists():
        raise ValueError("Choose a fresh output path")
    app = "Payload/Spotify.app/"
    executable = app + "Spotify"
    with ZipFile(source) as archive:
        original = archive.read(executable)
        original_info = archive.read(app + "Info.plist")
        if "EeveeOfflineLyricsRegistration" in plistlib.loads(original_info):
            raise ValueError("Choose the input IPA from before the lyrics registration patch")
        patched, report = patch(original)
        if not report["applied"]:
            with source.open("rb") as source_file, output.open("xb") as result_file:
                shutil.copyfileobj(source_file, result_file)
            return report
        with tempfile.TemporaryDirectory(prefix="offline-lyrics-") as temp:
            binary = Path(temp)/"Spotify"
            binary.write_bytes(patched)
            binary.chmod(0o755)
            sign_preserving_entitlements(binary, original, Path(temp)/"entitlements.plist")
            subprocess.run(["xcrun", "dyld_info", "-validate_only", str(binary)], check=True)
            patched = binary.read_bytes()
        partial = output.with_suffix(".ipa.partial")
        with partial.open("xb") as target, ZipFile(target, "w") as result:
            for entry in archive.infolist():
                payload = patched if entry.filename == executable else archive.read(entry)
                result.writestr(entry, payload)
        with ZipFile(partial) as result:
            if result.testzip() is not None:
                raise ValueError("Failed IPA integrity check")
        partial.rename(output)
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path, help="assembled IPA with the current Eevee dylib")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    print(json.dumps(patch_ipa(args.ipa, args.output), indent=2))
