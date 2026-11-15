"""Validate the current Eevee/Pixie source snapshot without an IPA or credentials."""
from pathlib import Path
import hashlib
import json
from pixie_target import PROFILE, validate_sources, resolve_source, target_header

ROOT = Path(__file__).resolve().parents[2]

def main():
    validate_sources()
    assert resolve_source("TargetProfile.h").read_text() == target_header()
    manifest = json.loads((ROOT / f"NativeDownloads/provenance-pixie-v{PROFILE['pixie_version']}.json").read_text())
    assert manifest["spotify_version"] == PROFILE["spotify_version"]
    for relative, expected in manifest["source_sha256_by_file"].items():
        path = ROOT / relative
        assert hashlib.sha256(path.read_bytes()).hexdigest() == expected, relative
    from patch_native_restrictions import guard_header, limits_header
    from patch_key_request_mode import key_header
    from patch_native_trace import header
    for name, expected in [("NativeRestrictionsPatch.h", guard_header()),
                           ("OfflineLimits.h", limits_header()),
                           ("NativeKeyModePatch.h", key_header()),
                           ("NativeTracePatch.h", header())]:
        assert resolve_source(name).read_text() == expected, name
    from export_headers import headers as export_headers
    for name, expected in export_headers().items():
        assert resolve_source(name).read_text() == expected, name
    for path in (ROOT / "NativeDownloads/tools").glob("*.py"):
        compile(path.read_text(), str(path), "exec")
    print(f"PASS: {len(manifest['source_sha256_by_file'])} source hashes, generated native guards and Python syntax")

if __name__ == "__main__":
    main()
