"""Install a guarded, runtime-selectable offline key-request argument.

Only the verified Spotify 9.1.92 caller is redirected. A fixed build-time
trampoline saves its live registers, reads a C atomic in SpotifyAudioProbe,
then executes the original virtual call. No executable page is changed later.
"""
import struct
import subprocess
import tempfile
from pathlib import Path

from patch_native_restrictions import UUID, branch, layout

from pixie_target import PROFILE, native_address, native_bytes

PREFERRED = int(PROFILE["preferred_address"], 16)
CALL_SITE = native_address("call_site")
WINDOW = native_address("window")
ORIGINAL = native_bytes("window_original")
PROVIDER = native_address("provider")
PROVIDER_HEAD = native_bytes("provider_head")
MAPPING = native_address("mapping")
MAPPING_BYTES = native_bytes("mapping_original")
CAVE = native_address("selector_cave")
DLSYM_STUB = native_address("dlsym_stub")
DLSYM_STUB_HEAD = native_bytes("dlsym_stub_head")
SELECTOR_NAME = b'SAPCurrentKeyRequestMode\0'
ASSEMBLY = Path(__file__).with_name('key_mode_trampoline.S')


def _compiled_template():
    with tempfile.TemporaryDirectory(prefix='pixie-key-thunk-') as directory:
        obj = Path(directory) / 'thunk.o'
        sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
        subprocess.run(['xcrun', 'clang', '-c', '-arch', 'arm64', '-target', 'arm64-apple-ios15.0',
                        '-isysroot', sdk, str(ASSEMBLY), '-o', str(obj)], check=True)
        data = obj.read_bytes()
    cursor = 32
    for _ in range(struct.unpack_from('<I', data, 16)[0]):
        command, length = struct.unpack_from('<II', data, cursor)
        if command == 0x19:
            section_count = struct.unpack_from('<I', data, cursor + 64)[0]
            for index in range(section_count):
                section = cursor + 72 + index * 80
                if data[section:section + 16].split(b'\0')[0] != b'__text':
                    continue
                size = struct.unpack_from('<Q', data, section + 40)[0]
                offset = struct.unpack_from('<I', data, section + 48)[0]
                relocations = struct.unpack_from('<I', data, section + 60)[0]
                if relocations:
                    raise ValueError('Key trampoline contains unresolved relocations')
                blob = data[offset:offset + size]
                if not blob.endswith(SELECTOR_NAME) or len(blob) > 0x200:
                    raise ValueError('Unexpected key trampoline template')
                return blob
        cursor += length
    raise ValueError('Key trampoline text section absent')


def trampoline():
    out = bytearray(_compiled_template())
    words = [struct.unpack_from('<I', out, i)[0] for i in range(0, len(out) & ~3, 4)]
    adrp = words.index(0x90000010) * 4
    if words[adrp // 4 + 1] != 0x91000210:
        raise ValueError('dlsym call template differs')
    page_delta = (DLSYM_STUB >> 12) - ((CAVE + adrp) >> 12)
    if not -(1 << 20) <= page_delta < (1 << 20):
        raise ValueError('dlsym page out of adrp range')
    struct.pack_into('<I', out, adrp,
                     0x90000010 | ((page_delta & 3) << 29) | (((page_delta >> 2) & 0x7FFFF) << 5))
    struct.pack_into('<I', out, adrp + 4, 0x91000210 | ((DLSYM_STUB & 0xFFF) << 10))
    # The final self-branch is unique; return to the unmodified blr x9.
    terminator = out.index(struct.pack('<I', 0x14000000), 0x70)
    if terminator + 4 != out.index(SELECTOR_NAME):
        raise ValueError('Key trampoline terminator differs')
    struct.pack_into('<I', out, terminator, branch(CAVE + terminator, CALL_SITE + 4))
    return bytes(out)


def _offset(segments, address, size):
    for name, vm, _, fileoff, filesize, protection in segments:
        if name == b'__TEXT' and vm <= address and address + size <= vm + filesize and protection & 5 == 5:
            return fileoff + address - vm
    raise ValueError('Expected executable file-backed text')


def _verify_dlsym_binding(data):
    cursor = 32
    symtab = dysym = stubs = None
    for _ in range(struct.unpack_from('<I', data, 16)[0]):
        command, length = struct.unpack_from('<II', data, cursor)
        if command == 2:
            symtab = struct.unpack_from('<IIII', data, cursor + 8)
        elif command == 0xB:
            dysym = struct.unpack_from('<IIIIIIIIIIIIIIIIII', data, cursor + 8)
        elif command == 0x19:
            for index in range(struct.unpack_from('<I', data, cursor + 64)[0]):
                section = cursor + 72 + index * 80
                if data[section:section + 16].split(b'\0')[0] == b'__stubs':
                    address, size = struct.unpack_from('<QQ', data, section + 32)
                    first, width = struct.unpack_from('<II', data, section + 68)
                    if address <= DLSYM_STUB < address + size:
                        stubs = (address, first, width)
        cursor += length
    if not symtab or not dysym or not stubs:
        raise ValueError('Cannot verify dlsym import binding')
    address, first, width = stubs
    if width != 12 or (DLSYM_STUB - address) % width:
        raise ValueError('dlsym stub layout changed')
    index = struct.unpack_from('<I', data, dysym[12] + 4 * (first + (DLSYM_STUB - address) // width))[0]
    if index >= symtab[1]:
        raise ValueError('dlsym indirect symbol index invalid')
    string = symtab[2] + struct.unpack_from('<I', data, symtab[0] + 16 * index)[0]
    if data[string:data.index(b'\0', string)] != b'_dlsym':
        raise ValueError('Expected dlsym stub is bound to another symbol')


def patch(data, runtime_selectable=True):
    commands_end, first_section, segments, uuid = layout(data)
    if uuid != UUID:
        raise ValueError('Unsupported Spotify UUID')
    _verify_dlsym_binding(data)
    for address, expected in ((WINDOW, ORIGINAL), (PROVIDER, PROVIDER_HEAD),
                              (MAPPING, MAPPING_BYTES), (DLSYM_STUB, DLSYM_STUB_HEAD)):
        at = _offset(segments, address, len(expected))
        if data[at:at + len(expected)] != expected:
            raise ValueError(f'Key requester code differs at {address:#x}')
    call = _offset(segments, CALL_SITE, 4)
    if not runtime_selectable:
        out=bytearray(data)
        struct.pack_into('<I',out,call,0x52800002)
        return bytes(out), {'caller':hex(CALL_SITE),'original_mode':1,'initial_mode':0,
            'runtime_selectable':False,'implementation':'direct mov w2, #0; recovery rollback',
            'native_callbacks_and_persistence_unchanged':True}
    stub = trampoline()
    target = _offset(segments, CAVE, len(stub))
    if target < commands_end or target + len(stub) > first_section or any(data[target:target + len(stub)]):
        raise ValueError('Verified executable header padding unavailable')
    out = bytearray(data)
    out[target:target + len(stub)] = stub
    struct.pack_into('<I', out, call, branch(CALL_SITE, CAVE))
    return bytes(out), {
        'caller': hex(CALL_SITE), 'trampoline': hex(CAVE), 'trampoline_bytes': len(stub),
        'provider': hex(PROVIDER), 'original_mode': 1, 'initial_mode': 0,
        'runtime_selectable': True, 'getter': SELECTOR_NAME[:-1].decode(),
        'native_callbacks_and_persistence_unchanged': True,
    }


def key_header():
    stub = trampoline()
    as_bytes = lambda value: ','.join(f'0x{b:02x}' for b in value)
    return ('// Generated by tools/patch_key_request_mode.py; checked by the build.\n'
            '#pragma once\n#include <stdint.h>\n'
            f'static const uintptr_t SAPKeyModeCaveOffset=0x{CAVE - PREFERRED:x};\n'
            f'static const uint8_t SAPKeyModeCallerHead[]={{{as_bytes(struct.pack("<I", branch(CALL_SITE, CAVE)))}}};\n'
            f'static const uint8_t SAPKeyModeTrampoline[]={{{as_bytes(stub)}}};\n')
