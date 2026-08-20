#!/usr/bin/env bash
# Build EeveeSwiftProtobuf.framework — apple/swift-protobuf compiled with
# module-name `EeveeSwiftProtobuf` so its @objc class names don't collide
# with the SwiftProtobuf statically embedded in SpotifyShared.framework.
#
# Outputs a fat (arm64+arm64e) framework at:
#   $THEOS/lib/iphone/$THEOS_PACKAGE_SCHEME/EeveeSwiftProtobuf.framework
#
# Why we do this instead of using the prebuilt SwiftProtobuf deb:
# duplicate-class warnings + SIGSEGV crashes when both copies (ours +
# SpotifyShared's statically-linked one) register classes under identical
# names. Renamed module → distinct Swift mangling → no collision.

set -euo pipefail

VERSION="${SWIFTPROTOBUF_VERSION:-1.29.0}"
SRC="${SRC_DIR:-/tmp/swiftprotobuf-build}"
MODULE="EeveeSwiftProtobuf"
PACKAGE_SCHEME="${THEOS_PACKAGE_SCHEME:-rootless}"
OUT="$THEOS/lib/iphone/${PACKAGE_SCHEME}/${MODULE}.framework"
DEPLOY_TARGET="${DEPLOY_TARGET:-14.0}"

if [ "$PACKAGE_SCHEME" = "roothide" ]; then
    INSTALL_NAME="@loader_path/.jbroot/Library/Frameworks/${MODULE}.framework/${MODULE}"
else
    INSTALL_NAME="@rpath/${MODULE}.framework/${MODULE}"
fi

[ -n "${THEOS:-}" ] || { echo "THEOS env not set"; exit 1; }

color() { printf '\033[1;32m==> %s\033[0m\n' "$*"; }

if [ ! -d "$SRC/.git" ]; then
    color "Cloning apple/swift-protobuf $VERSION"
    rm -rf "$SRC"
    git clone --depth 1 -b "$VERSION" https://github.com/apple/swift-protobuf "$SRC"
fi

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
SOURCES="$(find "$SRC/Sources/SwiftProtobuf" -name '*.swift' -not -path '*/CMakeFiles/*')"

build_arch() {
    local ARCH="$1"
    local TRIPLE="${ARCH}-apple-ios${DEPLOY_TARGET}"
    local OBJDIR="$SRC/build-$ARCH"
    color "Compiling ${MODULE} for $ARCH"
    rm -rf "$OBJDIR"; mkdir -p "$OBJDIR"
    swiftc -O \
        -target "$TRIPLE" -sdk "$SDK" \
        -emit-library -emit-module \
        -module-name "$MODULE" \
        -enable-library-evolution -emit-module-interface \
        -Xfrontend -enable-testing -parse-as-library \
        -Xlinker -install_name -Xlinker "$INSTALL_NAME" \
        -Xlinker -application_extension \
        -o "$OBJDIR/${MODULE}" \
        -emit-module-path "$OBJDIR/${MODULE}.swiftmodule" \
        $SOURCES
}

build_arch arm64
build_arch arm64e

color "Assembling fat framework at $OUT"
rm -rf "$OUT"
mkdir -p "$OUT/Modules/${MODULE}.swiftmodule"

lipo -create "$SRC/build-arm64/${MODULE}" "$SRC/build-arm64e/${MODULE}" -output "$OUT/${MODULE}"

# RootHide enforces signatures on injected dependencies too. Keep the classic
# rootless framework build unchanged; only its RootHide counterpart needs this.
if [ "$PACKAGE_SCHEME" = "roothide" ]; then
    command -v ldid >/dev/null 2>&1 || { echo "ldid not found"; exit 1; }
    ldid -S "$OUT/${MODULE}"
fi

for ARCH in arm64 arm64e; do
    OBJDIR="$SRC/build-$ARCH"
    cp "$OBJDIR/${MODULE}.swiftmodule"     "$OUT/Modules/${MODULE}.swiftmodule/${ARCH}-apple-ios.swiftmodule"
    cp "$OBJDIR/${MODULE}.swiftinterface"  "$OUT/Modules/${MODULE}.swiftmodule/${ARCH}-apple-ios.swiftinterface" 2>/dev/null || true
    cp "$OBJDIR/${MODULE}.swiftdoc"        "$OUT/Modules/${MODULE}.swiftmodule/${ARCH}-apple-ios.swiftdoc" 2>/dev/null || true
    cp "$OBJDIR/${MODULE}.abi.json"        "$OUT/Modules/${MODULE}.swiftmodule/${ARCH}-apple-ios.abi.json" 2>/dev/null || true
done

cat > "$OUT/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>${MODULE}</string>
    <key>CFBundleIdentifier</key><string>com.eevee.eeveeswiftprotobuf</string>
    <key>CFBundleName</key><string>${MODULE}</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>MinimumOSVersion</key><string>${DEPLOY_TARGET}</string>
</dict>
</plist>
EOF

color "Done"
file "$OUT/${MODULE}"
