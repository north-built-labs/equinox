#!/usr/bin/env bash
# Equinox installer — https://github.com/north-built-labs/equinox
#
#   curl -fsSL https://raw.githubusercontent.com/north-built-labs/equinox/main/install.sh | bash
#
# Options (pass after `bash -s --`):
#   --from-source   build from the latest source instead of downloading the prebuilt app (needs Xcode)
#   --uninstall     remove Equinox and its settings
#
# Env: EQUINOX_INSTALL_DIR (default /Applications, or ~/Applications if that isn't writable),
#      EQUINOX_NO_LAUNCH=1 to skip launching after install,
#      EQUINOX_DOWNLOAD_URL to install a different archive (CI installs the build under test via file://).
set -euo pipefail

REPO="north-built-labs/equinox"
APP_NAME="Equinox.app"
MODE="${1:-}"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "Equinox is a macOS app."
MACOS="$(sw_vers -productVersion)"
(( ${MACOS%%.*} >= 15 )) || fail "Equinox needs macOS 15 or later (this Mac has $MACOS)."

INSTALL_DIR="${EQUINOX_INSTALL_DIR:-/Applications}"
if [[ ! -w "$INSTALL_DIR" ]]; then
    INSTALL_DIR="$HOME/Applications"
    mkdir -p "$INSTALL_DIR"
fi
TARGET="$INSTALL_DIR/$APP_NAME"

if [[ "$MODE" == "--uninstall" ]]; then
    pkill -x Equinox 2>/dev/null || true
    for dir in "$INSTALL_DIR" /Applications "$HOME/Applications"; do
        [[ -d "$dir/$APP_NAME" ]] && rm -rf "${dir:?}/$APP_NAME" && ok "Removed $dir/$APP_NAME"
    done
    rm -rf "$HOME/Library/Application Support/Equinox" && ok "Removed settings and presets"
    say "Equinox is uninstalled. Your audio is back to normal."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SOURCE_APP=""
if [[ "$MODE" != "--from-source" ]]; then
    say "Downloading the latest Equinox release…"
    if curl -fsSL -o "$TMP/Equinox.zip" "${EQUINOX_DOWNLOAD_URL:-https://github.com/$REPO/releases/latest/download/Equinox-macos.zip}"; then
        ditto -x -k "$TMP/Equinox.zip" "$TMP/release"
        SOURCE_APP="$TMP/release/$APP_NAME"
    else
        say "No prebuilt release available — building from source instead."
    fi
fi

if [[ -z "$SOURCE_APP" ]]; then
    command -v swift >/dev/null 2>&1 || fail "Building needs Swift 6. Install Xcode from the App Store, open it once, then run this again."
    say "Fetching the source…"
    mkdir -p "$TMP/src"
    curl -fsSL "https://codeload.github.com/$REPO/tar.gz/refs/heads/main" | tar -xz -C "$TMP/src" --strip-components 1
    say "Building (this takes a minute or two)…"
    (cd "$TMP/src" && scripts/build-app.sh >"$TMP/build.log" 2>&1) || { tail -20 "$TMP/build.log" >&2; fail "Build failed (log above)."; }
    SOURCE_APP="$TMP/src/build/$APP_NAME"
fi

[[ -d "$SOURCE_APP" ]] || fail "Something went wrong: $APP_NAME wasn't produced."

if pgrep -x Equinox >/dev/null 2>&1; then
    say "Quitting the running Equinox…"
    pkill -x Equinox || true
    sleep 1
fi
rm -rf "$TARGET"
ditto "$SOURCE_APP" "$TARGET"
xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true
ok "Installed $TARGET"

if [[ "${EQUINOX_NO_LAUNCH:-}" != "1" ]]; then
    open "$TARGET"
    cat <<'NEXT'

  Equinox is running — look for the waveform icon in your menu bar.

  1. Click "Enable Equinox" in the welcome window.
  2. Allow "System Audio Recording" when macOS asks (that's how Equinox hears your Mac's sound;
     nothing is recorded or saved).
  3. Play some music and drag the EQ curve.

  Uninstall any time:
    curl -fsSL https://raw.githubusercontent.com/north-built-labs/equinox/main/install.sh | bash -s -- --uninstall

NEXT
fi
