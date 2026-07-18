#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# VM lifecycle and image management library for bootc testing.
# Provides image loading, bootc installation, QEMU VM control, and disk helpers.
# Sourced by test scripts; not executed directly.
set -euo pipefail

# Resolve project root relative to this library file.
_VM_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$_VM_LIB_DIR/../.." && pwd)"

DISK_SIZE="${DISK_SIZE:-10G}"
VM_MEMORY="${VM_MEMORY:-4096}"
VM_CPUS="${VM_CPUS:-2}"
SSH_PORT="${SSH_PORT:-2222}"
QEMU_PID="${QEMU_PID:-}"
QEMU_CONSOLE_LOG="${QEMU_CONSOLE_LOG:-}"
DISK_IMAGE="${DISK_IMAGE:-}"

# Determine whether a string looks like a registry reference (contains / but is not a local path).
is_registry_ref() {
    local ref="$1"
    # If the path exists on disk, it is not a registry ref
    [[ ! -e "$ref" ]] && [[ "$ref" == */* ]]
}

# load_image - Load an image into podman storage.
# Usage: load_image <rootfs-directory-or-registry-ref> <local-image-ref>
#
# If the input is a registry ref, pulls it and sets IMAGE_REF to the ref.
# If the input is a local rootfs directory, packages it via buildah and
# tags it as <local-image-ref>.
#
# Sets IMAGE_REF to the podman-resolvable image reference on success.
load_image() {
    local input="$1"
    local local_ref="${2:-localhost/snosi:latest}"

    if is_registry_ref "$input"; then
        IMAGE_REF="$input"
        echo "Pulling registry image: $IMAGE_REF"
        podman pull "$IMAGE_REF"
    else
        # Local rootfs directory
        [[ -e "$input" ]] || { echo "Error: Path does not exist: $input" >&2; exit 1; }
        [[ -d "$input" ]] || { echo "Error: $input is not a directory" >&2; exit 1; }

        IMAGE_REF="$local_ref"

        # Package rootfs directory into OCI image using buildah.
        # Uses mount + cp -a + commit to preserve SUID/SGID, xattrs, capabilities.
        "$PROJECT_ROOT/shared/outformat/image/buildah-package.sh" \
            "$input" "$IMAGE_REF"

        echo "Image loaded as: $IMAGE_REF"
    fi
}

# install_to_disk - Install a podman image to a raw disk via bootc.
# Usage: install_to_disk <disk-path> [extra-podman-args...] [-- extra-bootc-args...]
#
# Runs bootc install to-disk inside a privileged podman container.
# The disk image must already exist (see create_disk).
# Requires IMAGE_REF to be set (via load_image).
#
# Extra arguments before "--" are passed to `podman run`.
# Extra arguments after "--" are passed to `bootc install to-disk`.
#
# Example:
#   install_to_disk /tmp/disk.raw \
#       -v "${SSH_KEY}.pub:/run/ssh-key.pub:ro" \
#       -- --root-ssh-authorized-keys /run/ssh-key.pub
install_to_disk() {
    local disk_path="$1"
    shift

    [[ -n "${IMAGE_REF:-}" ]] || { echo "Error: IMAGE_REF is not set; call load_image first" >&2; exit 1; }
    [[ -f "$disk_path" ]] || { echo "Error: Disk image not found: $disk_path (call create_disk first)" >&2; exit 1; }

    # Split remaining args at "--" into podman extras and bootc extras
    local -a podman_extra=()
    local -a bootc_extra=()
    local past_separator=false
    for arg in "$@"; do
        if [[ "$arg" == "--" ]]; then
            past_separator=true
            continue
        fi
        if $past_separator; then
            bootc_extra+=("$arg")
        else
            podman_extra+=("$arg")
        fi
    done

    local disk_dir
    disk_dir="$(dirname "$disk_path")"
    local disk_name
    disk_name="$(basename "$disk_path")"

    # Install image to disk via bootc
    podman run --rm --privileged --pid=host \
        -v /var/lib/containers:/var/lib/containers \
        -v /dev:/dev \
        -v "$disk_dir:/work" \
        "${podman_extra[@]+"${podman_extra[@]}"}" \
        --security-opt label=type:unconfined_t \
        "$IMAGE_REF" \
        bootc install to-disk \
        --generic-image \
        --via-loopback \
        --skip-fetch-check \
        --composefs-backend \
        --filesystem btrfs \
        --karg console=ttyS0 \
        "${bootc_extra[@]+"${bootc_extra[@]}"}" \
        "/work/$disk_name"

    echo "Installation complete"
}

create_disk() {
    local path="$1"
    truncate -s "$DISK_SIZE" "$path"
    DISK_IMAGE="$path"
    echo "Created disk image: $path ($DISK_SIZE)"
}

# Find OVMF firmware. Prints "CODE_PATH VARS_PATH" to stdout.
find_ovmf() {
    # Each entry is "code_path:vars_path"
    local pairs=(
        "/usr/incus/share/qemu/OVMF_CODE.4MB.fd:/usr/incus/share/qemu/OVMF_VARS.4MB.fd"
        "/usr/share/OVMF/OVMF_CODE_4M.fd:/usr/share/OVMF/OVMF_VARS_4M.fd"
        "/usr/share/OVMF/OVMF_CODE.fd:/usr/share/OVMF/OVMF_VARS.fd"
        "/usr/share/edk2/ovmf/OVMF_CODE.fd:/usr/share/edk2/ovmf/OVMF_VARS.fd"
        "/usr/share/qemu/OVMF_CODE.fd:/usr/share/qemu/OVMF_VARS.fd"
        "/usr/share/edk2-ovmf/x64/OVMF_CODE.fd:/usr/share/edk2-ovmf/x64/OVMF_VARS.fd"
    )
    for pair in "${pairs[@]}"; do
        local code="${pair%%:*}"
        local vars="${pair##*:}"
        if [[ -f "$code" && -f "$vars" ]]; then
            echo "$code $vars"
            return 0
        fi
    done
    echo "Error: OVMF firmware (CODE+VARS) not found" >&2
    return 1
}

vm_start() {
    local disk="${1:-$DISK_IMAGE}"
    [[ -n "$disk" ]] || { echo "Error: No disk image specified" >&2; return 1; }
    [[ -f "$disk" ]] || { echo "Error: Disk image not found: $disk" >&2; return 1; }

    local ovmf_pair
    ovmf_pair=$(find_ovmf)
    local ovmf_code_src="${ovmf_pair%% *}"
    local ovmf_vars_src="${ovmf_pair##* }"

    # Copy firmware next to the disk image so QEMU can always access it
    # (source may be in a restricted directory like /usr/incus/)
    # VARS must be writable — UEFI stores boot variables there
    local workdir="${disk%/*}"
    local ovmf_code="$workdir/OVMF_CODE.fd"
    local ovmf_vars="$workdir/OVMF_VARS.fd"
    cp "$ovmf_code_src" "$ovmf_code"
    cp "$ovmf_vars_src" "$ovmf_vars"

    local pidfile="${disk%.raw}.pid"
    local consolelog="${disk%.raw}-console.log"

    # virtio-gpu-pci: GDM (desktop images) needs a DRM node to bind to even
    # with -display none, or systemctl is-system-running reports "degraded".
    qemu-system-x86_64 \
        -machine q35 \
        -enable-kvm -cpu host \
        -m "$VM_MEMORY" -smp "$VM_CPUS" \
        -drive "if=pflash,format=raw,unit=0,file=$ovmf_code,readonly=on" \
        -drive "if=pflash,format=raw,unit=1,file=$ovmf_vars" \
        -drive "file=$disk,format=raw,if=virtio" \
        -netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22" \
        -device virtio-net-pci,netdev=net0 \
        -device virtio-gpu-pci \
        -display none \
        -monitor none \
        -chardev "file,id=serial0,path=$consolelog" \
        -serial chardev:serial0 \
        -pidfile "$pidfile" \
        -daemonize

    QEMU_PID=$(cat "$pidfile")
    QEMU_CONSOLE_LOG="$consolelog"
    echo "VM started (PID: $QEMU_PID, SSH port: $SSH_PORT)"
    echo "Console log: $consolelog"
}

vm_stop() {
    if [[ -n "$QEMU_PID" ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
        kill "$QEMU_PID"
        # Wait for QEMU to exit
        local i=0
        while kill -0 "$QEMU_PID" 2>/dev/null && (( i++ < 10 )); do
            sleep 0.5
        done
        echo "VM stopped (PID: $QEMU_PID)"
    else
        echo "VM is not running"
    fi
    QEMU_PID=""
}

vm_cleanup() {
    vm_stop
    if [[ -n "$DISK_IMAGE" && -f "$DISK_IMAGE" ]]; then
        rm -f "$DISK_IMAGE"
        echo "Removed disk image: $DISK_IMAGE"
    fi
    DISK_IMAGE=""
}
