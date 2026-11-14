"""Install Pixie 1.4 export observations in the 9.1.92 Spotify executable.

Every observation is a guarded register snapshot (ABI 2) taken at a displaced
function prologue. The original instructions, arguments, results and lifetimes
are preserved; no executable memory is written at runtime.

Addresses and original bytes come from targets/spotify-9.1.92.json ("export").
The input must be the current 9.1.92 executable: exact UUID, original
instructions at every entry and zero-filled caves are required. Existing Pixie
and Eevee patches are neither restored nor replaced.
"""
from functools import cache
from pathlib import Path
import struct
import subprocess
import tempfile

from pixie_target import PROFILE
from patch_native_restrictions import branch, layout, UUID
from patch_key_request_mode import DLSYM_STUB, _verify_dlsym_binding
from patch_native_trace import text_tail_padding

BASE = int(PROFILE["preferred_address"], 16)
SYMBOL = b"SAPObserveExportBoundaryV2\0"
EXPORT = PROFILE["export"]
CAVE_BASE = int(EXPORT["cave_base"], 16)
CAVE_STRIDE = EXPORT["cave_stride"]

# Order is the order of the generated headers: V2 observations first, then the
# media-unsealing observation, which has its own header.
OBSERVATION_NAMES = ["CacheKey", "StreamKey", "CacheCipher", "CacheCipherApple",
                     "MediaKeyPath", "MediaKeyBlob", "MediaContext", "MediaRecord"]
UNSEAL_NAME = "UnsealedMediaKey"


def window(name):
    value = EXPORT["windows"][name]
    return int(value["address"], 16), bytes.fromhex(value["bytes"])


def point(name):
    value = EXPORT["points"][name]
    return (name, int(value["address"], 16), int(value["cave"], 16) if "cave" in value else CAVE_BASE + value["kind"] * CAVE_STRIDE,
            bytes.fromhex(value["original"]), value["kind"])


POINTS = [point(name) for name in OBSERVATION_NAMES]
UNSEAL_POINT = point(UNSEAL_NAME)
ALL_POINTS = [*POINTS, UNSEAL_POINT]


@cache
def template(kind):
    stores = '\n'.join(f' stp x{i},x{i+1},[sp,#{i*8}]' for i in range(0, 30, 2))
    stores += '\n str x30,[sp,#240]'
    vectors = '\n'.join(f' stp q{i},q{i+1},[sp,#{256+i*16}]' for i in range(0, 32, 2))
    assembly = f'''.text
.p2align 2
.globl _export_snapshot_v2
_export_snapshot_v2:
 sub sp,sp,#800
{stores}
 add x17,sp,#800
 str x17,[sp,#248]
{vectors}
 mrs x17,nzcv
 str x17,[sp,#768]
 mrs x17,fpcr
 str x17,[sp,#776]
 mrs x17,fpsr
 str x17,[sp,#784]
 movn x0,#1
 adr x1,Lname
 .long 0x90000010
 add x16,x16,#0
 blr x16
 cbz x0,Ldone
 mov x16,x0
 mov w0,#{kind}
 mov x1,sp
 blr x16
Ldone:
 ldr x17,[sp,#776]
 msr fpcr,x17
 ldr x17,[sp,#784]
 msr fpsr,x17
 ldr x17,[sp,#768]
 msr nzcv,x17
{vectors.replace('stp', 'ldp')}
{stores.replace('stp', 'ldp').replace('str', 'ldr')}
 add sp,sp,#800
 .long 0x14000000
Lname:
 .asciz "SAPObserveExportBoundaryV2"
'''
    with tempfile.TemporaryDirectory(prefix='pixie-frame-v2-') as temp:
        source, obj = Path(temp)/'frame.S', Path(temp)/'frame.o'
        source.write_text(assembly)
        sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
        subprocess.run(['xcrun', 'clang', '-c', '-arch', 'arm64', '-target',
                        'arm64-apple-ios15.0', '-isysroot', sdk, str(source), '-o', str(obj)], check=True)
        raw = obj.read_bytes()
    cursor = 32
    for _ in range(struct.unpack_from('<I', raw, 16)[0]):
        command, size = struct.unpack_from('<II', raw, cursor)
        if command == 0x19:
            for n in range(struct.unpack_from('<I', raw, cursor+64)[0]):
                at = cursor+72+n*80
                if raw[at:at+16].split(b'\0')[0] == b'__text':
                    length = struct.unpack_from('<Q', raw, at+40)[0]
                    offset = struct.unpack_from('<I', raw, at+48)[0]
                    if struct.unpack_from('<I', raw, at+60)[0]:
                        raise ValueError('Unresolved snapshot relocation')
                    return raw[offset:offset+length]
        cursor += size
    raise ValueError('Snapshot text not found')


def trampoline(entry_point):
    name, entry, cave, displaced, kind = entry_point
    code = bytearray(template(kind))
    symbol = code.index(SYMBOL)
    words = [struct.unpack_from('<I', code, i)[0] for i in range(0, symbol, 4)]
    at = words.index(0x90000010)*4
    delta = (DLSYM_STUB >> 12)-((cave+at) >> 12)
    if not -(1 << 20) <= delta < (1 << 20):
        raise ValueError('Snapshot resolver out of range')
    struct.pack_into('<I', code, at, 0x90000010 | ((delta & 3) << 29) | (((delta >> 2) & 0x7ffff) << 5))
    struct.pack_into('<I', code, at+4, 0x91000210 | ((DLSYM_STUB & 4095) << 10))
    adr = next(i*4 for i, word in enumerate(words) if word & 0x9f00001f == 0x10000001)
    word = struct.unpack_from('<I', code, adr)[0]
    imm = (((word >> 5) & 0x7ffff) << 2) | ((word >> 29) & 3)
    imm += len(displaced)
    struct.pack_into('<I', code, adr, 0x10000001 | ((imm & 3) << 29) | (((imm >> 2) & 0x7ffff) << 5))
    final = (len(words)-1)*4
    code[final:final] = displaced
    final += len(displaced)
    struct.pack_into('<I', code, final, branch(cave+final, entry+len(displaced)))
    if len(code) > CAVE_STRIDE:
        raise ValueError('Snapshot exceeds its cave')
    return bytes(code)


def patch(data):
    end, first, segments, uuid = layout(data)
    if uuid != UUID:
        raise ValueError('Unsupported export target UUID')
    _verify_dlsym_binding(data)
    _, vm, _, fo, size, protection = next(s for s in segments if s[0] == b'__TEXT')

    def offset(address, length):
        if not (vm <= address and address+length <= vm+size):
            raise ValueError('Export observation outside text')
        return fo+address-vm
    for name in EXPORT["windows"]:
        address, expected = window(name)
        start = offset(address, len(expected))
        if data[start:start+len(expected)] != expected:
            raise ValueError(f'Native {name} window differs')
    out = bytearray(data)
    changes = []
    tail_start, tail_end = text_tail_padding(data)
    for entry_point in ALL_POINTS:
        name, entry, cave, displaced, kind = entry_point
        code = trampoline(entry_point)
        start, dest = offset(entry, len(displaced)), offset(cave, len(code))
        if data[start:start+len(displaced)] != displaced:
            raise ValueError(f'Original {name} instructions differ')
        header_padding = end <= dest and dest + len(code) <= first
        tail_padding = tail_start <= dest and dest + len(code) <= tail_end
        if protection & 5 != 5 or not (header_padding or tail_padding) or any(data[dest:dest+len(code)]):
            raise ValueError(f'{name} export cave unavailable')
        out[dest:dest+len(code)] = code
        out[start:start+len(displaced)] = struct.pack('<I', branch(entry, cave))+displaced[4:]
        changes.append({'boundary': name, 'kind': kind, 'entry': hex(entry), 'cave': hex(cave), 'size': len(code)})
    return bytes(out), {'uuid': uuid.hex(), 'snapshot_abi': 2, 'boundaries': changes,
                        'existing_pixie_and_eevee_patches_preserved': True,
                        'per_block_hooks': False, 'native_methods_invoked_by_observers': False}


def _bytes(value):
    return ','.join(f'0x{x:02x}' for x in value)


def _point_lines(entry_point, prefix):
    name, entry, cave, displaced, kind = entry_point
    return [f'static const uintptr_t {prefix}{name}Offset=0x{entry-BASE:x};',
            f'static const uintptr_t {prefix}{name}CaveOffset=0x{cave-BASE:x};',
            f'static const uint8_t {prefix}{name}Head[]={{{_bytes(struct.pack("<I", branch(entry, cave)))}}};',
            f'static const uint8_t {prefix}{name}Code[]={{{_bytes(trampoline(entry_point))}}};']


def observation_header():
    lines = [f'// Generated version-2 export observations for Spotify {PROFILE["spotify_version"]}.',
             '#pragma once', '#include <stdint.h>']
    for entry_point in POINTS:
        lines += _point_lines(entry_point, 'SAPExportV2')
    return '\n'.join(lines)+'\n'


def unseal_header():
    guard_address, guard = window("unseal_guard")
    caller_address, caller = window("unseal_caller")
    lines = [f'// Generated native media-unsealing observation for Spotify {PROFILE["spotify_version"]}.',
             '#pragma once', '#include <stdint.h>',
             *_point_lines(UNSEAL_POINT, 'SAPExportV2'),
             f'static const uintptr_t SAPMediaUnsealCodeOffset=0x{guard_address-BASE:x};',
             f'static const uint8_t SAPMediaUnsealCode[]={{{_bytes(guard[:8])}}};',
             f'static const uintptr_t SAPMediaUnsealCallerOffset=0x{caller_address-BASE:x};',
             f'static const uint8_t SAPMediaUnsealCallerCode[]={{{_bytes(caller)}}};']
    return '\n'.join(lines)+'\n'
