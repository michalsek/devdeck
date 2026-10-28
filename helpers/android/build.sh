#!/usr/bin/env bash
# Builds the debug APK of the DevDeck companion and copies it to build/devdeck-companion.apk.
set -euo pipefail
cd "$(dirname "$0")"

if [[ ! -f local.properties && -z "${ANDROID_HOME:-}" && -z "${ANDROID_SDK_ROOT:-}" ]]; then
    export ANDROID_HOME="$HOME/Library/Android/sdk"
fi

./gradlew --no-daemon assembleDebug "$@"

mkdir -p build
cp app/build/outputs/apk/debug/app-debug.apk build/devdeck-companion.apk
echo "$(pwd)/build/devdeck-companion.apk"
