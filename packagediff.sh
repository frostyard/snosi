#!/bin/bash
set -euo pipefail

TMP_MANIFEST=$(mktemp)
TMP_LOCAL=$(mktemp)
trap 'rm -f "$TMP_MANIFEST" "$TMP_LOCAL"' EXIT

jq -r '.packages[] | .name' output/base.manifest | sort > "$TMP_MANIFEST"
grep -v '^Listing' /usr/share/snow/snow.packages.txt | awk -F/ '{print $1}' | sort > "$TMP_LOCAL"
echo "Manifest packages: $(wc -l < "$TMP_MANIFEST")"
echo "Local packages: $(wc -l < "$TMP_LOCAL")"
echo ""
echo "=== In MANIFEST but NOT on local system ==="
comm -23 "$TMP_MANIFEST" "$TMP_LOCAL"
echo ""
echo "=== On LOCAL system but NOT in manifest ==="
comm -13 "$TMP_MANIFEST" "$TMP_LOCAL"
