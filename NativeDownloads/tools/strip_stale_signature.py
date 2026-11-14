"""Remove dead bytes between the last __LINKEDIT table and the code signature of a Mach-O executable.

The executable inside the assembled EeveeSpotify IPA keeps Spotify's original 1.8 MB code signature as dead
data in front of the signature that was added later. LiveContainer ignores it, but the ldid used by AltStore
asserts that the string table ends within 0x10 bytes of the signature (ldid.cpp: end >= size - 0x10), so a
direct AltStore install of such an IPA fails. The tail is cut and LC_CODE_SIGNATURE is removed so that
codesign appends a fresh signature right after the last table. Code and data before __LINKEDIT are untouched.
"""
def strip_stale_signature(data):
    """Drop dead bytes between the last __LINKEDIT table and the code signature.

    The Chroma IPA executable keeps its original 1.8 MB code signature as dead data
    in front of the new one. LiveContainer ignores it, but the ldid inside AltStore
    asserts that the string table ends within 0x10 bytes of the signature
    (ldid.cpp: end >= size - 0x10). The tail is cut and LC_CODE_SIGNATURE is removed so
    that codesign re-appends the new signature right after the last table.
    """
    import struct
    data=bytearray(data);ncmds=struct.unpack_from('<I',data,16)[0];offset=32
    ends=[];signature=linkedit=None
    for _ in range(ncmds):
        command,length=struct.unpack_from('<II',data,offset)
        if command==0x19 and data[offset+8:offset+24].rstrip(b'\0')==b'__LINKEDIT':linkedit=offset
        elif command==0x1d:signature=offset
        elif command==0x2:
            symoff,nsyms,stroff,strsize=struct.unpack_from('<IIII',data,offset+8);ends+=[symoff+nsyms*16,stroff+strsize]
        elif command==0xb:
            indirect,count=struct.unpack_from('<II',data,offset+56);ends.append(indirect+count*4)
        elif command in (0x22,0x80000022):  # dyld info: five (offset, size) pairs
            for position in range(8,48,8):
                start,size=struct.unpack_from('<II',data,offset+position)
                if size:ends.append(start+size)
        elif command in (0x1e,0x26,0x29,0x2b,0x2e,0x80000033,0x80000034):
            start,size=struct.unpack_from('<II',data,offset+8)
            if size:ends.append(start+size)
        offset+=length
    if signature is None or linkedit is None:raise ValueError('Executable has no code signature or __LINKEDIT')
    sig_offset,sig_size=struct.unpack_from('<II',data,signature+8)
    if sig_offset+sig_size!=len(data):raise ValueError('Code signature is not at the end of the executable')
    fileoff,filesize=struct.unpack_from('<QQ',data,linkedit+40)
    if any(end>sig_offset for end in ends):raise ValueError('A __LINKEDIT table follows the code signature')
    keep=(max(ends)+15)&~15
    if sig_offset-keep<=0x10:return bytes(data),0
    removed=len(data)-keep
    struct.pack_into('<Q',data,linkedit+48,keep-fileoff)
    length=struct.unpack_from('<I',data,signature+4)[0];sizeofcmds=struct.unpack_from('<I',data,20)[0]
    commands_end=32+sizeofcmds
    data[signature:commands_end]=data[signature+length:commands_end]+bytes(length)
    struct.pack_into('<II',data,16,ncmds-1,sizeofcmds-length)
    del data[keep:]
    return bytes(data),removed
