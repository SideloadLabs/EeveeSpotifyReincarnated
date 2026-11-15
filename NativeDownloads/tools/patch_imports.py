"""Redirect selected two-level chained imports to an added dylib dependency.

No executable instructions, encrypted media or fixup chains are rewritten.
Only the five import ordinals and one LC_LOAD_DYLIB are changed.
Layout: Apple's mach-o/fixup-chains.h and loader.h.
"""
import argparse
import json
import struct
from pathlib import Path

SYMBOLS = {
    "_AudioUnitSetProperty", "_AudioUnitGetProperty", "_AudioOutputUnitStart",
    "_AudioOutputUnitStop", "_AudioComponentInstanceDispose",
}
DEPENDENCY = "@loader_path/Frameworks/SpotifyAudioProbe.dylib"
DYLIB_COMMANDS = {0xC, 0x18, 0x80000018, 0x8000001F, 0x80000023}


def patch(data: bytes, dependency: str = DEPENDENCY):
    result = bytearray(data)
    magic, cpu, subtype, filetype, ncmds, sizeofcmds, flags, reserved = struct.unpack_from("<8I", data)
    if magic != 0xFEEDFACF or cpu != 0x100000C:
        raise ValueError("Expected a thin little-endian arm64 Mach-O")
    cursor = 32
    libraries = []
    first_section = len(data)
    fixups = None
    for _ in range(ncmds):
        command, size = struct.unpack_from("<II", data, cursor)
        if size < 8 or cursor + size > 32 + sizeofcmds:
            raise ValueError("Malformed load commands")
        if command in DYLIB_COMMANDS:
            name_offset = struct.unpack_from("<I", data, cursor + 8)[0]
            libraries.append(data[cursor + name_offset:cursor + size].split(b"\0")[0].decode())
        elif command == 0x19:  # LC_SEGMENT_64
            sections = struct.unpack_from("<I", data, cursor + 64)[0]
            for index in range(sections):
                section = cursor + 72 + index * 80
                offset = struct.unpack_from("<I", data, section + 48)[0]
                if offset:
                    first_section = min(first_section, offset)
        elif command == 0x80000034:
            fixups = struct.unpack_from("<II", data, cursor + 8)
        elif command == 0x2C and struct.unpack_from("<I", data, cursor + 16)[0]:
            raise ValueError("Executable is encrypted")
        cursor += size
    if cursor != 32 + sizeofcmds or fixups is None:
        raise ValueError("No valid chained-fixups load command")
    if dependency in libraries:
        raise ValueError("Probe dependency already installed")
    ordinal = len(libraries) + 1
    base, fixup_size = fixups
    version, starts, imports, symbols, count, import_format, symbol_format = struct.unpack_from("<7I", data, base)
    if version != 0 or symbol_format != 0 or import_format not in (1, 2, 3):
        raise ValueError("Unsupported chained imports encoding")
    if ordinal > (65520 if import_format == 3 else 240):
        raise ValueError("New ordinal does not fit chained-import encoding")
    stride = {1: 4, 2: 8, 3: 16}[import_format]
    changes = []
    found = set()
    for index in range(count):
        offset = base + imports + index * stride
        if offset + stride > base + fixup_size:
            raise ValueError("Imports table extends beyond fixups")
        record = struct.unpack_from("<Q" if import_format == 3 else "<I", data, offset)[0]
        mask = 65535 if import_format == 3 else 255
        old_ordinal = record & mask
        name_offset = record >> (32 if import_format == 3 else 9)
        name_start = base + symbols + name_offset
        name_end = data.index(b"\0", name_start, base + fixup_size)
        name = data[name_start:name_end].decode()
        if name not in SYMBOLS:
            continue
        if not 1 <= old_ordinal <= len(libraries) or not any(x in libraries[old_ordinal - 1] for x in ("AudioToolbox", "AudioUnit")):
            raise ValueError(f"Unexpected original provider for {name}: {old_ordinal}")
        struct.pack_into("<Q" if import_format == 3 else "<I", result, offset, (record & ~mask) | ordinal)
        found.add(name)
        changes.append({"symbol": name, "import_index": index, "offset": offset, "old_ordinal": old_ordinal, "new_ordinal": ordinal})
    if found != SYMBOLS:
        raise ValueError(f"Missing required imports: {sorted(SYMBOLS - found)}")
    name = dependency.encode() + b"\0"
    size = (24 + len(name) + 7) & ~7
    if cursor + size > first_section or any(data[cursor:cursor + size]):
        raise ValueError("Insufficient zero-filled Mach-O header padding")
    command = struct.pack("<6I", 0xC, size, 24, 0, 0x10000, 0x10000) + name
    result[cursor:cursor + size] = command.ljust(size, b"\0")
    struct.pack_into("<II", result, 16, ncmds + 1, sizeofcmds + size)
    return bytes(result), {"dependency": dependency, "ordinal": ordinal, "changes": changes}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    binary, manifest = patch(args.input.read_bytes())
    args.output.write_bytes(binary)
    print(json.dumps(manifest, indent=2))
