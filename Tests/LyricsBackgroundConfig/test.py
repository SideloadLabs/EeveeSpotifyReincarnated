from pathlib import Path
import plistlib
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'NativeDownloads/tools'))
from lyrics_background_config import patch_info

for fmt in [plistlib.FMT_BINARY, plistlib.FMT_XML]:
    original = {'CFBundleIdentifier': 'com.spotify.client', 'UIBackgroundModes': ['audio', 'processing'],
                'BGTaskSchedulerPermittedIdentifiers': ['com.spotify.client.offline.downloads'],
                'Nested': {'keep': True}}
    data = plistlib.dumps(original, fmt=fmt)
    patched = patch_info(data)
    value = plistlib.loads(patched)
    identifier = 'com.spotify.client.pixie.lyrics.processing'
    assert value['BGTaskSchedulerPermittedIdentifiers'] == ['com.spotify.client.offline.downloads', identifier]
    assert value['UIBackgroundModes'] == original['UIBackgroundModes']
    assert value['Nested'] == original['Nested']
    assert patch_info(patched) == patched, 'Repeated packaging changed identifiers or plist encoding'
    assert patched.startswith(b'bplist') == (fmt == plistlib.FMT_BINARY)
    old = dict(original, CFBundleIdentifier='com.spotify.client.resigned',
               BGTaskSchedulerPermittedIdentifiers=[
                   'com.spotify.client.offline.downloads', 'com.spotify.client.pixie.lyrics.*',
                   'com.spotify.client.resigned.pixie.lyrics.download', identifier, 'com.spotify.client.pixie.lyrics.continued.*',
                   'com.spotify.client.pixie.lyrics.continued', 'com.other.task'])
    migrated = patch_info(plistlib.dumps(old, fmt=fmt))
    cleaned = plistlib.loads(migrated)
    assert cleaned['BGTaskSchedulerPermittedIdentifiers'] == ['com.spotify.client.offline.downloads', 'com.other.task',
                                                              'com.spotify.client.resigned.pixie.lyrics.processing']
    assert cleaned['UIBackgroundModes'] == original['UIBackgroundModes']
    assert patch_info(migrated) == migrated
    without_tasks = plistlib.dumps({'CFBundleIdentifier': 'com.spotify.client'}, fmt=fmt)
    assert plistlib.loads(patch_info(without_tasks))['BGTaskSchedulerPermittedIdentifiers'] == [identifier]
    assert plistlib.loads(patch_info(without_tasks))['UIBackgroundModes'] == ['processing']
    ordinary = patch_info(patched, signing_bundle_identifier='com.spotify.client.QK2MKTAFK3')
    ordinary_config = plistlib.loads(ordinary)
    assert ordinary_config['CFBundleIdentifier'] == original['CFBundleIdentifier']
    assert ordinary_config['BGTaskSchedulerPermittedIdentifiers'] == [
        'com.spotify.client.offline.downloads', 'com.spotify.client.QK2MKTAFK3.pixie.lyrics.processing']
    assert patch_info(ordinary, signing_bundle_identifier='com.spotify.client.QK2MKTAFK3') == ordinary
    assert plistlib.loads(patch_info(ordinary, background_processing=False)) == original
for invalid in [{}, {'CFBundleIdentifier': ''}, {'CFBundleIdentifier': 'com.example', 'BGTaskSchedulerPermittedIdentifiers': [123]}]:
    try:
        patch_info(plistlib.dumps(invalid))
    except ValueError:
        pass
    else:
        raise AssertionError('Malformed app configuration was accepted')
print('Exact lyrics task identifier, ordinary signed bundle and preservation of Spotify tasks passed')
