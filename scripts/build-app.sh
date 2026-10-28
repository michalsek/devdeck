#!/bin/bash
# Builds DevDeck.app.
#   bash scripts/build-app.sh            # build into build/DevDeck.app
#   bash scripts/build-app.sh --install  # also copy to ~/Applications and launch
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$REPO/build/DevDeck.app"
VERSION="$(cat "$REPO/VERSION" 2>/dev/null || echo 0.1.0)"

swift build --package-path "$REPO" -c release
BIN="$(swift build --package-path "$REPO" -c release --show-bin-path)/DevDeck"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DevDeck"
# Agent hooks call this helper (see Sources/devdeck-hook).
cp "$(dirname "$BIN")/devdeck-hook" "$APP/Contents/MacOS/devdeck-hook"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
swift "$REPO/scripts/make-icon.swift" "$WORK/icon.png"
ICONSET="$WORK/DevDeck.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size "$WORK/icon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$WORK/icon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/DevDeck.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.devdeck.app</string>
  <key>CFBundleName</key><string>DevDeck</string>
  <key>CFBundleDisplayName</key><string>DevDeck</string>
  <key>CFBundleExecutable</key><string>DevDeck</string>
  <key>CFBundleIconFile</key><string>DevDeck</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
  DEST="$HOME/Applications/DevDeck.app"
  mkdir -p "$HOME/Applications"
  pkill -x DevDeck 2>/dev/null || true
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  open "$DEST"
  echo "Installed and launched $DEST"
fi
