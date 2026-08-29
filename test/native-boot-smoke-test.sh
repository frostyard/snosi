#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Boot smoke test for a native A/B product disk artifact: proves the exact
# candidate bytes boot to multi-user.target with no failed units. Runs in
# build-native-images.yml's test-public-origin job between verify-remote.sh
# and the verified-marker upload (the promotion gate), and locally against a
# prepare-native-publication.sh output dir.
#
# Usage: sudo native-boot-smoke-test.sh <prepared-dir> [base-url]
#
#   prepared-dir  prepare-native-publication.sh output dir; must contain
#                 publication-info.json and SHA256SUMS. The disk blob itself
#                 is OPTIONAL: CI ships only the metadata between jobs, so
#                 when absent it is downloaded from the candidate subpath.
#   base-url      HTTP(S) URL of the product's os/native/v1/<product>/x86-64
#                 directory. Required when the blob is not present locally.
#                 The candidate subpath (.candidate/<version>/, the
#                 publish-lib.sh candidate_subpath() convention) is appended.
#
# Environment:
#   SMOKE_CONSOLE_COPY  copy the QEMU serial log here (pass and fail alike)
#                       so CI can upload it as an artifact
#   SSH_TIMEOUT         seconds to wait for SSH (default 600 -- true first
#                       boot applies presets before sshd has host keys)
#
# Root/verity partitions boot byte-pristine. SSH access is seeded exactly
# the way snosi-install's seed_var() does it: a public key at
# lib/snosi/etc-overlay/upper/ssh/authorized_keys.d/root on the var
# partition (read through the sshd AuthorizedKeysFile drop-in) -- var is
# user-data territory the installer recreates on real installs anyway.
# /root itself is on the sealed read-only root and cannot carry keys.
set -euo pipefail

usage() {
    echo "Usage: sudo $0 <prepared-dir> [base-url]" >&2
    exit 2
}
[[ "${1:-}" != "-h" && "${1:-}" != "--help" ]] || usage
[[ $# -ge 1 && $# -le 2 ]] || usage

PREPARED_DIR="$1"
BASE_URL="${2:-}"
BASE_URL="${BASE_URL%/}"
: "${SSH_TIMEOUT:=600}"

[[ $EUID -eq 0 ]] || { echo "Error: must run as root (losetup/mount/KVM)" >&2; exit 1; }
for cmd in qemu-system-x86_64 jq curl xz sha256sum losetup lsblk udevadm ssh-keygen; do
    command -v "$cmd" >/dev/null || { echo "Error: required command not found: $cmd" >&2; exit 1; }
done
[[ -f "$PREPARED_DIR/publication-info.json" ]] || { echo "Error: $PREPARED_DIR/publication-info.json not found" >&2; exit 1; }
[[ -f "$PREPARED_DIR/SHA256SUMS" ]] || { echo "Error: $PREPARED_DIR/SHA256SUMS not found" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/vm.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/ssh.sh"

PRODUCT="$(jq -r .product "$PREPARED_DIR/publication-info.json")"
VERSION="$(jq -r .version "$PREPARED_DIR/publication-info.json")"
DISK_NAME="$(jq -r .artifacts.disk.name "$PREPARED_DIR/publication-info.json")"
[[ "$VERSION" =~ ^[0-9]{14}$ ]] || { echo "Error: bad version '$VERSION'" >&2; exit 1; }
[[ -n "$DISK_NAME" && "$DISK_NAME" != "null" ]] || { echo "Error: no .artifacts.disk.name in publication-info.json" >&2; exit 1; }

WORK_DIR="$(mktemp -d /var/tmp/native-boot-smoke.XXXXXX)"
LOOP_DEV=""
MOUNTED=""

die() {
    echo "FAIL: $1" >&2
    if [[ -n "${QEMU_CONSOLE_LOG:-}" && -f "$QEMU_CONSOLE_LOG" ]]; then
        echo "--- last 60 serial console lines ---" >&2
        tail -60 "$QEMU_CONSOLE_LOG" >&2 || true
        echo "--- end console ---" >&2
    fi
    exit 1
}

# dump_failed_unit_diagnostics - Print per-unit status and journal for every
# failed unit in the guest.
#
# `systemctl --failed` names the unit but not the reason, and the serial
# console tail is capped at 60 lines and carries early-boot noise rather than
# the failing unit's own output. Without this, a promotion-blocking failure in
# CI is only reproducible by rebuilding the candidate and booting it by hand
# (hit 2026-08-29: plymouth-start.service degraded the snow candidate and the
# uploaded artifacts held no journal for it).
#
# Diagnostics only: this never changes the pass/fail decision, so every command
# is best-effort and the caller still dies on the state check.
dump_failed_unit_diagnostics() {
    local units unit
    # Collect first: vm_ssh runs ssh, which would consume the loop's stdin.
    mapfile -t units < <(vm_ssh "systemctl list-units --state=failed --no-legend --plain --no-pager" 2>/dev/null | awk '{print $1}' || true)
    (( ${#units[@]} )) || return 0
    for unit in "${units[@]}"; do
        [[ -n "$unit" ]] || continue
        # Only pass through well-formed unit names -- these are interpolated
        # into a remote shell command.
        [[ "$unit" =~ ^[A-Za-z0-9:_.@-]+\.[a-z]+$ ]] || continue
        echo "--- systemctl status $unit ---" >&2
        vm_ssh "systemctl status --no-pager --full '$unit'" >&2 || true
        echo "--- journalctl -u $unit ---" >&2
        vm_ssh "journalctl --no-pager --full --lines=100 -u '$unit'" >&2 || true
    done
    echo "--- end failed unit diagnostics ---" >&2
}

cleanup() {
    local rc=$?
    vm_stop >/dev/null 2>&1 || true
    [[ -n "$MOUNTED" ]] && umount "$MOUNTED" 2>/dev/null || true
    [[ -n "$LOOP_DEV" ]] && losetup -d "$LOOP_DEV" 2>/dev/null || true
    if [[ -n "${SMOKE_CONSOLE_COPY:-}" && -n "${QEMU_CONSOLE_LOG:-}" && -f "$QEMU_CONSOLE_LOG" ]]; then
        # install -m 0644, not cp: this script runs as root and QEMU creates
        # the chardev log 0640 root:root -- an unreadable copy makes CI's
        # unprivileged upload-artifact step fail with EACCES (seen live).
        install -m 0644 "$QEMU_CONSOLE_LOG" "$SMOKE_CONSOLE_COPY" || true
    fi
    rm -rf "$WORK_DIR"
    exit "$rc"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Obtain and verify the disk blob (local copy preferred; else candidate URL).
# The hash check runs in BOTH paths: we boot only bytes that match SHA256SUMS.
# ---------------------------------------------------------------------------
expected_sha="$(awk -v n="$DISK_NAME" '$2 == n {print $1}' "$PREPARED_DIR/SHA256SUMS")"
[[ -n "$expected_sha" ]] || die "no SHA256SUMS entry for $DISK_NAME"

blob="$WORK_DIR/$DISK_NAME"
if [[ -f "$PREPARED_DIR/$DISK_NAME" ]]; then
    echo "Using local blob $PREPARED_DIR/$DISK_NAME"
    cp --sparse=always "$PREPARED_DIR/$DISK_NAME" "$blob"
else
    [[ -n "$BASE_URL" ]] || die "disk blob not in $PREPARED_DIR and no base-url given"
    url="$BASE_URL/.candidate/$VERSION/$DISK_NAME"
    echo "Downloading $url"
    curl -fsSL --retry 3 -o "$blob" "$url" || die "download failed: $url"
fi
actual_sha="$(sha256sum "$blob" | cut -d' ' -f1)"
[[ "$actual_sha" == "$expected_sha" ]] || die "sha256 mismatch for $DISK_NAME: got $actual_sha want $expected_sha"

DISK_IMAGE="$WORK_DIR/disk.raw"
if [[ "$DISK_NAME" == *.xz ]]; then
    echo "Decompressing $DISK_NAME"
    xz -T0 -dc "$blob" >"$DISK_IMAGE"
else
    mv "$blob" "$DISK_IMAGE"
fi
rm -f "$blob"

# ---------------------------------------------------------------------------
# Seed SSH access on the var partition (root/verity stay pristine).
# ---------------------------------------------------------------------------
ssh_keygen "$WORK_DIR"
LOOP_DEV="$(losetup --find --show --partscan "$DISK_IMAGE")"
udevadm settle || true
var_part="$(lsblk -lnpo NAME,PARTLABEL "$LOOP_DEV" | awk '$2 == "var" {print $1}')"
[[ -n "$var_part" ]] || die "no partition with PARTLABEL=var on $LOOP_DEV"
mkdir -p "$WORK_DIR/mnt"
mount -t ext4 "$var_part" "$WORK_DIR/mnt"
MOUNTED="$WORK_DIR/mnt"
install -d -m 0755 "$WORK_DIR/mnt/lib/snosi/etc-overlay/upper/ssh/authorized_keys.d"
install -m 0600 "${SSH_KEY}.pub" "$WORK_DIR/mnt/lib/snosi/etc-overlay/upper/ssh/authorized_keys.d/root"
umount "$WORK_DIR/mnt"
MOUNTED=""
losetup -d "$LOOP_DEV"
LOOP_DEV=""

# ---------------------------------------------------------------------------
# Boot and assert.
# ---------------------------------------------------------------------------
echo "Booting $PRODUCT $VERSION"
vm_start "$DISK_IMAGE"
wait_for_ssh || die "SSH not reachable within ${SSH_TIMEOUT}s (boot failed or hung)"

state="$(vm_ssh "timeout 300 systemctl is-system-running --wait" 2>/dev/null || true)"
if [[ "$state" != "running" ]]; then
    echo "--- failed units ---" >&2
    vm_ssh "systemctl --failed --no-legend" >&2 || true
    dump_failed_unit_diagnostics
    die "system state is '$state', expected 'running' (startup incomplete or failed units)"
fi
echo "PASS: system state is 'running' (startup complete, no failed units)"

mu="$(vm_ssh "systemctl is-active multi-user.target" || true)"
[[ "$mu" == "active" ]] || die "multi-user.target is '$mu', expected 'active'"
echo "PASS: multi-user.target active"

# shellcheck disable=SC2016
img_id="$(vm_ssh 'source /etc/os-release && echo "$IMAGE_ID"')"
[[ "$img_id" == "$PRODUCT" ]] || die "IMAGE_ID '$img_id' != expected product '$PRODUCT'"
# shellcheck disable=SC2016
img_ver="$(vm_ssh 'source /etc/os-release && echo "$IMAGE_VERSION"')"
[[ "$img_ver" == "$VERSION" ]] || die "IMAGE_VERSION '$img_ver' != expected version '$VERSION'"
echo "PASS: os-release IMAGE_ID=$img_id IMAGE_VERSION=$img_ver"

vm_ssh "test -f /usr/lib/snosi/native-ab" || die "native-ab marker missing -- wrong artifact class booted"
echo "PASS: /usr/lib/snosi/native-ab present"

vm_ssh "systemctl poweroff" 2>/dev/null || true
i=0
while kill -0 "$QEMU_PID" 2>/dev/null && (( i++ < 60 )); do sleep 2; done
kill -0 "$QEMU_PID" 2>/dev/null && die "VM did not power off within 120s"
QEMU_PID=""
echo "PASS: clean poweroff"

echo ""
echo "OK: $PRODUCT $VERSION boot smoke test passed"
