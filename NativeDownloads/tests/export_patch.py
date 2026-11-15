"""Export observation sites: generated headers, cave layout and, when available, the real executable."""
from pathlib import Path
import hashlib
import json
import os
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import export_headers
import patch_export as export
from patch_native_restrictions import branch
from pixie_target import PROFILE

# Generated headers must match the target profile.
for name, expected in export_headers.headers().items():
    assert (ROOT / "src/Generated" / name).read_text() == expected, name

# No source outside the generated headers may carry another Spotify build's image identity: a hardcoded
# 9.1.90 UUID in ExportObservation.m silently disabled every export boundary on 9.1.92.
import re
foreign = {"9.1.90": "fbce22c17e1b3e0d9be866ff9291943e", "9.1.88": "f51dbd933b8f3a12943196c606e3afc2"}
run = re.compile(r"0x[0-9a-fA-F]{2}(?:\s*,\s*0x[0-9a-fA-F]{2})+")
for path in (ROOT / "src").rglob("*"):
    if path.suffix not in {".m", ".c", ".h", ".swift"} or "Generated" in path.parts:
        continue
    if str(path.relative_to(ROOT / "src")) == "Diagnostics/EncodedAudio.m":
        continue  # research-only decoder, compiled out (SAP_PROBE_MEDIA_CACHE=0) and UUID-guarded
    text = path.read_text(errors="ignore").lower()
    flattened = [re.sub(r"[^0-9a-f]", "", re.sub(r"0x", "", m.group(0))) for m in run.finditer(text)]
    for version, uuid in foreign.items():
        assert uuid not in text and not any(uuid in item for item in flattened), \
            f"{path}: contains the Spotify {version} image identity; use TargetProfile.h"
assert "SAP_SPOTIFY_UUID_BYTES" in (ROOT / "src/Export/ExportObservation.m").read_text()

# The key owner's file descriptor moved from +0xc8 (9.1.90) to +0x120 (9.1.92); only the generated constant may be used.
for path in (ROOT / "src").rglob("*.m"):
    if "Generated" in path.parts or path.name == "EncodedAudio.m":
        continue
    text = path.read_text(errors="ignore")
    assert not re.search(r"owner\s*\+\s*0xc8\b|UINTPTR_MAX-0xc8\b", text), f"{path}: hardcoded 9.1.90 owner descriptor offset"

# Caves: 512-byte slots, disjoint from each other and from the Pixie native caves.
ranges = []
for name, entry, cave, displaced, kind in export.ALL_POINTS:
    code = export.trampoline((name, entry, cave, displaced, kind))
    assert len(code) <= export.CAVE_STRIDE and len(displaced) in (4, 16), name
    branch(entry, cave)
    ranges.append((cave, cave + len(code), name))
native = PROFILE["native"]
reserved = [int(native[key], 16) for key in ("setter_cave", "selector_cave")]
reserved += [int(point["cave"], 16) for point in PROFILE["trace_points"]]
for start, end, name in ranges:
    for cave in reserved:
        assert not (start <= cave < end), f"{name} cave overlaps a Pixie native cave"
ranges.sort()
for (a0, a1, an), (b0, b1, bn) in zip(ranges, ranges[1:]):
    assert a1 <= b0, f"{an} overlaps {bn}"
assert len({entry for _, entry, _, _, _ in export.ALL_POINTS}) == len(export.ALL_POINTS)

# Real executable (not part of the repository): apply, compare, repeat and mismatch checks.
source = os.environ.get("PIXIE_EXECUTABLE") or os.environ.get("PIXIE_9192_EXECUTABLE")
if source and Path(source).is_file():
    original = Path(source).read_bytes()
    final, manifest = export.patch(original)
    allowed = []
    for name, entry, cave, displaced, kind in export.ALL_POINTS:
        allowed += [(entry - export.BASE, entry - export.BASE + 4),
                    (cave - export.BASE, cave - export.BASE + len(export.trampoline((name, entry, cave, displaced, kind))))]
    allowed.sort()
    position = 0
    for start, end in allowed:
        assert original[position:start] == final[position:start]
        position = end
    assert original[position:] == final[position:]
    for call in (lambda: export.patch(final),):
        try:
            call()
        except ValueError:
            pass
        else:
            raise AssertionError("Repeat export patch accepted")
    for _, entry, cave, _, _ in export.ALL_POINTS:
        for where in (entry - export.BASE, cave - export.BASE):
            bad = bytearray(original)
            bad[where] ^= 1
            try:
                export.patch(bad)
            except ValueError:
                pass
            else:
                raise AssertionError("Mismatched export source or cave accepted")
    for name in PROFILE['export']['windows']:
        bad = bytearray(original)
        bad[export.window(name)[0] - export.BASE] ^= 1
        try:
            export.patch(bad)
        except ValueError:
            pass
        else:
            raise AssertionError(f"Mismatched {name} code guard accepted")
    # The dead bytes in front of the signature are removed without touching code or data.
    from strip_stale_signature import strip_stale_signature
    from patch_native_restrictions import layout
    stripped, removed = strip_stale_signature(final)
    assert len(stripped) == len(final) - removed
    _, first, segments, _ = layout(final)
    text = next(s for s in segments if s[0] == b"__TEXT")
    assert stripped[first:text[3] + text[4]] == final[first:text[3] + text[4]]
    if removed:
        try:
            strip_stale_signature(stripped)
        except ValueError:
            pass
        else:
            raise AssertionError("A second strip of an unsigned executable was accepted")
    out = Path(os.environ.get("PIXIE_TEST_BUILD_DIR", ROOT.parent / "outputs/export-patch-test"))
    out.mkdir(parents=True, exist_ok=True)
    (out / "verified-export-boundaries.json").write_text(json.dumps(
        {"sha256": hashlib.sha256(final).hexdigest(), "allowed_ranges": allowed, "manifest": manifest}, indent=2))
    print(f"PASS exact {PROFILE['spotify_version']} export sites, padding only; repeat/mismatched/occupied patches rejected")
else:
    print("PASS generated headers and cave layout (set PIXIE_EXECUTABLE to check the real executable)")
