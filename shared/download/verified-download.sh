#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Shared helper for verified downloads with SHA256 checksum validation.
set -euo pipefail

CHECKSUMS_FILE="${CHECKSUMS_FILE:-$(dirname "${BASH_SOURCE[0]}")/checksums.json}"

verified_download() {
    local key="$1"
    local output_path="$2"

    [[ -f "$CHECKSUMS_FILE" ]] || { echo "Error: Checksums file not found: $CHECKSUMS_FILE" >&2; return 1; }

    local url checksum
    url=$(jq -r --arg key "$key" '.[$key].url // empty' "$CHECKSUMS_FILE")
    checksum=$(jq -r --arg key "$key" '.[$key].sha256 // empty' "$CHECKSUMS_FILE")

    [[ -n "$url" ]] || { echo "Error: No URL for key '$key'" >&2; return 1; }
    [[ -n "$checksum" ]] || { echo "Error: No checksum for key '$key'" >&2; return 1; }

    echo "Downloading $key..."
    curl --retry 3 --location --fail --silent --show-error --output "$output_path" "$url" || { echo "Error: Download failed" >&2; return 1; }

    local actual
    actual=$(sha256sum "$output_path" | cut -d' ' -f1)
    if [[ "$actual" != "$checksum" ]]; then
        echo "Error: Checksum mismatch for $key" >&2
        echo "  Expected: $checksum" >&2
        echo "  Actual:   $actual" >&2
        rm -f "$output_path"
        return 1
    fi
    echo "Verified $key"
}
