"""Disable the supplied Eevee reminder's guarded target lookup.

The single same-length class-name edit makes the existing 9.1.x activation
check return early, preserving Spotify's original offlining action handler.
"""
TARGET = b"Offline_ContentOffliningUIImpl.ContentOffliningUIHelperImplementation"
DISABLED = b"Xffline_ContentOffliningUIImpl.ContentOffliningUIHelperImplementation"


def patch_reminder(data: bytes):
    if data.count(TARGET) != 1 or len(TARGET) != len(DISABLED):
        raise ValueError("Expected exactly one known Eevee offlining reminder target")
    offset = data.index(TARGET)
    result = data[:offset] + DISABLED + data[offset + len(TARGET):]
    if len(result) != len(data) or result.count(TARGET) != 0 or result.count(DISABLED) != 1:
        raise ValueError("Unexpected reminder patch result")
    return result, {"offset": offset, "changed_bytes": 1,
                    "old_target": TARGET.decode(), "disabled_target": DISABLED.decode()}
