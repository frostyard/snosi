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
QEMU_CONSOLE_LOG="${QEMU_CONSOLE_LOG:-}"
DISK_IMAGE="${DISK_IMAGE:-}"

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

    qemu-system-x86_64 \
        -machine q35 \
        -enable-kvm -cpu host \
        -m "$VM_MEMORY" -smp "$VM_CPUS" \
        -drive "if=pflash,format=raw,unit=0,file=$ovmf_code,readonly=on" \
        -drive "if=pflash,format=raw,unit=1,file=$ovmf_vars" \
        -drive "file=$disk,format=raw,if=virtio" \
        -netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22" \
        -device virtio-net-pci,netdev=net0 \
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
