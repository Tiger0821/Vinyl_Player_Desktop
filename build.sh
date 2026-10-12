#!/bin/bash
# Builds Wax.app into ./build.
#
#   ./build.sh            build only
#   ./build.sh run        build, then (re)launch it
#   ./build.sh install    build, copy to /Applications, then launch that copy
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Wax"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"

# Compile, assemble and sign outside the project folder. A folder synced by iCloud (Desktop,
# Documents) tags app bundles with Finder metadata that codesign refuses to sign over, and
# the compiler's intermediate files have no business being uploaded.
CACHE="${WAX_BUILD_CACHE:-$HOME/Library/Caches/Wax}"
SCRATCH="$CACHE/swiftpm"
STAGE="$CACHE/stage"
STAGED="$STAGE/$APP_NAME.app"

swift build -c release --scratch-path "$SCRATCH"
BINARY="$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path)/$APP_NAME"

rm -rf "$STAGE"
mkdir -p "$STAGED/Contents/MacOS" "$STAGED/Contents/Resources"
cp "$BINARY" "$STAGED/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$STAGED/Contents/Info.plist"
# The room photographs, rendered by Art/room_scene.py.
mkdir -p "$STAGED/Contents/Resources/Scenes"
cp Resources/Scenes/*.jpg Resources/Scenes/*.png Resources/Scenes/*.json "$STAGED/Contents/Resources/Scenes/"

# The icon is drawn by the app itself, then cut down to the sizes macOS wants.
ICON_PNG="$STAGE/icon-1024.png"
ICONSET="$STAGE/AppIcon.iconset"
if "$BINARY" --render-icon "$ICON_PNG" >/dev/null; then
    rm -rf "$ICONSET"
    mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size" "$ICON_PNG" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        sips -z "$((size * 2))" "$((size * 2))" "$ICON_PNG" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$STAGED/Contents/Resources/AppIcon.icns"
    rm -rf "$ICONSET" "$ICON_PNG"
else
    echo "warning: couldn't render the icon; continuing without one" >&2
fi

# A real signing identity keeps the "control Music" permission across rebuilds. An ad-hoc
# signature works too, but macOS then asks again after every build.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -n 1)}"
if [ -z "$IDENTITY" ] || ! codesign --force --sign "$IDENTITY" "$STAGED" 2>/dev/null; then
    codesign --force --sign - "$STAGED"
    echo "Signed ad hoc."
else
    echo "Signed as: $IDENTITY"
fi

rm -rf "$APP"
mkdir -p "$BUILD_DIR"
ditto "$STAGED" "$APP"
echo "Built $APP"

case "${1:-}" in
run)
    pkill -x "$APP_NAME" 2>/dev/null || true
    open "$APP"
    ;;
install)
    pkill -x "$APP_NAME" 2>/dev/null || true
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" "/Applications/$APP_NAME.app"
    open "/Applications/$APP_NAME.app"
    echo "Installed to /Applications/$APP_NAME.app"
    ;;
esac
