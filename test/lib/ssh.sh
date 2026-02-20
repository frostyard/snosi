#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# SSH helper library for bootc install testing.
# Provides keypair generation, remote command execution, and connectivity polling.
# This file is sourced by the test orchestrator — do not execute directly.
set -euo pipefail

# Defaults
: "${SSH_TIMEOUT:=300}"
: "${SSH_PORT:=2222}"

# Common SSH options: disable host key checking, suppress warnings, set timeout.
SSH_OPTS=(
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o ConnectTimeout=5
)

# ssh_keygen - Generate a temporary ED25519 keypair.
# Usage: ssh_keygen [directory]
# If directory is provided, the keypair is created there.
# Otherwise, a new temp directory is created (caller must clean up).
# Sets SSH_KEY to the private key path.
ssh_keygen() {
    local keydir="${1:-$(mktemp -d)}"
    SSH_KEY="$keydir/id_ed25519"
    ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -q
    echo "Generated SSH keypair: $SSH_KEY"
}

# vm_ssh - Execute a command on the VM via SSH.
# Usage: vm_ssh <command> [args...]
# Requires SSH_KEY to be set (via ssh_keygen).
vm_ssh() {
    [[ -n "${SSH_KEY:-}" ]] || { echo "Error: SSH_KEY is not set; call ssh_keygen first" >&2; return 1; }
    ssh "${SSH_OPTS[@]}" -p "$SSH_PORT" -i "$SSH_KEY" root@localhost "$@"
}

# wait_for_ssh - Poll until SSH is reachable or timeout expires.
# Uses SSH_PORT and SSH_TIMEOUT from the environment.
# Returns 0 on success, 1 on timeout.
wait_for_ssh() {
    [[ -n "${SSH_KEY:-}" ]] || { echo "Error: SSH_KEY is not set; call ssh_keygen first" >&2; return 1; }

    local deadline elapsed=0
    deadline=$((SECONDS + SSH_TIMEOUT))
    echo "Waiting up to ${SSH_TIMEOUT}s for SSH on port ${SSH_PORT}..."

    while (( SECONDS < deadline )); do
        if vm_ssh true 2>/dev/null; then
            elapsed=$((SECONDS - (deadline - SSH_TIMEOUT)))
            echo "SSH available after ${elapsed}s"
            return 0
        fi
        sleep 2
    done

    echo "Error: SSH not reachable after ${SSH_TIMEOUT}s" >&2
    if [[ -n "${QEMU_CONSOLE_LOG:-}" && -f "$QEMU_CONSOLE_LOG" ]]; then
        echo "=== Last 50 lines of VM console ===" >&2
        tail -50 "$QEMU_CONSOLE_LOG" >&2
    fi
    return 1
}
