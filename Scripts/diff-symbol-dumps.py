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


def _mangle_dotted_swift_class(dotted):
    parts = dotted.split(".")
    if len(parts) == 2 and all(parts):
        mod, cls = parts
        return "_TtC%d%s%d%s" % (len(mod), mod, len(cls), cls)
    return None


def tweak_hook_names(sources_dir):
    """Every class name the tweak hooks, from _TtC... mangled names,
    dotted Module.Class names (plus their _TtC mangled equivalents),
    plain SPT*/HUB* ObjC names, and targetName/NSClassFromString/findTweakClass literals."""
    names = set()
    mangled_pat = re.compile(r'"(_Tt[A-Za-z0-9_]+)"')
    dotted_pat = re.compile(r'"([A-Z][A-Za-z0-9_]+\.[A-Z][A-Za-z0-9_]+)"')
    objc_pat = re.compile(r'"((?:SPT|HUB)[A-Za-z0-9_]+)"')
    target_pat = re.compile(r'targetName\s*(?::\s*String)?\s*=\s*"([A-Za-z_][A-Za-z0-9_.]*)"')
    lookup_pat = re.compile(
        r'(?:NSClassFromString|findTweakClass)\(\s*"([A-Za-z_][A-Za-z0-9_.]*)"\s*\)'
    )

    for path in glob.glob(os.path.join(sources_dir, "**", "*.swift"), recursive=True):
        try:
            with io.open(path, "r", encoding="utf-8", errors="replace") as f:
                text = f.read()
        except OSError:
            continue

        names.update(mangled_pat.findall(text))
        names.update(objc_pat.findall(text))
        names.update(target_pat.findall(text))
        names.update(lookup_pat.findall(text))

        for dotted in dotted_pat.findall(text):
            names.add(dotted)
            mangled = _mangle_dotted_swift_class(dotted)
            if mangled:
                names.add(mangled)

    for item in list(names):
        if "." in item:
            mangled = _mangle_dotted_swift_class(item)
            if mangled:
                names.add(mangled)

    return names


def _extract_class_hook_selectors(text):
    selectors = set()
    hook_cls_pat = re.compile(r"class\s+\w+\s*:\s*ClassHook<[^>]+>\s*\{")
    func_pat = re.compile(
        r"(?<!//\s)func\s+`?([A-Za-z_][A-Za-z0-9_]*)`?\s*\(([^)]*)\)",
        re.MULTILINE | re.DOTALL,
    )
    for m in hook_cls_pat.finditer(text):
        start = m.end() - 1
        depth = 0
        i = start
        body = None
        while i < len(text):
            if text[i] == "{":
                depth += 1
            elif text[i] == "}":
                depth -= 1
                if depth == 0:
                    body = text[start:i + 1]
                    break
            i += 1
        if not body:
            continue

        for fm in func_pat.finditer(body):
            prefix = body[max(0, fm.start() - 120):fm.start()]
            if "orion:new" in prefix.splitlines()[-2:]:
                continue
            if any("orion:new" in ln for ln in prefix.splitlines()[-2:]):
                continue
            fname = fm.group(1)
            params_str = fm.group(2).strip()
            if not params_str:
                selectors.add(fname)
                continue
            parts = [p.strip() for p in params_str.split(",") if p.strip()]
            sel_parts = []
            for p_idx, part in enumerate(parts):
                lhs = part.split(":", 1)[0].strip()
                tokens = lhs.split()
                ext_label = tokens[0] if tokens else "_"
                if p_idx == 0:
                    if ext_label == "_":
                        sel_parts.append(fname + ":")
                    else:
                        sel_parts.append(fname + ext_label[0].upper() + ext_label[1:] + ":")
                else:
                    if ext_label == "_":
                        sel_parts.append(":")
                    else:
                        sel_parts.append(ext_label + ":")
            selectors.add("".join(sel_parts))
    return selectors


def tweak_hook_selectors(sources_dir):
    """Every ObjC selector the tweak hooks or checks at runtime."""
    selectors = set()
    sel_pats = (
        re.compile(r'Selector\(\s*\(?\s*"([A-Za-z_][A-Za-z0-9_:]*)"\s*\)?\s*\)'),
        re.compile(r'NSSelectorFromString\(\s*"([A-Za-z_][A-Za-z0-9_:]*)"\s*\)'),
        re.compile(r'sel_registerName\(\s*"([A-Za-z_][A-Za-z0-9_:]*)"\s*\)'),
        re.compile(r'@objc\(\s*([A-Za-z_][A-Za-z0-9_:]*)\s*\)'),
    )
    for path in glob.glob(os.path.join(sources_dir, "**", "*.swift"), recursive=True):
        try:
            with io.open(path, "r", encoding="utf-8", errors="replace") as f:
                text = f.read()
        except OSError:
            continue
        for pat in sel_pats:
            selectors.update(pat.findall(text))
        selectors.update(_extract_class_hook_selectors(text))
    return selectors


def is_ad_or_upsell_service_class(class_name):
    return ("Ads" in class_name or "Upsell" in class_name) and "Service" in class_name


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
    hook_selectors = tweak_hook_selectors(args.tweak_sources)

    crit, high, lines = [], [], []

    for bucket in BUCKETS:
        removed, added = diff_bucket(old[bucket], new[bucket])
        if bucket == "classes":
            gone_hooks = [c for c in removed if c in hooks]
            if gone_hooks:
                crit.append("Hooked classes no longer present in the new binary:")
                crit.extend("  - %s" % c for c in sorted(gone_hooks))
            new_unhooked_services = [
                c for c in added
                if c not in hooks and is_ad_or_upsell_service_class(c)
            ]
            if new_unhooked_services:
                crit.append("New unhooked Ads/Upsell Service classes in the new binary:")
                crit.extend("  - %s" % c for c in sorted(new_unhooked_services))
        if bucket == "selectors":
            gone_selectors = [s for s in removed if s in hook_selectors]
            if gone_selectors:
                crit.append("Hooked selectors no longer present in the new binary:")
                crit.extend("  - %s" % s for s in sorted(gone_selectors))
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
