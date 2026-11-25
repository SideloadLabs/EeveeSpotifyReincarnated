"""Read SQLite afresh on Spotify's native offline lyrics fetch path, any version.

The native LyricsRepository consults its in-memory cache *before* the offline
data source; external SQLite commits do not invalidate that cache. In the
already selected offline branch, skip only that cache lookup and fall through
to the native SQLite reader. Select this reader locally so audio synchronization
continues to receive the original Spotify configuration.

The branch is located by its instruction shape, not by address or UUID:

    ldrb wA, [xB, #net]      ; repository network state (1 = offline)
    <any>
    cmp  wA, #1
    b.ne online
    add  xC, xD, #0x10       ; <- ENTRY: cache lookup starts here
    mov  x8, xC
    bl   cache getter
    mov  x0, xC
    bl   optional check
    cmp  w0, #1
    b.ne ...
    ldr  x8, [xE, #slot]     ; <- DESTINATION: isLyricsOfflineEnabled check
    ldrb w8, [x8, #flag]
    cmp  w8, #1
    b.ne ...

Verified unique on Spotify 9.1.90, 9.1.92, 9.1.98 and 9.2.0 (9.2.0: 0x100813f30,
the address previously patched by hand). Not present in 9.1.76/9.1.86, where
the patch is skipped. Exactly one match is required; otherwise nothing changes
and the report says why. Only the cache jump and the viewer's feature-flag load are changed.
"""
import argparse
import json
import struct
from pathlib import Path

MH_MAGIC_64 = 0xFEEDFACF
LC_SEGMENT_64 = 0x19
LC_UUID = 0x1B
SHAPE_LENGTH = 15
ENTRY_INDEX = 4
DESTINATION_INDEX = 11


def _commands(data):
    ncmds = struct.unpack_from("<I", data, 16)[0]
    offset = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, offset)
        yield cmd, offset
        offset += size


def _text_section(data):
    """(vmaddr, size, fileoff) of __TEXT,__text in a thin arm64 Mach-O, or None."""
    if len(data) < 32 or struct.unpack_from("<I", data, 0)[0] != MH_MAGIC_64:
        return None
    for cmd, offset in _commands(data):
        if cmd == LC_SEGMENT_64 and data[offset+8:offset+24].rstrip(b"\0") == b"__TEXT":
            nsects = struct.unpack_from("<I", data, offset + 64)[0]
            for index in range(nsects):
                section = offset + 72 + index * 80
                if data[section:section+16].rstrip(b"\0") == b"__text":
                    address, length, fileoff = struct.unpack_from("<QQI", data, section + 32)
                    if fileoff + length <= len(data):
                        return address, length, fileoff
    return None


def _uuid(data):
    for cmd, offset in _commands(data):
        if cmd == LC_UUID:
            return data[offset+8:offset+24].hex()
    return None


# Each decoder returns its operands, or None when the word is another instruction.
def _ldrb(word):
    return ((word >> 10) & 0xFFF, (word >> 5) & 31, word & 31) if (word & 0xFFC00000) == 0x39400000 else None


def _ldr_x(word):
    return (((word >> 10) & 0xFFF) * 8, (word >> 5) & 31, word & 31) if (word & 0xFFC00000) == 0xF9400000 else None


def _cmp_one(word):
    return (word >> 5) & 31 if (word & 0xFFFFFC1F) == 0x7100041F else None


def _b_ne(word):
    return (word & 0xFF00001F) == 0x54000001


def _add_0x10(word):
    return ((word >> 5) & 31, word & 31) if (word & 0xFFFFFC00) == 0x91004000 else None


def _mov_x(word):
    return ((word >> 16) & 31, word & 31) if (word & 0xFFE0FFE0) == 0xAA0003E0 else None


def _bl(word):
    return (word & 0xFC000000) == 0x94000000


def branch(source, destination):
    delta = destination - source
    if delta % 4 or not -(1 << 27) <= delta < (1 << 27):
        raise ValueError("Branch target out of range")
    return 0x14000000 | ((delta >> 2) & 0x3FFFFFF)


JUMP = branch(0, (DESTINATION_INDEX - ENTRY_INDEX) * 4)


VIEWER_ENABLED = 0x52800028  # mov w8, #1, followed by the original cmp/b.ne
FLAG_INDEX = 12


def _shape(words, patched=False):
    """Match the 15-instruction offline branch. `patched`: words[4] is our jump."""
    first = _ldrb(words[0])
    if first is None or _cmp_one(words[2]) != first[2] or not _b_ne(words[3]):
        return None
    if patched:
        if words[ENTRY_INDEX] != JUMP or _mov_x(words[5]) is None:
            return None
        base = _mov_x(words[5])[0]
    else:
        cache = _add_0x10(words[ENTRY_INDEX])
        if cache is None:
            return None
        base = cache[1]
    if _mov_x(words[5]) != (base, 8) or not _bl(words[6]) or _mov_x(words[7]) != (base, 0) or not _bl(words[8]):
        return None
    if _cmp_one(words[9]) != 0 or not _b_ne(words[10]):
        return None
    slot, flag = _ldr_x(words[11]), _ldrb(words[12])
    viewer_patched = patched and words[FLAG_INDEX] == VIEWER_ENABLED
    if slot is None or slot[2] != 8 or not (viewer_patched or (flag and flag[1:] == (8, 8))):
        return None
    if _cmp_one(words[13]) != 8 or not _b_ne(words[14]):
        return None
    return {"network_state_offset": hex(first[0]), "offline_flag_offset": hex(flag[0]) if flag else None}


def find(data):
    """Return (matches, already_patched_entries); (None, None) if not arm64 Mach-O."""
    section = _text_section(data)
    if section is None:
        return None, None
    address, length, fileoff = section
    count = length // 4
    words = struct.unpack_from("<%dI" % count, data, fileoff)
    matches, patched = [], []
    for index in range(count - SHAPE_LENGTH + 1):
        if not _b_ne(words[index + 3]):  # cheap filter before decoding the window
            continue
        window = words[index:index + SHAPE_LENGTH]
        entry = address + (index + ENTRY_INDEX) * 4
        found = _shape(window)
        if found:
            matches.append((entry, fileoff + (index + ENTRY_INDEX) * 4, found))
        elif window[ENTRY_INDEX] == JUMP:
            fields = _shape(window, patched=True)
            if fields and window[FLAG_INDEX] == VIEWER_ENABLED:
                patched.append(entry)
            elif fields:
                matches.append((entry, fileoff + (index + ENTRY_INDEX) * 4, fields))
    return matches, patched


def patch(data, spotify_version=None):
    """Patch the unique offline cache lookup. An unknown shape never raises: the
    executable is returned unchanged with the reason. Raises only for an
    executable that already carries this patch (the builder must start clean)."""
    report = {"applied": False, "spotify_version": spotify_version}
    matches, patched = find(data)
    if matches is None:
        report["reason"] = "not a thin arm64 Mach-O with __TEXT,__text"
        return data, report
    report["uuid"] = _uuid(data)
    if patched:
        raise ValueError("Native offline lyrics cache branch is already patched")
    if len(matches) != 1:
        report["reason"] = ("offline lyrics cache branch not found in this Spotify version" if not matches
                            else "offline lyrics cache branch is ambiguous (%d matches)" % len(matches))
        report["candidates"] = [hex(entry) for entry, _, _ in matches]
        return data, report
    entry, offset, fields = matches[0]
    destination = entry + (DESTINATION_INDEX - ENTRY_INDEX) * 4
    word = struct.pack("<I", branch(entry, destination))
    result = bytearray(data)
    old = bytes(result[offset:offset + 4])
    result[offset:offset + 4] = word
    flag_offset = offset + (FLAG_INDEX - ENTRY_INDEX) * 4
    struct.pack_into("<I", result, flag_offset, VIEWER_ENABLED)
    report.update({"applied": True, "entry": hex(entry), "destination": hex(destination),
                   "file_offset": offset, "viewer_flag_file_offset": flag_offset, "old_bytes": old.hex(), "new_bytes": word.hex(), **fields,
                   "scope": "offline native lyrics fetch skips memory cache and reads native SQLite"})
    return bytes(result), report


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("executable", type=Path, help="decrypted Spotify executable")
    parser.add_argument("--output", type=Path, help="write the patched executable here")
    args = parser.parse_args()
    patched, report = patch(args.executable.read_bytes())
    if args.output and report["applied"]:
        args.output.write_bytes(patched)
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
