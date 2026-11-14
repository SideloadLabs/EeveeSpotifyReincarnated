"""Run the current Pixie host fixtures without Spotify, credentials or UI launches.

Each target lists only its production dependencies: test doubles must never be
linked with a second implementation. Results and full child output are retained
under one fresh output directory. A green host suite does not prove device I/O.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import datetime
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT.parent


@dataclass(frozen=True)
class Fixture:
    name: str
    suite: str
    sources: tuple[str, ...]
    groups: tuple[str, ...] = ()
    diagnostics: bool = False
    frameworks: tuple[str, ...] = ("Foundation",)
    scenarios: tuple[tuple[str, ...], ...] = ((),)
    defines: tuple[str, ...] = ()


# basename resolution allows the production tree to be reorganized without
# copying it into the tests or relying on directory-wide source globs.
FIXTURES = (
    Fixture("native_cache_namespace", "export", ("native_cache_namespace.m",)),
    Fixture("page_contract", "library", ("PixiePageController.m", "page_contract.m"), scenarios=tuple((s,) for s in ("swift", "legacy", "both", "late", "unsupported", "lookalike"))),
    Fixture("progress_animation", "library", ("progress_animation.m",), frameworks=("Foundation", "QuartzCore")),
    Fixture("ogg_inspection", "export", ("OggInspection.c","OggExport.c","ogg_inspection.m"), scenarios=((str(ROOT / "tests/fixtures/export-tone-10s.ogg"),),)),
    Fixture("ogg_validation_trace", "diagnostics", ("OggValidationTrace.m","OggExport.c","ogg_validation_trace.m")),
    Fixture("native_download_quality", "devices", ("NativeDownloadQuality.m","native_download_quality.m")),
    Fixture("offline_library_append", "library", ("OfflineLibraryExport.m","OfflineLibraryProgress.m","offline_library_append.m")),
    Fixture("offline_library_pipeline", "library", ("OfflineLibraryExport.m","offline_library_pipeline.m")),
    Fixture("m4a_conversion_queue", "export", ("M4AConversionQueue.m","m4a_conversion_queue.m")),
    Fixture("offline_library_progress", "library", ("OfflineLibraryProgress.m","offline_library_progress.m")),
    Fixture("offline_library_chrome", "library", ("offline_library_chrome.m",), frameworks=("Foundation","CoreGraphics")),
    Fixture("offline_library_selection", "library", ("offline_library_selection.m",)),
    Fixture("offline_library_refresh", "library", ("OfflineLibraryProgress.m", "offline_library_refresh.m")),
    Fixture("journal_poll_scope", "diagnostics", ("journal_poll_scope.m",)),
    Fixture("offline_library_catalog", "library", ("OfflineLibraryCatalog.m", "WireProto.m", "offline_library_catalog.m")),
    Fixture("offline_catalog_transport", "transport", ("OfflineLibraryCatalog.m", "SpotifyTransportRegistry.m", "SpotifyServiceCalls.m", "SpotifyTransportHooks.m", "WireProto.m", "offline_catalog_transport.m"), scenarios=tuple((s,) for s in ("candidate_churn", "service_route", "stream_route", "method_route", "slow_route", "cancel_reopen", "cancel_late_route", "service_isolation", "invalid_proof", "weak_route", "bridge_last", "late_reply", "cancel_before_send", "exhaustion", "stream_once", "persisted_route", "persisted_invalid"))),
    Fixture("spotify_cache_clear", "library", ("SpotifyCacheClear.m", "WireProto.m", "spotify_cache_clear.m"), scenarios=tuple((s,) for s in ("normal", "stats_unreadable", "error", "not_invoked", "busy"))),
    Fixture("offline_library_delete", "library", ("OfflineLibraryDelete.m", "AlbumMetadata.m", "WireProto.m", "offline_library_delete.m")),
    Fixture("offline_library_export", "library", ("OfflineLibraryExport.m", "offline_library_export.m")),
    Fixture("artist_catalog_append", "catalog", ("artist_catalog_append.m",)),
    Fixture("export_refresh_policy", "export", ("export_refresh_policy.m",)),
    Fixture("share_completion_relay", "export", ("ShareCompletionRelay.m", "share_completion_relay.m")),
    Fixture("native_share_tap_policy", "export", ("native_share_tap_policy.m",)),
    Fixture("share_file_promise", "export", ("ShareFilePromise.m", "share_file_promise.m")),
    Fixture("native_share_route", "export", ("native_share_route.m",)),
    Fixture("temporary_offline_export", "export", ("TemporaryOfflineExport.m", "WireProto.m", "temp_offline_export.m")),
    Fixture("export_cache_index", "export", ("ExportCacheIndex.m", "export_cache_index.m")),
    Fixture("export_share_folder", "export", ("ExportShareFolder.m", "ExportArtworkMetadata.m", "WireProto.m", "export_share_folder.m")),
    Fixture("export_key_vault", "export", ("ExportKeyVault.m", "export_key_vault.m")),
    Fixture("export_library", "export", ("ExportLibrary.m", "export_library.m")),
    Fixture("export_commands", "export", ("SpotifyCommands.m", "WireProto.m", "export_commands.m")),
    Fixture("export_metadata", "export", ("ExportAlbumMetadata.m", "ExportArtworkMetadata.m", "WireProto.m", "export_album_metadata.m"), diagnostics=True),
    Fixture("export_storage", "export", ("CacheStorageKey.m", "cache_storage_key.m")),
    Fixture("export_workflow", "export", ("export_native_workflow.m", "WireProto.m", "NativeCacheMap.m", "CacheStorageKey.m", "CacheEnvelope.c", "OggExport.c", "OggArtwork.c", "ExportArtworkMetadata.m", "ExportLibrary.m", "MediaDecode.c")),
    Fixture("audio_probe", "audio", ("AudioProbe.c", "test_probe.c"), diagnostics=True, frameworks=("Foundation", "AudioToolbox")),
    Fixture("av_hooks", "audio", ("AudioProbe.c", "AVAudioHooks.m", "av_hooks.m"), diagnostics=True, frameworks=("Foundation", "AudioToolbox", "AVFoundation", "CoreMedia")),
    Fixture("offline_flags", "config", ("OfflineFlags.m", "offline_flags.m"), diagnostics=True),
    Fixture("offline_config", "config", ("OfflineConfig.m", "offline_config.m"), diagnostics=True),
    Fixture("download_evidence", "config", ("download_evidence.m",)),
    Fixture("journal_lazy_payload", "diagnostics", ("journal_lazy_payload.m",)),
    Fixture("native_setup_status", "config", ("native_setup_status.m",)),
    Fixture("key_mode_policy", "config", ("key_mode_policy.c",), frameworks=()),
    Fixture("process_scope", "config", ("process_scope.m",)),
    Fixture("localization", "config", ("Localization.m", "localization.m"), scenarios=(("English", "-AppleLanguages", "(en-GB)"), ("English", "-AppleLanguages", "(ru-RU)"))),
    Fixture("player_trace", "diagnostics", ("PlayerTrace.m", "WireProto.m", "player_trace.m"), diagnostics=True),
    Fixture("track_journal", "diagnostics", ("WireProto.m", "NativeErrorLog.m", "PlayerTrace.m", "track_journal.m"), groups=("journal",), diagnostics=True),
    Fixture("diagnostic_trace", "diagnostics", ("DiagnosticTrace.m", "NativeKeyTrace.m", "WireProto.m", "diagnostic_trace.m"), scenarios=tuple((s,) for s in ("normal", "rotation", "loss", "write_error", "reset", "off_reset", "noise"))),
    Fixture("support_log", "diagnostics", ("SupportLogSerializer.m", "support_log.m")),
    Fixture("track_download", "transport", ("PlayerTrace.m", "WireProto.m", "track_download.m"), groups=("manual_download",), diagnostics=True),
    Fixture("artist_session", "session", ("WireProto.m", "artist_session.m"), groups=("artist_session",)),
    Fixture("artist_metadata", "catalog", ("ArtistMetadata.m", "WireProto.m", "artist_metadata.m")),
    Fixture("album_metadata", "catalog", ("AlbumMetadata.m", "WireProto.m", "album_metadata.m")),
    Fixture("playlist_downloads", "playlists", ("WireProto.m", "playlist_downloads.m"), groups=("playlists",)),
    Fixture("playlist_streaming", "playlists", ("WireProto.m", "playlist_streaming.m"), groups=("playlists",)),
    Fixture("download_compatibility", "devices", ("OfflineCompatibilityChecks.m", "WireProto.m", "download_compatibility.m"), diagnostics=True),
    Fixture("offline_devices", "devices", ("OfflineDeviceManager.m", "WireProto.m", "offline_devices.m"), diagnostics=True),
    Fixture("offline_devices_eevee_auth", "devices", ("OfflineDeviceManager.m", "WireProto.m", "offline_devices.m"), diagnostics=True, defines=("SAP_REAL_EEVEE_AUTH",)),
)
GROUP_FALLBACKS = {
    "manual_download": ("ManualTrackDownload.m",),
    "artist_session": ("ArtistDownloadSession.m",),
    "playlists": ("PlaylistTaskRegistry.m",),
    "journal": ("TrackJournal.m", "JournalFormatting.m"),
}


def source(name: str) -> Path:
    # Fixture files have unique names apart from the capitalized production file.
    matches = [p for base in (ROOT / "src", ROOT / "tests") for p in base.rglob("*") if p.is_file() and p.name == name]
    if len(matches) != 1:
        raise RuntimeError(f"Expected exactly one source {name}, found: {matches}")
    return matches[0]


def group(name: str) -> list[Path]:
    try:
        from pixie_target import source_group
    except ModuleNotFoundError:
        return [source(n) for n in GROUP_FALLBACKS[name]]
    return list(source_group(name))


def include_dirs() -> list[Path]:
    return sorted({ROOT / "src", *(p.parent for p in (ROOT / "src").rglob("*.h"))})


def fixture_sources(test: Fixture) -> list[Path]:
    paths = [source(n) for n in test.sources]
    for name in test.groups:
        paths.extend(group(name))
    if test.name=="export_workflow":paths.extend(source(n) for n in ("M4AExport.m","M4AConversionQueue.m","TemporaryOfflineExport.m","ExportShareFolder.m","OggInspection.c","OggValidationTrace.m"))
    if test.diagnostics:
        paths.extend(source(n) for n in ("DiagnosticsPreferences.m", "Localization.m", "DiagnosticTrace.m", "NativeKeyTrace.m", "WireProto.m", "trace_platform_stub.m"))
    if any(p.name in ("NativeCacheMap.m", "CacheStorageKey.m") for p in paths):paths.append(source("ExportKeyVault.m"))
    if any(p.name=="NativeCacheMap.m" for p in paths):paths.append(source("ExportCacheIndex.m"))
    return list(dict.fromkeys(paths))


def execute(command, log, env, timeout=180):
    command = list(map(str, command))
    log.write("$ " + json.dumps(command) + "\n")
    log.flush()
    result = subprocess.run(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f"Command exited {result.returncode}: {command[0]}")


def run_fixture(test: Fixture, build: Path, sanitize: bool):
    folder = build / test.name
    folder.mkdir(parents=True)
    home = folder / "temporary"
    home.mkdir()
    env = dict(os.environ, TMPDIR=str(home) + "/", PIXIE_TEST_BUILD_DIR=str(folder))
    # Diagnostic fixtures must not reuse a user's preference setting.
    binary = folder / test.name
    paths = fixture_sources(test)
    command = ["xcrun", "clang", "-arch", "arm64", "-fobjc-arc", "-std=gnu11", "-O1", "-g", "-DSAP_TESTING", "-DSAP_VAULT_TESTING=1"]
    if test.name == "page_contract":
        # Run the actual page implementation without loading UIKit on macOS.
        # The real controller declarations determine their superclass here;
        # changing either page back to UITableViewController breaks this test.
        import re
        (folder / "UIKit").mkdir()
        (folder / "UIKit/UIKit.h").write_text('#import <Foundation/Foundation.h>\ntypedef NSInteger UITableViewStyle;\nenum { UITableViewStyleInsetGrouped=2 };\n@interface UITableViewController : NSObject\n- (instancetype)initWithStyle:(UITableViewStyle)style;\n@end\n')
        declarations = []
        for filename, name in (("PixieManagerSettings.m", "SAPSettingsTable"), ("OfflineLibraryUI.m", "SAPOfflineLibraryController")):
            match = re.search(r"@interface " + name + r"\s*:\s*(\w+)", source(filename).read_text())
            if not match:
                raise RuntimeError(f"Missing production declaration for {name}")
            implementation = source(filename).read_text().split("@implementation " + name, 1)[1].split("@end", 1)[0]
            initializer = re.search(r"- \(instancetype\)init \{[^}]+\}", implementation)
            if not initializer:
                raise RuntimeError(f"Missing production initializer for {name}")
            declarations.append(f"@interface {name} : {match.group(1)} @end\n@implementation {name}\n{initializer.group(0)}\n@end\n")
        (folder / "PageContractControllers.inc").write_text("".join(declarations))
        command.append("-I" + str(folder))
    if test.name == "native_download_quality":command.append("-Wl,-export_dynamic")
    if test.name == "offline_library_refresh":
        # Execute the actual UIKit controller's state/lifecycle methods on the
        # host. Only presentation and transport boundaries are stand-ins.
        ui = (ROOT / "src/Library/OfflineLibraryUI.m").read_text()
        def method(signature):
            start = ui.index(signature)
            end = ui.index("\n}", start) + 2
            return ui[start:end] + "\n"
        helpers = ui[ui.index("static NSString * const SAPOfflineUnknownArtist"):ui.index("@class SAPOfflineLibraryController")]
        (folder / "OfflineLibraryRefreshHelpers.inc").write_text(helpers)
        (folder / "OfflineLibraryRefreshState.inc").write_text("\n".join(method(x) for x in (
            "- (instancetype)init {\n", "- (void)load {", "- (void)refresh {",
            "- (void)beginExport:(NSArray<NSDictionary *> *)rows zip:(BOOL)zip save:(BOOL)save {", "- (void)releasePendingPackage {", "- (void)appendExportRows:(NSArray<NSDictionary *> *)rows {")))
        (folder / "OfflineLibraryRefreshController.inc").write_text("\n".join(method(x) for x in (
            "+ (NSArray<NSDictionary *> *)artistRowsForTracks:(NSArray<NSDictionary *> *)tracks {", "- (NSArray<NSDictionary *> *)buildReleaseSections {",
            "- (void)viewDidAppear:", "- (void)updateLoading {", "- (void)refreshCatalog {", "- (void)progressActionTapped {", "- (NSArray<NSDictionary *> *)selectedRows {", "- (NSArray<NSDictionary *> *)newExportRows {")))
        command.append("-I" + str(folder))
    command.extend("-I" + str(p) for p in include_dirs())
    command.extend("-D" + s for s in test.defines)
    if sanitize:
        command.append("-fsanitize=address,undefined")
    if any(p.name=="M4AExport.m" for p in paths):
        command.extend(["-framework","AVFoundation","-framework","AudioToolbox","-framework","CoreMedia"])
    if any(p.name in ("ExportLibrary.m","ExportCacheIndex.m") for p in paths):command.append("-lsqlite3")
    command.extend(paths)
    for framework in test.frameworks:
        command.extend(("-framework", framework))
    command.extend(("-o", binary))
    with (folder / "output.log").open("w") as log:
        if "SAP_REAL_EEVEE_AUTH" in test.defines:
            bridge = folder / "libEeveeAuthenticationFixture.dylib"
            execute(("xcrun", "swiftc", "-parse-as-library", "-emit-library", "-module-name", "PixieAuthenticationFixture", PROJECT / "Sources/EeveeSpotify/PixieAuthentication.swift", source("eevee_auth_headers.swift"), "-o", bridge), log, env)
            command.append(bridge)
        execute(command, log, env)
        for args in test.scenarios:
            execute((binary, *args), log, env)


def run_script(name: str, build: Path):
    folder = build / name
    folder.mkdir(parents=True)
    paths = {"export_artwork_cache": ROOT / "tools/test_export_artwork_cache.py", "track_export": ROOT / "tools/test_audio_export.py", "m4a_codec": ROOT / "tools/test_m4a_export.py", "offline_library_package": ROOT / "tests/test_offline_library_package.py", "export_patch": ROOT / "tests/export_patch.py", "native_restrictions": ROOT / "tools/test_native_restrictions.py", "native_trace_abi": ROOT / "tests/native_trace_patch.py", "signing_metadata": ROOT / "tests/signing_metadata.py"}
    env = dict(os.environ, PIXIE_TEST_BUILD_DIR=str(folder), PYTHONDONTWRITEBYTECODE="1")
    with (folder / "output.log").open("w") as log:
        execute((sys.executable, paths[name]), log, env)


def main():
    suites = sorted({f.suite for f in FIXTURES} | {"packaging"})
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--suite", action="append", choices=suites, help="Repeat to choose suites; default runs every host suite")
    parser.add_argument("--fixture", action="append", help="Run only these fixture names")
    parser.add_argument("--build-dir", type=Path, default=PROJECT / "outputs" / datetime.now().strftime("host-tests-%Y%m%d-%H%M%S-%f"))
    parser.add_argument("--no-sanitize", action="store_true", help="Disable AddressSanitizer/UBSan for a diagnostic run")
    parser.add_argument("--list", action="store_true")
    args = parser.parse_args()
    scripted = {"export_artwork_cache": "export", "track_export": "export", "m4a_codec": "export", "offline_library_package": "library", "export_patch": "packaging", "native_restrictions": "packaging", "native_trace_abi": "packaging", "signing_metadata": "packaging"}
    jobs = [(f.name, f.suite, f) for f in FIXTURES] + [(n, s, None) for n, s in scripted.items()]
    all_names = {n for n, _, _ in jobs}
    if args.fixture and set(args.fixture) - all_names:
        parser.error("Unknown fixtures: " + ", ".join(sorted(set(args.fixture) - all_names)))
    jobs = [j for j in jobs if (not args.suite or j[1] in args.suite) and (not args.fixture or j[0] in args.fixture)]
    if args.list:
        for name, suite, _ in jobs:
            print(f"{suite}: {name}")
        return 0
    build = args.build_dir.resolve()
    if build.exists() and any(build.iterdir()):
        parser.error("Choose a new empty build directory; previous results are retained")
    build.mkdir(parents=True, exist_ok=True)
    unsupported = platform.system() != "Darwin" or platform.machine() != "arm64"
    results = []
    for name, suite, test in jobs:
        started = time.monotonic()
        result = {"name": name, "suite": suite}
        if unsupported:
            result.update(status="SKIP", reason="Native host fixtures require Apple Silicon macOS and Xcode")
        else:
            try:
                if test:
                    run_fixture(test, build, not args.no_sanitize)
                else:
                    run_script(name, build)
                log_path = build / name / "output.log"
                skipped_checks = [line.strip() for line in log_path.read_text().splitlines() if line.startswith("SKIP") or line.startswith("SKIP:")]
                result.update(status="PASS", log=str(log_path), skipped_checks=skipped_checks)
            except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
                result.update(status="FAIL", reason=str(error), log=str(build / name / "output.log"))
        result["seconds"] = round(time.monotonic() - started, 3)
        results.append(result)
        print(f"{result['status']}: {suite}/{name}" + (f" — {result['reason']}" if "reason" in result else ""), flush=True)
    counts = {status: sum(r["status"] == status for r in results) for status in ("PASS", "SKIP", "FAIL")}
    from pixie_target import PROFILE
    report = {"host": platform.platform(), "production_target": f"Eevee {PROFILE['eevee_version']} / Spotify {PROFILE['spotify_version']} / Pixie {PROFILE['pixie_version']}", "sanitizers": not args.no_sanitize, "device_runtime_tested": False, "counts": counts, "results": results}
    (build / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"Results: {counts}; {build / 'results.json'}", flush=True)
    return 1 if counts["FAIL"] or not counts["PASS"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
