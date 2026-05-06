#!/bin/bash
set -euo pipefail

BINARY="${1:-.build/release/duck-wispr}"
APP_DIR="${2:-DuckWispr.app}"
VERSION="${3:-0.3.0}"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BINARY" "$APP_DIR/Contents/MacOS/duck-wispr"

# Bundle whisper-cpp binary so the DMG is self-contained
for candidate in /opt/homebrew/bin/whisper-cli /usr/local/bin/whisper-cli /opt/homebrew/bin/whisper-cpp /usr/local/bin/whisper-cpp; do
    if [[ -x "$candidate" ]]; then
        cp "$candidate" "$APP_DIR/Contents/MacOS/whisper-cli"

        # Bundle dependent dylibs
        mkdir -p "$APP_DIR/Contents/Frameworks"
        for dylib in /opt/homebrew/lib/libwhisper.1.dylib; do
            if [[ -f "$dylib" ]]; then
                cp -L "$dylib" "$APP_DIR/Contents/Frameworks/"
                chmod 755 "$APP_DIR/Contents/Frameworks/libwhisper.1.dylib"
            fi
        done
        for dylib in /opt/homebrew/opt/ggml/lib/libggml.0.dylib /opt/homebrew/opt/ggml/lib/libggml-base.0.dylib; do
            if [[ -f "$dylib" ]]; then
                cp -L "$dylib" "$APP_DIR/Contents/Frameworks/"
                name=$(basename "$dylib")
                chmod 755 "$APP_DIR/Contents/Frameworks/$name"
            fi
        done

        FW="$APP_DIR/Contents/Frameworks"

        # Fix libggml-base.0.dylib — it has no internal deps beyond system libs
        install_name_tool -id "@loader_path/libggml-base.0.dylib" "$FW/libggml-base.0.dylib" 2>/dev/null || true

        # Fix libggml.0.dylib — it depends on libggml-base
        install_name_tool -id "@loader_path/libggml.0.dylib" "$FW/libggml.0.dylib" 2>/dev/null || true
        install_name_tool -change "@rpath/libggml-base.0.dylib" "@loader_path/libggml-base.0.dylib" "$FW/libggml.0.dylib" 2>/dev/null || true

        # Fix libwhisper.1.dylib — it depends on libggml + libggml-base
        install_name_tool -id "@loader_path/libwhisper.1.dylib" "$FW/libwhisper.1.dylib" 2>/dev/null || true
        install_name_tool -change "$(otool -L "$FW/libwhisper.1.dylib" | grep ggml/ | awk '{print $1}' | head -1)" "@loader_path/libggml.0.dylib" "$FW/libwhisper.1.dylib" 2>/dev/null || true
        install_name_tool -change "$(otool -L "$FW/libwhisper.1.dylib" | grep ggml-base/ | awk '{print $1}' | head -1)" "@loader_path/libggml-base.0.dylib" "$FW/libwhisper.1.dylib" 2>/dev/null || true

        # Fix whisper-cli binary — it depends on the three dylibs
        install_name_tool -change "@rpath/libwhisper.1.dylib" "@executable_path/../Frameworks/libwhisper.1.dylib" "$APP_DIR/Contents/MacOS/whisper-cli"
        install_name_tool -change "$(otool -L "$APP_DIR/Contents/MacOS/whisper-cli" | grep ggml/ | awk '{print $1}' | head -1)" "@executable_path/../Frameworks/libggml.0.dylib" "$APP_DIR/Contents/MacOS/whisper-cli"
        install_name_tool -change "$(otool -L "$APP_DIR/Contents/MacOS/whisper-cli" | grep ggml-base/ | awk '{print $1}' | head -1)" "@executable_path/../Frameworks/libggml-base.0.dylib" "$APP_DIR/Contents/MacOS/whisper-cli"

        # Re-sign everything
        codesign --force --sign - "$FW/libggml-base.0.dylib" 2>/dev/null || true
        codesign --force --sign - "$FW/libggml.0.dylib" 2>/dev/null || true
        codesign --force --sign - "$FW/libwhisper.1.dylib" 2>/dev/null || true
        codesign --force --sign - "$APP_DIR/Contents/MacOS/whisper-cli" 2>/dev/null || true

        break
    fi
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cp "$REPO_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

cat > "$APP_DIR/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>duck-wispr</string>
    <key>CFBundleIdentifier</key>
    <string>com.human37.duck-wispr</string>
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

# TODO: Replace ad-hoc signing (--sign -) with Developer ID certificate for
# Gatekeeper acceptance and notarization. Requires Apple Developer account.
# Example: codesign --force --sign "Developer ID Application: ..." --options runtime ...
codesign --force --sign - --identifier com.human37.duck-wispr "$APP_DIR"

echo "Built $APP_DIR"
