#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Enablement-model migration test: installs an OLD-model image (enablement
# symlinks shipped in /etc, empty machine-id), then updates it to a
# NEW-model image (no enablement symlinks, machine-id "uninitialized",
# presets applied at first boot) and verifies preset-migration.service
# bridges the boundary:
#
#   1. bootc's 3-way /etc merge drops the old image's enablement symlinks
#      (unchanged in live /etc + absent from new image /etc = removed)
#   2. the migration boot runs preset-migration.service (static /usr wants
#      activation), which re-applies presets, writes the marker, reboots
#   3. the following boot has full enablement parity with the new image's
#      /usr/share/snosi/enablement-manifest.txt and a healthy system state
#
# Usage: sudo ./test/bootc-migration-test.sh <old-install-ref> <new-rootfs-dir-or-ref>
#
# Example:
#   sudo ./test/bootc-migration-test.sh ghcr.io/frostyard/snow:latest output/snow
#
# Environment:
#   DISK_SIZE (default 25G — the hop image is loaded into the guest's /var)
#   KEEP_VM=1 to skip cleanup and leave the VM running for inspection.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${DISK_SIZE:=25G}"
: "${KEEP_VM:=0}"

# shellcheck source=test/lib/ssh.sh
source "$SCRIPT_DIR/lib/ssh.sh"
# shellcheck source=test/lib/vm.sh
source "$SCRIPT_DIR/lib/vm.sh"

WORK_DIR=""
NEW_REF_LOCAL="localhost/snosi-migration:new"
REGISTRY_PORT="${REGISTRY_PORT:-5001}"
REGISTRY_STARTED=""
loop=""

usage() {
    echo "Usage: $0 <old-install-ref> <new-rootfs-dir-or-ref>" >&2
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
    if [[ -n "$loop" ]]; then
        losetup -d "$loop" 2>/dev/null || true
    fi
    vm_cleanup
    if [[ -n "$REGISTRY_STARTED" ]]; then
        podman rm -f snosi-migration-registry 2>/dev/null || true
    fi
    podman rmi -f "$NEW_REF_LOCAL" 2>/dev/null || true
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]] && ! mountpoint -q "$WORK_DIR/mnt" 2>/dev/null; then
        rm -rf "$WORK_DIR"
    fi
}

[[ $# -eq 2 ]] || usage
OLD_REF="$1"
NEW_INPUT="$2"

[[ $EUID -eq 0 ]] || { echo "Error: must run as root" >&2; exit 1; }
if ss -tln 2>/dev/null | awk '{print $4}' | grep -q ":${SSH_PORT:-2222}$"; then
    echo "Error: SSH forward port already in use (stale VM?)" >&2
    exit 1
fi

trap cleanup EXIT
WORK_DIR=$(mktemp -d /var/tmp/bootc-migration-test.XXXXXX)
echo "Temp directory: $WORK_DIR"

fail=0
verdict() { # description command [args...]
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        echo "ok - $desc"
    else
        echo "not ok - $desc"
        fail=$((fail + 1))
    fi
}

# ---------------------------------------------------------------
echo ""
echo "=== Step 1: Install OLD-model image: $OLD_REF ==="
load_image "$OLD_REF"
ssh_keygen "$WORK_DIR"
create_disk "$WORK_DIR/disk.raw"
install_to_disk "$WORK_DIR/disk.raw"

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
umount "$WORK_DIR/mnt"
losetup -d "$loop"
loop=""

echo ""
echo "=== Step 3: Boot OLD system and baseline ==="
vm_start "$DISK_IMAGE"
wait_for_ssh

old_wants=$(vm_ssh "find /etc/systemd/system -path '*.wants/*' -type l | wc -l")
old_machine_id=$(vm_ssh "cat /etc/machine-id")
echo "old-model /etc wants symlinks: $old_wants"
echo "machine-id: $old_machine_id"
verdict "old model ships enablement symlinks in /etc" test "$old_wants" -gt 50

# ---------------------------------------------------------------
echo ""
echo "=== Step 4: Load NEW-model image and transfer to guest ==="
if is_registry_ref "$NEW_INPUT"; then
    NEW_REF="$NEW_INPUT"
    vm_ssh "podman pull --quiet $NEW_REF >/dev/null"
else
    "$PROJECT_ROOT/shared/outformat/image/buildah-package.sh" \
        "$NEW_INPUT" "$NEW_REF_LOCAL"
    # bootc 1.16.3's containers-storage composefs pull only accepts
    # zstd:chunked layers — a plain buildah image fails `bootc switch` with
    # "Invalid splitstream content type". Re-chunk exactly like CI does.
    # The transfer must be a registry pull: podman save|load strips the
    # chunked framing, so serve a throwaway registry on the host and pull
    # from the guest via QEMU user-net's host address (10.0.2.2).
    "$PROJECT_ROOT/shared/outformat/image/chunkah-package.sh" \
        "$NEW_REF_LOCAL" "$(date +%s)"
    podman rm -f snosi-migration-registry 2>/dev/null || true
    podman run -d --rm --name snosi-migration-registry \
        -p "$REGISTRY_PORT:5000" docker.io/library/registry:2 >/dev/null
    REGISTRY_STARTED=1
    podman push --tls-verify=false --force-compression \
        --compression-format zstd:chunked \
        "$NEW_REF_LOCAL" "localhost:$REGISTRY_PORT/snosi-migration:new"
    NEW_REF="10.0.2.2:$REGISTRY_PORT/snosi-migration:new"
    echo "Pulling $NEW_REF in guest (several GB, be patient)..."
    vm_ssh "podman pull --quiet --tls-verify=false $NEW_REF >/dev/null"
fi

echo ""
echo "=== Step 5: bootc switch to NEW-model image ==="
vm_ssh "bootc switch --quiet --transport containers-storage $NEW_REF"
staged=$(vm_ssh "bootc status --format json" | jq -r '.status.staged.image.imageDigest // "null"')
echo "staged: $staged"
verdict "new image staged" test "$staged" != "null"

# ---------------------------------------------------------------
echo ""
echo "=== Step 6: Reboot across the model boundary ==="
# Expected sequence: shutdown finalize merges /etc (dropping the old
# enablement symlinks), the migration boot runs preset-migration.service
# and reboots itself, and the boot after that is the steady state. We poll
# until the marker exists AND preset-migration is inactive in the CURRENT
# boot (i.e. we are past the migration boot), tolerating the SSH drop of
# the intermediate reboot.
vm_ssh "systemctl reboot" || true
down_deadline=$((SECONDS + 120))
while (( SECONDS < down_deadline )); do
    vm_ssh -o ConnectTimeout=2 true 2>/dev/null || break
    sleep 2
done

steady=0
steady_deadline=$((SECONDS + 600))
while (( SECONDS < steady_deadline )); do
    if ! vm_ssh -o ConnectTimeout=5 true 2>/dev/null; then
        sleep 3
        continue
    fi
    marker=$(vm_ssh "test -f /var/lib/preset-enablement.done && echo yes || echo no" 2>/dev/null || echo err)
    mig_state=$(vm_ssh "systemctl show -P ActiveState preset-migration.service" 2>/dev/null || echo err)
    if [[ "$marker" == "yes" && "$mig_state" == "inactive" ]]; then
        steady=1
        break
    fi
    echo "  (marker=$marker migration=$mig_state — waiting for post-migration boot)"
    sleep 5
done
verdict "reached steady state after migration (marker present, migration unit inactive)" \
    test "$steady" -eq 1

# ---------------------------------------------------------------
echo ""
echo "=== Step 7: Verify post-migration state ==="

booted_name=$(vm_ssh "bootc status --format json" | jq -r '.status.booted.image.image.image // "null"')
verdict "booted image is the new-model image" test "$booted_name" = "$NEW_REF"

new_machine_id=$(vm_ssh "cat /etc/machine-id")
verdict "machine-id preserved across migration ($old_machine_id)" \
    test "$new_machine_id" = "$old_machine_id"

# The migration boot itself must have run preset-migration. Its journal
# never persists (the unit reboots before systemd-journal-flush), so the
# durable evidence is the marker CONTENT: "migration" = the migration path
# wrote it; "first-boot" would mean a spurious first boot ran instead.
marker_content=$(vm_ssh "cat /var/lib/preset-enablement.done 2>/dev/null" || echo missing)
verdict "preset-migration.service ran on the migration boot (marker: $marker_content)" \
    test "$marker_content" = "migration"

# Manifest parity: every enablement symlink the new image expects exists.
missing=$(vm_ssh '
    missing=0
    while read -r scope rel; do
        [ -n "$rel" ] || continue
        [ -L "/etc/systemd/$scope/$rel" ] || { echo "MISSING: $scope/$rel" >&2; missing=$((missing+1)); }
    done < /usr/share/snosi/enablement-manifest.txt
    echo $missing
')
echo "manifest entries missing: $missing"
verdict "full enablement manifest parity after migration" test "$missing" = "0"

# Spot-check the units that matter most.
for unit in display-manager.service NetworkManager.service bootc-update-stage.timer; do
    state=$(vm_ssh "systemctl is-enabled $unit 2>/dev/null" || echo missing)
    verdict "$unit is enabled (state: $state)" \
        bash -c 'test "$1" = enabled -o "$1" = alias' _ "$state"
done

set +e
vm_ssh "systemctl is-system-running --wait"
health_rc=$?
vm_ssh "systemctl --failed --no-legend"
set -e
final_state=$(vm_ssh "systemctl is-system-running" || true)
verdict "system running or degraded (headless graphics)" \
    bash -c 'test "$1" = 0 -o "$2" = degraded' _ "$health_rc" "$final_state"

# ---------------------------------------------------------------
echo ""
if [[ "$fail" -eq 0 ]]; then
    echo "=== MIGRATION TEST PASSED ==="
else
    echo "=== MIGRATION TEST FAILED: $fail check(s) ==="
fi
exit "$fail"
