"""Observe guarded 9.1.92 key boundaries without reading key contents.

The request trampoline preserves the fixed mode-0 argument and returns to the
original indirect call. Completion trampolines replay all displaced prologues.
Nothing is patched at runtime. The helper does no tracing while diagnostics
are off, and the original callbacks retain their arguments and ownership.
"""
import struct
import subprocess
import tempfile
from functools import cache
from pathlib import Path
from patch_native_restrictions import layout,branch,UUID
from patch_key_request_mode import DLSYM_STUB,_verify_dlsym_binding

SYMBOL=b'SAPTraceNativeBoundary\0'
from pixie_target import PROFILE
POINTS = [(point["name"], int(point["address"], 16), int(point["cave"], 16),
           bytes.fromhex(point["original"]), point["kind"])
          for point in PROFILE["trace_points"]]

def text_tail_padding(data):
    """Return unused file-backed __TEXT space after its final declared section."""
    cursor=32
    for _ in range(struct.unpack_from('<I',data,16)[0]):
        command,length=struct.unpack_from('<II',data,cursor)
        if command==0x19 and data[cursor+8:cursor+24].split(b'\0')[0]==b'__TEXT':
            fileoff,filesize=struct.unpack_from('<QQ',data,cursor+40)
            count=struct.unpack_from('<I',data,cursor+64)[0]
            if length<72 or 72+count*80>length or fileoff+filesize>len(data):
                raise ValueError('Invalid executable text section table')
            section_end=fileoff
            for index in range(count):
                section=cursor+72+index*80
                size=struct.unpack_from('<Q',data,section+40)[0]
                offset=struct.unpack_from('<I',data,section+48)[0]
                if offset:
                    if offset<fileoff or offset+size>fileoff+filesize:
                        raise ValueError('Text section exceeds its file-backed segment')
                    section_end=max(section_end,offset+size)
            return section_end,fileoff+filesize
        cursor+=length
    raise ValueError('Executable text segment absent')

@cache
def template(kind):
    stores='\n'.join(f' stp x{i}, x{i+1}, [sp, #{i*8}]' for i in range(0,18,2))+'\n stp x18, x30, [sp, #144]'
    vectors='\n'.join(f' stp q{i}, q{i+1}, [sp, #{160+i*16}]' for i in range(0,8,2))
    restores='\n'.join(f' ldp x{i}, x{i+1}, [sp, #{i*8}]' for i in range(0,18,2))+'\n ldp x18, x30, [sp, #144]'
    vrestore='\n'.join(f' ldp q{i}, q{i+1}, [sp, #{160+i*16}]' for i in range(0,8,2))
    asm=f'''.text
.p2align 2
.globl _trace_boundary
_trace_boundary:
 sub sp, sp, #320
{stores}
{vectors}
 mrs x17, nzcv
 str x17, [sp, #288]
 mrs x17, fpcr
 str x17, [sp, #296]
 mrs x17, fpsr
 str x17, [sp, #304]
 {'str xzr, [sp, #16]' if kind==0 else ''}
 movn x0, #1
 adr x1, Lname
 .long 0x90000010
 add x16, x16, #0
 blr x16
 cbz x0, Ldone
 mov x16, x0
 mov w0, #{kind}
 mov x1, sp
 blr x16
Ldone:
 ldr x17, [sp, #296]
 msr fpcr, x17
 ldr x17, [sp, #304]
 msr fpsr, x17
 ldr x17, [sp, #288]
 msr nzcv, x17
{vrestore}
{restores}
 add sp, sp, #320
 .long 0x14000000
Lname:
 .asciz "SAPTraceNativeBoundary"
'''
    with tempfile.TemporaryDirectory(prefix='pixie-native-trace-') as tmp:
        source=Path(tmp)/'boundary.S';obj=Path(tmp)/'boundary.o';source.write_text(asm)
        sdk=subprocess.check_output(['xcrun','--sdk','iphoneos','--show-sdk-path'],text=True).strip()
        subprocess.run(['xcrun','clang','-c','-arch','arm64','-target','arm64-apple-ios15.0','-isysroot',sdk,str(source),'-o',str(obj)],check=True)
        raw=obj.read_bytes()
    cursor=32
    for _ in range(struct.unpack_from('<I',raw,16)[0]):
        cmd,size=struct.unpack_from('<II',raw,cursor)
        if cmd==0x19:
            for n in range(struct.unpack_from('<I',raw,cursor+64)[0]):
                s=cursor+72+n*80
                if raw[s:s+16].split(b'\0')[0]!=b'__text':continue
                length=struct.unpack_from('<Q',raw,s+40)[0];offset=struct.unpack_from('<I',raw,s+48)[0]
                if struct.unpack_from('<I',raw,s+60)[0]:raise ValueError('Unresolved trace relocation')
                return raw[offset:offset+length]
        cursor+=size
    raise ValueError('Trace template missing')

def trampoline(point):
    name,address,cave,expected,kind=point;out=bytearray(template(kind));symbol=out.index(SYMBOL)
    words=[struct.unpack_from('<I',out,i)[0] for i in range(0,symbol,4)]
    adrp=words.index(0x90000010)*4
    delta=(DLSYM_STUB>>12)-((cave+adrp)>>12)
    if not -(1<<20)<=delta<(1<<20):raise ValueError('Trace dlsym out of range')
    struct.pack_into('<I',out,adrp,0x90000010|((delta&3)<<29)|(((delta>>2)&0x7ffff)<<5))
    struct.pack_into('<I',out,adrp+4,0x91000210|((DLSYM_STUB&0xfff)<<10))
    # Insert the original callback prologue before its final branch. ADR's
    # target follows it, so its immediate must be adjusted by the inserted size.
    final=(len(words)-1)*4
    replay=b'' if kind==0 else expected
    if replay:
        adr=next(i*4 for i,w in enumerate(words) if w&0x9f00001f==0x10000001)
        old=struct.unpack_from('<I',out,adr)[0]
        imm=(((old>>5)&0x7ffff)<<2)|((old>>29)&3);imm+=len(replay)
        struct.pack_into('<I',out,adr,0x10000001|((imm&3)<<29)|(((imm>>2)&0x7ffff)<<5))
        out[final:final]=replay;final+=len(replay)
    struct.pack_into('<I',out,final,branch(cave+final,address+len(expected)))
    if len(out)>0x200:raise ValueError('Trace cave overflows')
    return bytes(out)

def patch(data):
    end,first,segments,uuid=layout(data)
    if uuid!=UUID:raise ValueError('Unsupported trace executable UUID')
    _verify_dlsym_binding(data);out=bytearray(data);reports=[]
    text=next(s for s in segments if s[0]==b'__TEXT');_,vm,_,fo,size,protection=text
    tail_start,tail_end=text_tail_padding(data)
    def off(address,length):
        if not vm<=address or address+length>vm+size:raise ValueError('Trace outside executable text')
        return fo+address-vm
    for point in POINTS:
        name,address,cave,expected,kind=point;code=trampoline(point);target=off(cave,len(code));source=off(address,len(expected))
        header_padding=end<=target and target+len(code)<=first
        tail_padding=tail_start<=target and target+len(code)<=tail_end
        if protection&5!=5 or not (header_padding or tail_padding) or any(data[target:target+len(code)]):raise ValueError('Trace padding is occupied or unavailable')
        if data[source:source+len(expected)]!=expected:raise ValueError(f'Trace {name} prologue differs')
        if kind==0 and data[source+4:source+8]!=bytes.fromhex('20013fd6'):raise ValueError('Native key call target instruction differs')
        out[target:target+len(code)]=code;struct.pack_into('<I',out,source,branch(address,cave))
        reports.append({'boundary':name,'address':hex(address),'cave':hex(cave),'bytes':len(code),'padding':'text_header' if header_padding else 'text_tail_after_last_section','preserves_native_callback_ownership':True})
    return bytes(out),{'uuid':UUID.hex(),'fixed_request_mode':0,'helper':SYMBOL[:-1].decode(),'boundaries':reports,'key_material_read':False}

def header():
    lines=[f'// Generated guarded native observation boundaries for Spotify {PROFILE["spotify_version"]}.','#pragma once','#include <stdint.h>']
    for point in POINTS:
        name,address,cave,expected,kind=point;stub=trampoline(point)
        values=lambda b:','.join(f'0x{x:02x}' for x in b)
        lines += [f'static const uintptr_t SAPTrace{name}Offset=0x{address-0x100000000:x};',
                  f'static const uintptr_t SAPTrace{name}CaveOffset=0x{cave-0x100000000:x};',
                  f'static const uint8_t SAPTrace{name}Head[]={{{values(struct.pack("<I",branch(address,cave)))}}};',
                  f'static const uint8_t SAPTrace{name}Code[]={{{values(stub)}}};']
    return '\n'.join(lines)+'\n'
