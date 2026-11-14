"""Build the current Eevee/Pixie IPA in one fresh output directory."""
import argparse
from datetime import datetime
import os
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile

from pixie_target import PROFILE, ROOT, validate_sources


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--theos", type=Path, default=os.environ.get("THEOS"))
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--jobs", type=int, default=4)
    args = parser.parse_args()
    if not args.theos or not args.theos.is_dir():
        parser.error("Supply --theos /path/to/theos or set THEOS")
    source = args.ipa.resolve()
    if not source.is_file():
        parser.error("Input IPA not found")
    validate_sources()
    make = shutil.which("gmake") or shutil.which("make")
    if not make or "GNU Make" not in subprocess.check_output([make, "--version"], text=True):
        parser.error("GNU Make is required (gmake or make)")
    output = (args.output_dir or ROOT.parent / "outputs" /
              datetime.now().strftime("build-%Y%m%d-%H%M%S-%f")).resolve()
    output.mkdir(parents=True, exist_ok=False)
    env = dict(os.environ, THEOS=str(args.theos.resolve()),
               THEOS_PACKAGE_SCHEME="rootless")
    # Theos requires a project path without spaces. Sources stay in this project.
    with tempfile.TemporaryDirectory(prefix="pixie-project-") as temporary:
        alias = Path(temporary) / "project"
        alias.symlink_to(ROOT.parent, target_is_directory=True)
        env["THEOS_PROJECT_DIR"] = str(alias)
        with (output / "eevee-build.log").open("w") as log:
            subprocess.run([make, f"-j{args.jobs}", "all", "FINALPACKAGE=1",
                            f"THEOS_PROJECT_DIR={alias}",
                            "REPO_SLUG=Glongq/EeveeSpotifyReincarnated", "BRANCH_NAME=Master"],
                           cwd=alias, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
    eevee = ROOT.parent / ".theos/obj/EeveeSpotify.dylib"
    subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none", str(eevee)], check=True)
    archive = output / f'Spotify-{PROFILE["spotify_version"]}-EeveeSpotify-Pixie-v{PROFILE["pixie_version"]}.ipa'
    with (output / "ipa-build.log").open("w") as log:
        subprocess.run([sys.executable, str(ROOT / "tools/build_eevee_9192.py"), str(source),
                        "--eevee-dylib", str(eevee), "--output", str(archive)],
                       cwd=ROOT.parent, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
    print(archive)


if __name__ == "__main__":
    main()
