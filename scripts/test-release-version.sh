#!/usr/bin/env bash
# Regression checks for version selection and fail-closed GitHub lookups. No network or signing keys.
set -euo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == 'api --paginate repos/{owner}/{repo}/releases --jq .[] | select(.draft == false and .prerelease == false) | .tag_name' ]] || exit 99
printf '%s' "${MOCK_TAGS:-}"
exit "${MOCK_STATUS:-0}"
MOCK
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
unset RELEASE_LATEST
base="$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)"
expect() {
    local actual
    actual="$(scripts/release-version.sh)"
    [[ "$actual" == "$1" ]] || { echo "Expected $1, got $actual" >&2; exit 1; }
}
export MOCK_TAGS=''
expect "$base"                       # First release.
export MOCK_TAGS='v0.0.1'
expect "$base"                       # Explicit version bump wins.
export MOCK_TAGS="v$base"
IFS=. read -r major minor patch <<< "$base"
expect "$major.$minor.$((patch + 1))" # Otherwise increment patch.
export MOCK_TAGS=$'v99.8.7\nv99.8.6\n'
expect '99.8.8'                       # Only the newest tag is used.
RELEASE_LATEST=v99.8.7 expect '99.8.8' # Local override remains available.
export MOCK_STATUS=1 MOCK_TAGS=''
if scripts/release-version.sh > "$TMP/version"; then
    echo 'Version selection ignored an API failure' >&2; exit 1
fi
[[ ! -s "$TMP/version" ]] || { echo 'API failure emitted a version' >&2; exit 1; }
# Even a partial API response must fail if a later page errors.
export MOCK_TAGS=v99.8.7
if scripts/release-version.sh > "$TMP/version"; then
    echo 'Version selection ignored a partial API failure' >&2; exit 1
fi
echo 'Release version regression checks passed.'
