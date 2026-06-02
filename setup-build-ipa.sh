#!/usr/bin/env bash
# Universal setup + runner for build-ipa-local.sh
#
# This script:
#   - Validates you're on macOS (required for Xcode toolchain)
#   - Installs/builds dependencies via Homebrew + pip
#   - Installs ipapatch
#   - Clones Theos (if missing)
#   - Runs ./build-ipa-local.sh <vanilla.ipa>
#
# Usage:
#   ./setup-build-ipa.sh /path/to/Spotify-vanilla.ipa
#   ./setup-build-ipa.sh --skip-run   (only install deps)
#   ./setup-build-ipa.sh --help

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

VANILLA_IPA=""
SKIP_RUN=0

usage() {
  cat <<'EOF'
Usage:
  ./setup-build-ipa.sh <path/to/Spotify-vanilla.ipa>

Options:
  --skip-run    Install/verify dependencies but do not run build-ipa-local.sh
  -h, --help    Show this help

Notes:
  - IPA building requires macOS with Xcode (or Xcode Command Line Tools).
  - Theos will be installed to ~/theos unless $THEOS is already set.
  - ipapatch will be installed to ~/.local/bin by default.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --skip-run) SKIP_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      if [ -z "$VANILLA_IPA" ]; then VANILLA_IPA="$1"; shift; else
        echo "Unexpected argument: $1" >&2
        usage
        exit 1
      fi
      ;;
  esac
done

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

say() { printf '\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m==> %s\033[0m\n' "$*"; }
err() { printf '\033[1;31m==> %s\033[0m\n' "$*" >&2; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { err "Missing required command: $1"; return 1; }
}

is_macos() {
  [ "$(uname -s)" = "Darwin" ]
}

ensure_path_contains() {
  local dir="$1"
  case ":$PATH:" in
    *":$dir:"*) : ;;
    *) export PATH="$dir:$PATH" ;;
  esac
}

# ─────────────────────────────────────────────────────────────────────────────
# 0) Platform checks
# ─────────────────────────────────────────────────────────────────────────────

if ! is_macos; then
  err "This build pipeline requires macOS (Xcode toolchain: xcrun/swiftc/lipo/plutil)."
  err "You're on: $(uname -s)."
  err "Tip: run this on a Mac (local machine) or a macOS runner/VM." 
  exit 2
fi

# Xcode / CLT
if ! command -v xcrun >/dev/null 2>&1; then
  err "xcrun not found. Install Xcode Command Line Tools first:"
  err "  xcode-select --install"
  exit 2
fi

# Swift toolchain availability (used by Tools/SwiftProtobufBuild)
if ! command -v swiftc >/dev/null 2>&1; then
  err "swiftc not found. Install Xcode (or ensure the full toolchain is available)."
  exit 2
fi

# ─────────────────────────────────────────────────────────────────────────────
# 1) Homebrew + packages
# ─────────────────────────────────────────────────────────────────────────────

if ! command -v brew >/dev/null 2>&1; then
  warn "Homebrew not found. Installing Homebrew..."
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

  # shellcheck disable=SC1091
  if [ -x /opt/homebrew/bin/brew ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [ -x /usr/local/bin/brew ]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi
fi

say "Installing brew packages..."
# keep in sync with GH Actions
brew update >/dev/null
brew install make dpkg ldid wget git unzip zip >/dev/null

# Prefer GNU make as `make` (workflow does this via gnubin)
GMAKE_GNUBIN="$(brew --prefix make)/libexec/gnubin"
if [ -d "$GMAKE_GNUBIN" ]; then
  ensure_path_contains "$GMAKE_GNUBIN"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 2) Python deps (cyan from pyzule-rw)
# ─────────────────────────────────────────────────────────────────────────────

say "Installing Python dependencies (cyan / pyzule-rw)..."
need_cmd python3

# On many Macs, Python/pip are managed by Homebrew.
# Upgrading pip in-place can fail with: uninstall-no-record-file.
# Use pipx to install pyzule-rw in an isolated venv instead.
brew install pipx >/dev/null

LOCAL_BIN="$HOME/.local/bin"
mkdir -p "$LOCAL_BIN"
ensure_path_contains "$LOCAL_BIN"

pipx ensurepath >/dev/null 2>&1 || true
pipx install --force git+https://github.com/asdfzxcvbn/pyzule-rw.git >/dev/null

need_cmd cyan

# ─────────────────────────────────────────────────────────────────────────────
# 3) ipapatch
# ─────────────────────────────────────────────────────────────────────────────

LOCAL_BIN="$HOME/.local/bin"
mkdir -p "$LOCAL_BIN"
ensure_path_contains "$LOCAL_BIN"

if ! command -v ipapatch >/dev/null 2>&1; then
  say "Installing ipapatch into $LOCAL_BIN..."
  ARCH="$(uname -m)"
  if [ "$ARCH" = "x86_64" ]; then
    SUFFIX="macos-amd64"
  else
    SUFFIX="macos-arm64"
  fi

  curl -fsSL "https://github.com/asdfzxcvbn/ipapatch/releases/latest/download/ipapatch.${SUFFIX}" \
    -o "$LOCAL_BIN/ipapatch"
  chmod +x "$LOCAL_BIN/ipapatch"
fi

need_cmd ipapatch
ipapatch --help >/dev/null

# ─────────────────────────────────────────────────────────────────────────────
# 4) Theos
# ─────────────────────────────────────────────────────────────────────────────

if [ -z "${THEOS:-}" ]; then
  if [ -d "$HOME/theos" ]; then
    export THEOS="$HOME/theos"
  else
    say "Installing Theos into ~/theos..."
    git clone --recursive https://github.com/theos/theos.git "$HOME/theos"
    export THEOS="$HOME/theos"
  fi
fi

# Basic tool checks used by build-ipa-local.sh
say "Verifying required tools..."
need_cmd dpkg-deb
need_cmd ldid
need_cmd plutil
need_cmd unzip
need_cmd zip
need_cmd lipo
need_cmd install_name_tool

# ─────────────────────────────────────────────────────────────────────────────
# 5) Run build (optional)
# ─────────────────────────────────────────────────────────────────────────────

if [ "$SKIP_RUN" -eq 1 ]; then
  say "Setup complete (skipped running build)."
  exit 0
fi

if [ -z "$VANILLA_IPA" ]; then
  err "Missing IPA path."
  usage
  exit 1
fi

if [ ! -f "$VANILLA_IPA" ]; then
  err "IPA not found: $VANILLA_IPA"
  exit 1
fi

say "Running build-ipa-local.sh..."
chmod +x ./build-ipa-local.sh
./build-ipa-local.sh "$VANILLA_IPA"

