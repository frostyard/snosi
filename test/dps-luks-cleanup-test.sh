#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Root-only regression for nested-mount cleanup in the Task 2 DPS helper.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATH="/usr/sbin:/sbin:$PATH"
# shellcheck disable=SC1091
source "$ROOT_DIR/test/lib/vm.sh"

[[ ${EUID:-$(id -u)} -eq 0 ]] || {
    echo "SKIP: requires root" >&2
    exit 0
}

work=$(mktemp -d)
disk="$work/disk.raw"
recovery_key="$work/recovery.key"
mapper=""
loop=""
root_mount="$work/root"

cleanup() {
    set +e
    mountpoint -q "$root_mount/nested" && umount "$root_mount/nested"
    mountpoint -q "$root_mount/boot" && umount "$root_mount/boot"
    mountpoint -q "$root_mount" && umount "$root_mount"
    [[ -z "$mapper" ]] || cryptsetup status "$mapper" >/dev/null 2>&1 && cryptsetup close "$mapper"
    if [[ -n "$loop" ]] && losetup "$loop" >/dev/null 2>&1; then
        losetup --detach "$loop"
    fi
    rm -rf "$work"
}
trap cleanup EXIT

truncate -s 3G "$disk"
printf '%s\n' cleanup-test-recovery-key >"$recovery_key"
chmod 600 "$recovery_key"
create_dps_luks_btrfs_root "$disk" "$root_mount" "$recovery_key"
mapper=$DPS_CRYPT_NAME
loop=$DPS_LOOP_DEVICE
mkdir "$root_mount/nested"
mount -t tmpfs none "$root_mount/nested"

set +e
destroy_dps_luks_btrfs_root
set -e

mountpoint -q "$root_mount" && {
    echo "FAIL: target root remains mounted" >&2
    exit 1
}
cryptsetup status "$mapper" >/dev/null 2>&1 && {
    echo "FAIL: mapper remains active" >&2
    exit 1
}
losetup --list --noheadings --output NAME | grep -Fxq "$loop" && {
    echo "FAIL: loop device remains attached" >&2
    exit 1
}

echo "PASS: nested mount cleanup removed target root, mapper, and loop"
