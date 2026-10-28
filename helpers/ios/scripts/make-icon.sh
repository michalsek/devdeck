#!/bin/bash
# Regenerates the iOS AppIcon from the repo's shared icon script.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
repo="$(cd "$here/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
(cd "$repo" && swift scripts/make-icon.swift "$tmp/raw.png" >/dev/null)
swift "$here/scripts/flatten-icon.swift" "$tmp/raw.png" "$here/DevDeckCompanion/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
echo "$here/DevDeckCompanion/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
