#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Compare directory structure and file contents between two Docker/OCI images using diffoscope
set -euo pipefail

# ============================================================================
# Configuration and globals
# ============================================================================
SCRIPT_NAME="$(basename "$0")"
TMPDIR=""
TMPDIR_BASE=""
DIFFOSCOPE_ARGS=()
OUTPUT_FILE=""
OUTPUT_FORMAT="text"

# ============================================================================
# Usage and help
# ============================================================================
usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS] <image1> <image2>

Compare directory structure and file contents between two Docker/OCI images.
Uses diffoscope for detailed recursive comparison.

Arguments:
  <image1>    First image reference (the image being compared)
  <image2>    Second image reference (the reference/baseline image)

Options:
  -t, --tmpdir <dir>        Use custom temp directory (default: /tmp)
  -o, --output <file>       Write output to file instead of stdout
  -f, --format <format>     Output format: text, html, json, markdown (default: text)
  --exclude <pattern>       Exclude files matching pattern (passed to diffoscope)
  --max-diff-size <bytes>   Maximum diff size (default: diffoscope default)
  --max-report-size <bytes> Maximum report size (default: diffoscope default)
  -h, --help                Show this help message

Image Reference Formats:
  oci:<path>                Local OCI image directory
  docker://<image>:<tag>    Remote Docker registry image
  docker-archive:<path>     Local Docker archive (.tar)
  containers-storage:<name> Local containers/storage image

Examples:
  # Compare local OCI image with remote reference
  $SCRIPT_NAME oci:./output/snow docker://ghcr.io/frostyard/reference:latest

  # Compare two remote images
  $SCRIPT_NAME docker://myregistry/myimage:v1 docker://myregistry/myimage:v2

  # Generate HTML report
  $SCRIPT_NAME -f html -o report.html \\
    oci:./output/snow docker://ghcr.io/reference:latest

  # Compare with exclusions
  $SCRIPT_NAME \\
    --exclude '*.pyc' \\
    --exclude '/var/cache/*' \\
    oci:./output/snow docker://ghcr.io/reference:latest

  # Use custom temp directory (for large images)
  $SCRIPT_NAME --tmpdir /var/tmp oci:./output/snow docker://ref:latest

EOF
    exit "${1:-0}"
}

# ============================================================================
# Cleanup handler
# ============================================================================
cleanup() {
    if [[ -n "$TMPDIR" && -d "$TMPDIR" ]]; then
        echo "Cleaning up temporary files..." >&2
        rm -rf "$TMPDIR"
    fi
}

trap cleanup EXIT

# ============================================================================
# Argument parsing
# ============================================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -t|--tmpdir)
                if [[ -z "${2:-}" ]]; then
                    echo "Error: --tmpdir requires a directory argument" >&2
                    exit 1
                fi
                TMPDIR_BASE="$2"
                shift 2
                ;;
            -o|--output)
                if [[ -z "${2:-}" ]]; then
                    echo "Error: --output requires a file argument" >&2
                    exit 1
                fi
                OUTPUT_FILE="$2"
                shift 2
                ;;
            -f|--format)
                if [[ -z "${2:-}" ]]; then
                    echo "Error: --format requires a format argument" >&2
                    exit 1
                fi
                OUTPUT_FORMAT="$2"
                shift 2
                ;;
            --exclude)
                if [[ -z "${2:-}" ]]; then
                    echo "Error: --exclude requires a pattern argument" >&2
                    exit 1
                fi
                DIFFOSCOPE_ARGS+=("--exclude" "$2")
                shift 2
                ;;
            --max-diff-size)
                if [[ -z "${2:-}" ]]; then
                    echo "Error: --max-diff-size requires a size argument" >&2
                    exit 1
                fi
                DIFFOSCOPE_ARGS+=("--max-diff-block-lines" "$2")
                shift 2
                ;;
            --max-report-size)
                if [[ -z "${2:-}" ]]; then
                    echo "Error: --max-report-size requires a size argument" >&2
                    exit 1
                fi
                DIFFOSCOPE_ARGS+=("--max-report-size" "$2")
                shift 2
                ;;
            -h|--help)
                usage 0
                ;;
            -*)
                echo "Error: Unknown option: $1" >&2
                usage 1
                ;;
            *)
                if [[ -z "${IMAGE1:-}" ]]; then
                    IMAGE1="$1"
                elif [[ -z "${IMAGE2:-}" ]]; then
                    IMAGE2="$1"
                else
                    echo "Error: Too many arguments" >&2
                    usage 1
                fi
                shift
                ;;
        esac
    done

    if [[ -z "${IMAGE1:-}" || -z "${IMAGE2:-}" ]]; then
        echo "Error: Two image references are required" >&2
        usage 1
    fi
}

# ============================================================================
# Check dependencies
# ============================================================================
check_dependencies() {
    local missing=()

    for cmd in skopeo jq tar file diffoscope; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "Error: Missing required commands: ${missing[*]}" >&2
        echo "Install diffoscope: pip install diffoscope" >&2
        exit 1
    fi
}

# ============================================================================
# Extract OCI image to directory
# ============================================================================
extract_image() {
    local image_ref="$1"
    local output_dir="$2"
    local oci_dir="$output_dir/oci"
    local rootfs_dir="$output_dir/rootfs"
    local extract_failures=0

    mkdir -p "$oci_dir" "$rootfs_dir"

    echo "Fetching image: $image_ref" >&2

    # Copy image to local OCI format
    skopeo copy "$image_ref" "oci:$oci_dir:latest" --quiet

    # Get the manifest
    local manifest_file="$oci_dir/index.json"
    if [[ ! -f "$manifest_file" ]]; then
        echo "Error: Could not find index.json in OCI image" >&2
        return 1
    fi

    # Parse the manifest to get layer digests
    local manifest_digest
    manifest_digest=$(jq -r '.manifests[0].digest' "$manifest_file" | sed 's/sha256://')

    local manifest_path="$oci_dir/blobs/sha256/$manifest_digest"
    if [[ ! -f "$manifest_path" ]]; then
        echo "Error: Could not find manifest blob" >&2
        return 1
    fi

    # Extract layers in order
    echo "Extracting layers..." >&2
    local layers
    layers=$(jq -r '.layers[].digest' "$manifest_path" | sed 's/sha256://')

    while IFS= read -r layer_digest; do
        local layer_path="$oci_dir/blobs/sha256/$layer_digest"
        if [[ -f "$layer_path" ]]; then
            # Detect compression and extract
            local file_type
            file_type=$(file -b "$layer_path")

            case "$file_type" in
                *gzip*)
                    tar -xzf "$layer_path" -C "$rootfs_dir" 2>/dev/null || { echo "WARNING: failed to extract layer $layer_path — diff may be incomplete" >&2; ((extract_failures++)) || true; }
                    ;;
                *zstd*|*Zstandard*)
                    tar --zstd -xf "$layer_path" -C "$rootfs_dir" 2>/dev/null || { echo "WARNING: failed to extract layer $layer_path — diff may be incomplete" >&2; ((extract_failures++)) || true; }
                    ;;
                *xz*)
                    tar -xJf "$layer_path" -C "$rootfs_dir" 2>/dev/null || { echo "WARNING: failed to extract layer $layer_path — diff may be incomplete" >&2; ((extract_failures++)) || true; }
                    ;;
                *bzip2*)
                    tar -xjf "$layer_path" -C "$rootfs_dir" 2>/dev/null || { echo "WARNING: failed to extract layer $layer_path — diff may be incomplete" >&2; ((extract_failures++)) || true; }
                    ;;
                POSIX\ tar*)
                    tar -xf "$layer_path" -C "$rootfs_dir" 2>/dev/null || { echo "WARNING: failed to extract layer $layer_path — diff may be incomplete" >&2; ((extract_failures++)) || true; }
                    ;;
                *)
                    # Try auto-detection
                    tar -xf "$layer_path" -C "$rootfs_dir" 2>/dev/null || { echo "WARNING: failed to extract layer $layer_path — diff may be incomplete" >&2; ((extract_failures++)) || true; }
                    ;;
            esac
        fi
    done <<< "$layers"

    if (( extract_failures > 0 )); then
        echo "WARNING: $extract_failures layer(s) failed to extract for $image_ref — the comparison below may be incomplete" >&2
    fi

    # Handle whiteout files (OCI layer deletion markers)
    find "$rootfs_dir" -name ".wh.*" 2>/dev/null | while read -r whiteout; do
        local dir
        dir=$(dirname "$whiteout")
        local name
        name=$(basename "$whiteout" | sed 's/^\.wh\.//')

        if [[ "$name" == ".wh..opq" ]]; then
            # Opaque whiteout - directory contents should be hidden
            # For comparison purposes, we just remove the marker
            rm -f "$whiteout"
        else
            # Regular whiteout - remove the target file
            rm -rf "${dir:?}/${name}" 2>/dev/null || true
            rm -f "$whiteout"
        fi
    done

    # Clean up OCI blobs to save space before comparison
    rm -rf "$oci_dir"

    echo "$rootfs_dir"
}

# ============================================================================
# Main entry point
# ============================================================================
main() {
    parse_args "$@"
    check_dependencies

    echo "" >&2
    echo "OCI Image Comparison Tool (using diffoscope)" >&2
    echo "=============================================" >&2
    echo "" >&2
    echo "IMAGE1: $IMAGE1" >&2
    echo "IMAGE2: $IMAGE2" >&2

    # Create temporary directory (use custom base if specified)
    if [[ -n "$TMPDIR_BASE" ]]; then
        if [[ ! -d "$TMPDIR_BASE" ]]; then
            echo "Error: Temp directory does not exist: $TMPDIR_BASE" >&2
            exit 1
        fi
        TMPDIR=$(mktemp -d -p "$TMPDIR_BASE" compare-images.XXXXXX)
    else
        TMPDIR=$(mktemp -d -t compare-images.XXXXXX)
    fi
    # Export TMPDIR so diffoscope and other tools use it for temp files
    export TMPDIR
    echo "" >&2
    echo "Working directory: $TMPDIR" >&2

    # Extract both images
    echo "" >&2
    echo "Extracting IMAGE1..." >&2
    local rootfs1
    rootfs1=$(extract_image "$IMAGE1" "$TMPDIR/image1")

    echo "" >&2
    echo "Extracting IMAGE2..." >&2
    local rootfs2
    rootfs2=$(extract_image "$IMAGE2" "$TMPDIR/image2")

    # Build diffoscope command
    local diffoscope_cmd=(diffoscope)

    # Add output format
    case "$OUTPUT_FORMAT" in
        html)
            if [[ -n "$OUTPUT_FILE" ]]; then
                diffoscope_cmd+=("--html" "$OUTPUT_FILE")
            else
                diffoscope_cmd+=("--html" "-")
            fi
            ;;
        json)
            if [[ -n "$OUTPUT_FILE" ]]; then
                diffoscope_cmd+=("--json" "$OUTPUT_FILE")
            else
                diffoscope_cmd+=("--json" "-")
            fi
            ;;
        markdown)
            if [[ -n "$OUTPUT_FILE" ]]; then
                diffoscope_cmd+=("--markdown" "$OUTPUT_FILE")
            else
                diffoscope_cmd+=("--markdown" "-")
            fi
            ;;
        text|*)
            if [[ -n "$OUTPUT_FILE" ]]; then
                diffoscope_cmd+=("--text" "$OUTPUT_FILE")
            fi
            # Default is text to stdout, no flag needed
            ;;
    esac

    # Add any additional arguments
    if [[ ${#DIFFOSCOPE_ARGS[@]} -gt 0 ]]; then
        diffoscope_cmd+=("${DIFFOSCOPE_ARGS[@]}")
    fi

    # Add the directories to compare
    diffoscope_cmd+=("$rootfs1" "$rootfs2")

    # Run diffoscope
    echo "" >&2
    echo "Running diffoscope comparison..." >&2
    echo "Command: ${diffoscope_cmd[*]}" >&2
    echo "" >&2

    # diffoscope returns 0 if identical, 1 if different, other codes for errors
    # We don't want to exit on difference, so we capture the return code
    local ret=0
    "${diffoscope_cmd[@]}" || ret=$?

    echo "" >&2
    if [[ $ret -eq 0 ]]; then
        echo "Images are identical!" >&2
    elif [[ $ret -eq 1 ]]; then
        echo "Comparison complete. Differences found." >&2
    else
        echo "diffoscope exited with code $ret" >&2
    fi

    return $ret
}

main "$@"
