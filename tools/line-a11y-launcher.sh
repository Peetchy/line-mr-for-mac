#!/bin/bash
# Launch LINE.app with the VoiceOver accessibility bridge.
#
# Ensures libline_a11y.dylib is installed (and ad-hoc signed) in
#   $(getconf DARWIN_USER_CACHE_DIR)/jp.naver.line.mac/a11y/platformthemes/
# -- a location LINE's sandbox may read and map executable -- and launches
# /Applications/LINE.app/Contents/MacOS/LINE with QT_PLUGIN_PATH pointing there.
#
# Usage: line-a11y-launcher.sh [--restart] [--foreground] [--dylib PATH]
#   --restart      quit a running LINE first (the plugin path is only read at startup)
#   --foreground   run LINE in the foreground of this shell instead of detaching
#   --dylib PATH   install this dylib instead of ../build/libline_a11y.dylib

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINE_APP="${LINE_APP:-/Applications/LINE.app}"
LINE_BIN="$LINE_APP/Contents/MacOS/LINE"
BUNDLE_ID="jp.naver.line.mac"
SRC_DYLIB="$SCRIPT_DIR/../build/libline_a11y.dylib"
RESTART=0
FOREGROUND=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --restart) RESTART=1 ;;
        --foreground) FOREGROUND=1 ;;
        --dylib) SRC_DYLIB="$2"; shift ;;
        -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 64 ;;
    esac
    shift
done

CACHE_DIR="$(getconf DARWIN_USER_CACHE_DIR)"
PLUGIN_ROOT="${CACHE_DIR%/}/$BUNDLE_ID/a11y"
DEST_DIR="$PLUGIN_ROOT/platformthemes"
DEST="$DEST_DIR/libline_a11y.dylib"

[[ -x "$LINE_BIN" ]] || { echo "error: $LINE_BIN not found" >&2; exit 1; }

# Install or refresh the plugin.
if [[ -f "$SRC_DYLIB" ]]; then
    if [[ ! -f "$DEST" ]] || ! cmp -s "$SRC_DYLIB" "$DEST"; then
        mkdir -p "$DEST_DIR"
        rm -f "$DEST"   # never overwrite a signed Mach-O in place
        cp "$SRC_DYLIB" "$DEST"
        xattr -c "$DEST" 2>/dev/null || true
        codesign -f -s - "$DEST"
        echo "Installed $DEST"
    fi
elif [[ ! -f "$DEST" ]]; then
    echo "error: $DEST is not installed and $SRC_DYLIB does not exist (run 'make' first)" >&2
    exit 1
fi

if ! codesign -v "$DEST" 2>/dev/null; then
    codesign -f -s - "$DEST"
    echo "Re-signed $DEST"
fi

# QT_PLUGIN_PATH is only consulted at startup.
if pgrep -x LINE >/dev/null; then
    if [[ $RESTART -eq 1 ]]; then
        echo "Quitting running LINE..."
        osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
        for _ in $(seq 1 40); do
            pgrep -x LINE >/dev/null || break
            sleep 0.25
        done
        if pgrep -x LINE >/dev/null; then
            echo "error: LINE did not quit; close it and retry" >&2
            exit 1
        fi
        # LINE relaunches its call helper only if it is gone.
        for _ in $(seq 1 20); do
            pgrep -x LineCall >/dev/null || break
            sleep 0.25
        done
    else
        echo "error: LINE is already running. Quit it first or pass --restart." >&2
        exit 1
    fi
fi

# Calls run in LineCall.app, which can only map the plugin from its own cache directory; the bridge
# in LINE points LineCall's QT_PLUGIN_PATH there (src/call_launch_hook.h).
CALL_DEST="${CACHE_DIR%/}/$BUNDLE_ID.LineCall/a11y/platformthemes/libline_a11y.dylib"
if [[ ! -f "$CALL_DEST" ]] || ! cmp -s "$DEST" "$CALL_DEST"; then
    mkdir -p "$(dirname "$CALL_DEST")"
    rm -f "$CALL_DEST"
    cp "$DEST" "$CALL_DEST"
    xattr -c "$CALL_DEST" 2>/dev/null || true
    echo "Installed $CALL_DEST"
fi
SRC_SHIM="$(dirname "$SRC_DYLIB")/libqcocoa_a11y.dylib"
CALL_SHIM="${CACHE_DIR%/}/$BUNDLE_ID.LineCall/a11y/platforms/libqcocoa_a11y.dylib"
if [[ -f "$SRC_SHIM" ]] && { [[ ! -f "$CALL_SHIM" ]] || ! cmp -s "$SRC_SHIM" "$CALL_SHIM"; }; then
    mkdir -p "$(dirname "$CALL_SHIM")"
    rm -f "$CALL_SHIM"
    cp "$SRC_SHIM" "$CALL_SHIM"
    xattr -c "$CALL_SHIM" 2>/dev/null || true
    echo "Installed $CALL_SHIM"
fi

export QT_PLUGIN_PATH="$PLUGIN_ROOT"
echo "Launching LINE with QT_PLUGIN_PATH=$QT_PLUGIN_PATH"
echo "Bridge log: $PLUGIN_ROOT/a11y.log"

if [[ $FOREGROUND -eq 1 ]]; then
    exec "$LINE_BIN"
fi
nohup "$LINE_BIN" >/dev/null 2>&1 &
echo "LINE started (pid $!)"

# LINE starts LineCall through LaunchServices, which drops any environment or arguments a
# sandboxed app passes, and it replaces a LineCall started before it. So wait for LINE's own
# LineCall and swap it for one with the bridge; LINE keeps talking to the new instance.
CALL_BIN="$LINE_APP/Contents/Frameworks/LineCall.app/Contents/MacOS/LineCall"
if [[ -x "$CALL_BIN" ]]; then
    (
        for _ in $(seq 1 120); do
            pgrep -x LineCall >/dev/null && break
            sleep 0.25
        done
        sleep 1
        pkill -x LineCall 2>/dev/null || true
        for _ in $(seq 1 20); do
            pgrep -x LineCall >/dev/null || break
            sleep 0.25
        done
        QT_PLUGIN_PATH="$(dirname "$(dirname "$CALL_DEST")")" nohup "$CALL_BIN" >/dev/null 2>&1 &
    ) >/dev/null 2>&1 &
    echo "LineCall will be restarted with the bridge"
fi
