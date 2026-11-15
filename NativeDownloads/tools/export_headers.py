"""Generated headers for the Pixie 1.4 export feature on Spotify 9.1.92.

Everything comes from targets/spotify-9.1.92.json ("export"). Run
generate_export_headers.py to write them or --check to find stale files.
"""
import struct

from pixie_target import PROFILE
import patch_export

BASE = patch_export.BASE
VERSION = PROFILE["spotify_version"]


def _bytes(value):
    return ','.join(f'0x{x:02x}' for x in value)


def _word(code, index):
    return struct.unpack_from('<I', code, index*4)[0]


def _is_bl(word):
    return word >> 26 == 0b100101


def window_offset(name):
    return patch_export.window(name)[0] - BASE


def export_layout_header():
    lines = [f'// Guarded original callback field accesses for Spotify {VERSION}.', '#pragma once', '#include <stdint.h>']
    for index in range(4):
        address, code = patch_export.window(f'layout{index}')
        lines += [f'static const uintptr_t SAPExportLayoutOffset{index}=0x{address-BASE:x};',
                  f'static const uint8_t SAPExportLayoutCode{index}[]={{{_bytes(code)}}};']
    return '\n'.join(lines)+'\n'


def cache_storage_header():
    address, code = patch_export.window('cache_storage_owner')
    return '\n'.join([f'// Verified cache-owner SHA1, AES key setup and namespace construction, Spotify {VERSION}.',
                      '#pragma once', '#include <stdint.h>',
                      f'static const uintptr_t SAPCacheStorageOwnerOffset=0x{address-BASE:x};',
                      f'static const uint8_t SAPCacheStorageOwnerCode[]={{{_bytes(code)}}};'])+'\n'


def share_header():
    uuid = bytes.fromhex(PROFILE['uuid'])
    wrapper, wrapper_code = patch_export.window('share_wrapper_guard')
    constructor, constructor_code = patch_export.window('share_constructor_guard')
    return '\n'.join([
        f'// Native share-creation guards for Spotify {VERSION}: the exact frames after each guarded call.',
        '#pragma once', '#include <stdint.h>',
        f'static const uint8_t SAPShareCreationUUID[16]={{{_bytes(uuid)}}};',
        f'#define SAPShareWrapperGuardOffset UINT64_C(0x{wrapper-BASE:x})',
        f'#define SAPShareConstructorGuardOffset UINT64_C(0x{constructor-BASE:x})',
        f'#define SAPShareWrapperFrameOffset UINT64_C(0x{wrapper-BASE+len(wrapper_code):x})',
        f'#define SAPShareConstructorFrameOffset UINT64_C(0x{constructor-BASE+len(constructor_code):x})',
        f'static const uint8_t SAPShareWrapperGuard[]={{{_bytes(wrapper_code)}}};',
        f'static const uint8_t SAPShareConstructorGuard[]={{{_bytes(constructor_code)}}};'])+'\n'


def sites_header():
    """Offsets and fields the runtime derives from the verified windows."""
    layout1 = patch_export.window('layout1')[1]
    second = _word(layout1, 1)
    # ldr x8,[x19,#imm] must be the owner descriptor load that precedes add x1,x8,#4.
    if second & 0xffc003ff != 0xf9400268 or _word(layout1, 4) != 0x91001101:
        raise ValueError('Unexpected owner descriptor access in layout1')
    descriptor = ((second >> 10) & 0xfff) * 8
    caller, caller_code = patch_export.window('unseal_caller')
    if _word(caller_code, 5) != 0xd63f0100:
        raise ValueError('Unseal caller window does not end with blr x8')
    owner, owner_code = patch_export.window('cache_storage_owner')
    returns = [0x20, 0x2c]
    for offset in returns:
        if not _is_bl(_word(owner_code, offset//4 - 1)):
            raise ValueError('Cache owner return address does not follow a call')
    body_address, body = patch_export.window('cache_key_body')
    # Derive the namespace member from the actual loads, rather than retaining
    # the 9.1.92 +0x230 layout on a different Spotify build.
    first = _word(body, 0)
    if first & 0xffc003ff == 0x3dc00000:  # ldr q0,[x0,#imm*16]
        namespace = ((first >> 10) & 0xfff) * 16
        if _word(body, 2) != 0xb9400008 | ((namespace + 16) // 4 << 10):
            raise ValueError('Cache namespace tail load differs')
    elif first & 0xffc003ff == 0xb9400008 and len(body) >= 28:
        add = _word(body, 2)  # add x8,x0,#member; ldr q0,[x8]
        if add & 0xffc003ff != 0x91000008 or _word(body, 3) != 0x3dc00100:
            raise ValueError('Cache namespace vector load differs')
        namespace = (add >> 10) & 0xfff
        if ((first >> 10) & 0xfff) * 4 != namespace + 16:
            raise ValueError('Cache namespace member is not contiguous')
    else:
        raise ValueError('Unsupported cache namespace load layout')
    context = patch_export.point('MediaContext')[1]
    return '\n'.join([
        f'// Offsets derived from the verified Spotify {VERSION} export windows.',
        '#pragma once', '#include <stdint.h>',
        f'static const uintptr_t SAPExportOwnerDescriptorOffset=0x{descriptor:x};',
        f'static const uintptr_t SAPExportCacheNamespaceOffset=0x{namespace:x};',
        f'static const uintptr_t SAPExportUnsealCallerReturnOffset=0x{caller-BASE+0x18:x};',
        f'static const uintptr_t SAPExportCacheKeyBodyOffset=0x{body_address-BASE:x};',
        f'static const uint8_t SAPExportCacheKeyBody[]={{{_bytes(body)}}};',
        f'static const uintptr_t SAPCacheStorageOwnerReturnA=0x{owner-BASE+returns[0]:x};',
        f'static const uintptr_t SAPCacheStorageOwnerReturnB=0x{owner-BASE+returns[1]:x};',
        f'static const uintptr_t SAPExportMediaContextOffset=0x{context-BASE:x};'])+'\n'


def headers():
    return {
        'ExportObservationV2Patch.h': patch_export.observation_header(),
        'ExportMediaUnsealPatch.h': patch_export.unseal_header(),
        'ExportLayout.h': export_layout_header(),
        'CacheStorageLayout.h': cache_storage_header(),
        'ShareCreationLayout.h': share_header(),
        'ExportSites.h': sites_header(),
    }
