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
    quay.io/coreos/chunkah@sha256:faa8209f267fd1b384f3f4008a27ac0603333aab0d206bb146faf326282c64b4 \
    build --prune /sysroot/ --max-layers $MAX_LAYERS \
    --label ostree.commit- --label ostree.final-diffid- | podman load)

echo "$LOADED"

# Parse the loaded image reference
NEW_REF=$(echo "$LOADED" | grep -oP '(?<=Loaded image: ).*' || \
          echo "$LOADED" | grep -oP '(?<=Loaded image\(s\): ).*')

if [ -n "$NEW_REF" ] && [ "$NEW_REF" != "$IMAGE_REF" ]; then
    echo "==> Retagging chunked image to $IMAGE_REF..."
    podman tag "$NEW_REF" "$IMAGE_REF"
fi
