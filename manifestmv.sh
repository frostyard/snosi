#!/bin/bash

# move manifest files in output directory to a dedicated manifests subdirectory
set -e
if [ -z "$OUTPUTDIR" ]; then
    echo "Error: OUTPUTDIR is not set."
    OUTPUTDIR="output"
fi
MANIFEST_DIR="$OUTPUTDIR/manifests"
mkdir -p "$MANIFEST_DIR"
for file in "$OUTPUTDIR"/*.manifest.json; do
    # the IMAGE_ID is the text before the first dot in the filename
    IMAGE_ID=$(basename "$file" | cut -d'.' -f1)
    mkdir -p "$MANIFEST_DIR/$IMAGE_ID"
    if [ -f "$file" ]; then
        mv "$file" "$MANIFEST_DIR/$IMAGE_ID/"
        echo "Moved manifest file: $(basename "$file") to $MANIFEST_DIR/$IMAGE_ID/"
    fi
done