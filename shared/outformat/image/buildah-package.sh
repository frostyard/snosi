#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Package a rootfs directory into an OCI container image using buildah.
#
# Uses buildah mount + cp -a + commit to preserve ALL file metadata:
# SUID/SGID bits, xattrs, file capabilities, ACLs, hardlinks, ownership.
# This bypasses buildah copy/COPY which has a known SUID-dropping bug.
#
# Usage: buildah-package.sh <rootfs-dir> <image-ref> [label=value ...]
#
# Examples:
#   buildah-package.sh output/snow localhost/snow:latest
#   buildah-package.sh output/snow ghcr.io/frostyard/snow:v1 \
#       org.opencontainers.image.version=v1 \
#       org.opencontainers.image.description="Snow Linux OS Image"
set -euo pipefail

ROOTFS_DIR="$1"
IMAGE_REF="$2"
shift 2

[[ -d "$ROOTFS_DIR" ]] || { echo "Error: rootfs directory does not exist: $ROOTFS_DIR" >&2; exit 1; }

probe_rootfs_bootc_version() ( # rootfs
    local root=$1 proc="$1/proc" mounted=0 output status

    # shellcheck disable=SC2329 # Invoked by the helper subshell's EXIT trap.
    cleanup_proc() {
        local exit_status=$?
        trap - EXIT
        if [[ $mounted -eq 1 ]] && ! umount "$proc"; then
            echo "Error: failed to unmount rootfs proc: $proc" >&2
            exit_status=1
        fi
        exit "$exit_status"
    }

    [[ -d $proc ]] || {
        echo "Error: rootfs proc directory is missing: $proc" >&2
        exit 1
    }
    if mountpoint -q "$proc"; then
        echo "Error: rootfs proc is already mounted: $proc" >&2
        exit 1
    fi

    trap cleanup_proc EXIT
    mount --bind /proc "$proc" || {
        echo "Error: failed to bind host proc into rootfs: $proc" >&2
        exit 1
    }
    mounted=1

    set +e
    output=$(chroot "$root" /usr/bin/bootc --version 2>&1)
    status=$?
    set -e
    if [[ $status -ne 0 ]]; then
        printf 'Error: rootfs bootc execution failed:\n%s\n' "$output" >&2
        exit 1
    fi
    [[ $output == 'bootc 1.16.3' ]] || {
        printf 'Error: expected bootc 1.16.3, observed %s\n' "$output" >&2
        exit 1
    }
)

secure_label="io.snosi.bootc.secureboot-capable=false"
secure_assembly_label=""
first_image=""
final_probe=""
final_image_committed=0
secure_complete=0
cleanup_secure() {
    local status=$?
    set +e
    [[ -z "$first_image" ]] || buildah rmi "$first_image" >/dev/null 2>&1
    [[ -z "$final_probe" ]] || buildah rmi "$final_probe" >/dev/null 2>&1
    [[ $secure_complete -eq 1 || $final_image_committed -eq 0 ]] || buildah rmi "$IMAGE_REF" >/dev/null 2>&1
    [[ $secure_complete -eq 1 ]] || "$ASSEMBLER" --remove-injected "$ROOTFS_DIR" >/dev/null 2>&1
    return "$status"
}
if [[ ${SNOSI_BOOTC_SECURE:-0} == 1 ]]; then
    : "${SNOSI_BOOTC_MOK_KEY:?SNOSI_BOOTC_MOK_KEY is required for secure assembly}"
    : "${SNOSI_BOOTC_MOK_CERT:?SNOSI_BOOTC_MOK_CERT is required for secure assembly}"
    : "${SNOSI_BOOTC_PCR_KEY:?SNOSI_BOOTC_PCR_KEY is required for secure assembly}"
    : "${SNOSI_BOOTC_PCR_CERT:?SNOSI_BOOTC_PCR_CERT is required for secure assembly}"
    ASSEMBLER="$(dirname "${BASH_SOURCE[0]}")/../../bootc-secure/assemble-uki.sh"
    case ${SNOSI_BOOTC_SECURE_TEST_HOOKS:-0} in
        0)
            [[ -z ${SNOSI_BOOTC_SECURE_TEST_ASSEMBLER:-} ]] || {
                echo "Error: secure test assembler requires SNOSI_BOOTC_SECURE_TEST_HOOKS=1" >&2; exit 1;
            }
            ;;
        1)
            : "${SNOSI_BOOTC_SECURE_TEST_ASSEMBLER:?secure test assembler is required when test hooks are enabled}"
            ASSEMBLER="$SNOSI_BOOTC_SECURE_TEST_ASSEMBLER"
            ;;
        *)
            echo "Error: SNOSI_BOOTC_SECURE_TEST_HOOKS must be 0 or 1" >&2; exit 1;
            ;;
    esac
    [[ -x "$ASSEMBLER" ]] || {
        echo "Error: bootc secure assembler is unavailable" >&2; exit 1;
    }
    probe_rootfs_bootc_version "$ROOTFS_DIR"
    trap cleanup_secure EXIT
    # The reconciler's signed source must be in the pristine first OCI pass:
    # adding it after the storage digest would change the composefs identity.
    "$ASSEMBLER" --prepare-systemd-boot-source "$ROOTFS_DIR" \
        "$SNOSI_BOOTC_MOK_KEY" "$SNOSI_BOOTC_MOK_CERT"
    first_image="localhost/snosi-bootc-secure-first-$$"
    SNOSI_BOOTC_SECURE=0 "$0" "$ROOTFS_DIR" "$first_image" "io.snosi.bootc.secureboot-capable=false"
    digest=$(podman run --rm --privileged --pid=host -v /var/lib/containers:/var/lib/containers \
        --security-opt label=type:unconfined_t "$first_image" \
        bootc container compute-composefs-digest-from-storage "$first_image" | tr -d '\n')
    [[ $digest =~ ^[[:xdigit:]]{128}$ ]] || { echo "Error: unsupported bootc storage-digest interface" >&2; exit 1; }
    SNOSI_BOOTC_SECURE_COMPOSEFS_DIGEST="$digest" SNOSI_BOOTC_SECURE_BOOTC_VERSION=1.16.3 \
        SNOSI_BOOTC_PREVIOUS_PCR_KEY="${SNOSI_BOOTC_PREVIOUS_PCR_KEY:-}" \
        "$ASSEMBLER" "$ROOTFS_DIR" \
        "$SNOSI_BOOTC_MOK_KEY" "$SNOSI_BOOTC_MOK_CERT" "$SNOSI_BOOTC_PCR_KEY" "$SNOSI_BOOTC_PCR_CERT" \
        "${SNOSI_BOOTC_PREVIOUS_PCR_CERT:-}"
    final_probe="localhost/snosi-bootc-secure-final-$$"
    SNOSI_BOOTC_SECURE=0 "$0" "$ROOTFS_DIR" "$final_probe" "io.snosi.bootc.secureboot-capable=false"
    final_digest=$(podman run --rm --privileged --pid=host -v /var/lib/containers:/var/lib/containers \
        --security-opt label=type:unconfined_t "$final_probe" \
        bootc container compute-composefs-digest-from-storage "$final_probe" | tr -d '\n')
    [[ "$digest" == "$final_digest" ]] || { echo "Error: secure injection changed OCI composefs digest" >&2; exit 1; }
    "$ASSEMBLER" --scan-image "$final_probe" "$SNOSI_BOOTC_MOK_KEY" "$SNOSI_BOOTC_PCR_KEY" \
        "${SNOSI_BOOTC_PREVIOUS_PCR_KEY:-}"
    secure_label="io.snosi.bootc.secureboot-capable=true"
    secure_assembly_label="io.snosi.bootc.secureboot-assembly=bootc-1.16.3-storage-digest-v1"
fi

echo "=== Packaging rootfs into OCI image ==="
echo "  rootfs: $ROOTFS_DIR"
echo "  image:  $IMAGE_REF"

# Create empty container
container=$(buildah from scratch)

# Mount and copy rootfs preserving all metadata
mountpoint=$(buildah mount "$container")
cp -a "$ROOTFS_DIR"/. "$mountpoint"/
buildah umount "$container"

# Apply standard bootc labels
buildah config \
    --label "containers.bootc=1" \
    --label "org.opencontainers.image.vendor=frostyard" \
    "$container"

# Apply additional labels passed as arguments
for label in "$@"; do
    buildah config --label "$label" "$container"
done

# Trusted labels are applied last so caller labels cannot downgrade or forge them.
buildah config --label "$secure_label" "$container"
[[ -z "$secure_assembly_label" ]] || buildah config --label "$secure_assembly_label" "$container"

# Commit to image
buildah commit "$container" "$IMAGE_REF"
buildah rm "$container"
final_image_committed=1
if [[ ${SNOSI_BOOTC_SECURE:-0} == 1 ]]; then
    published_digest=$(podman run --rm --privileged --pid=host -v /var/lib/containers:/var/lib/containers \
        --security-opt label=type:unconfined_t "$IMAGE_REF" \
        bootc container compute-composefs-digest-from-storage "$IMAGE_REF" | tr -d '\n')
    [[ "$digest" == "$published_digest" ]] || { echo "Error: committed secure OCI image changed composefs digest" >&2; exit 1; }
    "$ASSEMBLER" --scan-image "$IMAGE_REF" "$SNOSI_BOOTC_MOK_KEY" "$SNOSI_BOOTC_PCR_KEY" \
        "${SNOSI_BOOTC_PREVIOUS_PCR_KEY:-}"
fi
secure_complete=1

echo "=== Image packaged: $IMAGE_REF ==="
