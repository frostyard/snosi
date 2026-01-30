#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Usage: ./update-checksums.sh <key> <new_url> [version]
set -euo pipefail
KEY="$1"; URL="$2"; VERSION="${3:-}"
CHECKSUMS="$(dirname "$0")/checksums.json"
TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT
curl --retry 3 -fsSL -o "$TMP" "$URL"
SHA=$(sha256sum "$TMP" | cut -d' ' -f1)
echo "SHA256: $SHA"
jq --arg k "$KEY" --arg u "$URL" --arg s "$SHA" --arg v "$VERSION" \
  '.[$k].url=$u | .[$k].sha256=$s | if $v != "" then .[$k].version=$v else . end' \
  "$CHECKSUMS" > "$CHECKSUMS.tmp" && mv "$CHECKSUMS.tmp" "$CHECKSUMS"
