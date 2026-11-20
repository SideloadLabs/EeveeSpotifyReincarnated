"""Exercise the shape-based offline lyrics cache patch on a synthetic Mach-O."""
import plistlib
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "NativeDownloads/tools"))
import patch_lyrics_offline_cache as patcher
import patch_lyrics_plugin_registration as registration

# The 15 instructions of Spotify 9.2.0's offline branch at 0x100813f20.
SHAPE = bytes.fromhex(
    "88c24039c2fa44f91f05007101050054"
    "d3420091e80313aa08ff7394e00313aa17cdd1951f040071c1060054"
    "c80645f9084942391f050071a10a0054"
)
BASE = 0x100000000


def macho(code, uuid=b"\x11" * 16, base=BASE):
    header, segment, uuid_cmd = 32, 72 + 80, 24
    text_offset = header + segment + uuid_cmd
    size = text_offset + len(code)
    data = bytearray(size)
    struct.pack_into("<8I", data, 0, 0xFEEDFACF, 0x100000C, 0, 2, 2, segment + uuid_cmd, 0, 0)
    struct.pack_into("<II16sQQQQiiII", data, 32, 0x19, segment, b"__TEXT", base, size, 0, size, 5, 5, 1, 0)
    struct.pack_into("<16s16sQQIIIIIIII", data, 32 + 72, b"__text", b"__TEXT",
                     base + text_offset, len(code), text_offset, 2, 0, 0, 0x80000400, 0, 0, 0)
    struct.pack_into("<II16s", data, 32 + segment, 0x1B, uuid_cmd, uuid)
    data[text_offset:] = code
    return bytes(data), text_offset


filler = struct.pack("<I", 0xD503201F) * 7  # nop
before, text_offset = macho(filler + SHAPE + filler)
after, report = patcher.patch(before, "test")
assert report["applied"], report
entry = BASE + text_offset + len(filler) + 4 * 4
assert report["entry"] == hex(entry) and report["destination"] == hex(entry + 7 * 4)
at = report["file_offset"]
assert before[:at] == after[:at] and before[at+4:] == after[at+4:], "more than one instruction changed"
word = struct.unpack_from("<I", after, at)[0]
assert word >> 26 == 5 and (word & 0x3FFFFFF) * 4 == 7 * 4, "branch does not reach the offline-enabled check"
assert report["network_state_offset"] == "0x30" and report["offline_flag_offset"] == "0x92"

# Already patched: refuse (the builder must start from a clean executable).
try:
    patcher.patch(after)
except ValueError:
    pass
else:
    raise AssertionError("an already patched executable was accepted")

# Unknown or changed code: unchanged, with a reason. Never raises.
for changed in (0, 4 * 4, 9 * 4, 12 * 4):
    code = bytearray(SHAPE); code[changed + 3] ^= 0x80
    data, _ = macho(filler + bytes(code) + filler)
    result, report = patcher.patch(data)
    assert result == data and not report["applied"] and "not found" in report["reason"], (changed, report)

# Two candidates: ambiguous, unchanged.
twice, _ = macho(SHAPE + filler + SHAPE)
result, report = patcher.patch(twice)
assert result == twice and not report["applied"] and "ambiguous" in report["reason"]

# Not a Mach-O.
result, report = patcher.patch(b"not a binary" * 4)
assert not report["applied"] and "Mach-O" in report["reason"]
print("Native offline lyrics cache patch: shape match, single-instruction change, refusals and skips passed")

def registration_code(plugin=registration.PLUGIN, displacement=0xA0):
    gate = 8
    target = gate+displacement
    name = target + registration.CONTINUATION_LENGTH
    code = bytearray(name + len(plugin))
    code[:gate] = registration.GATE_PREFIX
    # Compute the plugin name in x21 before applying Swift's large-string tag.
    distance = name-(gate+4)
    adr = 0x10000015 | (distance&3)<<29 | (distance>>2)<<5
    struct.pack_into("<III", code, gate, 0x54000001 | (displacement//4)<<5, adr, 0xB24102B5)
    struct.pack_into("<7I", code, target, 0xAA1903E0, 0x94000000, 0xF9400709,
                     0xD10403A8, 0xAA1903F4, 0xAA1803E1, 0xD63F0120)
    code[name:] = plugin
    return bytes(code)


info = plistlib.dumps({"CFBundleIdentifier": "com.spotify.client"}, fmt=plistlib.FMT_BINARY)
for base, identity, displacement in [(0x100000000, b"\x03"*16, 0xA0), (0x104100000, b"\xE8"*16, 0x180)]:
    native, offset = macho(filler + registration_code(displacement=displacement), identity, base=base)
    isolated, report = registration.patch(native)
    gate = offset + len(filler) + 8
    assert report["applied"] and report["file_offset"] == gate
    assert native[:gate] == isolated[:gate] and native[gate+4:] == isolated[gate+4:]
    assert struct.unpack_from("<I", isolated, gate)[0] == 0x14000000 | (displacement//4)
    stamped = registration.stamp_info(info, report)
    proof = plistlib.loads(stamped)[registration.PROOF_KEY]
    assert proof["UUID"] == identity and proof["GateOffset"] == gate-8
    assert proof["GateBytes"] == isolated[gate-8:gate+4] and proof["SkipOffset"] == gate+displacement
    assert proof["SkipBytes"] == isolated[gate+displacement:gate+displacement+28]
    same, repeated = registration.patch(isolated)
    assert same == isolated and repeated["already_patched"] and not repeated["applied"]
    assert registration.stamp_info(stamped, repeated) == stamped

unknown_code = registration_code(plugin=b"reference_plugin\0")
for code, count in [(unknown_code, 0), (registration_code() + b"\0" * ((-len(registration_code())) % 4) + registration_code(), 2)]:
    unknown, _ = macho(code)
    result, report = registration.patch(unknown)
    assert result == unknown and report == {"applied": False, "reason": f"expected one offline lyrics registration, found {count}"}
    assert plistlib.loads(registration.stamp_info(stamped, report)) == plistlib.loads(info)
print("Offline lyrics registration matches the plugin and continuation across relocated images, and skips ambiguity")
