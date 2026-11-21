"""Install the exact lyrics task identifier and preserve Spotify's identifiers."""
import plistlib
import re

BACKGROUND_PROCESSING_MARKER = b".pixie.lyrics.processing\x00"


def patch_info(data: bytes, *, signing_bundle_identifier: str | None = None,
               background_processing: bool = True) -> bytes:
    info = plistlib.loads(data)
    bundle = info.get("CFBundleIdentifier")
    if not isinstance(bundle, str) or not bundle:
        raise ValueError("Missing app bundle identifier")
    existing = info.get("BGTaskSchedulerPermittedIdentifiers", [])
    if not isinstance(existing, list) or not all(isinstance(x, str) for x in existing):
        raise ValueError("Invalid background task identifiers")
    target = bundle if signing_bundle_identifier is None else signing_bundle_identifier
    if not re.fullmatch(r"[A-Za-z0-9.-]+", target):
        raise ValueError("Invalid signing bundle identifier")
    suffix = BACKGROUND_PROCESSING_MARKER[:-1].decode()
    lyrics_identifiers = (".pixie.lyrics.*", ".pixie.lyrics.download", ".pixie.lyrics.continued",
                          ".pixie.lyrics.continued.*", suffix)
    retained = [value for value in existing if not value.endswith(lyrics_identifiers)]
    identifiers = [*retained, target + suffix] if background_processing else retained
    modes = info.get("UIBackgroundModes", [])
    if not isinstance(modes, list) or not all(isinstance(value, str) for value in modes):
        raise ValueError("Invalid background modes")
    updated_modes = [*modes, "processing"] if background_processing and "processing" not in modes else modes
    if identifiers == existing and updated_modes == modes:
        return data
    info["BGTaskSchedulerPermittedIdentifiers"] = identifiers
    if updated_modes != modes:
        info["UIBackgroundModes"] = updated_modes
    return plistlib.dumps(info, fmt=plistlib.FMT_BINARY if data.startswith(b"bplist") else plistlib.FMT_XML,
                          sort_keys=False)
