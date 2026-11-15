"""Write every target-dependent header in src/Generated from the active profile (PIXIE_TARGET)."""
import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from pixie_target import ROOT, target_header, PROFILE
from export_headers import headers
from patch_native_restrictions import guard_header, limits_header
from patch_key_request_mode import key_header
from patch_native_trace import header as trace_header

folder = ROOT / "src/Generated"
out = {"TargetProfile.h": target_header(), "NativeRestrictionsPatch.h": guard_header(), "OfflineLimits.h": limits_header(),
       "NativeKeyModePatch.h": key_header(), "NativeTracePatch.h": trace_header()}
out.update(headers())
for name, text in out.items():
    old = (folder / name).read_text() if (folder / name).is_file() else None
    (folder / name).write_text(text)
    print(("changed " if old != text else "same    ") + name)
