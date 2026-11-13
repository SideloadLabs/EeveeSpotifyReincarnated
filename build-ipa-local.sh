#!/usr/bin/env bash
# Local IPA build — mirror of .github/workflows/main.yml. Produces an IPA
# you can sign with Sideloadly/AltStore/TrollStore.
#
# Pipeline:
#   1. Build EeveeSwiftProtobuf.framework from apple/swift-protobuf source
#      (renamed module — see Tools/SwiftProtobufBuild/).
#   2. theos `make package FINALPACKAGE=1` — produces .deb with
#      EeveeSpotify.dylib + EeveeSpotify.bundle + framework.
#   3. Build zxPluginsInject.dylib — sideload compat shim (keychain redirect,
#      group containers, CloudKit stub). LC-injected via ipapatch in step 6.
#   4. cyan inject deb-contents (dylib + framework + bundle) into vanilla IPA.
#   5. ipapatch LC-inject zxPluginsInject into main exec + every appex.
#   6. Strip Watch.app if it survived cyan -du.
#
# Requires: theos, cyan (pyzule-rw), ipapatch, dpkg, ldid, plutil.

set -euo pipefail

VANILLA_IPA="${1:-}"
[ -n "$VANILLA_IPA" ] && [ -f "$VANILLA_IPA" ] || {
    echo "usage: $0 <path/to/Spotify-vanilla.ipa>" >&2
    exit 1
}

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

[ -n "${THEOS:-}" ] || { [ -d "$HOME/theos" ] && export THEOS="$HOME/theos" || { echo "THEOS not set"; exit 1; }; }

VERSION=$(grep -E '^Version:' control | awk '{print $2}')
SPOT_VERSION=$(unzip -p "$VANILLA_IPA" 'Payload/Spotify.app/Info.plist' \
    | plutil -extract CFBundleShortVersionString raw - 2>/dev/null || echo "unknown")
OUT_DIR="Outputs/IPAS"
OUT_IPA="$OUT_DIR/EeveeSpotify-${VERSION}-${SPOT_VERSION}.ipa"
mkdir -p "$OUT_DIR"

color() { printf '\033[1;32m==> %s\033[0m\n' "$*"; }

color "0/8  Oracle Pre-flight Audit"
./Scripts/run-tests.sh
python3 Scripts/oracle-audit-ipa.py "$VANILLA_IPA" --skip-dylib-check

color "1/8  EeveeSwiftProtobuf.framework"
chmod +x Tools/SwiftProtobufBuild/build-eeveeswiftprotobuf.sh
Tools/SwiftProtobufBuild/build-eeveeswiftprotobuf.sh

color "2/8  theos make package"
THEOS_PACKAGE_SCHEME=rootless make package FINALPACKAGE=1
DEB_FILE=$(ls -t packages/com.eevee.spotify_*.deb 2>/dev/null | head -1)
[ -n "$DEB_FILE" ] || { echo "deb not produced"; exit 1; }

color "3/8  zxPluginsInject.dylib"
chmod +x Tools/build-zxpi.sh
Tools/build-zxpi.sh >/dev/null

color "4/8  extract deb"
DEB_EXTRACT="$REPO_DIR/Outputs/deb-extract"
rm -rf "$DEB_EXTRACT"; mkdir -p "$DEB_EXTRACT"
dpkg-deb -R "$DEB_FILE" "$DEB_EXTRACT"
DYLIB_SRC=$(find "$DEB_EXTRACT" -name 'EeveeSpotify.dylib' | head -1)
BUNDLE_SRC=$(find "$DEB_EXTRACT" -type d -name 'EeveeSpotify.bundle' | head -1)
FRAMEWORK_SRC=$(find "$DEB_EXTRACT" -type d -name 'EeveeSwiftProtobuf.framework' | head -1)
[ -n "$DYLIB_SRC" ] || { echo "dylib not in deb"; exit 1; }

color "5/8  cyan inject"
INJECT=("$DYLIB_SRC")
[ -n "$FRAMEWORK_SRC" ] && INJECT+=("$FRAMEWORK_SRC")
[ -n "$BUNDLE_SRC" ]    && INJECT+=("$BUNDLE_SRC")
rm -f "$OUT_IPA"
cyan -i "$VANILLA_IPA" -o "$OUT_IPA" -f "${INJECT[@]}" -c 9 -m 15.0 -du

color "6/8  ipapatch LC-inject zxPluginsInject"
ipapatch --input "$OUT_IPA" --inplace --noconfirm --dylib packages/zxPluginsInject.dylib

# Belt-and-suspenders: cyan -du strips appex/Watch but verify.
zip -d "$OUT_IPA" "Payload/Spotify.app/Watch*" "Watch*" 2>/dev/null || true

color "7/8  stage alternate app icons"
# Copies Assets/AppIcon/*.png into Spotify.app and registers each stem under
# CFBundleIcons/CFBundleAlternateIcons in its Info.plist, which is what
# EeveeAppIconPickerView enumerates at runtime. This is the same step the
# GitHub IPA workflows run (buildpatched/buildnopatch/build-and-release-yourself),
# so a locally built IPA ends up with the identical icon set.
chmod +x Tools/alt-icons.sh
Tools/alt-icons.sh "$OUT_IPA"

color "8/8  Oracle Post-build Artifact Audit (Verifying injected dylib)"
python3 Scripts/oracle-audit-ipa.py "$OUT_IPA"

color "Done"
ls -lh "$OUT_IPA"
echo "Sign with Sideloadly / AltStore / TrollStore."
