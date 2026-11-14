"""Exercise the actual artwork loader function on macOS, without UIKit/device UI.

Only the native image service and UIKit JPEG encoder are doubled. The extracted
production function keeps its real queues, cancellation and cache implementation.
"""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

with tempfile.TemporaryDirectory(prefix="pixie-artwork-cache-") as temporary:
    work = Path(temporary)
    source = (ROOT / "src/Export/ExportArtwork.m").read_text()
    start = source.index("// Only explicit export requests")
    end = source.index("@interface SAPExportAudioShareItem")
    (work / "ExportArtworkUnderTest.inc").write_text(source[start:end])
    binary = work / "artwork-cache"
    subprocess.run([
        "xcrun", "clang", "-arch", "arm64", "-fobjc-arc", "-std=gnu11", "-O1", "-g",
        "-fsanitize=address,undefined", "-I" + str(work),
        str(ROOT / "tests/export_artwork_cache.m"), "-framework", "Foundation",
        "-framework", "CoreGraphics", "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], env=os.environ.copy(), check=True, timeout=20)
