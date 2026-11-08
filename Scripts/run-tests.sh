#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/eevee-oracle-tests.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "==> [1/3] Running ResolveConfigurationSnapshot test..."
python3 Tests/ResolveConfigurationSnapshot/test.py

echo "==> [2/3] Compiling and running Swift test suites..."
for main_swift in Tests/*/main.swift; do
    suite_dir="$(dirname "$main_swift")"
    suite_name="$(basename "$suite_dir")"
    bin_path="$TMP_DIR/$suite_name"

    extra_sources=()
    case "$suite_name" in
        BrowsitaSectionStripper)
            extra_sources+=("Sources/EeveeSpotify/Premium/Helpers/BrowsitaSectionStripper.swift")
            ;;
        URLAdClassification)
            extra_sources+=("Sources/EeveeSpotify/Shared/Models/Extensions/URL+Extension.swift")
            ;;
        ServerSidedFeaturePolicy)
            extra_sources+=("Sources/EeveeSpotify/Premium/Helpers/ServerSidedFeaturePolicy.swift")
            ;;
        BundledConfigurationPolicy)
            extra_sources+=("Sources/EeveeSpotify/Premium/Helpers/BundledConfigurationPolicy.swift")
            ;;
    esac

    if [ "${#extra_sources[@]}" -gt 0 ]; then
        swiftc "${extra_sources[@]}" "$main_swift" -o "$bin_path"
    else
        swiftc "$main_swift" -o "$bin_path"
    fi
    "$bin_path"
done

if [ -f "patched.ipa" ]; then
    echo "==> [3/3] Running offline Oracle IPA audit against patched.ipa..."
    python3 Scripts/oracle-audit-ipa.py "$@" patched.ipa
else
    echo "==> [3/3] Skipping offline Oracle IPA audit (patched.ipa not found)"
fi

echo "==> All Oracle tests and audits passed!"
