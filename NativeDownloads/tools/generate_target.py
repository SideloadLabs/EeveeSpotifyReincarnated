"""Generate or check the current native identity header."""
import argparse
from pixie_target import ROOT, target_header

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    path = ROOT / "src/Generated/TargetProfile.h"
    expected = target_header()
    if args.check:
        if not path.is_file() or path.read_text() != expected:
            raise SystemExit("TargetProfile.h is stale; run generate_target.py")
        print("PASS: current target identity header")
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(expected)

if __name__ == "__main__":
    main()
