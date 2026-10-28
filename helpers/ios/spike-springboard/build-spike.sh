#!/bin/bash
# EXPERIMENT ONLY: builds the SpringBoard marker spike dylib for the iOS simulator (arm64).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$here/build"
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun clang -target arm64-apple-ios18.0-simulator -isysroot "$sdk" -dynamiclib -fobjc-arc \
    -framework UIKit -framework Foundation -framework CoreGraphics -o "$here/build/DevDeckSpike.dylib" "$here/DevDeckSpike.m"
codesign -f -s - "$here/build/DevDeckSpike.dylib"
echo "$here/build/DevDeckSpike.dylib"
