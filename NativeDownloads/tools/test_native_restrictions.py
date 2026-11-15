import os
from pathlib import Path
import subprocess,struct
from patch_native_restrictions import patch,patch_at,layout
from zipfile import ZipFile
root=Path(__file__).resolve().parents[1];out=Path(os.environ.get('PIXIE_TEST_BUILD_DIR',root.parent/'outputs/native-restrictions-test'));out.mkdir(parents=True,exist_ok=True)
original=out/'native-restrictions-original';updated=out/'native-restrictions-patched'
subprocess.run(['xcrun','clang','-arch','arm64',*['-I'+str(p) for p in sorted({root/'src',*(h.parent for h in (root/'src').rglob('*.h'))})],str(root/'tests/native_restrictions.c'),str(root/'tests/native_restrictions.S'),'-Wl,-headerpad,0x10000','-o',str(original)],check=True)
symbols=subprocess.check_output(['xcrun','nm','-n',str(original)],text=True)
setter=int(next(x.split()[0] for x in symbols.splitlines() if x.endswith(' _TestNativeSetter')),16)
data=original.read_bytes();end,first,segments,_=layout(data);vm,fo=segments[0][1],segments[0][3]
text=next(x for x in segments if x[0]==b'__TEXT');vm,fo=text[1],text[3]
cave=vm+((first-fo-0x100)&~15)
new,report=patch_at(data,setter,cave,bytes.fromhex('e6031eaa'));updated.write_bytes(new);updated.chmod(0o755)
subprocess.run(['codesign','--force','--sign','-','--timestamp=none',str(updated)],check=True)
subprocess.run(['xcrun','dyld_info','-validate_only',str(updated)],check=True)
subprocess.run([str(updated)],check=True)
test_ipa=os.environ.get('SPOTIFY_TEST_IPA')
if test_ipa:
    with ZipFile(test_ipa) as z:spotify=z.read('Payload/Spotify.app/Spotify')
    new,report=patch(spotify)
    assert len(new)==len(spotify)
    assert sum(a!=b for a,b in zip(new,spotify))<60
    try:patch(new)
    except ValueError:pass
    else:raise AssertionError('A second patch must not overwrite existing code')
    print('PASS: exact supplied Spotify UUID/prologue/header padding verified; repeat patch rejected')
else:
    print('SKIP: real-IPA restriction check (set SPOTIFY_TEST_IPA to enable)')
