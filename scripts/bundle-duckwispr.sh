#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_DIR"

VERSION="$(grep 'public static let version' Sources/DuckWisprLib/Version.swift | sed 's/.*= "//;s/".*//')"
APP_DIR="DuckWispr.app"
DMG_NAME="DuckWispr-v${VERSION}"
BINARY=".build/release/duck-wispr"

echo "==> Building DuckWispr v${VERSION} DMG..."

# --- Build release binary ---
if [ ! -f "$BINARY" ]; then
    echo "==> Building release binary..."
    swift build -c release
fi

# --- Clean previous build ---
rm -rf "$APP_DIR" "${DMG_NAME}.dmg" /tmp/"${DMG_NAME}"

# --- App bundle structure ---
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Frameworks"
mkdir -p "$APP_DIR/Contents/Resources"

# Copy main binary
cp "$BINARY" "$APP_DIR/Contents/MacOS/duck-wispr"
chmod +x "$APP_DIR/Contents/MacOS/duck-wispr"

# --- Bundle whisper-cli + dylibs ---
WHISPER_BIN=""
for candidate in /opt/homebrew/bin/whisper-cli /usr/local/bin/whisper-cli /opt/homebrew/bin/whisper-cpp /usr/local/bin/whisper-cpp; do
    if [[ -x "$candidate" ]]; then
        WHISPER_BIN="$candidate"
        break
    fi
done

if [[ -z "$WHISPER_BIN" ]]; then
    echo "ERROR: whisper-cli not found. Install with: brew install whisper-cpp"
    exit 1
fi

echo "==> Bundling whisper-cli from $WHISPER_BIN"
cp "$WHISPER_BIN" "$APP_DIR/Contents/MacOS/whisper-cli"
chmod +x "$APP_DIR/Contents/MacOS/whisper-cli"

FW="$APP_DIR/Contents/Frameworks"

# Copy dylibs
for dylib in \
    /opt/homebrew/lib/libwhisper.1.dylib \
    /opt/homebrew/opt/ggml/lib/libggml.0.dylib \
    /opt/homebrew/opt/ggml/lib/libggml-base.0.dylib; do
    if [[ -f "$dylib" ]]; then
        echo "  Bundling $(basename "$dylib")"
        cp -L "$dylib" "$FW/"
        chmod 755 "$FW/$(basename "$dylib")"
    fi
done

# --- Rewrite dylib paths ---
echo "==> Rewriting dylib paths..."

# libggml-base: no internal deps beyond system
install_name_tool -id "@loader_path/libggml-base.0.dylib" "$FW/libggml-base.0.dylib" 2>/dev/null || true

# libggml: depends on libggml-base
install_name_tool -id "@loader_path/libggml.0.dylib" "$FW/libggml.0.dylib" 2>/dev/null || true
install_name_tool -change "@rpath/libggml-base.0.dylib" "@loader_path/libggml-base.0.dylib" "$FW/libggml.0.dylib" 2>/dev/null || true
# Also fix the absolute path reference
install_name_tool -change "/opt/homebrew/opt/ggml/lib/libggml-base.0.dylib" "@loader_path/libggml-base.0.dylib" "$FW/libggml.0.dylib" 2>/dev/null || true

# libwhisper: depends on libggml + libggml-base
install_name_tool -id "@loader_path/libwhisper.1.dylib" "$FW/libwhisper.1.dylib" 2>/dev/null || true
install_name_tool -change "/opt/homebrew/opt/ggml/lib/libggml.0.dylib" "@loader_path/libggml.0.dylib" "$FW/libwhisper.1.dylib" 2>/dev/null || true
install_name_tool -change "/opt/homebrew/opt/ggml/lib/libggml-base.0.dylib" "@loader_path/libggml-base.0.dylib" "$FW/libwhisper.1.dylib" 2>/dev/null || true
install_name_tool -change "@rpath/libwhisper.1.dylib" "@loader_path/libwhisper.1.dylib" "$FW/libwhisper.1.dylib" 2>/dev/null || true

# whisper-cli: depends on all three
install_name_tool -change "@rpath/libwhisper.1.dylib" "@executable_path/../Frameworks/libwhisper.1.dylib" "$APP_DIR/Contents/MacOS/whisper-cli"
install_name_tool -change "/opt/homebrew/opt/ggml/lib/libggml.0.dylib" "@executable_path/../Frameworks/libggml.0.dylib" "$APP_DIR/Contents/MacOS/whisper-cli"
install_name_tool -change "/opt/homebrew/opt/ggml/lib/libggml-base.0.dylib" "@executable_path/../Frameworks/libggml-base.0.dylib" "$APP_DIR/Contents/MacOS/whisper-cli"

# --- Re-sign all bundled binaries ---
echo "==> Code signing..."
codesign --force --sign - "$FW/libggml-base.0.dylib" 2>/dev/null || true
codesign --force --sign - "$FW/libggml.0.dylib" 2>/dev/null || true
codesign --force --sign - "$FW/libwhisper.1.dylib" 2>/dev/null || true
codesign --force --sign - "$APP_DIR/Contents/MacOS/whisper-cli" 2>/dev/null || true

# --- Icon ---
if [[ -f "Resources/AppIcon.icns" ]]; then
    cp "Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

# --- Info.plist ---
cat > "$APP_DIR/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>duck-wispr</string>
    <key>CFBundleIdentifier</key>
    <string>com.duckwispr.dictation</string>
    <key>CFBundleName</key>
    <string>DuckWispr</string>
    <key>CFBundleDisplayName</key>
    <string>DuckWispr</string>
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
</dict>
</plist>
PLIST

# --- Sign the full app bundle ---
codesign --force --sign - --identifier com.duckwispr.dictation "$APP_DIR"

echo "==> Built $APP_DIR"

# --- Create DMG ---
echo "==> Creating DMG..."
DMG_STAGING="/tmp/${DMG_NAME}"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"

# Copy app and Applications symlink
cp -R "$APP_DIR" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

# Create the DMG
hdiutil create -volname "$DMG_NAME" \
    -srcfolder "$DMG_STAGING" \
    -ov -format UDZO \
    "${DMG_NAME}.dmg"

rm -rf "$DMG_STAGING"

echo ""
echo "==> Done! DMG: ${DMG_NAME}.dmg ($(du -h "${DMG_NAME}.dmg" | cut -f1))"
echo "    Install: open ${DMG_NAME}.dmg → drag DuckWispr.app to Applications"
echo "    Run:     open /Applications/DuckWispr.app"
