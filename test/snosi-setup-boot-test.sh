#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Live QEMU smoke test for the graphical setup kiosk (T4,
# docs/plans/2026-07-17-graphical-installer-plan.md): boots the REAL
# network-installer ISO under enforced Secure Boot twice --
#
#   Leg 1 (virtio-vga attached): /dev/dri/card* exists, so
#     snosi-setup.service must start cage, cage must be running the
#     snosi-setup GTK app (llvmpipe -- no host GPU needed), and
#     getty@tty1 must have yielded (Conflicts=). The serial console
#     (serial-getty@ttyS0) must be untouched either way.
#   Leg 2 (no display device): the unit's ConditionPathExistsGlob fails,
#     snosi-setup must NOT run, and getty@tty1 must own tty1 -- the
#     text-mode fallback the plan requires proven, not assumed.
#
# What this deliberately does NOT cover: driving the wizard pages (the
# model test covers the logic; a human pass covers the pixels, checklist
# §9), and the snosi.textmode=1 cmdline escape hatch (needs grub surgery;
# covered by the same human pass).
#
# Requires: root, KVM, swtpm not needed (no install happens), OVMF secboot
# firmware, and either an existing output/native-installer rootfs or ~8min
# for a fresh mkosi build. Local-only (root/KVM), like every QEMU harness
# in this repo -- not wired into validate.yml.
#
# Usage: sudo ./test/snosi-setup-boot-test.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SSH_PORT="${SSH_PORT:-2237}"

PASS=0
FAIL=0
pass() { echo "ok - $1"; PASS=$((PASS + 1)); }
fail() { echo "not ok - $1${2:+ ($2)}"; FAIL=$((FAIL + 1)); }
assert_true() { local d="$1"; shift; if "$@"; then pass "$d"; else fail "$d"; fi; }
assert_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi; }

[[ $EUID -eq 0 ]] || { echo "Error: must run as root (KVM + loop devices)" >&2; exit 1; }
for cmd in qemu-system-x86_64 ssh-keygen cpio zstd; do
    command -v "$cmd" >/dev/null || { echo "Error: required command not found: $cmd" >&2; exit 1; }
done
OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.secboot.fd
OVMF_VARS=/usr/share/OVMF/OVMF_VARS_4M.ms.fd
[[ -f "$OVMF_CODE" && -f "$OVMF_VARS" ]] || { echo "Error: OVMF secboot firmware not found" >&2; exit 1; }

WORK_DIR="$(mktemp -d /var/tmp/snosi-setup-boot-test.XXXXXX)"
QEMU_PID=""
cleanup() {
    [[ -z "$QEMU_PID" ]] || kill "$QEMU_PID" 2>/dev/null || true
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Build the ISO with an ephemeral SSH key injected (same technique as
# test/native-installer-e2e-test.sh -- the key must be in the packed rootfs).
# ---------------------------------------------------------------------------
ROOTFS="$ROOT_DIR/output/native-installer"
if [[ ! -d "$ROOTFS" ]]; then
    echo "Building the native-installer rootfs (no existing $ROOTFS)..."
    (cd "$ROOT_DIR" && ./.mkosi/bin/mkosi --profile native-installer build >/dev/null)
fi
[[ -f "$ROOTFS/usr/bin/snosi-setup" || -L "$ROOTFS/usr/bin/snosi-setup" ]] ||
    { echo "Error: rootfs predates the GUI stack (no /usr/bin/snosi-setup); rebuild it" >&2; exit 1; }
# Staleness guard: a reused rootfs must carry the CURRENT activation design.
# ExtraTrees changes do NOT reach an existing output/ tree (caught live: a
# rerun against a pre-udev-rule rootfs tested yesterday's semantics), so
# refuse rather than silently test the wrong artifact.
[[ -L "$ROOTFS/usr/lib/systemd/system/multi-user.target.wants/snosi-setup.service" ]] ||
    { echo "Error: rootfs predates the snosi-setup static wants link; run 'mkosi --profile native-installer clean' and rerun" >&2; exit 1; }

ssh-keygen -t ed25519 -N "" -q -f "$WORK_DIR/id"
install -d -m 700 "$ROOTFS/root/.ssh"
install -m 600 "$WORK_DIR/id.pub" "$ROOTFS/root/.ssh/authorized_keys"

VERSION="$(date -u +%Y%m%d%H%M%S)"
echo "Assembling ISO ($VERSION)..."
"$ROOT_DIR/shared/native-installer/tools/build-iso.sh" "$ROOTFS" "$WORK_DIR" "$VERSION" >/dev/null
ISO="$WORK_DIR/snosi-native-installer_${VERSION}_x86-64.iso"
[[ -f "$ISO" ]] || { echo "Error: ISO not produced" >&2; exit 1; }

cp "$OVMF_VARS" "$WORK_DIR/vars.fd"

boot_vm() { # extra qemu args...
    qemu-system-x86_64 \
        -machine q35,smm=on -enable-kvm -cpu host -smp 4 -m 4096 \
        -vga none \
        -global driver=cfi.pflash01,property=secure,value=on \
        -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
        -drive "if=pflash,format=raw,file=$WORK_DIR/vars.fd" \
        -drive "file=$ISO,media=cdrom,readonly=on" \
        -netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22" \
        -device virtio-net-pci,netdev=net0 \
        -serial "file:$WORK_DIR/console.log" \
        -pidfile "$WORK_DIR/qemu.pid" -daemonize "$@"
    QEMU_PID="$(cat "$WORK_DIR/qemu.pid")"
}

vm_ssh() {
    ssh -i "$WORK_DIR/id" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 -o LogLevel=ERROR -p "$SSH_PORT" root@localhost "$@"
}

wait_ssh() {
    local t=0
    until vm_ssh true 2>/dev/null; do
        sleep 5; t=$((t + 5))
        [[ $t -lt 300 ]] || { echo "SSH timeout" >&2; tail -5 "$WORK_DIR/console.log" >&2; return 1; }
    done
}

stop_vm() {
    vm_ssh poweroff 2>/dev/null || true
    local t=0
    while kill -0 "$QEMU_PID" 2>/dev/null; do
        sleep 2; t=$((t + 2))
        [[ $t -lt 60 ]] || { kill "$QEMU_PID" 2>/dev/null || true; break; }
    done
    QEMU_PID=""
}

# ---------------------------------------------------------------------------
# Leg 1: display attached -> kiosk must run
# ---------------------------------------------------------------------------
echo ""
echo "=== Leg 1: virtio-vga attached (kiosk expected) ==="
# -vga none in boot_vm suppresses QEMU's implicit default VGA (which would
# otherwise give leg 2 a surprise /dev/dri/card0); virtio-vga here is then
# the ONLY display adapter.
boot_vm -device virtio-vga -display none
wait_ssh
assert_true "guest has a DRM device" vm_ssh 'ls /dev/dri/card* >/dev/null 2>&1'
assert_eq "snosi-setup.service is active" "$(vm_ssh 'systemctl is-active snosi-setup.service' 2>/dev/null)" "active"
assert_true "cage compositor is running" vm_ssh 'pgrep -x cage >/dev/null'
# Bracket-trick the compositor's client so pgrep does not match its own
# pattern-bearing command line; cage's cmdline is "cage -- /usr/bin/snosi-setup".
assert_true "snosi-setup GTK app is running under cage" \
    vm_ssh 'pgrep -f "[c]age -- /usr/bin/snosi-setup" >/dev/null && pgrep -af python3 | grep -q snosi-setup'
assert_eq "getty@tty1 yielded to the kiosk (ExecStartPre stop)" \
    "$(vm_ssh 'systemctl is-active getty@tty1.service' 2>/dev/null)" "inactive"
assert_eq "serial-getty@ttyS0 untouched" \
    "$(vm_ssh 'systemctl is-active serial-getty@ttyS0.service' 2>/dev/null)" "active"
# The app must SURVIVE, not just start: a GTK/GI import crash respawns then
# trips the start limit -- 10 seconds is beyond RestartSec*Burst churn.
sleep 10
assert_eq "snosi-setup.service still active after 10s (no crash loop)" \
    "$(vm_ssh 'systemctl is-active snosi-setup.service' 2>/dev/null)" "active"
assert_eq "no failed units with the kiosk up" "$(vm_ssh 'systemctl --failed --no-legend | wc -l' 2>/dev/null)" "0"
stop_vm

# ---------------------------------------------------------------------------
# Leg 2: no display device -> text-mode fallback must hold
# ---------------------------------------------------------------------------
echo ""
echo "=== Leg 2: no display device (getty fallback expected) ==="
cp "$OVMF_VARS" "$WORK_DIR/vars.fd"   # fresh varstore; boot entry hygiene
boot_vm -display none
wait_ssh
assert_true "guest has NO DRM device" vm_ssh '! ls /dev/dri/card* >/dev/null 2>&1'
assert_eq "snosi-setup.service did not run (condition)" \
    "$(vm_ssh 'systemctl is-active snosi-setup.service' 2>/dev/null)" "inactive"
assert_true "snosi-setup Condition failed cleanly (no display, not a failure)" \
    vm_ssh '[[ "$(systemctl show snosi-setup.service -p ConditionResult --value)" == no && "$(systemctl show snosi-setup.service -p Result --value)" == success ]]'
assert_eq "getty@tty1 owns tty1" "$(vm_ssh 'systemctl is-active getty@tty1.service' 2>/dev/null)" "active"
assert_eq "no failed units in text mode" "$(vm_ssh 'systemctl --failed --no-legend | wc -l' 2>/dev/null)" "0"
stop_vm

echo ""
echo "# Results: $PASS passed, $FAIL failed, $((PASS + FAIL)) total"
[[ "$FAIL" -eq 0 ]]
