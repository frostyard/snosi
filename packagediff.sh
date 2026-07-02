#!/bin/bash
set -euo pipefail

TMP_MANIFEST=$(mktemp)
TMP_LOCAL=$(mktemp)
trap 'rm -f "$TMP_MANIFEST" "$TMP_LOCAL"' EXIT

jq -r '.packages[] | .name' output/base.manifest | sort > "$TMP_MANIFEST"
# The build writes /usr/share/frostyard/<image-id>.packages.txt and sets the
# os-release ID to the same image id (see shared/scripts/common-postinst.sh),
# so the running system's ID selects its own manifest unambiguously.
IMAGE_ID=$(. /etc/os-release && echo "${ID:-}")
PKGFILE="/usr/share/frostyard/${IMAGE_ID}.packages.txt"
if [[ -z "$IMAGE_ID" || ! -f "$PKGFILE" ]]; then
    echo "ERROR: cannot find this image's package manifest (os-release ID='${IMAGE_ID}', expected ${PKGFILE})" >&2
    exit 1
fi
grep -v '^Listing' "$PKGFILE" | awk -F/ '{print $1}' | sort > "$TMP_LOCAL"
echo "Manifest packages: $(wc -l < "$TMP_MANIFEST")"
echo "Local packages: $(wc -l < "$TMP_LOCAL")"
echo ""
echo "=== In MANIFEST but NOT on local system ==="
comm -23 "$TMP_MANIFEST" "$TMP_LOCAL"
echo ""
echo "=== On LOCAL system but NOT in manifest ==="
comm -13 "$TMP_MANIFEST" "$TMP_LOCAL"
