#!/usr/bin/env bash
set -euo pipefail

TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/eevee-home-layout.XXXXXX")"
trap 'rm -rf "$TEST_TEMP"' EXIT

SIMULATOR_ID="$(xcrun simctl list devices available --json | python3 -c '
import json, sys
for devices in json.load(sys.stdin)["devices"].values():
    for device in devices:
        if device["name"].startswith("iPhone"):
            print(device["udid"])
            raise SystemExit(0)
raise SystemExit("No iPhone simulator installed")
')"
xcrun simctl boot "$SIMULATOR_ID" || true
xcrun simctl bootstatus "$SIMULATOR_ID" -b

TEST_APP="$TEST_TEMP/HomeLayoutTests.app"
mkdir -p "$TEST_APP"
cat > "$TEST_APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.eevee.homelayouttests</string>
<key>CFBundleExecutable</key><string>HomeLayoutTests</string>
<key>CFBundleName</key><string>HomeLayoutTests</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>MinimumOSVersion</key><string>16.1</string>
<key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
<key>LSRequiresIPhoneOS</key><true/>
</dict></plist>
PLIST

xcrun swiftc -swift-version 5 -parse-as-library \
    -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
    -target "$(uname -m)-apple-ios16.1-simulator" \
    "$TEST_ROOT/Sources/EeveeSpotify/Pages/HomeFeedLayout.swift" \
    "$TEST_ROOT/Tests/HomeFeedLayout/SimulatorTests.swift" \
    -o "$TEST_APP/HomeLayoutTests"
codesign --force --sign - "$TEST_APP"
xcrun simctl install "$SIMULATOR_ID" "$TEST_APP"
xcrun simctl launch --console "$SIMULATOR_ID" com.eevee.homelayouttests | tee "$TEST_TEMP/result.log"
grep -q 'HOME_LAYOUT_TESTS_PASSED' "$TEST_TEMP/result.log"
if grep -q 'Unable to simultaneously satisfy constraints' "$TEST_TEMP/result.log"; then
    echo 'Hidden Home content produced conflicting Auto Layout constraints' >&2
    exit 1
fi
