#!/bin/bash
set -euo pipefail

# ── DuckWispr DMG Builder ──────────────────────────────────────────
# Produces a self-contained DuckWispr.app + DMG with:
#   • The duck-wispr binary
#   • whisper-cli (from homebrew whisper-cpp)
#   • All required dylibs (libwhisper, libggml, libggml-base)
# No external dependencies needed at runtime.
#
# Usage:  scripts/build-dmg.sh [version]
#

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="DuckWispr"
CLI_NAME="duck-wispr"
BUNDLE_ID="com.human37.duck-wispr"
VERSION="${1:-0.1.5}"
DMG_NAME="${APP_NAME}-v${VERSION}"
BUILD_DIR="$REPO_DIR/.build"
STAGING_DIR="$BUILD_DIR/dmg-staging"
APP_DIR="$STAGING_DIR/${APP_NAME}.app"
FW_DIR="$APP_DIR/Contents/Frameworks"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RES_DIR="$APP_DIR/Contents/Resources"

# ── Colors ─────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
info()  { echo "${GREEN}==>${NC} $*"; }
warn()  { echo "${YELLOW}⚠${NC} $*"; }
error() { echo "${RED}✗${NC} $*"; exit 1; }

# ── 1. Build release binary ───────────────────────────────────────
info "Building ${APP_NAME} ${VERSION} (release)..."
cd "$REPO_DIR"
swift build -c release --disable-sandbox

BINARY="$BUILD_DIR/release/${CLI_NAME}"
[[ -f "$BINARY" ]] || error "Release binary not found at $BINARY"
info "Binary: $(du -h "$BINARY" | cut -f1)"

# ── 2. Find whisper-cli ───────────────────────────────────────────
WHISPER_BIN=""
for candidate in /opt/homebrew/bin/whisper-cli /usr/local/bin/whisper-cli /opt/homebrew/bin/whisper-cpp /usr/local/bin/whisper-cpp; do
    if [[ -x "$candidate" ]]; then
        WHISPER_BIN="$candidate"
        break
    fi
done
[[ -n "$WHISPER_BIN" ]] || error "whisper-cli not found. Install: brew install whisper-cpp"
info "whisper-cli: $WHISPER_BIN ($(du -h "$WHISPER_BIN" | cut -f1))"

# ── 3. Create app bundle structure ────────────────────────────────
info "Creating ${APP_NAME}.app bundle..."
rm -rf "$STAGING_DIR"
mkdir -p "$MACOS_DIR" "$FW_DIR" "$RES_DIR"

cp "$BINARY" "$MACOS_DIR/${CLI_NAME}"
cp "$WHISPER_BIN" "$MACOS_DIR/whisper-cli"

# ── 4. Bundle dylibs ──────────────────────────────────────────────
info "Bundling dylibs..."

# Copy dylibs (resolve symlinks with -L)
DYLIBS=(
    "/opt/homebrew/lib/libwhisper.1.dylib"
    "/opt/homebrew/opt/ggml/lib/libggml.0.dylib"
    "/opt/homebrew/opt/ggml/lib/libggml-base.0.dylib"
)

for dylib in "${DYLIBS[@]}"; do
    if [[ -f "$dylib" ]]; then
        cp -L "$dylib" "$FW_DIR/"
        name=$(basename "$dylib")
        chmod 755 "$FW_DIR/$name"
        info "  bundled $name"
    else
        warn "  not found: $dylib"
    fi
done

# ── 5. Fix dylib install names ────────────────────────────────────
info "Fixing dylib install names..."

# libggml-base — no internal deps
install_name_tool -id "@loader_path/libggml-base.0.dylib" "$FW_DIR/libggml-base.0.dylib" 2>/dev/null || true

# libggml — depends on libggml-base
install_name_tool -id "@loader_path/libggml.0.dylib" "$FW_DIR/libggml.0.dylib" 2>/dev/null || true
install_name_tool -change "@rpath/libggml-base.0.dylib" "@loader_path/libggml-base.0.dylib" "$FW_DIR/libggml.0.dylib" 2>/dev/null || true

# libwhisper — depends on libggml + libggml-base
install_name_tool -id "@loader_path/libwhisper.1.dylib" "$FW_DIR/libwhisper.1.dylib" 2>/dev/null || true
# Fix the ggml references (paths vary between installations)
GGML_REF=$(otool -L "$FW_DIR/libwhisper.1.dylib" | grep 'libggml\.0' | grep -v base | awk '{print $1}' | head -1)
GGML_BASE_REF=$(otool -L "$FW_DIR/libwhisper.1.dylib" | grep 'libggml-base' | awk '{print $1}' | head -1)
if [[ -n "$GGML_REF" ]]; then
    install_name_tool -change "$GGML_REF" "@loader_path/libggml.0.dylib" "$FW_DIR/libwhisper.1.dylib" 2>/dev/null || true
fi
if [[ -n "$GGML_BASE_REF" ]]; then
    install_name_tool -change "$GGML_BASE_REF" "@loader_path/libggml-base.0.dylib" "$FW_DIR/libwhisper.1.dylib" 2>/dev/null || true
fi

# whisper-cli — depends on libwhisper, libggml, libggml-base
install_name_tool -change "@rpath/libwhisper.1.dylib" "@executable_path/../Frameworks/libwhisper.1.dylib" "$MACOS_DIR/whisper-cli"
GGML_REF=$(otool -L "$MACOS_DIR/whisper-cli" | grep 'libggml\.0' | grep -v base | awk '{print $1}' | head -1)
GGML_BASE_REF=$(otool -L "$MACOS_DIR/whisper-cli" | grep 'libggml-base' | awk '{print $1}' | head -1)
if [[ -n "$GGML_REF" ]]; then
    install_name_tool -change "$GGML_REF" "@executable_path/../Frameworks/libggml.0.dylib" "$MACOS_DIR/whisper-cli" 2>/dev/null || true
fi
if [[ -n "$GGML_BASE_REF" ]]; then
    install_name_tool -change "$GGML_BASE_REF" "@executable_path/../Frameworks/libggml-base.0.dylib" "$MACOS_DIR/whisper-cli" 2>/dev/null || true
fi

# ── 6. Copy app icon ──────────────────────────────────────────────
if [[ -f "$REPO_DIR/Resources/AppIcon.icns" ]]; then
    cp "$REPO_DIR/Resources/AppIcon.icns" "$RES_DIR/AppIcon.icns"
    info "Copied AppIcon.icns"
else
    warn "No AppIcon.icns found — app will use default icon"
fi

# ── 7. Write Info.plist ──────────────────────────────────────────
info "Writing Info.plist..."
cat > "$APP_DIR/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${CLI_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME} 🦆</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>DuckWispr needs microphone access to record speech for transcription.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>DuckWispr needs to control Music.app and Spotify to pause/resume playback during dictation.</string>
</dict>
</plist>
PLIST

# ── 8. Code sign ──────────────────────────────────────────────────
info "Code signing (ad-hoc)..."
# Sign leaf entities first, then the app bundle (inside-out order).
for dylib in "$FW_DIR"/*.dylib; do
    codesign --force --sign - "$dylib" 2>/dev/null || true
done
codesign --force --sign - "$MACOS_DIR/whisper-cli" 2>/dev/null || true
codesign --force --sign - "$MACOS_DIR/${CLI_NAME}" 2>/dev/null || true
# Sign the app bundle last with explicit identifier and options
# --options runtime would require a Developer ID, but we add timestamp
# for consistency across builds to reduce TCC invalidation.
codesign --force --sign - --identifier "$BUNDLE_ID" --timestamp "$APP_DIR" 2>/dev/null || true

# Remove quarantine xattr from the entire staging dir so the DMG
# contents don't trigger Gatekeeper when mounted on another machine.
xattr -cr "$STAGING_DIR" 2>/dev/null || true

# ── 9. Verify ──────────────────────────────────────────────────────
info "Verifying whisper-cli can find its libraries..."
otool -L "$MACOS_DIR/whisper-cli" | grep -E "loader_path|executable_path" || warn "No @loader_path/@executable_path refs in whisper-cli"

# ── 10. Create DMG ────────────────────────────────────────────────
info "Creating DMG..."
DMG_PATH="$REPO_DIR/${DMG_NAME}.dmg"
rm -f "$DMG_PATH"

# Use hdiutil to create a DMG with the app + a symlink to /Applications
ln -s /Applications "$STAGING_DIR/Applications"

# Create a background image with instructions
mkdir -p "$STAGING_DIR/.background"
cat > "$STAGING_DIR/INSTALL.txt" << 'TXT'
=== INSTALLATION ===

1. Drag DuckWispr.app to the Applications folder.

2. If replacing an older version, the old app will be
   automatically stopped before the new one starts.

3. FIRST LAUNCH: Right-click (or Control-click) on DuckWispr.app
   in /Applications and select "Open". This bypasses Gatekeeper.

4. If macOS still blocks the app:
   -> Open Terminal
   -> Run: xattr -cr /Applications/DuckWispr.app
   -> Then: open /Applications/DuckWispr.app

5. Grant Microphone + Accessibility permissions when prompted.
   IMPORTANT: After granting Accessibility, if the app shows a
   restart icon, click "Restart DuckWispr Now" in the menu.

6. The app downloads a Whisper model on first launch (~500 MB).

For help: https://github.com/totnormal/duck-wispr
TXT

cat > "$STAGING_DIR/.background/README.html" << 'HTML'
<html><body style="font-family:Helvetica;background:#1c1c1e;color:white;text-align:center;padding-top:40px">
<h1 style="font-size:28pt">🦆 DuckWispr</h1>
<p style="font-size:14pt;color:#aaa">Drag to Applications folder to install</p>
<p style="font-size:11pt;color:#666;margin-top:30px">Push-to-talk voice dictation for macOS<br>with automatic media pause/duck</p>
</body></html>
HTML

hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

info "DMG created: $(du -h "$DMG_PATH" | cut -f1) — $DMG_PATH"
info ""
info "${GREEN}✓ Done!${NC} Double-click ${DMG_NAME}.dmg, drag ${APP_NAME}.app to Applications."
info "  Then run: open /Applications/${APP_NAME}.app"
info ""
info "First launch will prompt for Accessibility + Microphone permissions."
info "Click the 🦆 menu bar icon → Pause Media → choose your mode."

# Cleanup staging
rm -rf "$STAGING_DIR"
