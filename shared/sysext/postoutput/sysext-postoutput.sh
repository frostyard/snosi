#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Shared postoutput script for sysext images.
# Requires KEYPACKAGE environment variable to be set via mkosi.conf.
set -euo pipefail

if [[ -z "${KEYPACKAGE:-}" ]]; then
    echo "Error: KEYPACKAGE environment variable is not set"
    exit 1
fi

# Find the manifest file in the output directory
MANIFEST_FILE=$(find "$OUTPUTDIR" -maxdepth 1 -type f -name "$IMAGE_ID.manifest" | head -n 1)
if [[ -z "$MANIFEST_FILE" ]]; then
    echo "Error: No manifest file found for image ID: $IMAGE_ID"
    exit 1
fi
echo "Found manifest file: $MANIFEST_FILE"

# Extract version from manifest
KEYVERSION=$(jq -r --arg KEYPACKAGE "$KEYPACKAGE" '.packages[] | select(.name == $KEYPACKAGE) | .version' "$MANIFEST_FILE")
if [[ -z "$KEYVERSION" || "$KEYVERSION" == "null" ]]; then
    echo "Error: Could not determine version for package: $KEYPACKAGE"
    exit 1
fi
# Encode Debian epoch colon as underscore (e.g. "5:1.2.3" -> "5_1.2.3") so the
# version is valid in filenames and in systemd-sysupdate MatchPattern @v captures.
KEYVERSION="${KEYVERSION//:/_}"
echo "Determined version: $KEYVERSION for package: $KEYPACKAGE"

# Add key package info to manifest
jq --arg KEYPACKAGE "$KEYPACKAGE" --arg KEYVERSION "$KEYVERSION" -c \
    '.config.key_package=$KEYPACKAGE | .config.key_version=$KEYVERSION' \
    "$MANIFEST_FILE" > "$MANIFEST_FILE.tmp"
mv "$MANIFEST_FILE.tmp" "$MANIFEST_FILE"

# Extract Debian architecture from manifest and map to systemd arch name
DEB_ARCH=$(jq -r --arg KEYPACKAGE "$KEYPACKAGE" '.packages[] | select(.name == $KEYPACKAGE) | .architecture' "$MANIFEST_FILE")
echo "Debian architecture: $DEB_ARCH"
case "$DEB_ARCH" in
    amd64) ARCH=x86-64 ;;
    i386) ARCH=x86 ;;
    arm64) ARCH=arm64 ;;
    armhf) ARCH=arm ;;
    armel) ARCH=arm ;;
    ppc64el) ARCH=ppc64-le ;;
    s390x) ARCH=s390x ;;
    riscv64) ARCH=riscv64 ;;
    *) ARCH="$DEB_ARCH" ;;
esac
echo "Systemd architecture: $ARCH"

# Map the mkosi RELEASE codename to VERSION_ID, matching what %w expands to in
# systemd-sysupdate MatchPattern on a running system. RELEASE is provided by mkosi
# as an env var; the base image staging dir is not accessible from postoutput scripts.
case "$RELEASE" in
    forky) OS_VERSION=14 ;;
    trixie) OS_VERSION=13 ;;
    bookworm) OS_VERSION=12 ;;
    bullseye) OS_VERSION=11 ;;
    buster) OS_VERSION=10 ;;
    *) OS_VERSION="$RELEASE" ;;
esac
echo "OS version: $OS_VERSION"

echo "Image ID: $IMAGE_ID"

EXTFILENAME="$OUTPUTDIR/${IMAGE_ID}_${KEYVERSION}_${OS_VERSION}_${ARCH}"

# Find the existing output file (may have various compression extensions)
EXISTING_OUTPUT_FILE=""
EXISTING_EXT=""
for ext in raw raw.gz raw.xz raw.zst raw.bz2 raw.lz4; do
    if [[ -f "$OUTPUTDIR/${IMAGE_ID}.$ext" ]]; then
        EXISTING_OUTPUT_FILE="$OUTPUTDIR/${IMAGE_ID}.$ext"
        EXISTING_EXT="$ext"
        break
    fi
done
if [[ -z "$EXISTING_OUTPUT_FILE" ]]; then
    echo "Error: No existing output file found for image ID: $IMAGE_ID"
    exit 1
fi

# Copy and rename the output file with version info
cp "$EXISTING_OUTPUT_FILE" "$EXTFILENAME.$EXISTING_EXT"
echo "Created extension file: $EXTFILENAME.$EXISTING_EXT"

# Create symlink to the versioned file
if [[ -L "$OUTPUTDIR/${IMAGE_ID}" ]]; then
    rm "$OUTPUTDIR/${IMAGE_ID}"
fi
ln -s "$(basename "$EXTFILENAME.$EXISTING_EXT")" "$OUTPUTDIR/${IMAGE_ID}"
echo "Created symlink: $OUTPUTDIR/${IMAGE_ID} -> $(basename "$EXTFILENAME.$EXISTING_EXT")"

# Create versioned manifest
cp "$MANIFEST_FILE" "$OUTPUTDIR/$IMAGE_ID.$KEYVERSION.manifest.json"
