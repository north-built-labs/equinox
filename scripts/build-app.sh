#!/usr/bin/env bash
# Builds and signs build/Equinox.app. Usage: scripts/build-app.sh [--run]
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
SIGN_ID="${SIGN_ID:-Apple Development}"

swift build -c "$CONFIG" --product Equinox
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
APP="build/Equinox.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Equinox" "$APP/Contents/MacOS/Equinox"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign "$SIGN_ID" --timestamp=none "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--run" ]]; then
    pkill -x Equinox 2>/dev/null || true
    open "$APP"
fi
