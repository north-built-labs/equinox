#!/usr/bin/env bash
# Prints the version for the next release: Info.plist's version if it's newer than the latest release,
# otherwise the latest release with its patch number bumped. Needs `gh` (GH_TOKEN in CI).
set -euo pipefail
cd "$(dirname "$0")/.."
base="$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)"
latest="${RELEASE_LATEST-$(scripts/latest-release-tag.sh)}"   # RELEASE_LATEST overrides (tests)
latest="${latest#v}"
if [[ -z "$latest" ]]; then
    echo "$base"; exit 0
fi
newest="$(printf '%s\n%s\n' "$latest" "$base" | sort -V | tail -1)"
if [[ "$newest" == "$base" && "$base" != "$latest" ]]; then
    echo "$base"
else
    IFS=. read -r major minor patch <<< "$latest"
    echo "$major.${minor:-0}.$(( ${patch:-0} + 1 ))"
fi
