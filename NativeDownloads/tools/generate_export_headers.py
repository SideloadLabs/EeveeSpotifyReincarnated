"""Generate or check the 9.1.92 export headers from targets/spotify-9.1.92.json."""
import argparse
from pixie_target import ROOT
from export_headers import headers


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    folder = ROOT / "src/Generated"
    stale = []
    for name, expected in headers().items():
        path = folder / name
        if args.check:
            if not path.is_file() or path.read_text() != expected:
                stale.append(name)
        else:
            folder.mkdir(parents=True, exist_ok=True)
            path.write_text(expected)
    if stale:
        raise SystemExit("Stale export headers; run generate_export_headers.py: " + ", ".join(stale))
    if args.check:
        print("PASS: current export headers")


if __name__ == "__main__":
    main()
