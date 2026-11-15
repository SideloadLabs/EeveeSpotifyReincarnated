"""Check the exact 9.1.92 port against a supplied input IPA and optional output."""
import argparse
import hashlib
import json
import plistlib
import struct
from pathlib import Path
from zipfile import ZipFile

import patch_imports as audio
import patch_key_request_mode as mode
import patch_native_restrictions as quota
import patch_native_trace as trace
import patch_export as export
from export_release_materials import notices
from pixie_target import PROFILE
from signing_metadata import embedded_entitlements

APP = 'Payload/Spotify.app/'
EXECUTABLE = APP + 'Spotify'
EEVEE = APP + 'Frameworks/EeveeSpotify.dylib'
PROBE = APP + 'Frameworks/SpotifyAudioProbe.dylib'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    with ZipFile(args.input) as source:
        original = source.read(EXECUTABLE)
        info = plistlib.loads(source.read(APP + 'Info.plist'))
        require(info['CFBundleShortVersionString'] == PROFILE['spotify_version'], 'Wrong Spotify version')
        require(quota.layout(original)[3] == quota.UUID, 'Wrong Spotify UUID')
        # The manager destructor publishes this table. Its unchanged slot 65
        # points to the relocated six-argument restriction setter.
        manager_table = int(PROFILE['native']['manager_vtable'], 16)
        pointer = struct.unpack_from('<Q', original, manager_table - quota.PREFERRED + 65 * 8)[0]
        require(pointer & 0xfffffffff == quota.SETTER - quota.PREFERRED, 'Manager vtable changed')
        render_offset = int(PROFILE['native']['render_callback'], 16) - quota.PREFERRED
        require(original[render_offset:render_offset+16] == bytes.fromhex('a3050035f85fbca9f65701a9f44f02a9'),
                'Native render callback changed')
        required = ['SPTOfflineManagerImplementation',
                    'initWithScheduler:offlineManager:syncManager:metadataModel:',
                    'makeEntityAvailableOfflineWithURL:trackURLs:',
                    'resetEntityOfflineAvailabilityWithURL:', 'stateForTrackWithURL:',
                    'SPTFreeTierOfflineStatusUpdatingContentOperation', 'offlineSyncStatusForURL:']
        for name in required:
            require(name.encode() + b'\0' in original, 'Missing native hook target: ' + name)
        prepared, _ = audio.patch(original)
        prepared, quota_report = quota.patch(prepared)
        prepared, _ = mode.patch(prepared, runtime_selectable=False)
        patched, trace_report = trace.patch(prepared)
        patched, export_report = export.patch(patched)
        # Code outside the explicit observation entries/padding spans (the three diagnostic
        # boundaries and the Pixie 1.4 export boundaries) must remain byte-for-byte unchanged.
        spans = []
        for point in trace.POINTS:
            _, address, cave, _, _ = point
            spans.extend([(address-quota.PREFERRED, address-quota.PREFERRED+4),
                          (cave-quota.PREFERRED, cave-quota.PREFERRED+len(trace.trampoline(point)))])
        for point in export.ALL_POINTS:
            _, address, cave, _, _ = point
            spans.extend([(address-quota.PREFERRED, address-quota.PREFERRED+4),
                          (cave-quota.PREFERRED, cave-quota.PREFERRED+len(export.trampoline(point)))])
        position = 0
        for start, end in sorted(spans):
            require(prepared[position:start] == patched[position:start], 'Unexpected diagnostic change')
            position = end
        require(prepared[position:] == patched[position:], 'Unexpected diagnostic tail change')
        rejected = 0
        for point in trace.POINTS:
            for address in (point[1], point[2]):
                corrupted = bytearray(prepared)
                corrupted[address-quota.PREFERRED] ^= 1
                try:
                    trace.patch(corrupted)
                except ValueError:
                    rejected += 1
                else:
                    raise ValueError('Changed entry or occupied padding was accepted')
        try:
            trace.patch(patched)
        except ValueError:
            rejected += 1
        else:
            raise ValueError('Repeated trace patch was accepted')
        report = {'spotify_version': PROFILE['spotify_version'], 'pixie_version': PROFILE['pixie_version'],
                  'spotify_uuid': quota.UUID.hex(), 'manager_vtable': hex(manager_table),
                  'manager_setter_slot': 65, 'restriction_fields_unchanged': ['0x2b8', '0x2c0', '0x2c8', '0x2d0', '0x2d8'],
                  'hook_target_names_present': required, 'rejected_invalid_patch_cases': rejected,
                  'quota': quota_report, 'diagnostic_boundaries': trace_report, 'export_boundaries': export_report,
                  'phone_runtime_tested': False}
        if args.output:
            with ZipFile(args.output) as result:
                require(len(result.namelist()) == len(set(result.namelist())), 'Duplicate IPA entries')
                require(set(result.namelist()) - set(source.namelist()) == {PROBE, *notices()}, 'Unexpected added IPA entries')
                require(not (set(source.namelist()) - set(result.namelist())), 'Removed IPA entries')
                changed = [entry.filename for entry in source.infolist()
                           if (entry.CRC, entry.file_size) !=
                           (result.getinfo(entry.filename).CRC, result.getinfo(entry.filename).file_size)]
                require(set(changed) == {EXECUTABLE, EEVEE}, 'Unexpected changed original IPA entries')
                packaged = result.read(EXECUTABLE)
                require(embedded_entitlements(packaged) == embedded_entitlements(original),
                        'Executable entitlements changed')
                companion = result.read(PROBE)
                require(f"{PROFILE['spotify_version']}-v{PROFILE['pixie_version']}".encode() in companion,
                        'Companion build label differs')
                require(b'SAPObserveExportBoundaryV2' in companion and b'live.bin' not in companion,
                        'Companion export helper missing or research dump compiled in')
                _, first, segments, _ = quota.layout(patched)
                text = next(s for s in segments if s[0] == b'__TEXT')
                require(packaged[first:text[3]+text[4]] == patched[first:text[3]+text[4]],
                        'Packaged executable code differs from the verified patches')
                for start, end in spans:
                    require(packaged[start:end] == patched[start:end], 'Packaged observer differs')
                guard = quota.CAVE - quota.PREFERRED
                require(packaged[guard:guard+len(quota.trampoline())] == quota.trampoline(),
                        'Packaged restriction guard differs')
                plugins = [n for n in source.namelist() if n.endswith('.appex/Info.plist')]
                report.update({'changed_original_entries': changed, 'extensions_preserved': len(plugins),
                               'preserved_plugin_sha256': {n: hashlib.sha256(result.read(n)).hexdigest()
                                   for n in source.namelist() if n.endswith('.dylib') and n != EEVEE},
                               'entitlements_preserved': True,
                               'packaged_text_matches_verified_patches': True,
                               'output_sha256': hashlib.sha256(args.output.read_bytes()).hexdigest()})
        if args.report:
            args.report.write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
