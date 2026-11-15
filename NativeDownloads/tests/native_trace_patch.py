"""Execute the production observation trampolines in an ARM64 native fixture."""
from pathlib import Path
import struct,subprocess,sys,hashlib,os
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
import patch_native_trace as trace
from patch_native_restrictions import layout,branch
out=Path(os.environ.get('PIXIE_TEST_BUILD_DIR',ROOT.parent/'outputs/native-trace-test'));out.mkdir(parents=True,exist_ok=True)
original=out/'original';updated=out/'patched'
def run(*args):
    result=subprocess.run([str(x) for x in args],capture_output=True,text=True)
    if result.returncode:raise RuntimeError(str(args)+'\n'+result.stdout+result.stderr)
    return result.stdout+result.stderr
print(run('xcrun','clang','-arch','arm64','-O1',ROOT/'tests/native_trace_abi.c',ROOT/'tests/native_trace_abi.S','-Wl,-headerpad,0x24000','-o',original))
print(run(original))
symbols={line.split()[-1]:int(line.split()[0],16) for line in run('nm','-n',original).splitlines() if len(line.split())==3 and line.split()[0][0] in '0123456789abcdef'}
data=original.read_bytes();end,first,segments,_=layout(data);text=next(s for s in segments if s[0]==b'__TEXT');vm,fo=text[1],text[3]
real_dlsym=trace.DLSYM_STUB
trace.DLSYM_STUB=symbols['_TestDlsym'];changed=bytearray(data)
for i,(name,address,_,expected,kind) in enumerate(trace.POINTS):
    address=symbols[['_TestRequestSite','_TestSuccess','_TestFailure'][i]];cave=vm+first-fo-0x800+i*0x200
    point=(name,address,cave,expected,kind);code=trace.trampoline(point);at=fo+cave-vm;site=fo+address-vm
    assert at>=end and not any(data[at:at+len(code)]) and data[site:site+len(expected)]==expected
    changed[at:at+len(code)]=code;struct.pack_into('<I',changed,site,branch(address,cave))
updated.write_bytes(changed);updated.chmod(0o755)
print(run('codesign','--force','--sign','-','--timestamp=none',updated))
print(run('xcrun','dyld_info','-validate_only',updated))
print(run(updated,'patched'))
trace.DLSYM_STUB=real_dlsym

from patch_imports import patch as audio_patch
from patch_native_restrictions import patch as quota_patch
from patch_key_request_mode import patch as mode_patch
source=ROOT/'build/key-flow-audit/Spotify-original'
if source.exists():
    original_source=source.read_bytes()
    base,_=audio_patch(original_source);base,_=quota_patch(base);base,_=mode_patch(base,runtime_selectable=False)
    final,manifest=trace.patch(base)
    allowed=[]
    for point in trace.POINTS:
        _,address,cave,_,_=point
        allowed.extend([(address-0x100000000,address-0x100000000+4),(cave-0x100000000,cave-0x100000000+len(trace.trampoline(point)))])
    allowed.sort();position=0
    for start,end in allowed:
        assert hashlib.sha256(base[position:start]).digest()==hashlib.sha256(final[position:start]).digest()
        position=end
    assert final[position:]==base[position:]
    try:trace.patch(final)
    except ValueError:pass
    else:raise AssertionError('Repeat native trace patch accepted')
    for point in trace.POINTS:
        for where in [point[1]-0x100000000,point[2]-0x100000000]:
            bad=bytearray(base);bad[where]^=1
            try:trace.patch(bad)
            except ValueError:pass
            else:raise AssertionError('Mismatched source/cave accepted')
    assert next((ROOT/'src').rglob('NativeTracePatch.h')).read_text()==trace.header()
    import json
    (out/'verified-native-boundaries.json').write_text(json.dumps({'sha256':hashlib.sha256(final).hexdigest(),'allowed_ranges':allowed,'manifest':manifest,'native_abi_fixture_passed':True},indent=2)+'\n')
    print('PASS exact supplied 9.1.90 guards, dlsym binding, three code boundaries and padding only; repeat/mismatched/occupied patches rejected')
else:print('SKIP real-binary native trace checks: source fixture absent')
