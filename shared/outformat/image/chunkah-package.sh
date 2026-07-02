#!/bin/bash
set -euo pipefail

IMAGE_REF="$1"
SOURCE_DATE_EPOCH="$2"
MAX_LAYERS="${MAX_LAYERS:-128}"

echo "==> Chunkifying $IMAGE_REF (Max Layers: $MAX_LAYERS) - Date: $SOURCE_DATE_EPOCH"

# Get config from existing image
CONFIG=$(podman inspect "$IMAGE_REF")

# Run chunkah (default 64 layers) and pipe to podman load
# Uses --mount=type=image to expose the source image content to chunkah
# Note: We need --privileged for some podman-in-podman/mount scenarios or just standard access
LOADED=$(podman run --rm \
    --security-opt label=type:unconfined_t \
    --mount=type=image,src="$IMAGE_REF",dst=/chunkah \
    -e "CHUNKAH_CONFIG_STR=$CONFIG" \
    -e "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH" \
    quay.io/coreos/chunkah@sha256:fdff3175bfb41e111089392ef8a41b46a10766c7b2ec454ba1272a0c39ce3bf3 \
    build --prune /sysroot/ --max-layers "$MAX_LAYERS" \
    --label ostree.commit- --label ostree.final-diffid- | podman load)

echo "$LOADED"

# Parse the loaded image reference. The image is already loaded at this
# point, so a wording change in podman's output must not abort the script —
# fail loudly instead so the message format can be fixed.
NEW_REF=$(echo "$LOADED" | grep -oP '(?<=Loaded image: ).*' || \
          echo "$LOADED" | grep -oP '(?<=Loaded image\(s\): ).*' || true)
if [ -z "$NEW_REF" ]; then
    echo "ERROR: could not parse loaded image ref from podman output above" >&2
    exit 1
fi

if [ "$NEW_REF" != "$IMAGE_REF" ]; then
    echo "==> Retagging chunked image to $IMAGE_REF..."
    podman tag "$NEW_REF" "$IMAGE_REF"
fi
