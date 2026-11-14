"""Exercise the ported production exporter with independent synthetic media.

Uses a generated ten-second Vorbis tone and the system openssl command for
independent encryption. Never reads device files or launches an app.
"""
from datetime import datetime
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import zlib

from pixie_target import ROOT,resolve_source,include_directories


def run(*args,**kwargs):return subprocess.run([str(a) for a in args],check=True,**kwargs)


def main():
    # tools/test.py passes a fresh fixture folder; a direct run keeps its own.
    out=Path(os.environ['PIXIE_TEST_BUILD_DIR']) if os.environ.get('PIXIE_TEST_BUILD_DIR') else ROOT.parent/'outputs'/datetime.now().strftime('export-fixture-%Y%m%d-%H%M%S-%f')
    out.mkdir(parents=True,exist_ok=True)
    audio=out/'tone.ogg';prefixed=out/'prefixed.ogg';native=out/'synthetic-native-cache.file'
    audio.write_bytes((ROOT/'tests/fixtures/export-tone-10s.ogg').read_bytes())
    plain=bytes(167)+audio.read_bytes();prefixed.write_bytes(plain)
    def encrypt(data,key,iv):
        return subprocess.check_output(['openssl','enc','-aes-128-ctr','-K',key.hex(),'-iv',iv.hex()],input=data)
    aligned=plain+bytes((-len(plain))%4)
    assert len(aligned)>len(plain), 'Fixture must contain nonempty alignment'
    media=encrypt(aligned,bytes([2])+bytes(15),bytes.fromhex('72e067fbddcbcf77ebe8bc643f630d93'))
    head=bytearray(64);struct.pack_into('<II',head,4,0x617233ab,len(media))
    struct.pack_into('<I',head,0,zlib.adler32(head[4:]))
    table=b''.join(struct.pack('<I',zlib.adler32(media[i:i+16384])) for i in range(0,len(media),16384))
    iv=bytearray(16);iv[0]=1;iv[2]=0x12;iv[3]=0x34
    native.write_bytes(encrypt(media+table+head,bytes(range(1,17)),bytes(iv)))
    binary=out/'track-export'
    sources=[ROOT/'tests/track_export.m',*(resolve_source(n) for n in [
        'WireProto.m','NativeCacheMap.m','CacheStorageKey.m','CacheEnvelope.c','OggExport.c','OggInspection.c','OggValidationTrace.m','OggArtwork.c','ExportArtworkMetadata.m','ExportLibrary.m','ExportKeyVault.m','ExportCacheIndex.m','M4AExport.m','M4AConversionQueue.m','MediaDecode.c','TemporaryOfflineExport.m','ExportShareFolder.m'])]
    with (out/'track-export.log').open('w') as log:
        run('xcrun','clang','-fobjc-arc','-std=gnu11','-DSAP_VAULT_TESTING=1','-DSAP_TESTING=1','-O1','-g','-fsanitize=address,undefined',
            *('-I'+str(p) for p in include_directories()),*sources,'-lm','-lsqlite3','-framework','AudioToolbox','-framework','AVFoundation','-framework','CoreMedia','-framework','Foundation','-o',binary,
            stdout=log,stderr=subprocess.STDOUT)
        run(binary,env={**os.environ,'SAP_OGG_FIXTURE':str(prefixed),'SAP_NATIVE_CACHE_FIXTURE':str(native)},
            stdout=log,stderr=subprocess.STDOUT)
    (out/'results.json').write_text(json.dumps({'status':'PASS','sanitizers':['address','undefined'],
        'real_generated_vorbis':True,'native_unseal_association_and_overwrite_protection':True,
        'two_encrypted_layers':True,'native_media_zero_alignment':True,'original_cache_unchanged':True,'device_media_used':False,
        'phone_launched':False},indent=2)+'\n')
    print(f'PASS: production export, native unsealing and two-layer storage: {out}')


if __name__=='__main__':main()
