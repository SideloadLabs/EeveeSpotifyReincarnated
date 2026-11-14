"""Record the current checked source snapshot after reviewing source changes."""
from pathlib import Path
import hashlib
import json
from pixie_target import PROFILE, ROOT


def snapshot():
    project = ROOT.parent
    paths = []
    for base in [ROOT / "src", ROOT / "tools", ROOT / "targets", ROOT / "tests",
                 project / "Sources", project / "Tests"]:
        paths.extend(path for path in base.rglob("*") if path.is_file()
                     and "__pycache__" not in path.parts
                     and "Generated/RepoSlug.swift" not in path.as_posix())
    paths.extend([project / "Makefile", project / f"BUILD-pixie-v{PROFILE['pixie_version']}.md"])
    return {str(path.relative_to(project)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted(paths)}


def main():
    value = {"release": PROFILE["id"], "spotify_version": PROFILE["spotify_version"],
             "spotify_build": PROFILE["spotify_build"], "spotify_uuid": PROFILE["uuid"],
             "eevee_version": PROFILE["eevee_version"], "pixie_version": PROFILE["pixie_version"],
             "source_sha256_by_file": snapshot()}
    (ROOT / f"provenance-pixie-v{PROFILE['pixie_version']}.json").write_text(json.dumps(value, indent=2) + "\n")
    print(f'Recorded {len(value["source_sha256_by_file"])} source files')


if __name__ == "__main__":
    main()
