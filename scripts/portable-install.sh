#!/bin/bash
# Portable install script for duck-wispr (proofreading-pipeline edition)
# Works without Homebrew tap — installs straight from this directory
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}duck-wispr portable installer${NC}"
echo ""

# ── Check OS ──────────────────────────────────────────────────────
if [[ "$(uname)" != "Darwin" ]]; then
    echo -e "${RED}Error: macOS only${NC}"
    exit 1
fi

macos_version=$(sw_vers -productVersion | cut -d. -f1)
if [[ "$macos_version" -lt 13 ]]; then
    echo -e "${RED}Error: macOS 13 (Ventura) or later required${NC}"
    exit 1
fi

# ── Architecture check ────────────────────────────────────────────
ARCH=$(uname -m)
echo "Architecture: $ARCH"

# ── Find Homebrew ─────────────────────────────────────────────────
BREW=""
for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [ -x "$candidate" ]; then
        BREW="$candidate"
        break
    fi
done

if [ -z "$BREW" ]; then
    echo -e "${RED}Homebrew not found. Install it first:${NC}"
    echo "  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
    exit 1
fi

# ── Install whisper-cpp ───────────────────────────────────────────
echo ""
echo "Installing whisper-cpp..."
if "$BREW" list whisper-cpp &>/dev/null; then
    echo -e "${GREEN}✓${NC} whisper-cpp already installed"
else
    "$BREW" install whisper-cpp
    echo -e "${GREEN}✓${NC} whisper-cpp installed"
fi

# ── Copy app bundle ───────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_SRC="$REPO_DIR/DuckWispr.app"
if [ ! -d "$APP_SRC" ]; then
    echo ""
    echo "Building app bundle..."
    cd "$REPO_DIR"
    swift build -c release 2>&1 | tail -1
    bash scripts/bundle-app.sh .build/release/duck-wispr DuckWispr.app dev
    APP_SRC="$REPO_DIR/DuckWispr.app"
fi

echo ""
echo "Installing app to ~/Applications..."
rm -rf ~/Applications/DuckWispr.app
cp -R "$APP_SRC" ~/Applications/DuckWispr.app
echo -e "${GREEN}✓${NC} App installed"

# ── Download model ────────────────────────────────────────────────
MODEL_SIZE="${1:-base.en}"
MODEL_DIR="$HOME/.config/duck-wispr/models"
MODEL_FILE="$MODEL_DIR/ggml-$MODEL_SIZE.bin"

if [ -f "$MODEL_FILE" ]; then
    echo -e "${GREEN}✓${NC} Model $MODEL_SIZE already exists"
else
    echo ""
    echo "Downloading $MODEL_SIZE model..."
    mkdir -p "$MODEL_DIR"
    curl -L -o "$MODEL_FILE" \
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-$MODEL_SIZE.bin"
    echo -e "${GREEN}✓${NC} Model downloaded"
fi

# ── Write config ──────────────────────────────────────────────────
CONFIG_DIR="$HOME/.config/duck-wispr"
mkdir -p "$CONFIG_DIR"

if [ ! -f "$CONFIG_DIR/config.json" ]; then
    cat > "$CONFIG_DIR/config.json" << 'CONFEOF'
{
  "hotkey": { "keyCode": 63, "modifiers": [] },
  "language": "en",
  "modelSize": "base.en",
  "spokenPunctuation": false,
  "proofreadingMode": "standard",
  "maxRecordings": 0,
  "toggleMode": false
}
CONFEOF
    echo -e "${GREEN}✓${NC} Config created"
fi

# ── Install launch agent (auto-start on login) ────────────────────
LAUNCH_AGENT="$HOME/Library/LaunchAgents/com.duckwispr.dictation.plist"
cat > "$LAUNCH_AGENT" << LAEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.duckwispr.dictation</string>
    <key>ProgramArguments</key>
    <array>
        <string>$HOME/Applications/DuckWispr.app/Contents/MacOS/duck-wispr</string>
        <string>start</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
LAEOF

launchctl unload "$LAUNCH_AGENT" 2>/dev/null || true
launchctl load "$LAUNCH_AGENT" 2>/dev/null || true
echo -e "${GREEN}✓${NC} Auto-start on login configured"

# ── Permissions ───────────────────────────────────────────────────
echo ""
echo -e "${BLUE}Permission setup${NC}"
echo ""
echo "You'll need to grant two permissions:"
echo "  1. System Settings → Privacy & Security → Accessibility (for text insertion)"
echo "  2. System Settings → Privacy & Security → Microphone (for recording)"
echo ""
echo "The app will open the Accessibility pane on first launch."

# ── Start ─────────────────────────────────────────────────────────
echo ""
echo "Starting duck-wispr..."
~/Applications/DuckWispr.app/Contents/MacOS/duck-wispr start &
sleep 2
echo ""
echo -e "${GREEN}duck-wispr is running!${NC}"
echo ""
echo "  Hotkey: Globe key (🌐, fn) — hold to talk, release to dictate"
echo "  Menu bar: Look for the waveform icon"
echo "  Config: ~/.config/duck-wispr/config.json"
echo "  Proofreading: standard mode active (filler removal, contraction fix, capitalization)"
