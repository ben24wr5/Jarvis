#!/bin/bash
# Builds OLED.app (Apple Silicon + Intel) and packages it as dist/OLED.dmg.
# Runs on macOS (GitHub's Mac build machines, or any Mac with Apple's command-line tools).
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
APP="$ROOT/dist/OLED.app"

echo "==> Compiling"
swift build -c release --arch arm64 --arch x86_64
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

echo "==> Assembling OLED.app"
rm -rf "$ROOT/dist"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/OLED" "$APP/Contents/MacOS/OLED"
sed "s/BUILD_NUMBER/$BUILD_NUMBER/" "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# App icon: drop a square PNG (1024x1024 ideally) at Resources/AppIcon.png and it is used automatically.
if [ -f "$ROOT/Resources/AppIcon.png" ]; then
  echo "==> Adding app icon"
  ICONSET="$ROOT/dist/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z $size $size "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$ICONSET"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
fi

echo "==> Signing"
codesign --force --deep --sign - "$APP"
codesign --verify --verbose "$APP"

echo "==> Making OLED.dmg"
STAGE="$ROOT/dist/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "OLED" -srcfolder "$STAGE" -ov -format UDZO "$ROOT/dist/OLED.dmg" >/dev/null
rm -rf "$STAGE"

echo "==> Done: dist/OLED.dmg"
ls -lh "$ROOT/dist/OLED.dmg"
