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
DPS_LOOP_DEVICE="${DPS_LOOP_DEVICE:-}"
DPS_CRYPT_NAME="${DPS_CRYPT_NAME:-bootc-dps-root-${BASHPID}}"
DPS_ROOT_MOUNT="${DPS_ROOT_MOUNT:-}"
IMAGE_POLICY="${IMAGE_POLICY:-}"
IMAGE_POLICY_HOME="${IMAGE_POLICY_HOME:-}"
IMAGE_IS_FIXTURE="${IMAGE_IS_FIXTURE:-0}"

create_registry_policy() {
    IMAGE_POLICY_HOME=$(mktemp -d)
    IMAGE_POLICY="$IMAGE_POLICY_HOME/.config/containers/policy.json"
    mkdir -p "$IMAGE_POLICY_HOME/.config/containers/registries.d"
    cat >"$IMAGE_POLICY" <<EOF
{
  "default": [{"type": "reject"}],
  "transports": {
    "docker": {
      "ghcr.io/frostyard/cayo": [{"type": "sigstoreSigned", "keyPath": "$PROJECT_ROOT/cosign.pub", "signedIdentity": {"type": "matchRepository"}}],
      "ghcr.io/frostyard/snow": [{"type": "sigstoreSigned", "keyPath": "$PROJECT_ROOT/cosign.pub", "signedIdentity": {"type": "matchRepository"}}],
      "ghcr.io/frostyard/snowfield": [{"type": "sigstoreSigned", "keyPath": "$PROJECT_ROOT/cosign.pub", "signedIdentity": {"type": "matchRepository"}}]
    },
    "containers-storage": {
      "": [{"type": "insecureAcceptAnything"}]
    }
  }
}
EOF
    cp "$PROJECT_ROOT/shared/bootc-secure/tree/etc/containers/registries.d/frostyard.yaml" \
        "$IMAGE_POLICY_HOME/.config/containers/registries.d/frostyard.yaml"
}

create_fixture_policy() {
    IMAGE_POLICY=$(mktemp)
    cat >"$IMAGE_POLICY" <<'EOF'
{"default": [{"type": "insecureAcceptAnything"}]}
EOF
}

# create_dps_luks_btrfs_root - prepare an externally managed bootc root.
# Usage: create_dps_luks_btrfs_root <disk-path> <mount-path> <recovery-key>
#
# Creates the Task 2 feasibility layout: a 1 GiB ESP plus an x86-64 DPS root
# partition containing LUKS2 and Btrfs. The caller must later call
# destroy_dps_luks_btrfs_root before removing the disk.
create_dps_luks_btrfs_root() {
    local disk_path=$1 mount_path=$2 recovery_key=$3
    local esp root_part
    [[ -f "$disk_path" ]] || { echo "Error: disk image not found: $disk_path" >&2; return 1; }
    [[ -f "$recovery_key" ]] || { echo "Error: recovery key not found: $recovery_key" >&2; return 1; }

    DPS_LOOP_DEVICE=$(losetup --find --show --partscan "$disk_path")
    sfdisk "$DPS_LOOP_DEVICE" <<'EOF'
label: gpt
,1G,U
,,4f68bce3-e8cd-4db1-96e7-fbcaf984b709
EOF
    partprobe "$DPS_LOOP_DEVICE"
    udevadm settle
    esp="${DPS_LOOP_DEVICE}p1"
    root_part="${DPS_LOOP_DEVICE}p2"
    mkfs.vfat -F 32 "$esp"
    cryptsetup luksFormat --type luks2 --batch-mode --key-file "$recovery_key" "$root_part"
    cryptsetup open --key-file "$recovery_key" "$root_part" "$DPS_CRYPT_NAME"
    mkfs.btrfs --force "/dev/mapper/$DPS_CRYPT_NAME"
    mkdir -p "$mount_path"
    mount "/dev/mapper/$DPS_CRYPT_NAME" "$mount_path"
    mkdir -p "$mount_path/boot"
    mount "$esp" "$mount_path/boot"
    DPS_ROOT_MOUNT=$mount_path
}

destroy_dps_luks_btrfs_root() {
    local attempt status=0
    if [[ -n "$DPS_ROOT_MOUNT" ]]; then
        for attempt in 1 2 3; do
            if umount --recursive "$DPS_ROOT_MOUNT"; then
                break
            fi
            if (( attempt < 3 )); then
                sleep 0.1
            fi
        done
        mountpoint -q "$DPS_ROOT_MOUNT" && status=1
    fi
    if cryptsetup status "$DPS_CRYPT_NAME" >/dev/null 2>&1; then
        for attempt in 1 2 3; do
            if cryptsetup close "$DPS_CRYPT_NAME"; then
                break
            fi
            if (( attempt < 3 )); then
                sleep 0.1
            fi
        done
        cryptsetup status "$DPS_CRYPT_NAME" >/dev/null 2>&1 && status=1
    fi
    if [[ -n "$DPS_LOOP_DEVICE" ]]; then
        for attempt in 1 2 3; do
            if losetup --detach "$DPS_LOOP_DEVICE"; then
                break
            fi
            if (( attempt < 3 )); then
                sleep 0.1
            fi
        done
        losetup "$DPS_LOOP_DEVICE" >/dev/null 2>&1 && status=1
    fi
    if [[ $status -eq 0 ]]; then
        DPS_ROOT_MOUNT=""
        DPS_LOOP_DEVICE=""
    fi
    return "$status"
}

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
        IMAGE_IS_FIXTURE=0
        echo "Pulling registry image: $IMAGE_REF"
        create_registry_policy
        HOME="$IMAGE_POLICY_HOME" podman pull "$IMAGE_REF"
    else
        # Local rootfs directory
        [[ -e "$input" ]] || { echo "Error: Path does not exist: $input" >&2; exit 1; }
        [[ -d "$input" ]] || { echo "Error: $input is not a directory" >&2; exit 1; }

        IMAGE_REF="$local_ref"
        IMAGE_IS_FIXTURE=1
        # Rootfs fixtures are deliberately unsigned. Keep this exception in a
        # disposable test-only policy rather than weakening the secure image.
        create_fixture_policy

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

    local -a policy_mount=()
    local -a podman_env=()
    if [[ "$IMAGE_IS_FIXTURE" == "1" ]]; then
        policy_mount=(-v "$IMAGE_POLICY:/etc/containers/policy.json:ro")
    else
        podman_env=(HOME="$IMAGE_POLICY_HOME")
    fi

    # Install image to disk via bootc
    env "${podman_env[@]}" podman run --rm --privileged --pid=host \
        -v /var/lib/containers:/var/lib/containers \
        -v /dev:/dev \
        -v "$disk_dir:/work" \
        "${policy_mount[@]+"${policy_mount[@]}"}" \
        "${podman_extra[@]+"${podman_extra[@]}"}" \
        --security-opt label=type:unconfined_t \
        "$IMAGE_REF" \
        bootc install to-disk \
        --generic-image \
        --via-loopback \
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
    # -vga none is REQUIRED alongside it: without it QEMU also adds its
    # default stdvga, the guest gets TWO DRM cards (bochs card0 primary +
    # virtio card1), and plymouthd 24.004.60 SEGVs in its DRM renderer on
    # that layout (root-caused 2026-07-18 via guest journal: plymouth-start
    # "code=killed, status=11/SEGV" -> degraded -> smoke gate failure on
    # every desktop image). Same virtio-gpu + -vga none idiom as
    # test/native-ab-secure-boot-test.sh's vm_start_secure.
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
        -vga none \
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
    if [[ -n "$IMAGE_POLICY" && -f "$IMAGE_POLICY" ]]; then
        rm -f "$IMAGE_POLICY"
    fi
    if [[ -n "$IMAGE_POLICY_HOME" && -d "$IMAGE_POLICY_HOME" ]]; then
        rm -rf "$IMAGE_POLICY_HOME"
    fi
    IMAGE_POLICY=""
    IMAGE_POLICY_HOME=""
    IMAGE_IS_FIXTURE=0
}
