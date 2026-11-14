"""Minimal arm64 Mach-O reader: segments, sections, function starts, vmaddr<->file offset."""
import struct

class Macho:
    def __init__(self, path):
        self.path = path
        self.data = open(path, "rb").read()
        d = self.data
        magic, cpu, sub, ftype, ncmds, sizeofcmds, flags, _ = struct.unpack_from("<IiiIIIII", d, 0)
        assert magic == 0xfeedfacf, hex(magic)
        off = 32
        self.segments = []   # (name, vmaddr, vmsize, fileoff, filesize)
        self.sections = {}   # (seg,sect) -> (addr, size, offset)
        self.func_starts = None
        self.fs_off = self.fs_size = 0
        self.base = None
        for _ in range(ncmds):
            cmd, size = struct.unpack_from("<II", d, off)
            if cmd == 0x19:  # LC_SEGMENT_64
                name = d[off+8:off+24].split(b"\0")[0].decode()
                vmaddr, vmsize, fileoff, filesize, _, _, nsects, _ = struct.unpack_from("<QQQQiiII", d, off+24)
                self.segments.append((name, vmaddr, vmsize, fileoff, filesize))
                if name == "__TEXT":
                    self.base = vmaddr
                so = off + 72
                for _ in range(nsects):
                    sname = d[so:so+16].split(b"\0")[0].decode()
                    sseg = d[so+16:so+32].split(b"\0")[0].decode()
                    addr, ssize, soff = struct.unpack_from("<QQI", d, so+32)
                    self.sections[(sseg, sname)] = (addr, ssize, soff)
                    so += 80
            elif cmd == 0x26:  # LC_FUNCTION_STARTS
                dataoff, datasize = struct.unpack_from("<II", d, off+8)
                self.fs_off, self.fs_size = dataoff, datasize
            off += size

    def v2f(self, vmaddr):
        for name, va, vs, fo, fs in self.segments:
            if va <= vmaddr < va + vs and name != "__PAGEZERO":
                return fo + (vmaddr - va)
        raise ValueError(hex(vmaddr))

    def f2v(self, fileoff):
        for name, va, vs, fo, fs in self.segments:
            if fo <= fileoff < fo + fs and name != "__PAGEZERO":
                return va + (fileoff - fo)
        raise ValueError(hex(fileoff))

    def read(self, vmaddr, n):
        o = self.v2f(vmaddr)
        return self.data[o:o+n]

    def function_starts(self):
        if self.func_starts is None and not self.fs_size:
            self.func_starts = []
        if self.func_starts is None:
            d = self.data[self.fs_off:self.fs_off + self.fs_size]
            out, addr, i = [], self.base, 0
            while i < len(d):
                v = shift = 0
                while True:
                    b = d[i]; i += 1
                    v |= (b & 0x7f) << shift
                    shift += 7
                    if not b & 0x80: break
                if v == 0: break
                addr += v
                out.append(addr)
            self.func_starts = out
        return self.func_starts

    def function_containing(self, vmaddr):
        import bisect
        fs = self.function_starts()
        i = bisect.bisect_right(fs, vmaddr) - 1
        return (fs[i], fs[i+1] if i + 1 < len(fs) else None)
