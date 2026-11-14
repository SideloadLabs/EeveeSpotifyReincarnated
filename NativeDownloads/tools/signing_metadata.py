"""Preserve entitlements when re-signing a patched thin ARM64 executable.

Some input IPAs have ldid signatures which codesign cannot display. Read their
embedded XML entitlement slot directly rather than treating that failure as an
empty entitlement set.
"""
import plistlib
import struct
import subprocess
from pathlib import Path


def embedded_entitlements(data):
    if len(data) < 32 or struct.unpack_from('<I', data)[0] != 0xFEEDFACF:
        raise ValueError('Expected a thin little-endian 64-bit Mach-O')
    count, size = struct.unpack_from('<II', data, 16)
    at, end = 32, 32 + size
    if end > len(data):
        raise ValueError('Truncated Mach-O load commands')
    signature = None
    for _ in range(count):
        if at + 8 > end:
            raise ValueError('Truncated Mach-O load command')
        command, length = struct.unpack_from('<II', data, at)
        if length < 8 or at + length > end:
            raise ValueError('Invalid Mach-O load command')
        if command == 0x1D:
            if length < 16 or signature is not None:
                raise ValueError('Invalid code-signature command')
            offset, length_of_signature = struct.unpack_from('<II', data, at + 8)
            if offset + length_of_signature > len(data):
                raise ValueError('Truncated embedded signature')
            signature = data[offset:offset + length_of_signature]
        at += length
    if at != end:
        raise ValueError('Invalid Mach-O command table')
    if signature is None:
        return {}
    if len(signature) < 12:
        raise ValueError('Truncated signature superblob')
    magic, length, count = struct.unpack_from('>III', signature)
    if magic != 0xFADE0CC0 or length > len(signature) or 12 + count * 8 > length:
        raise ValueError('Invalid signature superblob')
    entitlements, has_der = None, False
    for i in range(count):
        slot, offset = struct.unpack_from('>II', signature, 12 + i * 8)
        if offset < 12 + count * 8 or offset + 8 > length:
            raise ValueError('Invalid signature slot offset')
        magic, blob_size = struct.unpack_from('>II', signature, offset)
        if blob_size < 8 or offset + blob_size > length:
            raise ValueError('Invalid signature slot size')
        if slot == 5:
            if magic != 0xFADE7171 or entitlements is not None:
                raise ValueError('Invalid XML entitlement slot')
            entitlements = plistlib.loads(signature[offset + 8:offset + blob_size])
            if not isinstance(entitlements, dict):
                raise ValueError('Entitlements must be a dictionary')
        if slot == 7:
            has_der = True
    if has_der and entitlements is None:
        raise ValueError('DER-only entitlements cannot safely be discarded')
    return entitlements if entitlements is not None else {}


def sign_preserving_entitlements(image, original, metadata_path):
    expected = embedded_entitlements(original)
    command = ['codesign', '--force', '--sign', '-', '--timestamp=none']
    if expected:
        Path(metadata_path).write_bytes(plistlib.dumps(expected, sort_keys=False))
        command += ['--entitlements', str(metadata_path), '--generate-entitlement-der']
    subprocess.run(command + [str(image)], check=True)
    observed = embedded_entitlements(Path(image).read_bytes())
    if observed != expected:
        raise ValueError('Re-signing changed the original entitlements')
    return {'entitlements_preserved': True, 'entitlement_keys': sorted(expected),
            'app_groups': expected.get('com.apple.security.application-groups', [])}
