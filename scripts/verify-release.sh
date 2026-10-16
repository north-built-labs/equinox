#!/usr/bin/env bash
# Checks a packaged release the way users' machines will see it, before it's published.
#   scripts/verify-release.sh <Equinox-macos.zip> <version>
# Always: the archive unpacks to a valid, universal, code-signed Equinox.app stamped with <version>, and install.sh
# trusts the release key embedded in the app.
# When <zip>.sig exists (or REQUIRE_SIGNATURE=1): install.sh's key accepts <zip>.sshsig, and an older app runs its real updater (--update-dry-run) against
# the archive and must accept the signature, swap itself out and end up at <version>. The older app is the
# currently published release when PREVIOUS_ZIP points at it (what users actually have installed), otherwise
# a copy of this same build stamped 0.0.1.
set -euo pipefail
cd "$(dirname "$0")/.."

ZIP="${1:?usage: verify-release.sh <zip> <version>}"
VERSION="${2:?usage: verify-release.sh <zip> <version>}"
SIG="$ZIP.sig"
BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw Resources/Info.plist)"

fail() { echo "::error::verify-release: $*" >&2; exit 1; }
plist() { plutil -extract "$2" raw "$1/Contents/Info.plist"; }

TMP="$(mktemp -d)"
cleanup() { pkill -f "$TMP/" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

ZIP_ABS="$(cd "$(dirname "$ZIP")" && pwd)/$(basename "$ZIP")"
ditto -x -k "$ZIP_ABS" "$TMP/unpacked" || fail "archive doesn't unpack"
APP="$TMP/unpacked/Equinox.app"
[[ -d "$APP" ]] || fail "archive doesn't contain Equinox.app at its root"

[[ "$(plist "$APP" CFBundleIdentifier)" == "$BUNDLE_ID" ]] || fail "bundle id is $(plist "$APP" CFBundleIdentifier), expected $BUNDLE_ID"
[[ "$(plist "$APP" CFBundleShortVersionString)" == "$VERSION" ]] || fail "app version is $(plist "$APP" CFBundleShortVersionString), expected $VERSION"
codesign --verify --strict --verbose=2 "$APP" || fail "code signature doesn't verify"
archs="$(lipo -archs "$APP/Contents/MacOS/Equinox")"
[[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || fail "binary isn't universal (archs: $archs)"
echo "✓ Structure: $BUNDLE_ID $VERSION, code signature valid, archs: $archs"

# install.sh's allowed signers (one line per trusted key) must include the app's release key, in OpenSSH form.
grep -oE 'equinox-release namespaces="equinox-release" ssh-ed25519 [A-Za-z0-9+/=]+' install.sh > "$TMP/allowed_signers" \
    || fail "install.sh has no release signing key"
app_key="$(sed -nE 's/.*releasePublicKey = Data\(base64Encoded: "([^"]+)"\).*/\1/p' Sources/EquinoxCore/Updates.swift)"
ssh_key="$( (printf '\x00\x00\x00\x0bssh-ed25519\x00\x00\x00\x20'; base64 -d <<< "$app_key") | base64)"
grep -qF "ssh-ed25519 $ssh_key" "$TMP/allowed_signers" || fail "install.sh doesn't trust the app's release key ($ssh_key)"
echo "✓ Installer: trusts the app's release key"

if [[ ! -f "$SIG" ]]; then
    [[ "${REQUIRE_SIGNATURE:-}" == "1" ]] && fail "$SIG is missing"
    echo "– No signature; skipping the signature checks."
    exit 0
fi

[[ -f "$ZIP.sshsig" ]] || fail "$ZIP.sshsig is missing (install.sh needs it)"
ssh-keygen -Y verify -f "$TMP/allowed_signers" -I equinox-release -n equinox-release -s "$ZIP.sshsig" < "$ZIP" >/dev/null \
    || fail "install.sh's key doesn't accept $ZIP.sshsig"
echo "✓ Installer: accepts the archive's signature"

# Install the older app, then let it update itself to the archive.
INSTALLED="$TMP/apps/Equinox.app"
mkdir -p "$TMP/apps"
if [[ -n "${PREVIOUS_ZIP:-}" ]]; then
    ditto -x -k "$PREVIOUS_ZIP" "$TMP/apps" || fail "previous release doesn't unpack"
else
    ditto "$APP" "$INSTALLED"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 0.0.1" "$INSTALLED/Contents/Info.plist"
    codesign --force --sign - --timestamp=none "$INSTALLED" >/dev/null 2>&1
fi
FROM="$(plist "$INSTALLED" CFBundleShortVersionString)"

LOG="$TMP/dry-run.log"
SIG_ABS="$(cd "$(dirname "$SIG")" && pwd)/$(basename "$SIG")"
"$INSTALLED/Contents/MacOS/Equinox" --update-dry-run "$ZIP_ABS" "$SIG_ABS" "$VERSION" "$LOG" || true
result="$(cat "$LOG" 2>/dev/null || echo "no log written")"
[[ "$result" == HANDED-OFF* ]] || fail "the updater refused this release: $result"

# The detached swap script replaces the app once the old process has exited, then relaunches it.
for _ in $(seq 1 60); do
    [[ "$(plist "$INSTALLED" CFBundleShortVersionString 2>/dev/null)" == "$VERSION" ]] && break
    sleep 0.5
done
[[ "$(plist "$INSTALLED" CFBundleShortVersionString 2>/dev/null)" == "$VERSION" ]] || fail "the updater didn't swap in $VERSION"
[[ ! -e "$INSTALLED.old" && ! -e "$INSTALLED.new" ]] || fail "the updater left a stray .old/.new bundle behind"
echo "✓ Updater: $FROM accepted the signature and updated itself to $VERSION"
