#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Main orchestrator for bootc install integration tests.
# Loads an OCI image, installs it to a virtual disk via bootc, boots a QEMU VM,
# and runs tiered test scripts over SSH.
#
# Usage: ./test/bootc-install-test.sh <oci-image-path-or-registry-ref>
#
# Examples:
#   ./test/bootc-install-test.sh output/snow              # OCI directory from mkosi
#   ./test/bootc-install-test.sh ghcr.io/frostyard/snow:latest  # registry ref
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source helper libraries
# shellcheck source=test/lib/ssh.sh
source "$SCRIPT_DIR/lib/ssh.sh"
# shellcheck source=test/lib/vm.sh
source "$SCRIPT_DIR/lib/vm.sh"

# Environment variable defaults
: "${DISK_SIZE:=10G}"
: "${VM_MEMORY:=4096}"
: "${VM_CPUS:=2}"
: "${SSH_PORT:=2222}"
: "${SSH_TIMEOUT:=300}"
: "${BOOT_TIMEOUT:=300}"

# Internal state
WORK_DIR=""
IMAGE_LOADED=""     # non-empty if we loaded an image into podman
IMAGE_REF=""        # the podman-resolvable image reference

usage() {
    echo "Usage: $0 <oci-image-path-or-registry-ref>" >&2
    echo "" >&2
    echo "  oci-image-path    Local OCI directory or archive (e.g. output/snow)" >&2
    echo "  registry-ref      Container registry reference (e.g. ghcr.io/frostyard/snow:latest)" >&2
    exit 1
}

# shellcheck disable=SC2329
cleanup() {
    echo ""
    echo "=== Cleanup ==="

    # Stop VM and remove disk
    vm_cleanup

    # Remove loaded podman image if we loaded one
    if [[ -n "$IMAGE_LOADED" ]]; then
        echo "Removing loaded image: $IMAGE_LOADED"
        podman rmi -f "$IMAGE_LOADED" 2>/dev/null || true
    fi

    # Remove temp directory
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf "$WORK_DIR"
        echo "Removed temp directory: $WORK_DIR"
    fi
}

# Determine whether a string looks like a registry reference (contains / but is not a local path).
is_registry_ref() {
    local ref="$1"
    # If the path exists on disk, it is not a registry ref
    [[ ! -e "$ref" ]] && [[ "$ref" == */* ]]
}

# --- Argument parsing ---
[[ $# -eq 1 ]] || usage
INPUT="$1"

trap cleanup EXIT

# Create a working temp directory
WORK_DIR=$(mktemp -d)
echo "Temp directory: $WORK_DIR"

# ---------------------------------------------------------------
# Step 1 - LOAD: Get the image into podman storage
# ---------------------------------------------------------------
echo ""
echo "=== Step 1: Load image ==="

if podman image exists "$INPUT" 2>/dev/null; then
    # Local podman image (e.g., "snow" or "localhost/snow:latest")
    IMAGE_REF="$INPUT"
    echo "Using local image: $IMAGE_REF"
elif is_registry_ref "$INPUT"; then
    IMAGE_REF="$INPUT"
    echo "Pulling registry image: $IMAGE_REF"
    podman pull "$IMAGE_REF"
elif [[ -f "$INPUT" ]]; then
    # OCI archive file
    local_ref="localhost/snosi-test:latest"
    echo "Loading OCI archive: $INPUT"
    skopeo copy "oci-archive:$INPUT" "containers-storage:$local_ref"
    IMAGE_REF="$local_ref"
    IMAGE_LOADED="$IMAGE_REF"
    echo "Image loaded as: $IMAGE_REF"
else
    echo "Error: $INPUT is not a local image, registry ref, or archive file" >&2
    exit 1
fi

# ---------------------------------------------------------------
# Step 2 - Generate SSH keypair
# ---------------------------------------------------------------
echo ""
echo "=== Step 2: Generate SSH keypair ==="
ssh_keygen "$WORK_DIR"

# ---------------------------------------------------------------
# Step 3 - Create sparse disk image
# ---------------------------------------------------------------
echo ""
echo "=== Step 3: Create disk image ==="
create_disk "$WORK_DIR/disk.raw"

# ---------------------------------------------------------------
# Step 4 - INSTALL: Run bootc install to-disk via podman
# ---------------------------------------------------------------
echo ""
echo "=== Step 4: Install image to disk ==="
podman run --rm --privileged --pid=host \
    -v /var/lib/containers:/var/lib/containers \
    -v /dev:/dev \
    -v "$WORK_DIR:/work" \
    -v "${SSH_KEY}.pub:/run/ssh-key.pub:ro" \
    --security-opt label=type:unconfined_t \
    "$IMAGE_REF" \
    bootc install to-disk \
        --generic-image \
        --via-loopback \
        --skip-fetch-check \
        --composefs-backend \
        --filesystem btrfs \
        --karg console=ttyS0 \
        --root-ssh-authorized-keys /run/ssh-key.pub \
        /work/disk.raw

echo "Installation complete"

# ---------------------------------------------------------------
# Step 4b - Inject SSH key into installed disk
# ---------------------------------------------------------------
echo ""
echo "=== Step 4b: Inject SSH key ==="
loop=$(losetup --find --show --partscan "$WORK_DIR/disk.raw")
mkdir -p "$WORK_DIR/mnt"
mount "${loop}p3" "$WORK_DIR/mnt"

# Inject SSH key into the composefs state directory.
# composefs-backend layout: state/os/default/var/ maps to /var at runtime,
# and /root is a symlink to /var/roothome.
# bootc's --root-ssh-authorized-keys doesn't work with composefs-backend yet.
ssh_dir="$WORK_DIR/mnt/state/os/default/var/roothome/.ssh"
mkdir -p "$ssh_dir"
cp "${SSH_KEY}.pub" "$ssh_dir/authorized_keys"
chmod 700 "$ssh_dir"
chmod 600 "$ssh_dir/authorized_keys"
echo "Injected SSH key into disk"

umount "$WORK_DIR/mnt"
losetup -d "$loop"

# ---------------------------------------------------------------
# Step 5 - Boot VM
# ---------------------------------------------------------------
echo ""
echo "=== Step 5: Boot VM ==="
vm_start "$DISK_IMAGE"

# ---------------------------------------------------------------
# Step 6 - Wait for SSH
# ---------------------------------------------------------------
echo ""
echo "=== Step 6: Wait for SSH ==="
wait_for_ssh

# ---------------------------------------------------------------
# Step 7 - Run test tiers
# ---------------------------------------------------------------
echo ""
echo "=== Step 7: Run tests ==="

declare -a test_names=()
declare -a test_results=()

for test_script in "$SCRIPT_DIR"/tests/*.sh; do
    [[ -f "$test_script" ]] || continue
    test_name="$(basename "$test_script")"
    test_names+=("$test_name")

    echo ""
    echo "--- Running: $test_name ---"

    # Copy test script to VM
    scp "${SSH_OPTS[@]}" -i "$SSH_KEY" -P "$SSH_PORT" "$test_script" root@localhost:/tmp/"$test_name"

    # Execute test script and capture exit code
    set +e
    vm_ssh "bash /tmp/$test_name"
    rc=$?
    set -e

    test_results+=("$rc")

    if [[ "$rc" -eq 0 ]]; then
        echo "--- $test_name: PASSED ---"
    else
        echo "--- $test_name: FAILED ($rc failures) ---"
    fi
done

# ---------------------------------------------------------------
# Step 8 - Summary
# ---------------------------------------------------------------
echo ""
echo "========================================"
echo "           TEST SUMMARY"
echo "========================================"

overall=0
for i in "${!test_names[@]}"; do
    name="${test_names[$i]}"
    rc="${test_results[$i]}"
    if [[ "$rc" -eq 0 ]]; then
        status="PASS"
    else
        status="FAIL"
        overall=1
    fi
    printf "  %-30s %s\n" "$name" "$status"
done

echo "========================================"
if [[ "$overall" -eq 0 ]]; then
    echo "All tiers passed."
else
    echo "Some tiers failed."
fi

exit "$overall"
