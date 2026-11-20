"""Find Spotify's offline lyrics registration from its ARM64 code and plugin name."""
import argparse
import json
import plistlib
import shutil
import struct
import subprocess
import tempfile
from pathlib import Path
from zipfile import ZipFile

from patch_lyrics_offline_cache import _text_section
from patch_native_restrictions import branch, layout
from signing_metadata import sign_preserving_entitlements

PROOF_KEY = "EeveeOfflineLyricsRegistration"
PLUGIN = b"lyrics_offline_plugin\0"
# ldrb w8, [x20, x8]; cmp w8, #1. The next word is the conditional skip.
GATE_PREFIX = bytes.fromhex("886a68381f050071")
CONTINUATION_LENGTH = 28
WORD = struct.Struct("<I")


def _continuation(data, offset):
    # The skip resumes at the next plugin's service lookup and witness call.
    move, lookup, witness, result, context, argument, call = struct.unpack_from("<7I", data, offset)
    service = (witness >> 5) & 31
    return (move == 0xAA1903E0 and lookup & 0xFC000000 == 0x94000000
            and witness & 0xFFFFFC1F == 0xF9400409 and result == 0xD10403A8
            and context == 0xAA1903F4 and argument == (0xAA0003E1 | service << 16) and call == 0xD63F0120)


def _plugins(data, address, start, stop, names):
    """Resolve the callee-saved registers carrying Swift's tagged plugin names."""
    registers = {}
    plugins = []
    for offset in range(start, stop, 4):
        word, = WORD.unpack_from(data, offset)
        dest = word & 31
        if not 19 <= dest <= 28:
            continue
        opcode = word & 0x9F000000
        if opcode in (0x90000000, 0x10000000):  # ADRP / ADR
            immediate = ((word >> 5) & 0x7FFFF) << 2 | (word >> 29) & 3
            immediate = (immediate ^ 0x100000) - 0x100000
            pc = address + offset - start
            registers[dest] = (pc & ~4095) + (immediate << 12) if opcode == 0x90000000 else pc + immediate
        elif word & 0xFFC00000 in (0x91000000, 0xD1000000) and (word >> 5) & 31 == dest and dest in registers:
            delta = (word >> 10) & 0xFFF
            registers[dest] += delta if not word & 0x40000000 else -delta
        elif word == (0xB2410000 | dest << 5 | dest):  # ORR with Swift's large-string tag
            if registers.get(dest) in names:
                plugins.append(names[registers[dest]])
            registers.pop(dest, None)
        elif word & 0xFC000000 not in (0x94000000, 0x14000000) and word & 0xFF000000 != 0x54000000:
            registers.pop(dest, None)
    return plugins


def patch(data):
    """Replace one unambiguous lyrics gate. Unrecognized images stay unchanged."""
    report = {"applied": False}
    section = _text_section(data)
    if section is None:
        return data, {**report, "reason": "missing native ARM64 text section"}
    _, _, segments, uuid = layout(data)
    text = next((s for s in segments if s[0] == b"__TEXT"), None)
    if text is None or uuid is None or text[3] != 0 or text[5] & 5 != 5:
        return data, {**report, "reason": "missing executable identity"}
    _, base, _, fileoff, filesize, _ = text
    address, length, offset = section
    end = offset + length
    names = {}
    for name in (PLUGIN, b"reference_plugin\0", b"workout_tts_cue_offline_plugin\0"):
        match = data.find(name, fileoff, fileoff+filesize)
        while match >= 0:
            names[base+match-fileoff] = name
            match = data.find(name, match+1, fileoff+filesize)
    candidates = []
    position = data.find(GATE_PREFIX, offset, end)
    while position >= 0:
        gate = position
        position = data.find(GATE_PREFIX, gate+1, end)
        entry = gate + len(GATE_PREFIX)
        if (gate-offset) % 4 or entry+4 > end:
            continue
        word, = WORD.unpack_from(data, entry)
        if word & 0xFF00001F == 0x54000001:  # B.NE
            displacement = (word >> 5) & 0x7FFFF
            already = False
        elif word & 0xFC000000 == 0x14000000:  # B (a previously patched package)
            displacement = word & 0x3FFFFFF
            already = True
        else:
            continue
        target = entry + displacement * 4
        if not 0x80 <= displacement * 4 <= 0x500 or target + CONTINUATION_LENGTH > end:
            continue
        if not _continuation(data, target):
            continue
        if _plugins(data, address+entry+4-offset, entry+4, target, names) == [PLUGIN]:
            candidates.append((gate, entry, target, already))
    if len(candidates) != 1:
        return data, {**report, "reason": f"expected one offline lyrics registration, found {len(candidates)}"}
    gate, entry, target, already = candidates[0]
    replacement = WORD.pack(branch(entry, target))
    patched = data if already else data[:entry] + replacement + data[entry+4:]
    va = lambda value: address + value - offset
    return patched, {"applied": not already, "already_patched": already, "uuid": uuid.hex(), "file_offset": entry,
                     "entry": hex(va(entry)), "destination": hex(va(target)),
                     "old_bytes": data[entry:entry+4].hex(), "new_bytes": replacement.hex(),
                     "gate_offset": va(gate)-base, "gate_bytes": patched[gate:entry+4].hex(),
                     "skip_offset": va(target)-base, "skip_bytes": patched[target:target+CONTINUATION_LENGTH].hex()}


def stamp_info(data, report):
    """Bind the discovery to the exact code Eevee must verify at runtime."""
    info = plistlib.loads(data)
    if report.get("applied") or report.get("already_patched"):
        proof = {"UUID": bytes.fromhex(report["uuid"]), "GateOffset": report["gate_offset"],
                 "GateBytes": bytes.fromhex(report["gate_bytes"]), "SkipOffset": report["skip_offset"],
                 "SkipBytes": bytes.fromhex(report["skip_bytes"])}
        if proof == info.get(PROOF_KEY):
            return data
        info[PROOF_KEY] = proof
    elif PROOF_KEY in info:
        del info[PROOF_KEY]
    else:
        return data
    return plistlib.dumps(info, fmt=plistlib.FMT_BINARY if data.startswith(b"bplist") else plistlib.FMT_XML,
                          sort_keys=False)


def patch_ipa(source, output):
    """Run the same pass on an assembled IPA outside the Pixie profiles."""
    if output.exists():
        raise ValueError("Choose a fresh output path")
    app = "Payload/Spotify.app/"
    executable, plist = app+"Spotify", app+"Info.plist"
    with ZipFile(source) as archive:
        eevee = archive.read(app+"Frameworks/EeveeSpotify.dylib")
        original, original_info = archive.read(executable), archive.read(plist)
        if PROOF_KEY.encode("utf-8") not in eevee:
            raise ValueError("The Eevee dylib does not support the native lyrics registration check")
        patched, report = patch(original)
        updated_info = stamp_info(original_info, report)
        if not report["applied"] and updated_info == original_info:
            with source.open("rb") as source_file, output.open("xb") as result_file:
                shutil.copyfileobj(source_file, result_file)
            return report
        if report["applied"]:
            with tempfile.TemporaryDirectory(prefix="offline-lyrics-") as temp:
                binary = Path(temp)/"Spotify"
                binary.write_bytes(patched)
                binary.chmod(0o755)
                sign_preserving_entitlements(binary, original, Path(temp)/"entitlements.plist")
                subprocess.run(["xcrun", "dyld_info", "-validate_only", str(binary)], check=True)
                patched = binary.read_bytes()
        replacements = {executable: patched, plist: updated_info}
        partial = output.with_suffix(".ipa.partial")
        with partial.open("xb") as target, ZipFile(target, "w") as result:
            for entry in archive.infolist():
                payload = replacements[entry.filename] if entry.filename in replacements else archive.read(entry)
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
