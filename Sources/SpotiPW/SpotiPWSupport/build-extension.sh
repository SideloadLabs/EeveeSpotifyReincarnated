#!/usr/bin/env bash
# Builds the Live Activity widget extension without an Xcode project, and the App Intents metadata
# the host app needs for the widget's taps.
#
#   scripts/build-extension.sh <host Info.plist> <out dir>
#
# Writes <out dir>/SpotifyGlassLiveActivity.appex and <out dir>/app/Metadata.appintents, whose actions
# pipeline.sh merges into Spotify's own. Needs Xcode (xcode-select or DEVELOPER_DIR): the metadata
# processor ships only with it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_PLIST="${1:?usage: $0 <host Info.plist> <out dir>}"
OUT="${2:?usage: $0 <host Info.plist> <out dir>}"
NAME=SpotifyGlassLiveActivity
APPEX="$OUT/$NAME.appex"
SHARED="$ROOT/tweak/Sources/Shared/LiveActivity/LiveActivityShared.swift"
WIDGET="$ROOT/extension/LiveActivity/LiveActivityWidget.swift"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
TOOLCHAIN="$(dirname "$(dirname "$(dirname "$(xcrun --find swiftc)")")")"
XCODE_BUILD="$(xcodebuild -version | sed -n 's/^Build version //p')"
PROCESSOR="$(xcrun --find appintentsmetadataprocessor)"

WORK="$OUT/.build"
rm -rf "$APPEX" "$OUT/app" "$WORK"
mkdir -p "$APPEX" "$OUT/app" "$WORK"

# The protocols Xcode has swiftc record constant values for (SWIFT_EMIT_CONST_VALUE_PROTOCOLS in
# Xcode's App Intents build rules); the metadata processor reads the intents out of those values.
printf '%s\n' '["AppIntent","EntityQuery","AppEntity","TransientEntity","AppEnum","AppShortcutProviding","AppShortcutsProvider","AnyResolverProviding","AppIntentsPackage","DynamicOptionsProvider","_IntentValueRepresentable","_AssistantIntentsProvider","_GenerativeFunctionExtractable","IntentValueQuery","Resolver"]' > "$WORK/protocols.json"

# metadata <module> <deployment target> <bundle dir> <sources...>
metadata() {
  local module="$1" deploy="$2" bundle="$3"; shift 3
  local triple="arm64-apple-ios$deploy" dir="$WORK/$module"
  mkdir -p "$dir"
  printf '%s\n' "$@" > "$dir/sources.txt"
  echo "$dir/$module.swiftconstvalues" > "$dir/constvals.txt"
  xcrun --sdk iphoneos swiftc -typecheck -wmo -parse-as-library -target "$triple" -module-name "$module" \
    -emit-const-values-path "$dir/$module.swiftconstvalues" -Xfrontend -const-gather-protocols-file -Xfrontend "$WORK/protocols.json" "$@"
  "$PROCESSOR" --output "$bundle" --toolchain-dir "$TOOLCHAIN" --module-name "$module" --sdk-root "$SDK" \
    --xcode-version "$XCODE_BUILD" --platform-family iOS --deployment-target "$deploy" --target-triple "$triple" \
    --source-file-list "$dir/sources.txt" --swift-const-vals-list "$dir/constvals.txt" --force >/dev/null
}

echo "==> building $NAME.appex"
xcrun --sdk iphoneos swiftc -O -wmo -parse-as-library -target arm64-apple-ios17.0 -module-name "$NAME" \
  -Xlinker -e -Xlinker _NSExtensionMain -o "$APPEX/$NAME" "$SHARED" "$WIDGET"
metadata "$NAME" 17.0 "$APPEX" "$SHARED" "$WIDGET"

sed -e "s/HOST_BUNDLE_ID/$(plutil -extract CFBundleIdentifier raw -o - "$HOST_PLIST")/" \
    -e "s/HOST_SHORT_VERSION/$(plutil -extract CFBundleShortVersionString raw -o - "$HOST_PLIST")/" \
    -e "s/HOST_VERSION/$(plutil -extract CFBundleVersion raw -o - "$HOST_PLIST")/" \
    "$ROOT/extension/LiveActivity/Info.plist" > "$APPEX/Info.plist"
plutil -convert binary1 "$APPEX/Info.plist"

# The taps' intents run inside Spotify, so Spotify's metadata has to name them too, under the
# module the tweak compiles them in (Theos names it after the tweak instance).
metadata spotifyglass 16.0 "$OUT/app" "$SHARED"

codesign -f -s - "$APPEX" >/dev/null 2>&1
rm -rf "$WORK"
echo "    $APPEX"
