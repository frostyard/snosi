#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Orchestrator for bootc update-sequence integration tests
# (docs/plans/2026-07-03-bootc-update-validation-plan.md, Phases 1-3).
#
# Installs <install-ref> to a virtual disk via bootc, boots it in QEMU,
# writes persistence markers, then for each <hop-ref> runs `bootc switch`
# in the guest, reboots, and verifies deployment digests plus the full
# persistence matrix.
#
# Usage: ./test/bootc-update-test.sh <install-ref> <hop-ref> [<hop-ref>...]
#
# Example:
#   sudo ./test/bootc-update-test.sh \
#       ghcr.io/frostyard/snow:20260702011235 \
#       ghcr.io/frostyard/snow:20260703151145
#
# Environment:
#   DISK_SIZE (default 20G — multiple deployments need headroom)
#   INJECT_HOSTKEYS=1  Pre-generate SSH host keys on the installed disk.
#                      Workaround for images published before the
#                      sshd-keygen fix (#343); harmless but unnecessary after.
#   KEEP_VM=1          Skip cleanup (leave VM running for inspection).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults must be set BEFORE sourcing lib/vm.sh — it snapshots DISK_SIZE
# with a 10G fallback at source time. Updates pull whole images into the
# guest's /var, so the default install-test size is far too small here.
: "${DISK_SIZE:=20G}"
: "${INJECT_HOSTKEYS:=0}"
: "${KEEP_VM:=0}"

# shellcheck source=test/lib/ssh.sh
source "$SCRIPT_DIR/lib/ssh.sh"
# shellcheck source=test/lib/vm.sh
source "$SCRIPT_DIR/lib/vm.sh"

WORK_DIR=""

usage() {
    echo "Usage: $0 <install-ref> <hop-ref> [<hop-ref>...]" >&2
    echo "  Refs are registry references (e.g. ghcr.io/frostyard/snow:<tag>)." >&2
    exit 1
}

# shellcheck disable=SC2329
cleanup() {
    if [[ "$KEEP_VM" == "1" ]]; then
        echo "KEEP_VM=1: leaving VM (PID ${QEMU_PID:-?}) and $WORK_DIR in place"
        return
    fi
    echo ""
    echo "=== Cleanup ==="
    if [[ -n "$WORK_DIR" ]] && mountpoint -q "$WORK_DIR/mnt" 2>/dev/null; then
        umount "$WORK_DIR/mnt" || true
    fi
    if [[ -n "${loop:-}" ]]; then
        losetup -d "$loop" 2>/dev/null || true
    fi
    vm_cleanup
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]] && ! mountpoint -q "$WORK_DIR/mnt" 2>/dev/null; then
        rm -rf "$WORK_DIR"
        echo "Removed temp directory: $WORK_DIR"
    fi
}

# digest_of <registry-ref> - resolve a ref to its manifest digest (host-side,
# independent of the guest, so guest-reported digests are cross-checked).
digest_of() {
    skopeo inspect --format '{{.Digest}}' "docker://$1"
}

# guest_status_digest <staged|booted|rollback> - image digest of a deployment
# slot as reported by bootc inside the guest ("null" if the slot is empty).
guest_status_digest() {
    vm_ssh "bootc status --format json" | jq -r ".status.$1.image.imageDigest // \"null\""
}

# run_guest_script <local-path> - copy a script plus helpers into the guest
# and execute it. Returns the script's exit code.
run_guest_script() {
    local script="$1"
    local name
    name="$(basename "$script")"
    vm_ssh "mkdir -p /tmp/test-lib"
    scp "${SSH_OPTS[@]}" -i "$SSH_KEY" -P "$SSH_PORT" \
        "$SCRIPT_DIR/lib/helpers.sh" root@localhost:/tmp/test-lib/helpers.sh
    scp "${SSH_OPTS[@]}" -i "$SSH_KEY" -P "$SSH_PORT" \
        "$script" root@localhost:"/tmp/$name"
    vm_ssh "TEST_LIB_DIR=/tmp/test-lib bash /tmp/$name"
}

# reboot_guest - reboot the VM and wait for SSH to drop and come back.
# QEMU stays up across a guest reboot; only sshd goes away.
reboot_guest() {
    echo "Rebooting guest..."
    vm_ssh "systemctl reboot" || true
    # Wait for the old system to actually go down before polling for the new
    # one, otherwise wait_for_ssh can succeed against the pre-reboot sshd.
    local down_deadline=$((SECONDS + 120))
    while (( SECONDS < down_deadline )); do
        vm_ssh -o ConnectTimeout=2 true 2>/dev/null || break
        sleep 2
    done
    wait_for_ssh
}

# --- Argument parsing ---
[[ $# -ge 2 ]] || usage
INSTALL_REF="$1"
shift
HOP_REFS=("$@")

[[ $EUID -eq 0 ]] || { echo "Error: must run as root (bootc install needs the root user namespace)" >&2; exit 1; }

trap cleanup EXIT

# Real disk, not tmpfs: hop images are pulled into the guest's /var.
WORK_DIR=$(mktemp -d /var/tmp/bootc-update-test.XXXXXX)
echo "Temp directory: $WORK_DIR"

# ---------------------------------------------------------------
echo ""
echo "=== Step 1: Pull and install $INSTALL_REF ==="
load_image "$INSTALL_REF"
ssh_keygen "$WORK_DIR"
create_disk "$WORK_DIR/disk.raw"
install_to_disk "$WORK_DIR/disk.raw"

# ---------------------------------------------------------------
echo ""
echo "=== Step 2: Inject SSH access ==="
loop=$(losetup --find --show --partscan "$WORK_DIR/disk.raw")
mkdir -p "$WORK_DIR/mnt"
mount "${loop}p3" "$WORK_DIR/mnt"

ssh_dir="$WORK_DIR/mnt/state/os/default/var/roothome/.ssh"
mkdir -p "$ssh_dir"
cp "${SSH_KEY}.pub" "$ssh_dir/authorized_keys"
chmod 700 "$ssh_dir"
chmod 600 "$ssh_dir/authorized_keys"

if [[ "$INJECT_HOSTKEYS" == "1" ]]; then
    # Pre-#343 images never generate host keys (sshd-keygen is gated on
    # ConditionFirstBoot, which empty machine-id never satisfies).
    deploy_dir=$(find "$WORK_DIR/mnt/state/deploy" -mindepth 1 -maxdepth 1 -type d | head -1)
    ssh-keygen -A -f "$deploy_dir"
    echo "Injected SSH host keys into $deploy_dir/etc/ssh"
fi

umount "$WORK_DIR/mnt"
losetup -d "$loop"
loop=""

# ---------------------------------------------------------------
echo ""
echo "=== Step 3: Boot and baseline ==="
vm_start "$DISK_IMAGE"
wait_for_ssh

install_digest=$(digest_of "$INSTALL_REF")
booted=$(guest_status_digest booted)
echo "Installed: $INSTALL_REF"
echo "  expected digest: $install_digest"
echo "  booted digest:   $booted"
[[ "$booted" == "$install_digest" ]] || { echo "FATAL: booted digest does not match installed ref" >&2; exit 1; }

echo ""
echo "=== Step 4: Write persistence markers ==="
run_guest_script "$SCRIPT_DIR/update-tests/persistence-write.sh"

# ---------------------------------------------------------------
declare -a hop_names=()
declare -a hop_results=()
prev_digest="$install_digest"
overall=0

hop_num=0
for ref in "${HOP_REFS[@]}"; do
    hop_num=$((hop_num + 1))
    echo ""
    echo "=== Hop $hop_num: bootc switch $ref ==="
    expected=$(digest_of "$ref")
    echo "Expected digest: $expected"

    vm_ssh "bootc switch --quiet $ref"

    staged=$(guest_status_digest staged)
    echo "Staged digest:   $staged"
    if [[ "$staged" != "$expected" ]]; then
        echo "FATAL: staged digest does not match $ref" >&2
        exit 1
    fi

    reboot_guest

    booted=$(guest_status_digest booted)
    rollback=$(guest_status_digest rollback)
    echo "Booted digest:   $booted (expected $expected)"
    echo "Rollback digest: $rollback (expected $prev_digest)"

    hop_rc=0
    [[ "$booted" == "$expected" ]] || { echo "not ok - booted deployment is $ref"; hop_rc=1; }
    [[ "$rollback" == "$prev_digest" ]] || { echo "not ok - rollback slot holds previous deployment"; hop_rc=1; }

    echo ""
    echo "--- Persistence verification after hop $hop_num ---"
    set +e
    run_guest_script "$SCRIPT_DIR/update-tests/persistence-verify.sh"
    verify_rc=$?
    set -e
    hop_rc=$((hop_rc + verify_rc))

    echo "--- System health after hop $hop_num ---"
    set +e
    vm_ssh "systemctl is-system-running --wait"
    health_rc=$?
    vm_ssh "systemctl --failed --no-legend"
    set -e
    if [[ $health_rc -ne 0 ]]; then
        echo "not ok - system is not in 'running' state after hop"
        hop_rc=$((hop_rc + 1))
    fi

    hop_names+=("hop-$hop_num -> $ref")
    hop_results+=("$hop_rc")
    [[ $hop_rc -eq 0 ]] || overall=1
    prev_digest="$expected"
done

# ---------------------------------------------------------------
echo ""
echo "========================================"
echo "        UPDATE TEST SUMMARY"
echo "========================================"
echo "  install: $INSTALL_REF"
for i in "${!hop_names[@]}"; do
    if [[ "${hop_results[$i]}" -eq 0 ]]; then
        printf "  %-60s PASS\n" "${hop_names[$i]}"
    else
        printf "  %-60s FAIL (%s)\n" "${hop_names[$i]}" "${hop_results[$i]}"
    fi
done
echo "========================================"
exit "$overall"
