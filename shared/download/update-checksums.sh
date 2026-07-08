#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Usage: ./update-checksums.sh <key> <new_url> [version]
#
# Existing keys are updated in their target-specific metadata file:
#   - sysext-checksums.json for direct downloads consumed by sysext builds
#   - image-checksums.json for direct downloads consumed by OCI image builds
# Set CHECKSUMS_FILE to update one explicit metadata file.
set -euo pipefail
KEY="$1"; URL="$2"; VERSION="${3:-}"
CHECKSUMS_DIR="$(dirname "$0")"
if [[ -n "${CHECKSUMS_FILE:-}" ]]; then
  CHECKSUMS="$CHECKSUMS_FILE"
else
  CHECKSUMS=""
  for candidate in "$CHECKSUMS_DIR/sysext-checksums.json" "$CHECKSUMS_DIR/image-checksums.json"; do
    [[ -f "$candidate" ]] || { echo "Error: Checksums file not found: $candidate" >&2; exit 1; }
    if [[ "$(jq -r --arg k "$KEY" 'has($k)' "$candidate")" == "true" ]]; then
      CHECKSUMS="$candidate"
      break
    fi
  done
  [[ -n "$CHECKSUMS" ]] || { echo "Error: Key '$KEY' not found in split checksum metadata" >&2; exit 1; }
fi
TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT
curl --retry 3 -fsSL -o "$TMP" "$URL"
SHA=$(sha256sum "$TMP" | cut -d' ' -f1)
echo "SHA256: $SHA"
jq --arg k "$KEY" --arg u "$URL" --arg s "$SHA" --arg v "$VERSION" \
  '.[$k].url=$u | .[$k].sha256=$s | if $v != "" then .[$k].version=$v else . end' \
  "$CHECKSUMS" > "$CHECKSUMS.tmp" && mv "$CHECKSUMS.tmp" "$CHECKSUMS"
