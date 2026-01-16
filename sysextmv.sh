#!/bin/bash

# move sysext files in output directory to a dedicated sysexts subdirectory
# files we want to move match the pattern <image_id>_<version>_<arch>.<ext>
set -e
if [ -z "$OUTPUTDIR" ]; then
    echo "Error: OUTPUTDIR is not set."
    OUTPUTDIR="output"
fi
SYSEXT_DIR="$OUTPUTDIR/sysexts"
mkdir -p "$SYSEXT_DIR"
for file in "$OUTPUTDIR"/*_*_*.*; do
    if [ -f "$file" ]; then
        mv "$file" "$SYSEXT_DIR/"
        echo "Moved sysext file: $(basename "$file") to $SYSEXT_DIR/"
    fi
done