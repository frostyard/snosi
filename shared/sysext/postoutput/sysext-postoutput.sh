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
echo "Determined version: $KEYVERSION for package: $KEYPACKAGE"

# Add key package info to manifest
jq --arg KEYPACKAGE "$KEYPACKAGE" --arg KEYVERSION "$KEYVERSION" -c \
    '.config.key_package=$KEYPACKAGE | .config.key_version=$KEYVERSION' \
    "$MANIFEST_FILE" > "$MANIFEST_FILE.tmp"
mv "$MANIFEST_FILE.tmp" "$MANIFEST_FILE"

# Extract architecture
ARCH=$(jq -r --arg KEYPACKAGE "$KEYPACKAGE" '.packages[] | select(.name == $KEYPACKAGE) | .architecture' "$MANIFEST_FILE")
echo "Architecture: $ARCH"
echo "Image ID: $IMAGE_ID"

EXTFILENAME="$OUTPUTDIR/${IMAGE_ID}_${KEYVERSION}_${ARCH}"

# Find the existing output file (may have various compression extensions)
EXISTING_OUTPUT_FILE=""
for ext in raw raw.gz raw.xz raw.zst raw.bz2 raw.lz4; do
    if [[ -f "$OUTPUTDIR/${IMAGE_ID}.$ext" ]]; then
        EXISTING_OUTPUT_FILE="$OUTPUTDIR/${IMAGE_ID}.$ext"
        break
    fi
done
if [[ -z "$EXISTING_OUTPUT_FILE" ]]; then
    echo "Error: No existing output file found for image ID: $IMAGE_ID"
    exit 1
fi

# Copy and rename the output file with version info
cp "$EXISTING_OUTPUT_FILE" "$EXTFILENAME.${EXISTING_OUTPUT_FILE##*.}"
echo "Created extension file: $EXTFILENAME.${EXISTING_OUTPUT_FILE##*.}"

# Create symlink to the versioned file
if [[ -L "$OUTPUTDIR/${IMAGE_ID}" ]]; then
    rm "$OUTPUTDIR/${IMAGE_ID}"
fi
ln -s "$(basename "$EXTFILENAME.${EXISTING_OUTPUT_FILE##*.}")" "$OUTPUTDIR/${IMAGE_ID}"
echo "Created symlink: $OUTPUTDIR/${IMAGE_ID} -> $(basename "$EXTFILENAME.${EXISTING_OUTPUT_FILE##*.}")"

# Create versioned manifest
cp "$MANIFEST_FILE" "$OUTPUTDIR/$IMAGE_ID.$KEYVERSION.manifest.json"
