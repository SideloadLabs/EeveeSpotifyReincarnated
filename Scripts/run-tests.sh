#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/eevee-oracle-tests.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "==> [1/3] Running ResolveConfigurationSnapshot test..."
python3 Tests/ResolveConfigurationSnapshot/test.py
python3 Tests/NativeLyricsOfflineCache/test.py

echo "==> [2/3] Compiling and running Swift test suites..."
for main_swift in Tests/*/main.swift; do
    suite_dir="$(dirname "$main_swift")"
    suite_name="$(basename "$suite_dir")"
    bin_path="$TMP_DIR/$suite_name"

    extra_sources=()
    case "$suite_name" in
        LyricsRomanization)
            extra_sources+=("Sources/EeveeSpotify/Lyrics/Models/LyricsRomanization.swift")
            ;;
        NativeOfflineLyricsFormat)
            extra_sources+=("Sources/EeveeSpotify/Lyrics/Models/NativeOfflineLyricsFormat.swift")
            ;;
        NativeOfflineLyricsDatabase)
            extra_sources+=("Sources/EeveeSpotify/Lyrics/Models/NativeOfflineLyricsDatabase.swift")
            ;;
        LyricsProviders)
            lyrics=Sources/EeveeSpotify/Lyrics
            ext=Sources/EeveeSpotify/Shared/Models/Extensions
            extra_sources+=("$lyrics"/Repositories/*.swift "$lyrics"/Models/{Genius,Lrclib,Petit}/*.swift
                "$lyrics"/Models/{LyricsError,LyricsSearchQuery,LyricsLineDto,LyricsRomanizationStatus,KaraokeLyricsDto}.swift
                "$lyrics"/Models/Settings/LyricsOptions.swift "$lyrics"/Protocols/LyricsRepository.swift
                "$lyrics"/{LyricsDownloadHTTP,LyricsRequestGate,LyricsUncensorFill}.swift
                "$ext"/{CharacterSet,Collection,Dictionary}+Extension.swift)
            while IFS= read -r file; do extra_sources+=("$file"); done < <(find Sources/EeveeSpotify/Dependencies/XMLCoder -name '*.swift')
            ;;
        LyricsRequestGate)
            extra_sources+=("Sources/EeveeSpotify/Lyrics/LyricsRequestGate.swift")
            ;;
        LyricsDownloadHTTP)
            extra_sources+=("Sources/EeveeSpotify/Lyrics/LyricsRequestGate.swift"
                "Sources/EeveeSpotify/Lyrics/LyricsDownloadHTTP.swift"
                # The download context carries the custom view's lyrics.
                "Sources/EeveeSpotify/Lyrics/Models/KaraokeLyricsDto.swift")
            ;;
        LyricsTaskState)
            extra_sources+=("Sources/EeveeSpotify/Lyrics/LyricsTaskState.swift")
            ;;
        LyricsNotFoundStore)
            extra_sources+=("Sources/EeveeSpotify/Lyrics/LyricsNotFoundStore.swift")
            ;;
        OfflineLyricsStore)
            extra_sources+=("Sources/EeveeSpotify/Lyrics/Models/OfflineLyricsStore.swift"
                "Sources/EeveeSpotify/Lyrics/Models/Settings/LyricsOptions.swift"
                "Sources/EeveeSpotify/Lyrics/Models/KaraokeLyricsDto.swift")
            ;;
        OfflineLyricsDownloader)
            extra_sources+=("Sources/EeveeSpotify/Lyrics/OfflineLyricsDownloader.swift"
                "Sources/EeveeSpotify/Lyrics/LyricsForegroundExecution.swift"
                "Sources/EeveeSpotify/Lyrics/LyricsRequestGate.swift"
                "Sources/EeveeSpotify/Lyrics/LyricsNotFoundStore.swift")
            ;;
        NativeLyricsMetadata)
            extra_sources+=("Sources/EeveeSpotify/Lyrics/NativeLyricsMetadata.swift")
            ;;
        NativeLyricsCard)
            extra_sources+=("Sources/EeveeSpotify/Lyrics/NativeLyricsCard.swift")
            ;;
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
        VersionHookTarget)
            extra_sources+=("Sources/EeveeSpotify/Shared/Models/VersionHookTarget.swift")
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
