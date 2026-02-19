#!/bin/bash

# move manifest files in output directory to a dedicated manifests subdirectory
set -euo pipefail
shopt -s nullglob

if [ -z "${OUTPUTDIR:-}" ]; then
    echo "WARNING: OUTPUTDIR is not set. Defaulting to './output'."
    OUTPUTDIR="output"
fi
MANIFEST_DIR="$OUTPUTDIR/manifests"
mkdir -p "$MANIFEST_DIR"

manifest_files=("$OUTPUTDIR"/*.manifest.json)
if [ ${#manifest_files[@]} -eq 0 ]; then
    echo "No manifest files found in $OUTPUTDIR."
    exit 0
fi

for file in "${manifest_files[@]}"; do
    # the IMAGE_ID is the text before the first dot in the filename
    IMAGE_ID=$(basename "$file" | cut -d'.' -f1)
    mkdir -p "$MANIFEST_DIR/$IMAGE_ID"
    mv "$file" "$MANIFEST_DIR/$IMAGE_ID/"
    echo "Moved manifest file: $(basename "$file") to $MANIFEST_DIR/$IMAGE_ID/"
done
