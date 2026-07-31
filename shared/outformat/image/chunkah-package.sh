#!/bin/bash
set -euo pipefail

CHUNKAH_IMAGE='quay.io/coreos/chunkah@sha256:fdff3175bfb41e111089392ef8a41b46a10766c7b2ec454ba1272a0c39ce3bf3'

chunk_image() { # image-ref source-date-epoch [max-layers]
    local image_ref=$1 source_date_epoch=$2 max_layers=${3:-128}
    local config loaded new_ref
    [[ $source_date_epoch =~ ^[0-9]+$ ]] || {
        echo "Error: SOURCE_DATE_EPOCH must be a non-negative integer" >&2
        return 1
    }
    [[ $max_layers =~ ^[1-9][0-9]*$ ]] || {
        echo "Error: MAX_LAYERS must be a positive integer" >&2
        return 1
    }

    config=$(podman inspect "$image_ref")
    if ! loaded=$(podman run --rm \
        --security-opt label=type:unconfined_t \
        --mount=type=image,src="$image_ref",dst=/chunkah \
        -e "CHUNKAH_CONFIG_STR=$config" \
        -e "SOURCE_DATE_EPOCH=$source_date_epoch" \
        "$CHUNKAH_IMAGE" \
        build --prune /sysroot/ --max-layers "$max_layers" \
        --label ostree.commit- --label ostree.final-diffid- | podman load); then
        echo "ERROR: chunkah or podman load failed" >&2
        return 1
    fi
    printf '%s\n' "$loaded"
    new_ref=$(grep -oP '(?<=Loaded image: ).*' <<<"$loaded" ||
        grep -oP '(?<=Loaded image\(s\): ).*' <<<"$loaded" || true)
    [[ -n $new_ref ]] || {
        echo "ERROR: could not parse loaded image ref from podman output above" >&2
        return 1
    }
    [[ $new_ref == "$image_ref" ]] || podman tag "$new_ref" "$image_ref"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    [[ $# -eq 2 ]] || {
        echo "Usage: $0 IMAGE_REF SOURCE_DATE_EPOCH" >&2
        exit 1
    }
    chunk_image "$1" "$2" "${MAX_LAYERS:-128}"
fi
