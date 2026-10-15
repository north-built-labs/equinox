#!/usr/bin/env bash
# Live end-to-end checks. Plays a quiet 1 kHz tone (~14 s) and measures Equinox's processed output.
# Also renders UI snapshots. Usage: scripts/self-test.sh [snapshot-dir]
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build-app.sh >/dev/null
SNAPS="${1:-build/snapshots}"
build/Equinox.app/Contents/MacOS/Equinox --snapshots "$SNAPS"
pkill -x Equinox 2>/dev/null || true; sleep 1
OUT="build/selftest.txt"; rm -f "$OUT"
# Launched via LaunchServices so macOS attributes the audio permission to Equinox itself.
open -n -W build/Equinox.app --args --self-test "$PWD/$OUT"
cat "$OUT"
grep -q "^RESULT: all" "$OUT"
