#!/usr/bin/env bash
set -euo pipefail

# Build & launch i3wm-osx with the example config (or override via $CONFIG).

CONFIG="${CONFIG:-$HOME/.i3/config}"
if [[ ! -f "$CONFIG" ]]; then
    EXAMPLE="$(dirname "$0")/examples/config-macos"
    if [[ -f "$EXAMPLE" ]]; then
        echo "no config at $CONFIG, using $EXAMPLE"
        CONFIG="$EXAMPLE"
    else
        echo "no config found at $CONFIG"
        exit 1
    fi
fi

swift build -c release
exec "$(dirname "$0")/.build/release/i3wm-osx" -c "$CONFIG"
