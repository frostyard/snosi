#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Shared helper for verified downloads with SHA256 checksum validation.
# By default, lookup is split by build target:
#   - sysext-checksums.json: direct downloads consumed by mkosi.images/* sysexts
#   - image-checksums.json: direct downloads consumed by OCI profile builds
# Set CHECKSUMS_FILE to force lookup against one explicit metadata file.
set -euo pipefail

CHECKSUMS_DIR="$(dirname "${BASH_SOURCE[0]}")"
if [[ -n "${CHECKSUMS_FILE:-}" ]]; then
    CHECKSUMS_FILES=("$CHECKSUMS_FILE")
else
    CHECKSUMS_FILES=(
        "$CHECKSUMS_DIR/sysext-checksums.json"
        "$CHECKSUMS_DIR/image-checksums.json"
    )
fi

verified_download() (
    local key="$1"
    local output_path="$2"
    local output_dir output_name tmp=""
    local retries retry_delay

    retries="${VERIFIED_DOWNLOAD_RETRIES:-5}"
    retry_delay="${VERIFIED_DOWNLOAD_RETRY_DELAY:-10}"
    if [[ ! "$retries" =~ ^[0-9]+$ || ! "$retry_delay" =~ ^[0-9]+$ ]]; then
        echo "Error: VERIFIED_DOWNLOAD_RETRIES and VERIFIED_DOWNLOAD_RETRY_DELAY must be non-negative integers" >&2
        return 1
    fi

    cleanup_verified_download() {
        [[ -z "$tmp" || ! -e "$tmp" ]] || rm -f -- "$tmp"
    }
    trap cleanup_verified_download EXIT

    local url="" checksum="" checksums_file
    for checksums_file in "${CHECKSUMS_FILES[@]}"; do
        [[ -f "$checksums_file" ]] || { echo "Error: Checksums file not found: $checksums_file" >&2; return 1; }

        url=$(jq -r --arg key "$key" '.[$key].url // empty' "$checksums_file")
        checksum=$(jq -r --arg key "$key" '.[$key].sha256 // empty' "$checksums_file")
        if [[ -n "$url" || -n "$checksum" ]]; then
            break
        fi
    done

    [[ -n "$url" ]] || { echo "Error: No URL for key '$key'" >&2; return 1; }
    [[ -n "$checksum" ]] || { echo "Error: No checksum for key '$key'" >&2; return 1; }
    [[ ! -d "$output_path" ]] || { echo "Error: Output path is a directory: $output_path" >&2; return 1; }

    output_dir="$(dirname "$output_path")"
    output_name="$(basename "$output_path")"
    tmp="$(mktemp "$output_dir/.${output_name}.XXXXXX")" ||
        { echo "Error: Cannot create temporary output for $key" >&2; return 1; }

    echo "Downloading $key..."
    # Plain `curl --retry` does not retry curl error 56 (recv failure, a
    # connection reset) or 18 (partial file), so a transient network fault ends
    # the download at once and --retry-all-errors is needed to make the retry
    # budget apply to those errors. The fixed delay rides out a short 5xx outage
    # of the download host: a 504 answers immediately, so `curl`'s exponential
    # backoff spends the whole budget in seconds. A wrong pin still fails at the
    # SHA-256 check below, because a checksum mismatch is not a curl error and is
    # never retried. No --max-time: a large deb must not be cut off mid-transfer.
    curl --retry "$retries" --retry-all-errors --retry-delay "$retry_delay" \
        --connect-timeout 30 --location --fail --silent --show-error \
        --output "$tmp" "$url" ||
        { echo "Error: Download failed" >&2; return 1; }

    local actual
    actual=$(sha256sum "$tmp" | cut -d' ' -f1)
    if [[ "$actual" != "$checksum" ]]; then
        echo "Error: Checksum mismatch for $key" >&2
        echo "  Expected: $checksum" >&2
        echo "  Actual:   $actual" >&2
        return 1
    fi

    mv -f -- "$tmp" "$output_path"
    tmp=""
    echo "Verified $key"
)
