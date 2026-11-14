"""Compile opt-in settings/artist UIKit fixtures against the current Pixie modules.

The default and --compile-only paths never query simctl, install, or launch.
Use --run explicitly only when runtime UI testing has been authorized.
"""
from pathlib import Path
from datetime import datetime
import argparse
import json
import plistlib
import shutil
import subprocess
import time
from pixie_target import ROOT, include_directories, resolve_source, source_group


def run(*args, check=True):
    result = subprocess.run(list(map(str, args)), cwd=ROOT, check=False, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
    if check and result.returncode:
        raise RuntimeError(result.stdout)
    return result.stdout.strip()


def compile_fixture(name, out, sdk, target):
    folder = out / name
    folder.mkdir(parents=True)
    bundle = f"local.spotify.pixie.{name}.fixture"
    app = folder / "PixieUIFixture.app"
    app.mkdir()
    includes = ["-I" + str(p) for p in include_directories()]
    common = ["xcrun", "clang", "-target", target, "-isysroot", sdk, "-fobjc-arc", "-std=gnu11", "-DSAP_TESTING", *includes]
    if name == "settings":
        sources = [resolve_source(s) for s in ("PixieManagerSettings.m", "PixiePageController.m", "DiagnosticsPreferences.m", "Localization.m", "DiagnosticTrace.m", "NativeKeyTrace.m", "WireProto.m")]
        sources.extend((ROOT / "tests/trace_platform_stub.m", ROOT / "tests/SettingsFixtureActions.m"))
        objects = []
        for source in sources:
            obj = folder / (source.stem + ".o")
            run(*common, "-DSAP_UI_FIXTURE", "-c", source, "-o", obj)
            objects.append(obj)
        run("xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", "-target", target,
            "-sdk", sdk, *includes, "-import-objc-header", ROOT / "tests/SettingsFixtureBridge.h",
            ROOT / "tests/SettingsFixture.swift", *objects, "-framework", "UIKit", "-framework", "SwiftUI", "-o", app / "PixieUIFixture")
        scene = "SAPFixtureSceneDelegate"
    else:
        sources = [*source_group("artist_ui"), resolve_source("WireProto.m"), ROOT / "tests/ArtistDownloadsUIFixture.m"]
        run(*common, *sources, "-framework", "UIKit", "-framework", "QuartzCore", "-framework", "ImageIO", "-framework", "CoreText", "-framework", "CoreGraphics", "-o", app / "PixieUIFixture")
        scene = "ArtistPickerFixtureScene"
    info = {"CFBundleIdentifier": bundle, "CFBundleExecutable": "PixieUIFixture", "CFBundleName": "Pixie UI Fixture",
            "CFBundleVersion": "1", "CFBundleShortVersionString": "1", "CFBundlePackageType": "APPL",
            "CFBundleLocalizations": ["en"], "CFBundleDevelopmentRegion": "en", "LSRequiresIPhoneOS": True,
            "UIDeviceFamily": [1], "UILaunchScreen": {}, "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"],
            "UIApplicationSceneManifest": {"UIApplicationSupportsMultipleScenes": False, "UISceneConfigurations": {"UIWindowSceneSessionRoleApplication": [{"UISceneConfigurationName": "Default", "UISceneDelegateClassName": scene}]}}}
    (app / "Info.plist").write_bytes(plistlib.dumps(info))
    run("codesign", "--force", "--sign", "-", "--timestamp=none", app)
    return app, bundle


def launch_fixture(name, app, bundle, out):
    # Runtime access is confined to this function; compile-only never reaches it.
    devices = json.loads(run("xcrun", "simctl", "list", "devices", "--json"))["devices"]
    available = [d for ds in devices.values() for d in ds if d["state"] == "Booted" and d.get("isAvailable") and "iPhone" in d["name"]]
    if not available:
        raise RuntimeError("Explicit runtime test needs an already booted iPhone simulator")
    udid = available[0]["udid"]
    run("xcrun", "simctl", "install", udid, app)
    run("xcrun", "simctl", "terminate", udid, bundle, check=False)
    container = Path(run("xcrun", "simctl", "get_app_container", udid, bundle, "data"))
    result = container / "Documents/result.log"
    result.unlink(missing_ok=True)
    run("xcrun", "simctl", "launch", udid, bundle, "-AppleLanguages", "(en)")
    deadline = time.monotonic() + 45
    expected = "PASS: entry spacing, mini-player clearance, navigation and native pages rendered" if name == "settings" else "PASS: centered multiline artist load text"
    while time.monotonic() < deadline:
        text = result.read_text() if result.exists() else ""
        if expected in text:
            shutil.copy2(result, out / name / "result.log")
            return
        time.sleep(.3)
    raise RuntimeError(f"UI fixture {name} did not finish: {text}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", choices=("settings", "artist", "all"), default="all")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--compile-only", action="store_true", help="Compile/link only (the safe default); no simctl access")
    mode.add_argument("--run", action="store_true", help="Explicitly install and run on an already booted simulator")
    parser.add_argument("--output-dir", type=Path, default=ROOT.parent / "outputs" / datetime.now().strftime("ui-compile-%Y%m%d-%H%M%S-%f"))
    args = parser.parse_args()
    out = args.output_dir.resolve()
    if out.exists() and any(out.iterdir()):
        parser.error("Choose a fresh empty output directory")
    out.mkdir(parents=True, exist_ok=True)
    sdk = run("xcrun", "--sdk", "iphonesimulator", "--show-sdk-path")
    version = run("xcrun", "--sdk", "iphonesimulator", "--show-sdk-version")
    target = f"arm64-apple-ios{version}-simulator"
    results = []
    for name in ("settings", "artist") if args.fixture == "all" else (args.fixture,):
        app, bundle = compile_fixture(name, out, sdk, target)
        if args.run:
            launch_fixture(name, app, bundle, out)
        results.append({"fixture": name, "status": "PASS", "compiled": True, "runtime_tested": args.run, "app": str(app)})
        print(f"PASS: {name} compile/link" + (" and explicit simulator run" if args.run else "; runtime not tested; no simctl access"), flush=True)
    (out / "results.json").write_text(json.dumps({"mode": "run" if args.run else "compile-only", "target": target, "results": results}, indent=2) + "\n")
    print(out / "results.json")


if __name__ == "__main__":
    main()
