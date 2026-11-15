"""Compile SpotifyAudioProbe.dylib (the Pixie companion) for the current target."""
from pathlib import Path
import subprocess

from build_native_share import build_native_share
from pixie_target import companion_sources, include_directories

FRAMEWORKS = ("Foundation", "UIKit", "AudioToolbox", "AVFAudio", "CoreGraphics", "AVFoundation", "CoreMedia",
              "Network", "ImageIO", "QuartzCore", "LinkPresentation", "Security", "MessageUI", "UniformTypeIdentifiers")


def sdk_path():
    return subprocess.check_output(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], text=True).strip()


def build_companion(library, workdir):
    """Compile, ad-hoc sign and validate the companion at `library`; return its bytes."""
    library, workdir, sdk = Path(library), Path(workdir), sdk_path()
    swift = build_native_share(workdir / "NativeShareBridge.o", sdk)
    command = ["xcrun", "clang", "-dynamiclib", "-arch", "arm64", "-target", "arm64-apple-ios15.0",
               "-isysroot", sdk, "-fobjc-arc", "-std=gnu11", "-O2", "-fvisibility=hidden",
               "-Wall", "-Wextra", "-Wno-unused-parameter", "-Wno-nullability-completeness",
               "-Werror=implicit-function-declaration", "-DSAP_RESEARCH_DUMP=0", "-DSAP_ENABLE_WAV_CAPTURE=0"]
    command += ["-I" + str(path) for path in include_directories()]
    command += [str(path) for path in companion_sources()]
    command += ["-lm", "-lsqlite3", "-lz", *swift["link_args"]]
    for framework in FRAMEWORKS:
        command += ["-framework", framework]
    command += ["-Wl,-install_name,@rpath/SpotifyAudioProbe.dylib", "-o", str(library)]
    subprocess.run(command, check=True)
    subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none", str(library)], check=True)
    subprocess.run(["codesign", "--verify", "--strict", str(library)], check=True)
    subprocess.run(["xcrun", "dyld_info", "-validate_only", str(library)], check=True)
    return library.read_bytes()
