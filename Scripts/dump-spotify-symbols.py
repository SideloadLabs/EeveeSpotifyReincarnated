#!/usr/bin/env python3
"""
Dump hook-relevant symbol classes from a (decrypted) Spotify IPA/binary.

Buckets:
  [classes]   Swift/ObjC mangled class names (_TtC...) — what Orion hooks target
  [rpc]       gRPC/REST service paths (com.spotify.* / *.vN.Service/Method)
  [flags]     Feature-flag names (enable_*, ios_*, s2s_*, catalog_*)
  [selectors] ObjC-selector-shaped strings (heuristic)

Output is deterministic (sorted, no timestamps) so it diffs cleanly between
Spotify releases. Stdlib only — works on any python3.

Usage:
  dump-spotify-symbols.py <file.ipa | Spotify-binary> [-o output.txt]
"""

import argparse
import io
import mmap
import re
import sys
import zipfile

# Mach-O magics (on-disk byte order)
MH_MAGIC = b"\xce\xfa\xed\xfe"        # 32-bit
MH_MAGIC_64 = b"\xcf\xfa\xed\xfe"     # 64-bit
MH_CIGAM = b"\xfe\xed\xfa\xce"
MH_CIGAM_64 = b"\xfe\xed\xfa\xcf"
FAT_MAGIC = b"\xca\xfe\xba\xbe"
FAT_CIGAM = b"\xbe\xba\xfe\xca"
FAT_MAGIC_64 = b"\xca\xfe\xba\xbf"
FAT_CIGAM_64 = b"\xbf\xba\xfe\xca"

CPU_TYPE_ARM64 = 0x0100000C
CPU_TYPE_X86_64 = 0x01000007


def _u32(buf, off, big):
    return int.from_bytes(buf[off:off + 4], "big" if big else "little")


def macho_slice(blob):
    """Return (offset, size) of the arm64 (or first 64-bit) Mach-O slice."""
    if blob[:4] in (MH_MAGIC, MH_MAGIC_64, MH_CIGAM, MH_CIGAM_64):
        return 0, len(blob)
    if blob[:4] in (FAT_MAGIC, FAT_MAGIC_64):
        endian = "big"
    elif blob[:4] in (FAT_CIGAM, FAT_CIGAM_64):
        endian = "little"
    else:
        sys.stderr.write(
            "ERROR: not a Mach-O binary (bad magic %s). "
            "Is the IPA decrypted?\n" % blob[:4].hex()
        )
        sys.exit(2)

    nfat = _u32(blob, 4, endian == "big")
    entry_size = 32 if blob[:4] in (FAT_MAGIC_64, FAT_CIGAM_64) else 20
    fallback = None
    for i in range(nfat):
        base = 8 + i * entry_size
        cpu = _u32(blob, base, endian == "big")
        off = _u32(blob, base + 8, endian == "big")
        size = _u32(blob, base + 12, endian == "big")
        if cpu == CPU_TYPE_ARM64:
            return off, size
        if cpu == CPU_TYPE_X86_64 and fallback is None:
            fallback = (off, size)
    if fallback:
        return fallback
    sys.stderr.write("ERROR: no usable architecture slice in fat binary\n")
    sys.exit(2)


BUCKET_PATTERNS = {
    "classes": re.compile(rb"_TtC[A-Za-z0-9_]{5,}"),
    "rpc": re.compile(
        rb"(?:com\.spotify\.[A-Za-z0-9_.]+/[A-Za-z0-9_./-]{2,}"
        rb"|[A-Za-z0-9_.]{4,}\.v[0-9]+\.[A-Z][A-Za-z0-9]+/[A-Za-z0-9_]+"
        rb"|[a-z0-9][a-z0-9-]*/v[0-9]+/[a-z0-9_/.{}-]{3,}"
        rb"|(?:com\.)?[a-z0-9_.]{2,}\.v[0-9]+\.[A-Z][A-Za-z0-9]+Service)"
    ),
    "flags": re.compile(rb"\b(?:enable|ios|s2s|catalog)_[a-z0-9_]{2,}"),
    "selectors": re.compile(rb"[a-zA-Z_][a-zA-Z0-9_]*(?::[a-zA-Z0-9_]+)+:?"),
    # Standalone gRPC-method-shaped literals (FetchMessage, ResolveContext…).
    # Noisy on purpose, but own bucket: method churn (the FetchMessage rename
    # class) shows up here while the HIGH verdict stays tied to the rpc bucket.
    "methods": re.compile(
        rb"(?<![A-Za-z0-9_])(?:Get|Fetch|Set|Create|Delete|Update|List|Register"
        rb"|Unregister|Resolve|Batch|Put)[A-Z][A-Za-z0-9]+(?![A-Za-z0-9_])"
    ),
}

SELECTOR_EXCLUDES = (b"://", b"spotify:", b"/", b" ", b"\xc2")


def bucket_strings(data):
    out = {}
    for name, pattern in BUCKET_PATTERNS.items():
        found = set()
        for m in pattern.finditer(data):
            s = m.group(0)
            if name == "selectors":
                low = s.lower()
                if any(x in s for x in SELECTOR_EXCLUDES) or low.startswith(b"com."):
                    continue
            found.add(s.decode("ascii", "replace"))
        out[name] = sorted(found)
    return out


def load_binary(arg):
    """Accept an IPA (zip) or a raw Mach-O path; return (bytebuffer, size)."""
    with open(arg, "rb") as f:
        head = f.read(4)
    if head == b"PK\x03\x04":
        with zipfile.ZipFile(arg) as z:
            name = next(
                (n for n in z.namelist() if n.startswith("Payload/") and
                 n.endswith(".app/") is False and n.count("/") == 2 and
                 n.split("/")[-1] == "Spotify"),
                None,
            )
            if name is None:
                sys.stderr.write("ERROR: Payload/Spotify.app/Spotify not found in IPA\n")
                sys.exit(2)
            blob = z.read(name)
    else:
        with open(arg, "rb") as f:
            blob = f.read()
    off, size = macho_slice(blob)
    return blob[off:off + size]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("input", help="decrypted Spotify IPA or binary")
    ap.add_argument("-o", "--output", default="-", help="output path (default stdout)")
    args = ap.parse_args()

    data = load_binary(args.input)
    buckets = bucket_strings(data)

    lines = [
        "# eevee-symbol-dump v1",
        "# source: %s" % args.input,
        "# format: one entry per line under each [bucket]; sorted, deduped",
    ]
    for name in ("classes", "rpc", "flags", "methods", "selectors"):
        entries = buckets[name]
        lines.append("")
        lines.append("[%s]  # %d entries" % (name, len(entries)))
        lines.extend(entries)
    text = "\n".join(lines) + "\n"

    if args.output == "-":
        sys.stdout.write(text)
    else:
        with io.open(args.output, "w", encoding="utf-8") as f:
            f.write(text)
        total = sum(len(v) for v in buckets.values())
        sys.stderr.write(
            "dumped %d entries: %s\n" % (
                total, ", ".join("%s=%d" % (k, len(v)) for k, v in buckets.items()))
        )


if __name__ == "__main__":
    main()
