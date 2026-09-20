#!/usr/bin/env python3
"""
Diff two symbol dumps (from dump-spotify-symbols.py) and report what a
Spotify update changed in terms of hook impact.

Severity model:
  - Classes that EeveeSpotify hooks (targetName / NSClassFromString "_TtC…")
    are CRITICAL when they vanish — those hooks silently stop working.
  - RPC removals/renames are HIGH (matches the FetchMessage/pendragon class
    of breakage).
  - Everything else is informational (ADDED/REMOVED/RENAMED-SUSPECT lines).

Usage:
  diff-symbol-dumps.py <old_dump.txt> <new_dump.txt> [--tweak-sources DIR]
                       [-o report.md]
"""

import argparse
import glob
import io
import os
import re
import sys

BUCKETS = ("classes", "rpc", "flags", "methods", "selectors")


def parse_dump(path):
    buckets = {b: set() for b in BUCKETS}
    current = None
    with io.open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            m = re.match(r"^\[([a-z]+)\]", line)
            if m:
                current = m.group(1) if m.group(1) in buckets else None
                continue
            if current:
                buckets[current].add(line)
    return buckets


def tweak_hook_names(sources_dir):
    """Every mangled class name the tweak hooks, from targetName and
    NSClassFromString literals."""
    names = set()
    pat = re.compile(r'"(_TtC[^"]+)"')
    for path in glob.glob(os.path.join(sources_dir, "**", "*.swift"), recursive=True):
        try:
            with io.open(path, "r", encoding="utf-8", errors="replace") as f:
                for line in f:
                    names.update(pat.findall(line))
        except OSError:
            continue
    return names


def diff_bucket(old, new):
    return sorted(old - new), sorted(new - old)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("old_dump")
    ap.add_argument("new_dump")
    ap.add_argument("--tweak-sources", default="Sources/EeveeSpotify",
                    help="tweak sources dir to scan for hooked class names")
    ap.add_argument("-o", "--output", default="-")
    args = ap.parse_args()

    old = parse_dump(args.old_dump)
    new = parse_dump(args.new_dump)
    hooks = tweak_hook_names(args.tweak_sources)

    crit, high, lines = [], [], []

    for bucket in BUCKETS:
        removed, added = diff_bucket(old[bucket], new[bucket])
        if bucket == "classes":
            gone_hooks = [c for c in removed if c in hooks]
            if gone_hooks:
                crit.append("Hooked classes no longer present in the new binary:")
                crit.extend("  - %s" % c for c in sorted(gone_hooks))
        if bucket == "rpc":
            gone_rpc = [c for c in removed if "pendragon" in c or "customize" in c
                        or "bootstrap" in c or "ads" in c.lower()]
            if gone_rpc:
                high.append("Ad/Premium-relevant RPCs removed (check URL+Extension.swift):")
                high.extend("  - %s" % c for c in sorted(gone_rpc))

        if removed or added:
            lines.append("")
            lines.append("## [%s]  −%d / +%d" % (bucket, len(removed), len(added)))
            if removed:
                lines.append("")
                lines.append("### Removed (%d)" % len(removed))
                lines.extend("- `%s`" % s for s in removed[:400])
                if len(removed) > 400:
                    lines.append("- … and %d more" % (len(removed) - 400))
            if added:
                lines.append("")
                lines.append("### Added (%d)" % len(added))
                lines.extend("- `%s`" % s for s in added[:400])
                if len(added) > 400:
                    lines.append("- … and %d more" % (len(added) - 400))

    header = ["# Spotify symbol diff", "",
              "old: `%s`" % args.old_dump,
              "new: `%s`" % args.new_dump, ""]

    verdict = "CLEAN"
    if crit:
        verdict = "CRITICAL"
        header.append("## ⛔ CRITICAL — hooks will silently stop working")
        header.extend(crit)
        header.append("")
    if high:
        if verdict == "CLEAN":
            verdict = "HIGH"
        header.append("## ⚠️ HIGH — ad/Premium-relevant RPCs changed")
        header.extend(high)
        header.append("")
    if verdict == "CLEAN":
        header.append("## ✅ No critical or high-impact changes detected")
        header.append("")
        header.append("(cosmetic bucket changes, if any, are listed below)")
        header.append("")

    text = "\n".join(header + lines) + "\n"
    if args.output == "-":
        sys.stdout.write(text)
    else:
        with io.open(args.output, "w", encoding="utf-8") as f:
            f.write(text)
    sys.stderr.write("diff verdict: %s\n" % verdict)
    # Non-zero exit on critical findings so CI can surface them loudly,
    # without failing the whole run.
    sys.exit(0 if not crit else 3)


if __name__ == "__main__":
    main()
