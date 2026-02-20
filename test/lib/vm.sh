#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# QEMU VM lifecycle library for bootc install testing.
# Sourced by test scripts; not executed directly.
set -euo pipefail

DISK_SIZE="${DISK_SIZE:-10G}"
VM_MEMORY="${VM_MEMORY:-4096}"
VM_CPUS="${VM_CPUS:-2}"
SSH_PORT="${SSH_PORT:-2222}"
QEMU_PID="${QEMU_PID:-}"
DISK_IMAGE="${DISK_IMAGE:-}"

create_disk() {
    local path="$1"
    truncate -s "$DISK_SIZE" "$path"
    DISK_IMAGE="$path"
    echo "Created disk image: $path ($DISK_SIZE)"
}

find_ovmf() {
    local paths=(
        /usr/share/OVMF/OVMF_CODE.fd
        /usr/share/edk2/ovmf/OVMF_CODE.fd
        /usr/share/qemu/OVMF_CODE.fd
        /usr/share/edk2-ovmf/x64/OVMF_CODE.fd
    )
    for p in "${paths[@]}"; do
        if [[ -f "$p" ]]; then
            echo "$p"
            return 0
        fi
    done
    echo "Error: OVMF firmware not found" >&2
    return 1
}

vm_start() {
    local disk="${1:-$DISK_IMAGE}"
    [[ -n "$disk" ]] || { echo "Error: No disk image specified" >&2; return 1; }
    [[ -f "$disk" ]] || { echo "Error: Disk image not found: $disk" >&2; return 1; }

    local ovmf
    ovmf=$(find_ovmf)

    local pidfile="/tmp/qemu-test.pid"

    qemu-system-x86_64 \
        -enable-kvm -cpu host \
        -m "$VM_MEMORY" -smp "$VM_CPUS" \
        -bios "$ovmf" \
        -drive "file=$disk,format=raw,if=virtio" \
        -netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22" \
        -device virtio-net-pci,netdev=net0 \
        -nographic -serial mon:stdio \
        -daemonize -pidfile "$pidfile"

    QEMU_PID=$(cat "$pidfile")
    echo "VM started (PID: $QEMU_PID, SSH port: $SSH_PORT)"
}

vm_stop() {
    if [[ -n "$QEMU_PID" ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
        kill "$QEMU_PID"
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
