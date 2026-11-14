"""Guard native restriction updates in the exact supplied Spotify 9.1.92 binary.

A small leaf trampoline in verified zero-filled __TEXT header padding clamps the
six-argument setter's two nonnegative music limits before the original setter.
No runtime code writes, extra imports, polling, key material or episode changes.
"""
import struct

from pixie_target import PROFILE, native_address, native_bytes

PREFERRED = int(PROFILE["preferred_address"], 16)
SETTER = native_address("setter")
CAVE = native_address("setter_cave")
ORIGINAL = native_bytes("setter_original")
UUID = bytes.fromhex(PROFILE["uuid"])
MINIMUM_TRACKS = 1_000_000
# The setter accepts signed int32 seconds even though its stored field is int64.
MINIMUM_MUSIC_DURATION_SECONDS = (1 << 31) - 1


def branch(source, destination):
    delta = destination - source
    if delta % 4 or not -(1 << 27) <= delta < (1 << 27):
        raise ValueError('Branch out of range')
    return 0x14000000 | ((delta // 4) & 0x3ffffff)


def trampoline(cave=CAVE, setter=SETTER):
    # Negative/sentinel pairs remain unchanged. All six public arguments except
    # the two clamped nonnegative music arguments retain their original values.
    words = []
    original_index = 10
    for register in (1, 2):
        pc = cave + 4 * len(words)
        delta = (cave + 4 * original_index - pc) // 4
        words.append(0x37000000 | (31 << 19) | ((delta & 0x3fff) << 5) | register)  # tbnz wN,#31,original
    words += [
        0x52800000 | ((MINIMUM_MUSIC_DURATION_SECONDS & 0xffff) << 5) | 7,
        0x72a00000 | ((MINIMUM_MUSIC_DURATION_SECONDS >> 16) << 5) | 7,
        0x6b00001f | (7 << 16) | (1 << 5),
        0x1a800000 | (7 << 16) | (0xa << 12) | (1 << 5) | 1,
        0x52800000 | ((MINIMUM_TRACKS & 0xffff) << 5) | 7,
        0x72a00000 | ((MINIMUM_TRACKS >> 16) << 5) | 7,
        0x6b00001f | (7 << 16) | (2 << 5),
        0x1a800000 | (7 << 16) | (0xa << 12) | (2 << 5) | 2,
        0xaa1e03e6,                      # original mov x6,x30
    ]
    words.append(branch(cave + len(words) * 4, setter + 4))
    return struct.pack('<' + 'I' * len(words), *words)


def layout(data):
    magic, cpu, _, _, count, size = struct.unpack_from('<6I', data)
    if magic != 0xfeedfacf or cpu != 0x100000c:
        raise ValueError('Expected thin arm64 Mach-O')
    cursor = 32
    segments = []
    first_section = len(data)
    uuid = None
    for _ in range(count):
        command, length = struct.unpack_from('<II', data, cursor)
        if length < 8 or cursor + length > 32 + size:
            raise ValueError('Invalid load command')
        if command == 0x19:
            name = data[cursor+8:cursor+24].split(b'\0')[0]
            vm, vmsize, fileoff, filesize = struct.unpack_from('<QQQQ', data, cursor+24)
            maxprot, initprot, nsections = struct.unpack_from('<III', data, cursor+56)
            segments.append((name, vm, vmsize, fileoff, filesize, initprot))
            for i in range(nsections):
                section = cursor + 72 + i * 80
                offset = struct.unpack_from('<I', data, section + 48)[0]
                if offset:
                    first_section = min(first_section, offset)
        elif command == 0x1b:
            uuid = data[cursor+8:cursor+24]
        cursor += length
    if cursor != 32 + size:
        raise ValueError('Invalid load command size')
    return cursor, first_section, segments, uuid


def patch_at(data, setter, cave, expected):
    commands_end, first_section, segments, _ = layout(data)
    text = next(s for s in segments if s[0] == b'__TEXT')
    _, vm, _, fileoff, filesize, protection = text
    def offset(address, size):
        if not vm <= address or address + size > vm + filesize:
            raise ValueError('Patch outside file-backed __TEXT')
        return fileoff + address - vm
    stub = trampoline(cave, setter)
    start, target = offset(setter, len(expected)), offset(cave, len(stub))
    if protection & 5 != 5 or not commands_end <= target or target + len(stub) > first_section:
        raise ValueError('No executable header padding')
    if any(data[target:target+len(stub)]):
        raise ValueError('Header padding occupied')
    if data[start:start+len(expected)] != expected:
        raise ValueError('Native setter bytes differ')
    result = bytearray(data)
    result[target:target+len(stub)] = stub
    struct.pack_into('<I', result, start, branch(setter, cave))
    return bytes(result), {'setter': hex(setter), 'trampoline': hex(cave), 'trampoline_bytes': len(stub),
        'original_instruction': expected[:4].hex(), 'minimum_tracks': MINIMUM_TRACKS,
        'minimum_music_duration_seconds': MINIMUM_MUSIC_DURATION_SECONDS, 'negative_sentinels_unchanged': True}


def patch(data):
    if layout(data)[3] != UUID:
        raise ValueError('Unsupported Spotify UUID')
    return patch_at(data, SETTER, CAVE, ORIGINAL)


def guard_header():
    stub = trampoline()
    as_bytes = lambda b: ','.join(f'0x{x:02x}' for x in b)
    return ('// Generated by tools/patch_native_restrictions.py; checked by the build.\n'
        '#pragma once\n#include <stdint.h>\n'
        f'static const uintptr_t SAPRestrictionCaveOffset=0x{CAVE-PREFERRED:x};\n'
        f'static const uint8_t SAPGuardedSetterHead[]={{{as_bytes(struct.pack("<I", branch(SETTER,CAVE)))}}};\n'
        f'static const uint8_t SAPRestrictionTrampoline[]={{{as_bytes(stub)}}};\n')


def limits_header():
    return ('// Generated by tools/patch_native_restrictions.py; checked by the build.\n'
        '#pragma once\n'
        f'#define SAPMinimumTrackLimit {MINIMUM_TRACKS}\n'
        f'#define SAPMinimumMusicDurationSeconds {MINIMUM_MUSIC_DURATION_SECONDS}\n')
