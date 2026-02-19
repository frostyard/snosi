#!/bin/bash

# move sysext files in output directory to a dedicated sysexts subdirectory
# files we want to move match the pattern <image_id>_<version>_<arch>.<ext>
set -euo pipefail
shopt -s nullglob

if [ -z "${OUTPUTDIR:-}" ]; then
    echo "Error: OUTPUTDIR is not set."
    OUTPUTDIR="output"
fi
SYSEXT_DIR="$OUTPUTDIR/sysexts"
mkdir -p "$SYSEXT_DIR"

sysext_files=("$OUTPUTDIR"/*_*_*.*)
if [ ${#sysext_files[@]} -eq 0 ]; then
    echo "No sysext files found in $OUTPUTDIR."
    exit 0
fi

for file in "${sysext_files[@]}"; do
    mv "$file" "$SYSEXT_DIR/"
    echo "Moved sysext file: $(basename "$file") to $SYSEXT_DIR/"
done
