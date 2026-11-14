"""Verify embedded pictures and byte-identical codec packets with synthetic media."""
from pathlib import Path
import base64
import json
import os
import struct
import subprocess
import tempfile
from pixie_target import ROOT,resolve_source


def crc(data):
    value=0
    for byte in data:
        value ^= byte<<24
        for _ in range(8):value=((value<<1)^ (0x04c11db7 if value&0x80000000 else 0))&0xffffffff
    return value


def pages(data):
    at=0
    while at<len(data):
        assert data[at:at+4]==b'OggS'
        n=data[at+26];laces=data[at+27:at+27+n];end=at+27+n+sum(laces)
        page=data[at:end];assert crc(page[:22]+bytes(4)+page[26:])==struct.unpack_from('<I',page,22)[0]
        yield page,laces,page[27+n:];at=end
    assert at==len(data)


def packets(data):
    result=[];pending=bytearray()
    for page,laces,body in pages(data):
        at=0
        for size in laces:
            pending+=body[at:at+size];at+=size
            if size<255:result.append(bytes(pending));pending.clear()
    assert not pending
    return result


def page(body,laces,seq,serial,flags=0,granule=0):
    h=bytearray(b'OggS'+bytes([0,flags])+struct.pack('<QII',granule,serial,seq)+bytes(4)+bytes([len(laces)]))
    data=h+bytes(laces)+body;struct.pack_into('<I',data,22,crc(data));return data


def replace_comment(data,comment,shared):
    original=list(pages(data));serial=struct.unpack_from('<I',original[0][0],14)[0]
    old=packets(data);seq=1;result=original[0][0];tail=old[2] if shared else b''
    payload=comment+tail;laces=[]
    for packet in ([comment,tail] if shared else [comment]):
        if not packet:continue
        laces += [255]*(len(packet)//255)+[len(packet)%255]
    offset=0;continued=False
    while laces:
        batch=laces[:255];laces=laces[255:];size=sum(batch)
        result+=page(payload[offset:offset+size],batch,seq,serial,int(continued),0xffffffffffffffff if batch[-1]==255 else 0)
        offset+=size;seq+=1;continued=batch[-1]==255
    # Original fixture has its comment and setup together on its second page.
    assert len(original)>2 and original[1][1][-1]<255
    if not shared:
        setup=old[2];result+=page(setup,[255]*(len(setup)//255)+[len(setup)%255],seq,serial);seq+=1
    for p,l,b in original[2:]:
        result+=page(b,l,seq,serial,p[5],struct.unpack_from('<Q',p,6)[0]);seq+=1
    return result


def comments(packet):
    assert packet[:7]==b'\x03vorbis'
    vendor_size=struct.unpack_from('<I',packet,7)[0];at=11+vendor_size
    count=struct.unpack_from('<I',packet,at)[0];at+=4;out=[]
    for _ in range(count):
        size=struct.unpack_from('<I',packet,at)[0];at+=4;out.append(packet[at:at+size]);at+=size
    assert packet[at]&1
    return out


def main():
    source=(ROOT/'tests/fixtures/export-tone-10s.ogg').read_bytes();original=packets(source)
    with tempfile.TemporaryDirectory(prefix='pixie-ogg-artwork-') as folder:
        root=Path(folder);binary=root/'test';harness=root/'test.c'
        harness.write_text('''#include "OggArtwork.h"
#include "OggExport.h"
#include <stdlib.h>
int main(int n,char **v){FILE *s=fopen(v[1],"rb"),*o=fopen(v[2],"w+b"),*j=fopen(v[3],"rb");
fseek(j,0,SEEK_END);long size=ftell(j);rewind(j);unsigned char *b=malloc(size);fread(b,1,size,j);fclose(j);
fseek(s,0,SEEK_END);long length=ftell(s);rewind(s);int ok=SAPWriteOggWithArtwork(s,0,length,o,b,size,640,640);free(b);
uint64_t at=0,bytes=0;if(ok)ok=SAPValidateOggExport(o,10000,&at,&bytes)&&at==0;fclose(s);fclose(o);return ok?0:1;}
''')
        subprocess.run(['xcrun','clang','-O1','-g','-fsanitize=address,undefined','-I'+str(resolve_source('OggArtwork.h').parent),str(harness),str(resolve_source('OggArtwork.c')),str(resolve_source('OggExport.c')),'-o',str(binary)],check=True)
        jpeg=b'\xff\xd8'+b'fixture-image'*100+b'\xff\xd9';image=root/'image.jpg';image.write_bytes(jpeg)
        keep=b'TITLE=Synthetic tone';oldart=b'coverart=obsolete'
        for size,shared in [(0,False),(0,True),(65025,True),(130050,False),(255,True)]:
            fields=[keep,oldart,b'COMMENT='+b'x'*size]
            comment=b'\x03vorbis'+struct.pack('<I',6)+b'vendor'+struct.pack('<I',len(fields))+b''.join(struct.pack('<I',len(f))+f for f in fields)+b'\x01'
            data=replace_comment(source,comment,shared);src=root/'in.ogg';dst=root/'out.ogg';src.write_bytes(data)
            subprocess.run([str(binary),str(src),str(dst),str(image)],check=True)
            tagged=dst.read_bytes();result=packets(tagged)
            assert result[0]==original[0] and result[2:]==original[2:],'codec packets changed'
            tags=comments(result[1]);assert keep in tags and oldart not in tags
            picture=[t for t in tags if t.startswith(b'METADATA_BLOCK_PICTURE=')];assert len(picture)==1
            raw=base64.b64decode(picture[0].split(b'=',1)[1],validate=True)
            assert struct.unpack_from('>II',raw)==(3,10) and raw[8:18]==b'image/jpeg'
            assert struct.unpack_from('>IIIIII',raw,18)==(0,640,640,24,0,len(jpeg)) and raw[42:]==jpeg
            assert src.read_bytes()==data,'source changed'
            # Re-embedding must replace the old picture rather than append another.
            subprocess.run([str(binary),str(dst),str(root/'again.ogg'),str(image)],check=True)
            assert len([t for t in comments(packets((root/'again.ogg').read_bytes())[1]) if t.startswith(b'METADATA_BLOCK_PICTURE=')])==1
        corrupt=bytearray(source);corrupt[-1]^=1;src.write_bytes(corrupt)
        assert subprocess.run([str(binary),str(src),str(dst),str(image)]).returncode==1
        image.write_bytes(b'not jpeg');src.write_bytes(source)
        assert subprocess.run([str(binary),str(src),str(dst),str(image)]).returncode==1
    print('PASS: embedded picture, existing tags, shared/continued headers, replacement, corrupt input; codec packets unchanged; ASan/UBSan')


if __name__=='__main__':main()
