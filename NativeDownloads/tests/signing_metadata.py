"""Focused entitlement preservation checks; generated executables are never run."""
import plistlib
from pathlib import Path
import struct
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from signing_metadata import embedded_entitlements, sign_preserving_entitlements


ENTITLEMENTS = {
    'application-identifier': 'TESTTEAM.com.spotify.client',
    'com.apple.security.application-groups': [
        'group.com.spotify.client.notification', 'group.com.spotify.client.widget'],
    'keychain-access-groups': ['TESTTEAM.com.spotify.client'],
    'aps-environment': 'development',
    'get-task-allow': True,
    'test-metadata': {'enabled': True, 'revision': 3},
}


def macho(slots=None):
    """Create an ARM64 signature fixture with ldid-style XML and DER slots.

    The CodeDirectory intentionally lacks real signing data, so codesign cannot
    display the entitlements although the superblob's XML slot is readable.
    """
    header = struct.pack('<IIIIIIII', 0xFEEDFACF, 0x0100000C, 0, 2,
                         int(slots is not None), 16 if slots is not None else 0, 0, 0)
    if slots is None:
        return header
    blobs, indexes = bytearray(), bytearray()
    offset = 12 + 8 * len(slots)
    for slot, magic, payload in slots:
        blob = struct.pack('>II', magic, 8 + len(payload)) + payload
        indexes += struct.pack('>II', slot, offset + len(blobs))
        blobs += blob
    signature = struct.pack('>III', 0xFADE0CC0, offset + len(blobs), len(slots)) + indexes + blobs
    return header + struct.pack('<IIII', 0x1D, 16, 48, len(signature)) + signature


def rejected(data):
    try:
        embedded_entitlements(data)
    except ValueError:
        return
    raise AssertionError('Malformed or DER-only entitlements were silently accepted')


def main():
    original = macho([
        (0, 0xFADE0C02, b''),
        (5, 0xFADE7171, plistlib.dumps(ENTITLEMENTS)),
        (7, 0xFADE7172, b'\x30\x00'),
    ])
    assert embedded_entitlements(original) == ENTITLEMENTS
    assert embedded_entitlements(macho()) == {}
    rejected(original[:-1])
    invalid_offset = bytearray(original)
    struct.pack_into('<I', invalid_offset, 40, len(original) + 1)
    rejected(invalid_offset)
    invalid_slot = bytearray(original)
    struct.pack_into('>I', invalid_slot, 48 + 12 + 4, 1)
    rejected(invalid_slot)
    invalid_size = bytearray(original)
    first_blob = 48 + 12 + 8 * 3
    struct.pack_into('>I', invalid_size, first_blob + 4, len(original))
    rejected(invalid_size)
    rejected(macho([(7, 0xFADE7172, b'\x30\x00')]))
    rejected(macho([(5, 0xFADE7171, plistlib.dumps(['not a dictionary']))]))

    with tempfile.TemporaryDirectory(prefix='pixie-signing-metadata-test-') as folder:
        folder = Path(folder)
        fixture = folder / 'ldid-style-fixture'
        fixture.write_bytes(original)
        displayed = subprocess.run(
            ['codesign', '-d', '--entitlements', ':-', str(fixture)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        assert displayed.returncode != 0, 'Fixture should be unreadable through codesign'
        assert embedded_entitlements(fixture.read_bytes()) == ENTITLEMENTS

        image = folder / 'entitlement-test'
        subprocess.run(['xcrun', 'clang', '-arch', 'arm64', '-x', 'c', '-', '-o', str(image)],
                       input=b'int main(void) { return 0; }\n', check=True)
        metadata = folder / 'entitlements.plist'
        report = sign_preserving_entitlements(image, original, metadata)
        assert embedded_entitlements(image.read_bytes()) == ENTITLEMENTS
        assert plistlib.loads(metadata.read_bytes()) == ENTITLEMENTS
        assert report['entitlements_preserved'] is True
        assert report['entitlement_keys'] == sorted(ENTITLEMENTS)
        assert report['app_groups'] == ENTITLEMENTS['com.apple.security.application-groups']
        subprocess.run(['codesign', '--verify', '--strict', str(image)], check=True)

    print('PASS: raw XML entitlements survive unreadable codesign display; App Groups and other values preserved')
    print('PASS: unsigned input is empty; truncated signatures, invalid offsets/sizes and DER-only input fail')
    print('PASS: actual ARM64 binary re-signed and verified with preserved entitlements; executable never run')


if __name__ == '__main__':
    main()
