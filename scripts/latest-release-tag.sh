#!/usr/bin/env bash
# Print the newest published stable tag, or nothing only when none exist.
# API/authentication/network failures deliberately propagate to the caller.
set -euo pipefail
gh api --paginate 'repos/{owner}/{repo}/releases' \
    --jq '.[] | select(.draft == false and .prerelease == false) | .tag_name' | sed -n '1p'
