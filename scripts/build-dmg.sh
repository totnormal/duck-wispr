#!/bin/bash
# Build a distributable DMG for open-wispr
# Output: open-wispr-<version>.dmg
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_DIR"

VERSION=$(grep -o 'v[0-9]\+\.[0-9]\+\.[0-9]\+' Sources/OpenWisprLib/AppDelegate.swift | head -1 || echo "v0.37.0")
DMG_NAME="open-wispr-${VERSION}.dmg"
STAGING="$(mktemp -d)"

echo "Building open-wispr $VERSION DMG..."

# ── Build release binary ─────────────────────────────────────
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
swift build -c release 2>&1 | tail -1

# ── Bundle .app ──────────────────────────────────────────────
bash scripts/bundle-app.sh .build/release/open-wispr OpenWispr.app dev

# ── Create DMG staging ───────────────────────────────────────
mkdir -p "$STAGING"
cp -R OpenWispr.app "$STAGING/"
ln -sf /Applications "$STAGING/Applications"

# ── Create DMG ────────────────────────────────────────────────
rm -f "$DMG_NAME"
hdiutil create -volname "open-wispr $VERSION" \
    -srcfolder "$STAGING" \
    -ov -format UDZO \
    "$DMG_NAME" 2>&1 | tail -1

# ── Codesign ─────────────────────────────────────────────────
codesign --force --deep --sign - "$DMG_NAME" 2>/dev/null || true

# ── Cleanup ──────────────────────────────────────────────────
rm -rf "$STAGING"

echo ""
echo "DMG created: $DMG_NAME"
ls -lh "$DMG_NAME"
echo ""
echo "To install on another Mac:"
echo "  1. Transfer this DMG file"
echo "  2. Open it, drag OpenWispr.app to /Applications"
echo "  3. First launch auto-handles: model download, config, launch agent for auto-start"
echo "  4. Grant Microphone + Accessibility when prompted"
echo ""
echo "  Prerequisite: brew install whisper-cpp"
