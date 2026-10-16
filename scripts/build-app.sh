#!/usr/bin/env bash
# Builds build/Equinox.app.
#   scripts/build-app.sh            build (host architecture)
#   scripts/build-app.sh --run      build, then (re)launch
#   scripts/build-app.sh --release  universal (Apple silicon + Intel) build, ad-hoc signed, zipped to build/Equinox-macos.zip
# Env: SIGN_ID=<identity> to choose a signing identity (default: "Apple Development" if installed, else ad-hoc).
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
MODE="${1:-}"

ARCH_FLAGS=()
if [[ "$MODE" == "--release" ]]; then
    ARCH_FLAGS=(--arch arm64 --arch x86_64)
    SIGN_ID="${SIGN_ID:--}"     # releases never embed a personal certificate
fi
if [[ -z "${SIGN_ID:-}" ]]; then
    if security find-identity -v -p codesigning 2>/dev/null | grep -q "Apple Development"; then
        SIGN_ID="Apple Development"   # stable identity: macOS keeps the audio permission across rebuilds
    else
        SIGN_ID="-"                   # ad-hoc
    fi
fi

swift build -c "$CONFIG" --product Equinox ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"
APP="build/Equinox.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Equinox" "$APP/Contents/MacOS/Equinox"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign "$SIGN_ID" --timestamp=none "$APP"
echo "Built $APP (signed: $SIGN_ID)"

case "$MODE" in
    --run)
        pkill -x Equinox 2>/dev/null || true
        sleep 0.5
        open "$APP"
        ;;
    --release)
        rm -f build/Equinox-macos.zip
        ditto -c -k --keepParent "$APP" build/Equinox-macos.zip
        echo "Packaged build/Equinox-macos.zip"
        ;;
esac
