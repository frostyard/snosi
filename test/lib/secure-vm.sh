#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Secure OVMF and TPM lifecycle helpers for feasibility gates.

SECURE_VM_OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.secboot.fd
SECURE_VM_OVMF_VARS=/usr/share/OVMF/OVMF_VARS_4M.ms.fd
SECURE_VM_SWTPM_PID=""
SECURE_VM_TPM_SOCK=""

secure_vm_require_files() { # code vars mok-cert
    local code=$1 vars=$2 cert=$3
    [[ -f "$code" && -f "$vars" && -f "$cert" ]] || {
        echo "Error: Secure OVMF code, Microsoft-enrolled vars, and MOK certificate are required" >&2
        return 1
    }
}

secure_vm_prepare_ovmf() { # workdir
    local workdir=$1
    [[ -f "$SECURE_VM_OVMF_CODE" && -f "$SECURE_VM_OVMF_VARS" ]] || return 1
    cp "$SECURE_VM_OVMF_CODE" "$workdir/OVMF_CODE.fd"
    cp "$SECURE_VM_OVMF_VARS" "$workdir/OVMF_VARS.fd"
}

secure_vm_enroll_mok() { # vars mok-cert
    local vars=$1 cert=$2 guid
    [[ -f "$vars" && -f "$cert" ]] || return 1
    guid="$(python3 -c 'import uuid; print(uuid.uuid4())')"
    virt-fw-vars --inplace "$vars" --add-mok "$guid" "$cert"
}

secure_vm_start_swtpm_paths() { # state-dir socket-path pid-path
    local state_dir=$1 socket=$2 pid_file=$3 i=0
    mkdir -p "$state_dir" "$(dirname "$socket")" "$(dirname "$pid_file")"
    rm -f "$socket" "$pid_file"
    swtpm socket --tpm2 --tpmstate "dir=$state_dir" \
        --ctrl "type=unixio,path=$socket" \
        --pid "file=$pid_file" \
        --log "file=$state_dir/swtpm.log,level=1" -d
    while [[ ! -S "$socket" ]] && (( i++ < 50 )); do sleep 0.2; done
    [[ -S "$socket" ]] || return 1
    SECURE_VM_SWTPM_PID="$(<"$pid_file")"
    # shellcheck disable=SC2034 # consumed by the sourcing QEMU harness.
    SECURE_VM_TPM_SOCK="$socket"
}

secure_vm_start_swtpm() { # workdir; backwards-compatible conventional paths
    local workdir=$1
    secure_vm_start_swtpm_paths "$workdir/tpm" "$workdir/tpm/swtpm-ctrl.sock" "$workdir/tpm/swtpm.pid"
}

secure_vm_stop_owned_process() { # owned pid; never clears caller ownership
    local pid=$1 i=0
    [[ $pid =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 0
    kill -TERM "$pid" 2>/dev/null || return 1
    while kill -0 "$pid" 2>/dev/null && ((i++ < 25)); do sleep 0.2; done
    if kill -0 "$pid" 2>/dev/null; then
        kill -KILL "$pid" 2>/dev/null || return 1
        i=0
        while kill -0 "$pid" 2>/dev/null && ((i++ < 25)); do sleep 0.2; done
    fi
    ! kill -0 "$pid" 2>/dev/null
}

secure_vm_stop_swtpm() {
    [[ -z "$SECURE_VM_SWTPM_PID" ]] && return 0
    secure_vm_stop_owned_process "$SECURE_VM_SWTPM_PID" || return 1
    SECURE_VM_SWTPM_PID=""
    # shellcheck disable=SC2034 # Consumed by sourcing QEMU harnesses.
    SECURE_VM_TPM_SOCK=""
}
