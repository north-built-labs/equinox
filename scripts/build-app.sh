#!/usr/bin/env bash
# Builds build/Equinox.app.
#   scripts/build-app.sh            build (host architecture)
#   scripts/build-app.sh --run      build, then (re)launch
#   scripts/build-app.sh --release  universal (Apple silicon + Intel) build, ad-hoc signed, zipped to build/Equinox-macos.zip
#                                   and Ed25519-signed (build/Equinox-macos.zip.sig) for the in-app updater
# Env: SIGN_ID=<identity> to choose a signing identity (default: "Apple Development" if installed, else ad-hoc).
#      VERSION / BUILD_NUMBER stamp CFBundleShortVersionString / CFBundleVersion into the built app (CI releases).
#      EQUINOX_SIGNING_KEY: release signing key for --release (else ~/.config/equinox/release-signing-key).
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
if [[ -n "${VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
if [[ -n "${BUILD_NUMBER:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
fi
codesign --force --sign "$SIGN_ID" --timestamp=none "$APP"
echo "Built $APP (signed: $SIGN_ID)"

case "$MODE" in
    --run)
        pkill -x Equinox 2>/dev/null || true
        sleep 0.5
        open "$APP"
        ;;
    --release)
        # Signatures belong to one exact archive; never retain them across rebuilds.
        rm -f build/Equinox-macos.zip build/Equinox-macos.zip.sig build/Equinox-macos.zip.sshsig
        ditto -c -k --keepParent "$APP" build/Equinox-macos.zip
        echo "Packaged build/Equinox-macos.zip"
        # The in-app updater only installs archives signed with the release key (see scripts/sign-release.swift).
        if [[ -n "${EQUINOX_SIGNING_KEY:-}" || -f "$HOME/.config/equinox/release-signing-key" ]]; then
            swift scripts/sign-release.swift build/Equinox-macos.zip
        else
            echo "warning: no release signing key; build/Equinox-macos.zip is unsigned and the in-app updater will refuse it" >&2
        fi
        ;;
esac
