#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Tier 5: First-boot preset semantics for hermetic-/etc images.
# This script runs INSIDE the booted VM via SSH, on the VM's FIRST boot.
#
# The image ships /etc/machine-id as "uninitialized" and NO unit enablement
# symlinks in /etc (see shared/outformat/image/finalize/mkosi.finalize.chroot).
# On first boot PID 1 applies system presets and preset-global.service
# applies user presets, recreating every enablement symlink as runtime state.
# The finalize script records what it stripped in
# /usr/share/snosi/enablement-manifest.txt; this test verifies each entry
# was recreated (parity) and that first-boot semantics behaved.
set -euo pipefail

HELPERS="${TEST_LIB_DIR:-$(dirname "$0")/../lib}/helpers.sh"
# shellcheck source=test/lib/helpers.sh
source "$HELPERS"

echo "# Tier 5: First-boot preset parity"

MANIFEST=/usr/share/snosi/enablement-manifest.txt

check "Enablement manifest is present in /usr" test -s "$MANIFEST"

# machine-id was committed on first boot: a 32-hex ID, not "uninitialized"
# and not empty.
machine_id_valid() {
    local id
    id=$(cat /etc/machine-id 2>/dev/null) || return 1
    [[ "$id" =~ ^[0-9a-f]{32}$ ]]
}
check "machine-id committed (32-hex, not 'uninitialized')" machine_id_valid

# This boot was a true systemd first boot.
check "first-boot-complete.target was reached" \
    test "$(systemctl show -P ActiveState first-boot-complete.target)" = "active"

# preset-global ran and succeeded (user-scope preset application).
check "preset-global.service succeeded" \
    test "$(systemctl show -P Result preset-global.service)" = "success"

# The enablement-model marker exists (gates preset-migration.service off)
# and records the first-boot path — "migration" here would mean the
# migration unit ran on a fresh install.
check "preset-enablement marker written by first boot" \
    test "$(cat /var/lib/preset-enablement.done 2>/dev/null)" = "first-boot"
check "preset-migration.service did not run" \
    test "$(systemctl show -P ActiveState preset-migration.service)" = "inactive"

# systemd-firstboot must never run (it can prompt on console). It is a
# static unit, so it is neutered via a ConditionPathExists drop-in rather
# than a preset; assert it stayed inactive on this (first) boot.
check "systemd-firstboot.service did not run" \
    test "$(systemctl show -P ActiveState systemd-firstboot.service)" = "inactive"

# Parity: every enablement symlink stripped from the image /etc must have
# been recreated by the preset pass at first boot.
missing=0
total=0
while read -r scope rel; do
    [[ -n "$rel" ]] || continue
    (( total++ )) || true
    if [[ ! -L "/etc/systemd/$scope/$rel" ]]; then
        echo "# MISSING: /etc/systemd/$scope/$rel"
        (( missing++ )) || true
    fi
done < "$MANIFEST"
echo "# manifest entries: $total, missing after first boot: $missing"
check "All manifest enablement symlinks recreated by presets" \
    test "$missing" -eq 0 -a "$total" -gt 0

# Informational: runtime symlinks that are NOT in the manifest (new state
# created at first boot that the image never shipped — expected to be empty
# or nearly so; differences are worth eyeballing, not failing).
extra=$(
    for scope in system user; do
        [[ -d /etc/systemd/$scope ]] || continue
        find /etc/systemd/$scope -mindepth 2 -maxdepth 2 \
             \( -path '*.wants/*' -o -path '*.requires/*' \) -type l \
             -printf "$scope %P\n"
        find /etc/systemd/$scope -mindepth 1 -maxdepth 1 -type l \
             \( -lname '/usr/lib/systemd/*' -o -lname '/lib/systemd/*' \) \
             -printf "$scope %P\n"
    done | LC_ALL=C sort | LC_ALL=C comm -23 - "$MANIFEST"
)
if [[ -n "$extra" ]]; then
    echo "# extra runtime enablement symlinks not in manifest:"
    echo "$extra" | sed 's/^/#   /'
fi

# The conflicting gnome-remote-desktop variants must not both be enabled
# (desktop images only; skipped where the units do not exist).
if [[ -e /usr/lib/systemd/user/gnome-remote-desktop-headless.service ]]; then
    check "gnome-remote-desktop-headless is not enabled" \
        test ! -L /etc/systemd/user/gnome-session.target.wants/gnome-remote-desktop-headless.service
    check "gnome-remote-desktop is enabled" \
        test -L /etc/systemd/user/gnome-session.target.wants/gnome-remote-desktop.service
fi

# SSH host keys were generated on first boot (sshd-keygen path gate).
check "SSH host keys exist" bash -c 'ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1'

print_summary
