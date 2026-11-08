#!/usr/bin/env python3
"""
Offline automated IPA auditor for EeveeSpotify's oracle ad-blocking & entitlement
architecture.

Given a decrypted Spotify .ipa (or Mach-O binary), this script runs in <3 seconds
and verifies:
  1. Audit 1 (Broken Hooks): Every critical ad/premium/network hook target parsed
     from Sources/EeveeSpotify/**/*.swift exists in Payload/Spotify.app/Spotify.
  2. Audit 2 (Unhooked Ad Services): Every _TtC service class in the binary
     matching (Ads|AdSlot|InStream|Upsell|Leavebehind|Sponsored|RealTimeAd).*Service
     is accounted for in Sources/EeveeSpotify/ (or explicitly exempted as a
     non-ad-delivery / DI-required service).
  3. Audit 3 (Injected Dylib Verification): When the input is a .ipa containing
     Payload/Spotify.app/Frameworks/EeveeSpotify.dylib (or --dylib-check is used),
     verifies that every critical hook target and [ORACLE] sink marker from
     Sources/EeveeSpotify/ is compiled into that dylib.

Exits with code 0 on pass, 1 on any audit failure.
"""

import argparse
import glob
import io
import os
import re
import sys
import time
import zipfile

# Mach-O magics
MH_MAGICS = (
    b"\xce\xfa\xed\xfe",
    b"\xcf\xfa\xed\xfe",
    b"\xfe\xed\xfa\xce",
    b"\xfe\xed\xfa\xcf",
)
FAT_MAGICS_BE = (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf")
FAT_MAGICS_LE = (b"\xbe\xba\xfe\xca", b"\xbf\xba\xfe\xca")
CPU_TYPE_ARM64 = 0x0100000C
CPU_TYPE_X86_64 = 0x01000007

# Core chokepoint files whose hook targets must exist in EVERY Spotify IPA.
CORE_CHOKEPOINT_FILES = (
    "UpsellPopupBlocker.x.swift",
    "EeveePremiumForce.x.swift",
    "DataLoaderServiceHooks.x.swift",
    "HttpClientURLSessionHooks.x.swift",
    "RemoteFlagsHooks.x.swift",
    "HubsAdBlocker.x.swift",
    "SessionProtection.x.swift",
)

# Cumulative service/view blocker files across Spotify releases. Individual
# Swift services/views may be added or removed across 9.1.x versions; Audit 2
# ensures every ad/upsell service present in the audited IPA is covered by this
# cumulative superset, and Audit 3 ensures the entire cumulative superset is
# compiled into EeveeSpotify.dylib.
CUMULATIVE_BLOCKER_FILES = (
    "EeveeAdBlockerExtended.x.swift",
    "UpsellServiceBlocker.x.swift",
    "ClientMessagingPlatformBlocker.x.swift",
)

# Core chokepoint classes declared inside CUMULATIVE_BLOCKER_FILES that must
# still exist in every Spotify IPA under Audit 1.
CORE_CHOKEPOINT_CLASSES_IN_CUMULATIVE_FILES = {
    "SPTCoreURLSessionDataDelegate",
}

AD_SERVICE_REGEX = re.compile(
    r"(Ads|AdSlot|InStream|Upsell|Leavebehind|Sponsored|RealTimeAd).*Service"
)

# Services that match AD_SERVICE_REGEX in 9.1.8x binaries but must NOT have
# their SPTService -load method no-op'd because they either:
#   - provide required DI protocols to non-ad features (killing -load crashes
#     downstream service initialization), or
#   - serve legal/regulatory notices or preferences/utilities (DSA, ComScore, etc.).
KNOWN_NON_LOAD_HOOKED_SERVICES = {
    "_TtC19AdsPlatform_DSAImpl14DSAServiceImpl",
    "_TtC24AdsPlatform_ComScoreImpl19ComScoreServiceImpl",
    "_TtC25PremiumUpsell_PremiumImpl14PremiumService",
    "_TtC26CulturalMoments_UpsellImpl17UpsellServiceImpl",
    "_TtC27AdsPlatform_AdsFeedbackImpl22AdsFeedbackServiceImpl",
    "_TtC30Jam_AdsDisclaimerSheetPageImpl29AdsDisclaimerSheetPageService",
    "_TtC31AdsPlatform_AdsInAppBrowserImpl22AdsInAppBrowserService",
    "_TtC34AdsPlatform_MobiusAdsUtilitiesImpl29MobiusAdsUtilitiesServiceImpl",
    "_TtC35AdsPlatform_AdsIdentityTrackingImpl33AdsIdentityTrackingSessionService",
    "_TtC35AdsPlatform_AdsIdentityTrackingImpl37AdsIdentityPermissionRequestorService",
    "_TtC36AdsPlatform_AdsContextMenuButtonImpl31AdsContextMenuButtonServiceImpl",
    "_TtC36AdsPlatform_AdsPreferencesConfigImpl31AdsPreferencesConfigServiceImpl",
    "_TtC40PremiumUpsell_PremiumDestinationPageImpl29PremiumDestinationServiceImpl",
}


def _u32(buf, off, big):
    return int.from_bytes(buf[off:off + 4], "big" if big else "little")


def macho_slice(blob):
    if blob[:4] in MH_MAGICS:
        return 0, len(blob)
    if blob[:4] in FAT_MAGICS_BE:
        big = True
    elif blob[:4] in FAT_MAGICS_LE:
        big = False
    else:
        sys.stderr.write(
            f"ERROR: not a Mach-O binary (magic {blob[:4].hex()}). Is the IPA decrypted?\n"
        )
        sys.exit(2)

    nfat = _u32(blob, 4, big)
    entry_size = 32 if blob[:4] in (b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca") else 20
    fallback = None
    for i in range(nfat):
        base = 8 + i * entry_size
        cpu = _u32(blob, base, big)
        off = _u32(blob, base + 8, big)
        size = _u32(blob, base + 12, big)
        if cpu == CPU_TYPE_ARM64:
            return off, size
        if cpu == CPU_TYPE_X86_64 and fallback is None:
            fallback = (off, size)
    if fallback:
        return fallback
    sys.stderr.write("ERROR: no usable Mach-O slice found\n")
    sys.exit(2)


def load_binary_and_dylib(path):
    """Return (spotify_macho_bytes, dylib_macho_bytes_or_None, dylib_zip_path_or_None)."""
    with open(path, "rb") as f:
        head = f.read(4)
    if head == b"PK\x03\x04":
        with zipfile.ZipFile(path) as z:
            names = z.namelist()
            entry = next(
                (
                    n for n in names
                    if n.startswith("Payload/")
                    and not n.endswith(".app/")
                    and n.count("/") == 2
                    and n.split("/")[-1] == "Spotify"
                ),
                None,
            )
            if entry is None:
                sys.stderr.write("ERROR: Payload/Spotify.app/Spotify not found in IPA\n")
                sys.exit(2)
            blob = z.read(entry)

            dylib_entry = next(
                (
                    n for n in names
                    if n.startswith("Payload/")
                    and n.endswith("/Frameworks/EeveeSpotify.dylib")
                ),
                None,
            )
            dylib_blob = None
            if dylib_entry is not None:
                raw_dylib = z.read(dylib_entry)
                d_off, d_size = macho_slice(raw_dylib)
                dylib_blob = raw_dylib[d_off:d_off + d_size]
    else:
        with open(path, "rb") as f:
            blob = f.read()
        dylib_blob = None
        dylib_entry = None

    off, size = macho_slice(blob)
    return blob[off:off + size], dylib_blob, dylib_entry


def extract_binary_symbols(data):
    """Extract all identifier strings and _TtC Swift class symbols from binary."""
    all_strings = {
        m.group(0).decode("ascii")
        for m in re.finditer(rb"[A-Za-z_][A-Za-z0-9_.]{3,160}", data)
    }
    ttc_classes = {
        s for s in all_strings if s.startswith("_TtC") and len(s) >= 9
    }
    return all_strings, ttc_classes


def extract_printable_strings(data):
    """Extract printable ASCII strings from a Mach-O image (e.g. EeveeSpotify.dylib)."""
    return [
        m.group(0).decode("ascii")
        for m in re.finditer(rb"[\x20-\x7e]{4,240}", data)
    ]


def mangle_dotted_swift_class(dotted):
    parts = dotted.split(".")
    if len(parts) == 2 and all(parts):
        mod, cls = parts
        return f"_TtC{len(mod)}{mod}{len(cls)}{cls}"
    return None


def split_ttc_class(mangled):
    """Return (module_name, class_name) for a standard _TtC<len><mod><len><cls> symbol."""
    m = re.match(r"^_TtC(\d+)(.+)$", mangled)
    if not m:
        return None, None
    mod_len = int(m.group(1))
    rest = m.group(2)
    if len(rest) <= mod_len:
        return None, None
    mod = rest[:mod_len]
    rem = rest[mod_len:]
    m2 = re.match(r"^(\d+)(.+)$", rem)
    if not m2:
        return mod, rem
    cls_len = int(m2.group(1))
    cls = m2.group(2)[:cls_len]
    return mod, cls


def parse_tweak_hooks(sources_dir):
    """Parse Sources/EeveeSpotify/**/*.swift for every hooked targetName,
    findTweakClass(...), NSClassFromString(...), and [ORACLE][...] sink markers."""
    target_pat = re.compile(
        r'targetName\s*(?::\s*String)?\s*=\s*"([A-Za-z_][A-Za-z0-9_.]*)"'
    )
    lookup_pat = re.compile(
        r'(?:findTweakClass|NSClassFromString)\(\s*"([A-Za-z_][A-Za-z0-9_.]*)"\s*\)'
    )
    oracle_marker_pat = re.compile(r"(\[ORACLE\]\[[A-Z0-9_]+\])")

    all_hooked = set()
    core_chokepoint_targets = []
    cumulative_superset_targets = []
    oracle_markers = []
    seen_markers = set()

    swift_files = sorted(
        glob.glob(os.path.join(sources_dir, "**", "*.swift"), recursive=True)
    )
    for path in swift_files:
        try:
            with io.open(path, "r", encoding="utf-8", errors="replace") as f:
                text = f.read()
        except OSError:
            continue

        rel_path = os.path.relpath(path)
        base_name = os.path.basename(path)
        for marker in oracle_marker_pat.findall(text):
            if marker not in seen_markers:
                seen_markers.add(marker)
                oracle_markers.append((rel_path, marker))

        targets = target_pat.findall(text) + lookup_pat.findall(text)
        if not targets:
            continue

        seen_in_file = set()
        for t in targets:
            all_hooked.add(t)
            mangled = mangle_dotted_swift_class(t)
            if mangled:
                all_hooked.add(mangled)
            if t in seen_in_file:
                continue
            seen_in_file.add(t)

            if base_name in CORE_CHOKEPOINT_FILES or (
                base_name in CUMULATIVE_BLOCKER_FILES
                and t in CORE_CHOKEPOINT_CLASSES_IN_CUMULATIVE_FILES
            ):
                core_chokepoint_targets.append((rel_path, t))
                cumulative_superset_targets.append((rel_path, t))
            elif base_name in CUMULATIVE_BLOCKER_FILES:
                cumulative_superset_targets.append((rel_path, t))

    return (
        all_hooked,
        core_chokepoint_targets,
        cumulative_superset_targets,
        oracle_markers,
    )


def is_service_class(mangled):
    """True when the demangled class name itself is a *Service* implementation."""
    _, cls = split_ttc_class(mangled)
    if not cls:
        return mangled.endswith(("Service", "ServiceImpl", "ServiceImplementation"))
    return cls.endswith(("Service", "ServiceImpl", "ServiceImplementation"))


def audit_injected_dylib(dylib_blob, critical_targets, oracle_markers):
    """Verify every critical hook target and [ORACLE] sink marker is compiled into
    EeveeSpotify.dylib."""
    ident_strings, _ = extract_binary_symbols(dylib_blob)
    printable_lines = extract_printable_strings(dylib_blob)

    missing_dylib_hooks = []
    for rel_path, target in critical_targets:
        mangled = mangle_dotted_swift_class(target)
        in_dylib = (
            target in ident_strings
            or (mangled is not None and mangled in ident_strings)
            or any(target in line for line in printable_lines)
        )
        if not in_dylib:
            missing_dylib_hooks.append((rel_path, target))

    missing_oracle_markers = []
    for rel_path, marker in oracle_markers:
        if not any(marker in line for line in printable_lines):
            missing_oracle_markers.append((rel_path, marker))

    return missing_dylib_hooks, missing_oracle_markers


def main():
    t0 = time.monotonic()
    ap = argparse.ArgumentParser(description="Offline Oracle IPA Auditor")
    ap.add_argument("ipa_or_binary", help="Path to patched.ipa or decrypted Spotify binary")
    ap.add_argument(
        "--sources",
        default="Sources/EeveeSpotify",
        help="Path to EeveeSpotify Swift sources (default: Sources/EeveeSpotify)",
    )
    ap.add_argument(
        "--dylib-check",
        dest="dylib_check",
        action="store_true",
        default=None,
        help="Verify Payload/Spotify.app/Frameworks/EeveeSpotify.dylib inside the IPA (enabled automatically for .ipa files containing EeveeSpotify.dylib)",
    )
    ap.add_argument(
        "--skip-dylib-check",
        dest="dylib_check",
        action="store_false",
        help="Skip Audit 3 (injected dylib verification) and audit only the Spotify binary",
    )
    args = ap.parse_args()

    data, dylib_blob, dylib_entry = load_binary_and_dylib(args.ipa_or_binary)
    all_strings, ttc_classes = extract_binary_symbols(data)
    (
        all_hooked,
        core_chokepoint_targets,
        cumulative_superset_targets,
        oracle_markers,
    ) = parse_tweak_hooks(args.sources)

    # Audit 1: Core Chokepoint Hooks (must exist in every IPA)
    broken_hooks = []
    for rel_path, target in core_chokepoint_targets:
        mangled = mangle_dotted_swift_class(target)
        present = (target in all_strings) or (mangled is not None and mangled in all_strings)
        if not present:
            broken_hooks.append((rel_path, target))

    active_superset_in_ipa = sum(
        1
        for _, target in cumulative_superset_targets
        if (target in all_strings)
        or (
            mangle_dotted_swift_class(target) is not None
            and mangle_dotted_swift_class(target) in all_strings
        )
    )

    # Audit 2: Unhooked Ad Services
    candidate_ad_services = sorted(
        c for c in ttc_classes
        if AD_SERVICE_REGEX.search(c) and is_service_class(c)
    )
    unhooked_ad_services = [
        c for c in candidate_ad_services
        if c not in all_hooked and c not in KNOWN_NON_LOAD_HOOKED_SERVICES
    ]
    hooked_ad_services = [c for c in candidate_ad_services if c in all_hooked]

    # Audit 3: Injected Dylib Verification (checks entire cumulative superset + ORACLE markers)
    run_dylib_audit = (
        args.dylib_check if args.dylib_check is not None else (dylib_blob is not None)
    )
    missing_dylib_hooks = []
    missing_oracle_markers = []
    dylib_missing_file = False
    if run_dylib_audit:
        if dylib_blob is None:
            dylib_missing_file = True
        else:
            missing_dylib_hooks, missing_oracle_markers = audit_injected_dylib(
                dylib_blob, cumulative_superset_targets, oracle_markers
            )

    elapsed = time.monotonic() - t0
    print(
        f"[ORACLE-AUDIT] Scanned {len(all_strings):,} strings and "
        f"{len(ttc_classes):,} _TtC classes in {elapsed:.2f}s"
    )
    print(
        f"[ORACLE-AUDIT] Audit 1 (Core Chokepoint Targets in Spotify): "
        f"{len(core_chokepoint_targets) - len(broken_hooks)}/{len(core_chokepoint_targets)} present "
        f"({active_superset_in_ipa}/{len(cumulative_superset_targets)} cumulative superset targets in this IPA)"
    )
    print(
        f"[ORACLE-AUDIT] Audit 2 (Ad/Upsell Services in Spotify): "
        f"{len(hooked_ad_services)} hooked, "
        f"{len(candidate_ad_services) - len(hooked_ad_services) - len(unhooked_ad_services)} "
        f"exempt, {len(unhooked_ad_services)} unhooked"
    )
    if run_dylib_audit and not dylib_missing_file:
        print(
            f"[ORACLE-AUDIT] Audit 3 (Injected {dylib_entry}): "
            f"{len(cumulative_superset_targets) - len(missing_dylib_hooks)}/{len(cumulative_superset_targets)} cumulative hooks, "
            f"{len(oracle_markers) - len(missing_oracle_markers)}/{len(oracle_markers)} [ORACLE] markers compiled"
        )

    failed = False
    if broken_hooks:
        failed = True
        print("\n[FAIL] Audit 1 — Broken critical hooks missing from Spotify binary:")
        for rel_path, target in broken_hooks:
            print(f"  - {target} ({rel_path})")

    if unhooked_ad_services:
        failed = True
        print("\n[FAIL] Audit 2 — Unhooked Ad/Upsell services discovered in Spotify binary:")
        for svc in unhooked_ad_services:
            print(f"  - {svc}")

    if run_dylib_audit:
        if dylib_missing_file:
            failed = True
            print(
                "\n[FAIL] Audit 3 — Payload/Spotify.app/Frameworks/EeveeSpotify.dylib not found in input"
            )
        elif missing_dylib_hooks or missing_oracle_markers:
            failed = True
            print(
                f"\n[FAIL] Audit 3 — Outdated {dylib_entry} is missing compiled hooks/markers from current source:"
            )
            if missing_dylib_hooks:
                print(f"  Missing critical hook targets ({len(missing_dylib_hooks)}):")
                for rel_path, target in missing_dylib_hooks:
                    print(f"    - {target} ({rel_path})")
            if missing_oracle_markers:
                print(f"  Missing [ORACLE] telemetry markers ({len(missing_oracle_markers)}):")
                for rel_path, marker in missing_oracle_markers:
                    print(f"    - {marker} ({rel_path})")

    if failed:
        sys.exit(1)

    print("[ORACLE-AUDIT] PASS: All audits succeeded.")
    sys.exit(0)


if __name__ == "__main__":
    main()
