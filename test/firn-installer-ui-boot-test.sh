#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Boot test for the installer ISO's two GRUB entries
# (docs/adr/0022-installer-graphical-and-console-boot-entries.md). It boots
# the exact ISO bytes four times and checks over SSH which frontend owns tty1:
#
#   1. console entry (the menu default, no key pressed), -cdrom, virtio-vga:
#      the firn TUI kiosk on tty1 and ttyS0, no compositor.
#   2. graphical entry (hotkey g), -cdrom, virtio-vga: firn-gui running as
#      root inside cage, the TUI off tty1 but still on ttyS0. Then a
#      SIGTERM to firn-gui (its Quit path, exit 0) must hand tty1 to the TUI.
#   3. graphical entry, the ISO as a raw disk (USB-stick boot through the
#      GPT ESP and its own grub.cfg copy), -vga std: the same frontend on a
#      display-only DRM device, which firn-gui draws on the CPU.
#   4. graphical entry, -vga none: no display, so firn-gui-session exits 77
#      and the TUI takes tty1 at once.
#
# The SSH key reaches the guest as the systemd credential
# ssh.authorized_keys.root in an SMBIOS type 11 string, which systemd
# imports in VMs (systemd tmpfiles provision.conf writes it to
# /root/.ssh/authorized_keys). The ISO bytes are not modified, so this runs
# on published candidates. GRUB entries are chosen by sending their hotkey
# through the QEMU monitor once the menu shows on the serial console. Each
# leg prints the guest's memory use, for the RAM figures in ADR-0022. Plain
# (non-Secure-Boot) OVMF: build-iso.sh documents a console=tty0 hang under
# enforced Secure Boot with no GPU that is a fixture quirk, not a defect.
#
# Usage: sudo firn-installer-ui-boot-test.sh <iso>
#        sudo firn-installer-ui-boot-test.sh <prepared-dir> [base-url]
#
#   iso           a local installer ISO
#   prepared-dir  prepare-iso-publication.sh output dir, as for
#                 test/native-iso-boot-smoke-test.sh (the ISO is verified
#                 against its SHA256SUMS, fetched from the .candidate/
#                 subpath of base-url when absent)
#
# Environment:
#   UI_SCREENSHOT_DIR  save each graphical leg's screen as PNG here
#   UI_CONSOLE_DIR     save each leg's serial log here (pass and fail alike)
#   UI_BOOT_TIMEOUT    seconds to wait for the menu and for SSH (default 420)
#   VM_MEMORY, VM_CPUS guest size (default 6144 MiB, 2; the ISO needs about
#                      4.5 GiB to unpack its all-in-RAM rootfs)
set -euo pipefail

usage() {
    echo "Usage: sudo $0 <iso> | <prepared-dir> [base-url]" >&2
    exit 2
}
[[ "${1:-}" != "-h" && "${1:-}" != "--help" ]] || usage
[[ $# -ge 1 && $# -le 2 ]] || usage

: "${UI_BOOT_TIMEOUT:=420}"
: "${VM_MEMORY:=6144}"
: "${VM_CPUS:=2}"
: "${SSH_PORT:=2237}"
: "${MONITOR_PORT:=4447}"
# shellcheck disable=SC2034 # read by wait_for_ssh in lib/ssh.sh
SSH_TIMEOUT="$UI_BOOT_TIMEOUT"

[[ $EUID -eq 0 ]] || { echo "Error: must run as root (KVM)" >&2; exit 1; }
for cmd in qemu-system-x86_64 ssh ssh-keygen sha256sum base64; do
    command -v "$cmd" >/dev/null || { echo "Error: required command not found: $cmd" >&2; exit 1; }
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/vm.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/ssh.sh"

WORK_DIR="$(mktemp -d /var/tmp/firn-ui-boot.XXXXXX)"
QEMU_PID=""
CONSOLE_LOG=""
LEG=""

PASS=0
FAIL=0
pass() { echo "ok - $LEG: $1"; PASS=$((PASS + 1)); }
fail() { echo "not ok - $LEG: $1${2:+ ($2)}"; FAIL=$((FAIL + 1)); }
check() { local d="$1"; shift; if "$@"; then pass "$d"; else fail "$d"; fi; }
check_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi; }

stop_vm() {
    if [[ -n "$QEMU_PID" ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
        kill "$QEMU_PID" 2>/dev/null || true
        local _
        for _ in $(seq 1 20); do kill -0 "$QEMU_PID" 2>/dev/null || break; sleep 0.5; done
    fi
    QEMU_PID=""
    if [[ -n "${UI_CONSOLE_DIR:-}" && -n "$CONSOLE_LOG" && -f "$CONSOLE_LOG" ]]; then
        mkdir -p "$UI_CONSOLE_DIR"
        # install -m 0644, not cp: CI's unprivileged upload step must read it.
        install -m 0644 "$CONSOLE_LOG" "$UI_CONSOLE_DIR/$LEG.log" || true
    fi
}
cleanup() {
    local rc=$?
    stop_vm
    rm -rf "$WORK_DIR"
    exit "$rc"
}
trap cleanup EXIT

die() {
    echo "FAIL: $LEG: $1" >&2
    if [[ -n "$CONSOLE_LOG" && -f "$CONSOLE_LOG" ]]; then
        echo "--- last 40 serial console lines ---" >&2
        tail -40 "$CONSOLE_LOG" | tr -d '\033' >&2 || true
        echo "--- end console ---" >&2
    fi
    exit 1
}

# ---------------------------------------------------------------------------
# The ISO under test.
# ---------------------------------------------------------------------------
if [[ -f "$1" ]]; then
    [[ $# -eq 1 ]] || usage
    ISO="$1"
else
    PREPARED_DIR="$1"
    BASE_URL="${2:-}"
    BASE_URL="${BASE_URL%/}"
    for cmd in jq curl; do
        command -v "$cmd" >/dev/null || { echo "Error: required command not found: $cmd" >&2; exit 1; }
    done
    [[ -f "$PREPARED_DIR/publication-info.json" && -f "$PREPARED_DIR/SHA256SUMS" ]] ||
        { echo "Error: $PREPARED_DIR is not a prepared publication dir" >&2; exit 1; }
    version="$(jq -r .version "$PREPARED_DIR/publication-info.json")"
    iso_name="$(jq -r .artifacts.iso.name "$PREPARED_DIR/publication-info.json")"
    [[ "$version" =~ ^[0-9]{14}$ ]] || { echo "Error: bad version '$version'" >&2; exit 1; }
    [[ -n "$iso_name" && "$iso_name" != "null" ]] || { echo "Error: no .artifacts.iso.name" >&2; exit 1; }
    expected_sha="$(awk -v n="$iso_name" '$2 == n {print $1}' "$PREPARED_DIR/SHA256SUMS")"
    [[ -n "$expected_sha" ]] || { echo "Error: no SHA256SUMS entry for $iso_name" >&2; exit 1; }
    ISO="$WORK_DIR/$iso_name"
    if [[ -f "$PREPARED_DIR/$iso_name" ]]; then
        cp "$PREPARED_DIR/$iso_name" "$ISO"
    else
        [[ -n "$BASE_URL" ]] || { echo "Error: ISO not in $PREPARED_DIR and no base-url given" >&2; exit 1; }
        curl -fsSL --connect-timeout 10 --max-time 600 --retry 5 --retry-all-errors \
            --retry-max-time 300 -o "$ISO" "$BASE_URL/.candidate/$version/$iso_name" ||
            { echo "Error: download failed" >&2; exit 1; }
    fi
    actual_sha="$(sha256sum "$ISO" | cut -d' ' -f1)"
    [[ "$actual_sha" == "$expected_sha" ]] ||
        { echo "Error: sha256 mismatch for $iso_name: got $actual_sha want $expected_sha" >&2; exit 1; }
fi
echo "Testing installer ISO $ISO"

ovmf_pair="$(find_ovmf)"
OVMF_CODE="${ovmf_pair%% *}"
OVMF_VARS_SRC="${ovmf_pair##* }"

ssh_keygen "$WORK_DIR" >/dev/null
CREDENTIAL="io.systemd.credential.binary:ssh.authorized_keys.root=$(base64 -w0 <"$SSH_KEY.pub")"

monitor() { # HMP command -> sent to this leg's QEMU monitor
    local fd
    exec {fd}<>"/dev/tcp/127.0.0.1/$MONITOR_PORT"
    printf '%s\n' "$1" >&"$fd"
    sleep 1
    exec {fd}>&-
}

# boot_leg <name> <media: cdrom|disk> <display: virtio|std|none> [hotkey]
boot_leg() {
    LEG="$1"
    local media=() display=() hotkey="${4:-}"
    CONSOLE_LOG="$WORK_DIR/$LEG.console.log"
    case "$2" in
        cdrom) media=(-cdrom "$ISO") ;;
        disk) media=(-drive "if=virtio,format=raw,readonly=on,file=$ISO") ;;
    esac
    case "$3" in
        virtio) display=(-vga none -device virtio-vga) ;;
        std) display=(-vga std) ;;
        none) display=(-vga none) ;;
    esac
    cp "$OVMF_VARS_SRC" "$WORK_DIR/$LEG.vars.fd"
    echo ""
    echo "=== $LEG: $2, display $3, ${hotkey:+hotkey }${hotkey:-menu default} ==="
    qemu-system-x86_64 \
        -machine q35 \
        -enable-kvm -cpu host \
        -m "$VM_MEMORY" -smp "$VM_CPUS" \
        -drive "if=pflash,format=raw,unit=0,file=$OVMF_CODE,readonly=on" \
        -drive "if=pflash,format=raw,unit=1,file=$WORK_DIR/$LEG.vars.fd" \
        "${media[@]}" \
        "${display[@]}" \
        -display none \
        -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22" \
        -device virtio-net-pci,netdev=net0 \
        -smbios "type=11,value=$CREDENTIAL" \
        -serial "file:$CONSOLE_LOG" \
        -monitor "tcp:127.0.0.1:$MONITOR_PORT,server=on,wait=off" \
        -pidfile "$WORK_DIR/qemu.pid" \
        -daemonize
    QEMU_PID="$(cat "$WORK_DIR/qemu.pid")"

    # The menu reaches serial through OVMF's console redirection.
    local deadline=$((SECONDS + UI_BOOT_TIMEOUT))
    until grep -aqF 'Install snosi (console)' "$CONSOLE_LOG" 2>/dev/null; do
        kill -0 "$QEMU_PID" 2>/dev/null || die "QEMU exited before the GRUB menu"
        (( SECONDS < deadline )) || die "no GRUB menu on the serial console within ${UI_BOOT_TIMEOUT}s"
        sleep 0.5
    done
    pass "GRUB menu shows both entries on the serial console"
    [[ -z "$hotkey" ]] || monitor "sendkey $hotkey"

    wait_for_ssh >/dev/null || die "SSH did not come up within ${UI_BOOT_TIMEOUT}s"
}

guest() { vm_ssh "$@" 2>/dev/null; }
state() { guest systemctl is-active "$1" || true; }
prop() { guest systemctl show -p "$2" --value "$1" || true; }
wait_state() { # unit state seconds
    local _
    for _ in $(seq 1 "$3"); do
        [[ "$(state "$1")" == "$2" ]] && return 0
        sleep 1
    done
    return 1
}

report_memory() {
    echo "# $LEG guest memory:"
    guest 'free -m; df -m / | tail -1; ps -o rss=,comm= -C cage,firn-gui,firn 2>/dev/null' |
        sed 's/^/#   /' || true
}

screenshot() {
    [[ -n "${UI_SCREENSHOT_DIR:-}" ]] || return 0
    mkdir -p "$UI_SCREENSHOT_DIR"
    monitor "screendump $UI_SCREENSHOT_DIR/$LEG.png -f png"
    if [[ -s "$UI_SCREENSHOT_DIR/$LEG.png" ]]; then
        chmod 0644 "$UI_SCREENSHOT_DIR/$LEG.png"
        echo "# screenshot: $UI_SCREENSHOT_DIR/$LEG.png"
    else
        echo "# screenshot: QEMU wrote none"
    fi
}

check_serial_tui() {
    check_eq "the serial TUI kiosk runs" "$(state firn-kiosk-serial@ttyS0.service)" active
}

check_cmdline() {
    check "the kernel command line selects $1" guest "grep -qw 'systemd.unit=$1' /proc/cmdline"
}

# The guest commands are single-quoted on purpose: they expand in the guest.
# shellcheck disable=SC2016
check_gui_up() {
    if wait_state firn-gui.service active 60; then
        pass "firn-gui.service is active"
    else
        fail "firn-gui.service is active" "$(state firn-gui.service)"
    fi
    # cage forks a helper for its builtin seat, also named cage.
    check "cage runs as root" guest 'ps -o uid= -C cage | awk "\$1 != 0 {bad = 1} END {exit bad || NR == 0}"'
    check "firn-gui runs as root inside cage" \
        guest '[ "$(ps -o uid= -C firn-gui | tr -d " ")" = 0 ] && [ "$(ps -o comm= -p "$(ps -o ppid= -C firn-gui | tr -d " ")")" = cage ]'
    check_eq "the TUI is off tty1" "$(state firn-kiosk.service)" inactive
    sleep 10
    check_eq "firn-gui.service is still active after 10s" "$(state firn-gui.service)" active
    check_eq "firn-gui.service never restarted" "$(prop firn-gui.service NRestarts)" 0
    check_eq "no failed units" "$(guest 'systemctl --failed --no-legend --plain | wc -l')" 0
}

# ---------------------------------------------------------------------------
# Leg 1: console, the menu default.
# ---------------------------------------------------------------------------
boot_leg console cdrom virtio
check_cmdline firn-console.target
check_eq "the TUI kiosk owns tty1" "$(state firn-kiosk.service)" active
check_eq "firn-gui.service is not started" "$(state firn-gui.service)" inactive
check "no compositor runs" guest '! pgrep -x cage'
check_serial_tui
check_eq "no failed units" "$(guest 'systemctl --failed --no-legend --plain | wc -l')" 0
report_memory
stop_vm

# ---------------------------------------------------------------------------
# Leg 2: graphical on virtio-vga, then Quit.
# ---------------------------------------------------------------------------
boot_leg graphical-virtio cdrom virtio g
check_cmdline firn-graphical.target
check_gui_up
check_serial_tui
report_memory
screenshot
guest 'pkill -TERM -x firn-gui' || true
if wait_state firn-kiosk.service active 30; then
    pass "Quit (firn-gui exits 0) hands tty1 to the TUI"
else
    fail "Quit (firn-gui exits 0) hands tty1 to the TUI" "firn-kiosk.service $(state firn-kiosk.service)"
fi
check_eq "firn-gui.service ended cleanly" "$(prop firn-gui.service Result)" success
check "cage exited with firn-gui" guest '! pgrep -x cage'
stop_vm

# ---------------------------------------------------------------------------
# Leg 3: graphical from the ESP (USB-stick layout) on std VGA.
# ---------------------------------------------------------------------------
boot_leg graphical-std-disk disk std g
check_cmdline firn-graphical.target
check_gui_up
check_serial_tui
report_memory
screenshot
stop_vm

# ---------------------------------------------------------------------------
# Leg 4: graphical with no display -> console fallback.
# ---------------------------------------------------------------------------
boot_leg graphical-no-display cdrom none g
check_cmdline firn-graphical.target
check "the guest has no DRM device" guest '! ls /dev/dri/card* >/dev/null 2>&1'
if wait_state firn-kiosk.service active 60; then
    pass "the TUI takes tty1 when there is no display"
else
    fail "the TUI takes tty1 when there is no display" "firn-kiosk.service $(state firn-kiosk.service)"
fi
check_eq "firn-gui-session exited 77" "$(prop firn-gui.service ExecMainStatus)" 77
check_eq "the fallback skipped the restarts" "$(prop firn-gui.service NRestarts)" 0
check "no compositor runs" guest '! pgrep -x cage'
check_serial_tui
report_memory
stop_vm

echo ""
echo "# Results: $PASS passed, $FAIL failed, $((PASS + FAIL)) total"
[[ $FAIL -eq 0 ]]
