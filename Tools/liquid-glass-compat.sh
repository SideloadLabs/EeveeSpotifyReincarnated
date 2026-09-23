#!/usr/bin/env bash

set -euo pipefail

PB=/usr/libexec/PlistBuddy

patch_app() {
    local app="$1" plist="$1/Info.plist"
    [ -f "$plist" ] || { echo "[liquid-glass-compat] no Info.plist in $app" >&2; return 1; }

    local before
    before="$("$PB" -c "Print :UIDesignRequiresCompatibility" "$plist" 2>/dev/null || echo "<absent>")"

    "$PB" -c "Delete :UIDesignRequiresCompatibility" "$plist" 2>/dev/null || true
    "$PB" -c "Add :UIDesignRequiresCompatibility bool false" "$plist"

    echo "[liquid-glass-compat] UIDesignRequiresCompatibility: ${before} -> false ($(basename "$app"))"
}

patch_ipa() {
    local ipa abs tmp app
    ipa="$1"
    abs="$(cd "$(dirname "$ipa")" && pwd)/$(basename "$ipa")"
    tmp="$(mktemp -d -t liquid-glass-compat.XXXXXX)"
    trap 'rm -rf "$tmp"' RETURN
    ( cd "$tmp" && unzip -q "$abs" )
    app=$(find "$tmp/Payload" -maxdepth 2 -name '*.app' -type d | head -1)
    [ -n "$app" ] || { echo "[liquid-glass-compat] no .app in $ipa" >&2; return 1; }
    patch_app "$app"
    rm -f "$abs"
    ( cd "$tmp" && zip -qry "$abs" Payload )
}

target="${1:-}"
[ -n "$target" ] || { echo "usage: $0 <Spotify.app | path.ipa>" >&2; exit 1; }

if   [ -d "$target" ];                                                    then patch_app "$target"
elif [ -f "$target" ] && [[ "$target" == *.ipa || "$target" == *.zip ]]; then patch_ipa "$target"
else echo "[liquid-glass-compat] bad target: $target" >&2; exit 1
fi
