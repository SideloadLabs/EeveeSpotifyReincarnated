"""Pin Vitrine's embedded Substrate dependency to its own Frameworks directory."""
import argparse
import copy
from contextlib import contextmanager
import hashlib
import io
import json
from pathlib import Path
import struct
import subprocess
import tempfile
from zipfile import ZipFile

APP = 'Payload/Spotify.app/'
VITRINE = APP + 'Frameworks/spotifyglass.dylib'
SUBSTRATE = APP + 'Frameworks/CydiaSubstrate.framework/CydiaSubstrate'
PINNED_SUBSTRATE = '@loader_path/CydiaSubstrate.framework/CydiaSubstrate'


def run(*args):
    return subprocess.check_output(list(map(str, args)), text=True, stderr=subprocess.STDOUT)


def substrate_dependencies(image):
    dependencies = [line.strip().split(' (compatibility version')[0]
                    for line in run('otool', '-L', image).splitlines()[1:]]
    return [name for name in dependencies if name.endswith('/CydiaSubstrate.framework/CydiaSubstrate')]


def text_sections(data):
    """Fingerprint section bytes, excluding mutable Mach-O load commands/signature."""
    if len(data) < 32 or struct.unpack_from('<I', data)[0] != 0xfeedfacf:
        raise ValueError('Expected a thin 64-bit Mach-O image')
    count, size = struct.unpack_from('<II', data, 16)
    at, end = 32, 32 + size
    if end > len(data):
        raise ValueError('Invalid load-command bounds')
    sections = {}
    for _ in range(count):
        if at + 8 > end:
            raise ValueError('Truncated load command')
        command, length = struct.unpack_from('<II', data, at)
        if length < 8 or at + length > end:
            raise ValueError('Invalid load-command size')
        if command == 0x19 and length >= 72 and data[at+8:at+24].rstrip(b'\0') == b'__TEXT':
            nsections = struct.unpack_from('<I', data, at+64)[0]
            if 72 + 80*nsections > length:
                raise ValueError('Invalid section table')
            for i in range(nsections):
                section = at + 72 + i*80
                name = data[section:section+16].rstrip(b'\0').decode()
                section_size = struct.unpack_from('<Q', data, section+40)[0]
                offset = struct.unpack_from('<I', data, section+48)[0]
                if offset + section_size > len(data):
                    raise ValueError('Invalid section bounds')
                sections[name] = hashlib.sha256(data[offset:offset+section_size]).hexdigest()
        at += length
    if at != end or '__text' not in sections:
        raise ValueError('Missing executable text section')
    return sections


def pin_substrate_dependency(image):
    before = substrate_dependencies(image)
    if len(before) != 1:
        raise ValueError(f'Expected exactly one Substrate dependency, got {before}')
    sections = text_sections(image.read_bytes())
    if before[0] != PINNED_SUBSTRATE:
        run('install_name_tool', '-change', before[0], PINNED_SUBSTRATE, image)
    after = substrate_dependencies(image)
    if after != [PINNED_SUBSTRATE] or text_sections(image.read_bytes()) != sections:
        raise ValueError('Dependency rewrite changed executable sections or did not apply')
    return {'before': before[0], 'after': after[0], 'text_sections_unchanged': True,
            'text_section_sha256': sections, 'requires_main_executable_rpath': False}


@contextmanager
def open_ipa(source):
    with ZipFile(source) as archive:
        if VITRINE in archive.namelist():
            yield archive
            return
        ipas = [name for name in archive.namelist() if name.endswith('.ipa')]
        if len(ipas) != 1:
            raise ValueError('Expected an IPA or a ZIP containing exactly one IPA')
        with ZipFile(io.BytesIO(archive.read(ipas[0]))) as nested:
            yield nested


def fix_ipa(source, output):
    if source.resolve() == output.resolve() or output.exists():
        raise ValueError('Choose a new output file; the input and earlier outputs are preserved')
    with open_ipa(source) as original:
        names = original.namelist()
        if len(names) != len(set(names)) or original.testzip():
            raise ValueError('Invalid input archive')
        if SUBSTRATE not in names or not original.read(SUBSTRATE):
            raise ValueError('The required embedded Substrate executable is missing')
        with tempfile.TemporaryDirectory(prefix='pixie-sideload-path-') as temporary:
            image = Path(temporary)/'spotifyglass.dylib'
            image.write_bytes(original.read(VITRINE))
            dependency = pin_substrate_dependency(image)
            run('codesign', '--force', '--sign', '-', '--timestamp=none', image)
            run('codesign', '--verify', '--strict', image)
            run('xcrun', 'dyld_info', '-validate_only', image)
            replacement = image.read_bytes()
        output.parent.mkdir(parents=True, exist_ok=True)
        with ZipFile(output, 'w', allowZip64=True) as result:
            for member in original.infolist():
                result.writestr(copy.copy(member), replacement if member.filename == VITRINE else original.read(member.filename))
        with ZipFile(output) as result:
            if result.testzip() or result.namelist() != names:
                raise ValueError('Output archive integrity check failed')
            changed = [name for name in names if original.read(name) != result.read(name)]
            if changed != [VITRINE]:
                raise ValueError(f'Unexpected member changes: {changed}')
    return {'input': str(source.resolve()), 'output': str(output.resolve()),
            'ipa_sha256': hashlib.sha256(output.read_bytes()).hexdigest(),
            'changed_members': changed, 'dependency': dependency,
            'spotify_executable_unchanged': True, 'pixie_companion_unchanged': True,
            'embedded_substrate_unchanged': True, 'personal_certificate_included': False,
            'requires_installer_resigning': True, 'physical_device_tested': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    report = fix_ipa(args.source, args.output)
    (args.output.parent/'dependency-verification.json').write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
