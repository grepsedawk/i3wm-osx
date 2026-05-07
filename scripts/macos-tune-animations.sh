#!/usr/bin/env bash
# Tune (or restore) macOS-wide animation settings so workspace transitions
# under i3wm-osx feel closer to i3 on Linux. These are user-level `defaults`
# — they affect every macOS app, not just i3wm-osx — and are fully
# reversible with `off`.
#
# Usage:
#   scripts/macos-tune-animations.sh on    # disable / shorten animations
#   scripts/macos-tune-animations.sh off   # restore macOS defaults
set -euo pipefail

mode="${1:-}"

case "$mode" in
    on)
        echo "==> Disabling generic window animations..."
        defaults write -g NSAutomaticWindowAnimationsEnabled -bool false
        defaults write -g NSWindowResizeTime -float 0.001

        echo "==> Switching Dock minimize from genie → scale (much faster)..."
        defaults write com.apple.dock mineffect -string scale
        defaults write com.apple.dock launchanim -bool false
        defaults write com.apple.dock expose-animation-duration -float 0.1
        defaults write com.apple.dock springboard-show-duration -float 0.1
        defaults write com.apple.dock springboard-hide-duration -float 0.1
        defaults write com.apple.dock springboard-page-duration -float 0
        defaults write com.apple.dock autohide-time-modifier -float 0
        defaults write com.apple.dock autohide-delay -float 0

        killall Dock
        echo "Done. Workspace switches should feel snappy now."
        echo "To revert: scripts/macos-tune-animations.sh off"
        ;;
    off)
        defaults delete -g NSAutomaticWindowAnimationsEnabled 2>/dev/null || true
        defaults delete -g NSWindowResizeTime 2>/dev/null || true
        defaults delete com.apple.dock mineffect 2>/dev/null || true
        defaults delete com.apple.dock launchanim 2>/dev/null || true
        defaults delete com.apple.dock expose-animation-duration 2>/dev/null || true
        defaults delete com.apple.dock springboard-show-duration 2>/dev/null || true
        defaults delete com.apple.dock springboard-hide-duration 2>/dev/null || true
        defaults delete com.apple.dock springboard-page-duration 2>/dev/null || true
        defaults delete com.apple.dock autohide-time-modifier 2>/dev/null || true
        defaults delete com.apple.dock autohide-delay 2>/dev/null || true

        killall Dock
        echo "Animations restored to macOS defaults."
        ;;
    *)
        echo "Usage: $0 on|off" >&2
        exit 2
        ;;
esac
