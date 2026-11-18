#!/usr/bin/env bash
# Builds build/Prio.app with only the Xcode Command Line Tools installed.
# Universal (arm64 + x86_64) when the toolchain allows, else the native arch.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
BUILD="$ROOT/build"
APP="$BUILD/Prio.app"
TOOLS="$BUILD/tools"
VERSION="1.0.0"
BUILD_NUMBER="1"
BUNDLE_ID="io.github.prio-app.Prio"
MIN_MACOS="13.0"

log() { printf '==> %s\n' "$*"; }
note() { printf 'note: %s\n' "$*"; }

mkdir -p "$BUILD" "$TOOLS"

# 1. Compile ---------------------------------------------------------------
BIN=""
log "Building universal release binary (arm64 + x86_64)"
if swift build -c release --product Prio --arch arm64 --arch x86_64; then
    BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Prio"
else
    note "universal build failed; trying one build per architecture"
    ARM_OK=0
    X86_OK=0
    swift build -c release --product Prio --triple arm64-apple-macosx${MIN_MACOS} && ARM_OK=1 || true
    swift build -c release --product Prio --triple x86_64-apple-macosx${MIN_MACOS} && X86_OK=1 || true
    if [ "$ARM_OK" = 1 ] && [ "$X86_OK" = 1 ]; then
        ARM_BIN="$(swift build -c release --triple arm64-apple-macosx${MIN_MACOS} --show-bin-path)/Prio"
        X86_BIN="$(swift build -c release --triple x86_64-apple-macosx${MIN_MACOS} --show-bin-path)/Prio"
        lipo -create -output "$BUILD/Prio-universal" "$ARM_BIN" "$X86_BIN"
        BIN="$BUILD/Prio-universal"
    else
        note "x86_64 is not available with this toolchain; building for $(uname -m) only"
        swift build -c release --product Prio
        BIN="$(swift build -c release --show-bin-path)/Prio"
    fi
fi
[ -x "$BIN" ] || { echo "error: built binary not found at $BIN" >&2; exit 1; }
log "Binary architectures: $(lipo -archs "$BIN")"

# 2. Assemble the bundle ---------------------------------------------------
log "Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Prio"

# Note: no microphone usage description key. Prio never opens audio streams (R2).
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>Prio</string>
    <key>CFBundleExecutable</key>
    <string>Prio</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Prio</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_MACOS}</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright 2026 Prio contributors. MIT License.</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# 3. Icon --------------------------------------------------------------------
log "Rendering app icon"
ICONSET="$TOOLS/AppIcon.iconset"
rm -rf "$ICONSET"
if swiftc -O -o "$TOOLS/render-icon" "$ROOT/scripts/render-icon.swift" \
    && "$TOOLS/render-icon" "$ICONSET" \
    && iconutil -c icns -o "$APP/Contents/Resources/AppIcon.icns" "$ICONSET"; then
    :
else
    note "could not generate the app icon; the app will use the generic icon"
fi

# 4. Sign ----------------------------------------------------------------------
log "Signing (ad hoc)"
codesign --force --deep -s - "$APP"
codesign --verify --strict "$APP"

log "Done: $APP"
