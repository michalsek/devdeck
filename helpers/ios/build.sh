#!/bin/bash
# Builds the DevDeck companion app for the iOS simulator (arm64, ad-hoc signed) and prints its path.
#   helpers/ios/build.sh [Debug|Release]   (default Release)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
config="${1:-Release}"
derived="$here/build/DerivedData"
out="$here/build/DevDeckCompanion.app"

xcodebuild \
    -project "$here/DevDeckCompanion.xcodeproj" \
    -scheme DevDeckCompanion \
    -configuration "$config" \
    -sdk iphonesimulator \
    -destination "generic/platform=iOS Simulator" \
    -derivedDataPath "$derived" \
    -jobs 6 \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_IDENTITY=- \
    -quiet build >&2

rm -rf "$out"
cp -R "$derived/Build/Products/$config-iphonesimulator/DevDeckCompanion.app" "$out"
echo "$out"
