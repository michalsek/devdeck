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

# Companion apps that show device markers (see helpers/). Built when missing;
# REBUILD_COMPANIONS=1 forces a rebuild. DevDeck works without them.
COMPANIONS="$APP/Contents/Resources/Companions"
mkdir -p "$COMPANIONS"
IOS_COMPANION="$REPO/helpers/ios/build/DevDeckCompanion.app"
ANDROID_COMPANION="$REPO/helpers/android/build/devdeck-companion.apk"
if [ -n "${REBUILD_COMPANIONS:-}" ] || [ ! -d "$IOS_COMPANION" ]; then
  bash "$REPO/helpers/ios/build.sh" >/dev/null || echo "Warning: iOS companion didn't build" >&2
fi
if [ -n "${REBUILD_COMPANIONS:-}" ] || [ ! -f "$ANDROID_COMPANION" ]; then
  bash "$REPO/helpers/android/build.sh" >/dev/null || echo "Warning: Android companion didn't build" >&2
fi
[ -d "$IOS_COMPANION" ] && cp -R "$IOS_COMPANION" "$COMPANIONS/"
[ -f "$ANDROID_COMPANION" ] && cp "$ANDROID_COMPANION" "$COMPANIONS/"

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
