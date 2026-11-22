#!/bin/bash
# Builds Nebula.app with the Swift toolchain (Xcode or Command Line Tools).
# Usage:  ./build.sh            → build/Nebula.app
#         ./build.sh --install  → also copies it to /Applications and launches it
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Nebula.app"

echo "→ Compilo (release)…"
if [ "${UNIVERSAL:-0}" = "1" ]; then
    swift build -c release --arch arm64
    swift build -c release --arch x86_64
    mkdir -p build
    lipo -create \
        "$(swift build -c release --arch arm64 --show-bin-path)/Nebula" \
        "$(swift build -c release --arch x86_64 --show-bin-path)/Nebula" \
        -output build/Nebula-universal
    BIN="build/Nebula-universal"
else
    swift build -c release
    BIN="$(swift build -c release --show-bin-path)/Nebula"
fi

echo "→ Assemblo il bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Nebula"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Optional: standalone MarkItDown produced by CI (see .github/workflows/build.yml)
if [ -x Resources/markitdown/markitdown ]; then
    echo "→ Includo MarkItDown…"
    cp -R Resources/markitdown "$APP/Contents/Resources/markitdown"
    find "$APP/Contents/Resources/markitdown" -type f \( -name "*.so" -o -name "*.dylib" -o -perm -u+x \) \
        -exec codesign --force --sign - {} \; 2>/dev/null || true
fi

if [ -f Resources/AppIcon.png ]; then
    ICONSET="build/AppIcon.iconset"
    rm -rf "$ICONSET" && mkdir -p "$ICONSET"
    for s in 16 32 128 256 512; do
        sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
        d=$((s * 2))
        sips -z $d $d Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

echo "→ Firma ad-hoc…"
codesign --force --deep --sign - "$APP"

if [ "${1:-}" = "--install" ]; then
    echo "→ Installo in /Applications…"
    pkill -x Nebula 2>/dev/null || true
    rm -rf "/Applications/Nebula.app"
    cp -R "$APP" /Applications/
    /System/Library/CoreServices/pbs -update 2>/dev/null || true   # refresh the Services menu
    open /Applications/Nebula.app
fi

echo "✓ Fatto: $APP"
