#!/bin/bash
# EXPERIMENT ONLY: injects the spike dylib into a *throwaway* simulator's SpringBoard.
#   run-spike.sh <udid> inject   restart SpringBoard with the dylib (env var removed right after)
#   run-spike.sh <udid> revert   restart SpringBoard without it
# Control the marker with: echo agent|user|free > /tmp/devdeck-spike-state
set -euo pipefail
udid="$1"; action="${2:-inject}"
here="$(cd "$(dirname "$0")" && pwd)"
dylib="$here/build/DevDeckSpike.dylib"

restart_springboard() {
    # launchd_sim keeps SpringBoard alive, so stopping it respawns it with the current environment.
    xcrun simctl spawn "$udid" launchctl stop com.apple.SpringBoard
    sleep 4
}

case "$action" in
inject)
    [[ -f "$dylib" ]] || "$here/build-spike.sh" >/dev/null
    xcrun simctl spawn "$udid" launchctl setenv DYLD_INSERT_LIBRARIES "$dylib"
    restart_springboard
    # Only the respawned SpringBoard should get it; don't leak into every later process.
    xcrun simctl spawn "$udid" launchctl unsetenv DYLD_INSERT_LIBRARIES
    ;;
revert)
    xcrun simctl spawn "$udid" launchctl unsetenv DYLD_INSERT_LIBRARIES
    restart_springboard
    ;;
*) echo "usage: $0 <udid> inject|revert" >&2; exit 2 ;;
esac
