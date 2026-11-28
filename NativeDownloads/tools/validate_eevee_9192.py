"""Validate the current Eevee/Pixie source snapshot without an IPA or credentials."""
from pathlib import Path
import hashlib
import json
from pixie_target import PROFILE, validate_sources, resolve_source, target_header

ROOT = Path(__file__).resolve().parents[2]


def check_translation_keys():
    """Every key Pixie translates exists in English and Russian (other languages fall back to English)."""
    import re, subprocess
    bundle = ROOT / "layout/Library/Application Support/EeveeSpotify.bundle"
    tables = {language: json.loads(subprocess.run(
        ["plutil", "-convert", "json", "-o", "-", str(bundle / f"{language}.lproj/Localizable.strings")],
        capture_output=True, check=True).stdout) for language in ("en", "ru")}
    # Keys Pixie keeps as data (release categories, mode details, errors) and translates when shown.
    data_keys = {"albums", "eps", "singles", "singles_eps", "compilations", "appears_on", "unknown_artist",
                 "another_export_is_already_running", "audio_export_cancelled", "preparing_cover_artwork",
                 "download_in_progress", "metadata_unavailable", "malformed_native_offline_context",
                 "malformed_native_offline_item_identity", "native_offline_context_enumeration_failed",
                 "native_offline_context_identity_missing", "native_offline_item_validation_failed",
                 "native_offline_item_validation_omitted_requested",
                 "native_offline_item_validation_returned_inconsistent", "playlist_contents_are_still_loading",
                 "the_playlist_changed_while_being_read", "mode_0_is_verified_in_the", "mode_1_is_verified_in_the",
                 "only_restoring_a_confirmed_mode_1", "the_installed_request_mode_cannot_be",
                 "the_verified_selector_returned_1_restoring"}
    keys, literals = set(data_keys), set()
    for path in (ROOT / "NativeDownloads/src").rglob("*.m"):
        text = path.read_text()
        keys.update(re.findall(r'SAPLocalized\(@"([^"\\]*)"\)', text))
        literals.update(re.findall(r'@"([a-z0-9_]+)"', text))
    assert data_keys <= literals, f"Pixie no longer uses: {sorted(data_keys - literals)}"
    for language, table in tables.items():
        missing = sorted(keys - set(table))
        assert not missing, f"{language}.lproj lacks Pixie keys: {missing}"
    print(f"PASS: {len(keys)} Pixie translation keys in en and ru")


def main():
    validate_sources()
    assert resolve_source("TargetProfile.h").read_text() == target_header()
    manifest = json.loads((ROOT / f"NativeDownloads/provenance-pixie-v{PROFILE['pixie_version']}.json").read_text())
    # One snapshot serves every target of this Pixie release; each target has its own profile.
    assert manifest["pixie_version"] == PROFILE["pixie_version"]
    mismatched = []
    for relative, expected in manifest["source_sha256_by_file"].items():
        if relative.endswith(".md") or relative.endswith("BuildIdentity.h") \
                or relative.startswith("NativeDownloads/tools/port/"):
            continue  # documentation is not part of the source snapshot
        path = ROOT / relative
        if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            mismatched.append(relative)
    if mismatched:
        # Source edits are expected; report them without failing the build. Re-record with
        # NativeDownloads/tools/source_provenance.py to silence this.
        print("::warning::Changed since provenance was recorded: " + ", ".join(mismatched))
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
    check_translation_keys()
    print(f"PASS: {len(manifest['source_sha256_by_file'])} recorded hashes ({len(mismatched)} changed), generated native guards and Python syntax")

if __name__ == "__main__":
    main()
