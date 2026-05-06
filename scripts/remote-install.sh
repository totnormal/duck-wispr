#!/bin/bash
# One-liner: clone the repo and install everything
# Usage on the target Mac:
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/human37/duck-wispr/feat/proofreading-pipeline/scripts/remote-install.sh)"
set -euo pipefail

echo "════════════════════════════════════════════"
echo "  duck-wispr installer"
echo "  (proofreading pipeline edition)"
echo "════════════════════════════════════════════"
echo ""

# ── Prerequisite: Homebrew ──────────────────────────────────────
if ! command -v brew &>/dev/null; then
    echo "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    if [[ "$(uname -m)" == "arm64" ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    else
        eval "$(/usr/local/bin/brew shellenv)"
    fi
fi

# ── Clone repo ─────────────────────────────────────────────────
REPO_DIR="$HOME/duck-wispr-install"
echo ""
echo "Cloning duck-wispr..."
rm -rf "$REPO_DIR"
git clone --branch feat/proofreading-pipeline \
    https://github.com/human37/duck-wispr.git "$REPO_DIR"

cd "$REPO_DIR"

# ── Install whisper-cpp ────────────────────────────────────────
echo ""
echo "Installing whisper-cpp..."
brew install whisper-cpp 2>/dev/null || echo "  (already installed)"

# ── Build app ──────────────────────────────────────────────────
echo ""
echo "Building duck-wispr..."
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
swift build -c release 2>&1 | tail -3

echo ""
echo "Bundling .app..."
bash scripts/bundle-app.sh .build/release/duck-wispr DuckWispr.app dev

# ── Run portable install ───────────────────────────────────────
echo ""
echo "Running setup..."
bash scripts/portable-install.sh

echo ""
echo "════════════════════════════════════════════"
echo "  Installation complete!"
echo ""
echo "  The app lives at: ~/Applications/DuckWispr.app"
echo "  It auto-starts on login via launch agent"
echo "  Look for the waveform icon (〰️) in your menu bar"
echo "════════════════════════════════════════════"
