#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Validates the network-installer ISO's Debian-trusted, pre-enrollment
# Secure Boot chain (docs/native-ab-contracts.md §8; Phase 8 of
# docs/plans/2026-07-14-bootc-native-ab-coexistence-plan.md "Installer
# ISO"). Four parts:
#
#   1. Build mkosi.profiles/native-installer, then
#      shared/native-installer/tools/build-iso.sh to assemble the ISO.
#   2. Structural checks against the built ESP (loop-mounted, no boot
#      needed): shim at EFI/BOOT/BOOTX64.EFI, signed GRUB + MokManager
#      present, grub.cfg content, kernel/shim/grub/mmx64 signatures
#      (sbverify issuer/subject strings), and the installer userspace's
#      packed initramfs has the coherent Forky systemd 261 family plus
#      gpgv/cryptsetup.
#   3. QEMU positive boot: Secure Boot ENFORCED, against the STOCK
#      Microsoft-only OVMF varstore (OVMF_VARS_4M.ms.fd, copied fresh --
#      NO Snosi MOK ever enrolled into it) -- the ISO must reach the
#      installer userspace over SSH and report `mokutil --sb-state` as
#      enabled. This is the positive proof of the pre-enrollment chain:
#      Microsoft db -> Debian-signed shim -> Debian-signed GRUB ->
#      Debian-signed stock kernel, no Snosi MOK anywhere.
#   4. QEMU negative proof, same never-enrolled varstore: booting a
#      Snosi-MOK-signed artifact (grub's own UNSIGNED monolithic EFI
#      image, signed here with the project's real mkosi.key/mkosi.crt --
#      the same key shared/native-ab-secure/mkosi.conf uses for every
#      production native profile) in place of the trusted GRUB must FAIL
#      -- shim itself rejects it ("Security Violation") since neither `db`
#      nor MokList trusts that signer. This proves step 3 is a genuine
#      Secure Boot enforcement result, not an accidentally-permissive OVMF
#      configuration.
#
# Usage: sudo ./test/native-installer-iso-test.sh
# Env overrides: SSH_PORT (2233), SSH_TIMEOUT (240), VM_MEMORY (4096),
# VM_CPUS (2), SKIP_BUILD (0 -- set to 1 to reuse an existing
# output/native-installer + output/native-installer.iso), KEEP_VM (0).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

: "${SSH_PORT:=2233}"
: "${SSH_TIMEOUT:=240}"
# The installer's own hardware-firmware package block (Task 8.2, real
# network installs on physical machines) roughly doubled the packed-rootfs-
# as-initramfs size (~190MiB -> ~448MiB compressed / rootfs ~1.1GiB
# uncompressed). The kernel unpacks that whole cpio archive into tmpfs
# BEFORE any of this test's own SSH/console checks can run, and doing so
# needs the compressed blob AND its fully unpacked tmpfs content
# simultaneously resident -- root-caused live: at the old 2048MiB default
# this failed with "Initramfs unpacking failed: write error" (tmpfs ENOSPC,
# i.e. genuinely out of RAM) followed by a kernel panic ("Unable to mount
# root fs on unknown-block(0,0)", since a no-/init initramfs falls back to
# looking for a root= block device that does not exist here), well before
# reaching userspace. 4096MiB leaves ample headroom over that ~1.5GiB peak;
# real installer hardware is not expected to be memory-constrained the way
# a minimal test fixture might be.
: "${VM_MEMORY:=4096}"
: "${VM_CPUS:=2}"
: "${SKIP_BUILD:=0}"
: "${KEEP_VM:=0}"

# This dev host may itself be an immutable/bootc-managed system where
# `apt-get install` cannot add tools system-wide (see
# test/native-ab-secure-boot-test.sh's identical note) -- swtpm/virt-fw-vars
# equivalents there are resolved via linuxbrew/pip --user. This script has
# no such dependency itself; every required command below is expected to be
# a normal host package (sbsigntool, mtools, dosfstools, xorriso, OVMF,
# qemu-system-x86_64) on a real CI runner.
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/ssh.sh"

PASS=0
FAIL=0
pass() { echo "ok - $1"; PASS=$((PASS + 1)); }
fail() { echo "not ok - $1" >&2; [[ $# -lt 2 ]] || echo "  $2" >&2; FAIL=$((FAIL + 1)); }
assert_contains() { # description haystack needle
    if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1" "expected to find: $3 -- got: $2"; fi
}
assert_not_contains() { # description haystack needle
    if [[ "$2" != *"$3"* ]]; then pass "$1"; else fail "$1" "expected NOT to find: $3"; fi
}
assert_true() { local desc="$1"; shift; if "$@"; then pass "$desc"; else fail "$desc" "command failed: $*"; fi; }
print_summary() { echo ""; echo "# Results: $PASS passed, $FAIL failed, $((PASS + FAIL)) total"; exit "$FAIL"; }

for cmd in jq mkfs.vfat mcopy mmd mdir xorriso sbverify sbsign losetup qemu-system-x86_64 \
    cpio zstd ssh-keygen openssl; do
    command -v "$cmd" >/dev/null || { echo "Error: required command not found: $cmd" >&2; exit 1; }
done

MKOSI_VARS_DIR=/usr/share/OVMF
OVMF_CODE_SRC="$MKOSI_VARS_DIR/OVMF_CODE_4M.secboot.fd"
OVMF_VARS_SRC="$MKOSI_VARS_DIR/OVMF_VARS_4M.ms.fd"
[[ -f "$OVMF_CODE_SRC" ]] || { echo "Error: missing $OVMF_CODE_SRC" >&2; exit 1; }
[[ -f "$OVMF_VARS_SRC" ]] || { echo "Error: missing $OVMF_VARS_SRC" >&2; exit 1; }

WORK_DIR="$(mktemp -d /var/tmp/native-installer-iso-test.XXXXXX)"
QEMU_PID=""
LOOP_DEV=""
MNT_DIR=""
cleanup() {
    [[ -n "$QEMU_PID" ]] && kill -0 "$QEMU_PID" 2>/dev/null && kill -9 "$QEMU_PID" 2>/dev/null
    [[ -n "$MNT_DIR" && -d "$MNT_DIR" ]] && mountpoint -q "$MNT_DIR" 2>/dev/null && umount "$MNT_DIR" 2>/dev/null
    [[ -n "$LOOP_DEV" ]] && losetup -d "$LOOP_DEV" 2>/dev/null
    [[ "$KEEP_VM" == 1 ]] || rm -rf "$WORK_DIR"
}
trap cleanup EXIT

resolve_mkosi() {
    local commit dir
    commit="$(grep -m1 -oE 'systemd/mkosi@[0-9a-f]+' "$ROOT_DIR/.github/workflows/build.yml" | cut -d@ -f2)"
    dir="$ROOT_DIR/.mkosi"
    MKOSI="$dir/bin/mkosi"
    if [[ -x "$MKOSI" && "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" == "$commit" ]]; then
        echo "Using pinned mkosi @ $commit ($dir)"
        return
    fi
    echo "Installing mkosi @ $commit into $dir"
    rm -rf "$dir"
    git init -q "$dir"
    git -C "$dir" fetch -q --depth=1 https://github.com/systemd/mkosi.git "$commit"
    git -C "$dir" checkout -q --detach FETCH_HEAD
}

ROOTFS="$ROOT_DIR/output/native-installer"
OUTPUT_DIR="$ROOT_DIR/output"
VERSION="$(date -u +%Y%m%d%H%M%S)"
ISO="$OUTPUT_DIR/snosi-native-installer_${VERSION}_x86-64.iso"

if [[ "$SKIP_BUILD" != 1 ]]; then
    resolve_mkosi
    echo "=== Building native-installer profile ==="
    "$MKOSI" clean -ff --profile native-installer
    "$MKOSI" --profile native-installer build

    # Inject a fresh throwaway SSH key so the positive-boot proof (step 3)
    # can reach the installer userspace over SSH -- same pattern
    # test/bootc-install-test.sh / test/native-ab-updateux-test.sh use:
    # inject the pubkey into the built tree BEFORE packing, since this is
    # a live/RAM-only environment with no later "install to disk" step.
    ssh_keygen "$WORK_DIR"
    install -d -m 0700 "$ROOTFS/root/.ssh"
    install -m 0600 "$WORK_DIR/id_ed25519.pub" "$ROOTFS/root/.ssh/authorized_keys"

    echo "=== Assembling ISO ==="
    # build-iso.sh takes an OUTPUT DIRECTORY, not a file path: the exact
    # filename is not caller-controlled (docs/native-ab-contracts.md
    # "Installer ISO" -- snosi-native-installer_<version>_x86-64.iso), so a
    # caller can never accidentally build/publish a mis-named artifact.
    "$ROOT_DIR/shared/native-installer/tools/build-iso.sh" "$ROOTFS" "$OUTPUT_DIR" "$VERSION"
else
    # Reuse whatever was last built, whatever version it carries -- do NOT
    # keep the fresh $VERSION computed above once a different ISO is
    # substituted in, or every version-embedding assertion below (volid,
    # /etc/snosi-installer-release, filename) would compare the reused
    # ISO's real version against a version it was never built with.
    [[ -f "$ISO" ]] || {
        latest="$(ls -t "$OUTPUT_DIR"/snosi-native-installer_*_x86-64.iso 2>/dev/null | head -1 || true)"
        [[ -n "$latest" ]] || { echo "Error: SKIP_BUILD=1 but no snosi-native-installer_*_x86-64.iso found under $OUTPUT_DIR" >&2; exit 1; }
        ISO="$latest"
        VERSION="$(basename "$ISO" | sed -E 's/^snosi-native-installer_([0-9]{14})_x86-64\.iso$/\1/')"
        [[ "$VERSION" =~ ^[0-9]{14}$ ]] || { echo "Error: could not parse version from reused ISO filename: $ISO" >&2; exit 1; }
    }
    echo "SKIP_BUILD=1: reusing existing $ROOTFS / $ISO (version $VERSION)"
    ssh_keygen "$WORK_DIR"
    echo "NOTE: SKIP_BUILD reuses whatever SSH key (if any) is already baked into $ROOTFS/root/.ssh/authorized_keys"
fi

[[ -d "$ROOTFS" ]] || { echo "Error: missing built rootfs: $ROOTFS" >&2; exit 1; }
[[ -f "$ISO" ]] || { echo "Error: missing built ISO: $ISO" >&2; exit 1; }

# ===========================================================================
# Structural checks (no boot needed)
# ===========================================================================
echo ""
echo "=== Structural checks ==="

assert_eq() { # description actual expected
    if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi
}
assert_eq "ISO filename matches the frozen public name (docs/native-ab-contracts.md \"Installer ISO\")" \
    "$(basename "$ISO")" "snosi-native-installer_${VERSION}_x86-64.iso"

MNT_DIR="$WORK_DIR/esp-mnt"
mkdir -p "$MNT_DIR"
LOOP_DEV="$(losetup -P -f --show "$ISO")"

iso_label="$(blkid -o value -s LABEL "$LOOP_DEV" 2>/dev/null || true)"
assert_contains "ISO volume ID embeds the version" "$iso_label" "$VERSION"

mount -o ro "${LOOP_DEV}p2" "$MNT_DIR"

assert_true "shim present at EFI/BOOT/BOOTX64.EFI" test -f "$MNT_DIR/EFI/BOOT/BOOTX64.EFI"
assert_true "signed GRUB present at EFI/BOOT/grubx64.efi" test -f "$MNT_DIR/EFI/BOOT/grubx64.efi"
assert_true "MokManager present at EFI/BOOT/mmx64.efi" test -f "$MNT_DIR/EFI/BOOT/mmx64.efi"
assert_true "grub.cfg present at the baked-in /EFI/debian prefix" test -f "$MNT_DIR/EFI/debian/grub.cfg"
assert_true "vmlinuz present on the ESP" test -f "$MNT_DIR/native-installer/vmlinuz"
assert_true "initrd present on the ESP" test -f "$MNT_DIR/native-installer/initrd.img"
# fbx64.efi is deliberately never shipped -- see build-iso.sh's step-1
# comment (it reproducibly crashes shim under OVMF on this El Torito/GPT
# layout). Its absence is asserted so a future accidental re-addition
# fails this test instead of silently reintroducing the crash.
assert_true "fbx64.efi (fallback loader) deliberately NOT shipped" \
    bash -c '[[ ! -e "$1" ]]' _ "$MNT_DIR/EFI/BOOT/fbx64.efi"

grub_cfg_content="$(cat "$MNT_DIR/EFI/debian/grub.cfg")"
assert_contains "grub.cfg loads the installer kernel" "$grub_cfg_content" "/native-installer/vmlinuz"
assert_contains "grub.cfg loads the installer initrd" "$grub_cfg_content" "/native-installer/initrd.img"
assert_contains "grub.cfg is non-interactive (timeout=0)" "$grub_cfg_content" "set timeout=0"

shim_sig="$(sbverify --list "$MNT_DIR/EFI/BOOT/BOOTX64.EFI" 2>&1 || true)"
assert_contains "shim is Microsoft-signed (trusted via db, no enrollment)" "$shim_sig" "Microsoft"
grub_sig="$(sbverify --list "$MNT_DIR/EFI/BOOT/grubx64.efi" 2>&1 || true)"
assert_contains "GRUB is Debian-signed (trusted via shim's vendor cert)" "$grub_sig" "Debian Secure Boot"
mm_sig="$(sbverify --list "$MNT_DIR/EFI/BOOT/mmx64.efi" 2>&1 || true)"
assert_contains "MokManager is Debian-signed" "$mm_sig" "Debian Secure Boot"

kernel_sig="$(sbverify --list "$MNT_DIR/native-installer/vmlinuz" 2>&1 || true)"
assert_contains "kernel is Debian-signed" "$kernel_sig" "Debian Secure Boot"
assert_contains "kernel signer is the linux signing key specifically" "$kernel_sig" "linux"

manifest="$ROOT_DIR/output/native-installer.manifest"
if [[ -f "$manifest" ]]; then
    systemd_version="$(jq -er '.packages[] | select(.name == "systemd") | .version' "$manifest")"
    assert_true "installer userspace systemd is >= 261 (coherent Forky family, contract §8)" \
        dpkg --compare-versions "$systemd_version" ge 261
    for pkg in systemd-cryptsetup systemd-tpm libsystemd0 udev; do
        pkg_version="$(jq -er --arg p "$pkg" '.packages[] | select(.name == $p) | .version' "$manifest")"
        assert_contains "$pkg is from the same Forky build as systemd ($systemd_version)" "$pkg_version" "$systemd_version"
    done
else
    fail "native-installer.manifest present for systemd-family version check" "not found: $manifest"
fi

initrd_list="$WORK_DIR/initrd.list"
zstd -dc "$MNT_DIR/native-installer/initrd.img" 2>/dev/null | cpio -t --quiet 2>/dev/null > "$initrd_list" || true
assert_contains "initrd contains gpgv (signed index verification)" "$(cat "$initrd_list")" "usr/bin/gpgv"
# Anchored to the real binary path (both /sbin/cryptsetup and
# /usr/sbin/cryptsetup exist in a merged-/usr tree, the latter being a real
# file and the former a symlink to it) -- an earlier unanchored
# "cryptsetup$" pattern would also silently pass against any unrelated path
# that happened to end in that literal string.
assert_true "initrd contains cryptsetup" grep -q "usr/sbin/cryptsetup$" "$initrd_list"
assert_true "initrd contains mokutil" grep -q "usr/bin/mokutil$" "$initrd_list"
assert_true "initrd contains the product-aware CLI installer" \
    grep -q "usr/libexec/snosi-install$" "$initrd_list"
# cpio -t (no -v) lists names only, not symlink targets -- -tv is needed to
# see "init -> usr/lib/systemd/systemd" the way ls -l/tar -tv would show it.
initrd_verbose_list="$WORK_DIR/initrd.verbose.list"
zstd -dc "$MNT_DIR/native-installer/initrd.img" 2>/dev/null | cpio -tv --quiet 2>/dev/null > "$initrd_verbose_list" || true
assert_true "initrd's /init points at systemd (no switch_root design)" \
    grep -q "init -> usr/lib/systemd/systemd$" "$initrd_verbose_list"

release_content="$(zstd -dc "$MNT_DIR/native-installer/initrd.img" 2>/dev/null | \
    cpio -i --quiet --to-stdout 'etc/snosi-installer-release' 2>/dev/null || true)"
assert_contains "/etc/snosi-installer-release embeds the ISO version" \
    "$release_content" "SNOSI_INSTALLER_VERSION=${VERSION}"

assert_true "shipped update pubring present at /usr/lib/snosi/os-update-pubring.gpg" \
    grep -q "usr/lib/snosi/os-update-pubring.gpg$" "$initrd_list"
assert_true "shipped MOK dev certificate present at /usr/lib/snosi/mok-dev.crt" \
    grep -q "usr/lib/snosi/mok-dev.crt$" "$initrd_list"

umount "$MNT_DIR"
losetup -d "$LOOP_DEV"
MNT_DIR=""
LOOP_DEV=""

# ===========================================================================
# Step 3: QEMU positive boot -- Secure Boot ENFORCED, never-enrolled
# stock Microsoft varstore
# ===========================================================================
echo ""
echo "=== Step 3: positive boot (Secure Boot enforced, never-enrolled varstore) ==="

vars_pos="$WORK_DIR/OVMF_VARS.pos.fd"
cp "$OVMF_VARS_SRC" "$vars_pos"

serial_pos="$WORK_DIR/console.pos.log"
qemu-system-x86_64 \
    -machine q35 \
    -enable-kvm -cpu host \
    -m "$VM_MEMORY" -smp "$VM_CPUS" \
    -drive "if=pflash,format=raw,unit=0,file=$OVMF_CODE_SRC,readonly=on" \
    -drive "if=pflash,format=raw,unit=1,file=$vars_pos" \
    -cdrom "$ISO" \
    -netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22" \
    -device virtio-net-pci,netdev=net0 \
    -display none -vga none \
    -serial "file:$serial_pos" \
    -monitor none \
    -pidfile "$WORK_DIR/qemu.pos.pid" \
    -daemonize
QEMU_PID="$(cat "$WORK_DIR/qemu.pos.pid")"
echo "Positive-boot VM started (PID $QEMU_PID)"

if SSH_TIMEOUT="$SSH_TIMEOUT" wait_for_ssh; then
    pass "positive boot: ISO reaches the installer userspace over SSH"
    sb_state="$(vm_ssh mokutil --sb-state 2>&1 || true)"
    assert_contains "mokutil reports Secure Boot enabled" "$sb_state" "SecureBoot enabled"
    # The EFI stub's own "Secure Boot is enabled" line is printed by the PE
    # loader stub BEFORE the kernel proper (and its printk ring buffer)
    # exist -- it only ever reaches the raw serial console, never `dmesg`
    # inside the running system (confirmed live: `dmesg` over SSH never has
    # it, even though it captures everything from t=0.000000 onward).
    assert_contains "kernel EFI stub confirms Secure Boot is enabled (console)" \
        "$(cat "$serial_pos" 2>/dev/null || true)" "UEFI Secure Boot is enabled"
    dmesg_out="$(vm_ssh dmesg 2>&1 || true)"
    assert_contains "kernel is locked down from EFI Secure Boot" "$dmesg_out" "locked down from EFI Secure Boot"
    hostname_out="$(vm_ssh hostname 2>&1 || true)"
    assert_contains "reached the packed-rootfs installer userspace (no switch_root)" "$hostname_out" "snosi-installer"
    vm_ssh systemctl poweroff >/dev/null 2>&1 || true
else
    echo "=== console log (positive boot never reached SSH) ===" >&2
    tail -100 "$serial_pos" >&2 || true
    fail "positive boot: ISO reaches the installer userspace over SSH" "SSH never came up within ${SSH_TIMEOUT}s"
fi

sleep 2
kill -9 "$QEMU_PID" 2>/dev/null || true
QEMU_PID=""

# ===========================================================================
# Step 4: negative proof -- a Snosi-MOK-signed artifact on the SAME
# never-enrolled varstore must be REJECTED by shim
# ===========================================================================
echo ""
echo "=== Step 4: negative proof (Snosi-MOK-signed artifact, never-enrolled varstore) ==="

# Sign grub's own UNSIGNED monolithic EFI image with the project's real
# Secure Boot key (mkosi.key/mkosi.crt -- the same key
# shared/native-ab-secure/mkosi.conf uses for cayo-ab/snow-ab/snowfield-ab).
# A genuine Snosi-MOK-signed artifact, no product rebuild required.
unsigned_grub="$ROOTFS/usr/lib/grub/x86_64-efi/monolithic/grubx64.efi"
[[ -f "$unsigned_grub" ]] || { echo "Error: missing unsigned grub image: $unsigned_grub" >&2; exit 1; }
[[ -f "$ROOT_DIR/mkosi.key" && -f "$ROOT_DIR/mkosi.crt" ]] || {
    echo "Error: missing mkosi.key/mkosi.crt (local Secure Boot signing key -- gitignored dev material)" >&2
    exit 1
}
mok_signed_stub="$WORK_DIR/snosi-mok-signed.efi"
sbsign --key "$ROOT_DIR/mkosi.key" --cert "$ROOT_DIR/mkosi.crt" \
    --output "$mok_signed_stub" "$unsigned_grub" >/dev/null
mok_sig="$(sbverify --list "$mok_signed_stub" 2>&1 || true)"
assert_contains "negative-test fixture is genuinely Snosi-MOK-signed" "$mok_sig" "snosi Secure Boot validation"

# Small GPT+ESP disk (no El Torito needed for this -- a plain virtio-blk
# GPT disk boots identically as far as shim/GRUB verification is
# concerned): real Debian-signed shim + mmx64 from the built rootfs, but
# grubx64.efi swapped for the Snosi-MOK-signed stub. Same chain shim
# verifies in the real ISO, only the final artifact's signer differs.
neg_esp="$WORK_DIR/negative-esp.img"
truncate -s 64M "$neg_esp"
mkfs.vfat -F 32 -n SNOSI_NEG "$neg_esp" >/dev/null
mmd -i "$neg_esp" ::EFI ::EFI/BOOT
mcopy -i "$neg_esp" "$ROOTFS/usr/lib/shim/shimx64.efi.signed" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$neg_esp" "$mok_signed_stub" ::EFI/BOOT/grubx64.efi
mcopy -i "$neg_esp" "$ROOTFS/usr/lib/shim/mmx64.efi.signed" ::EFI/BOOT/mmx64.efi

vars_neg="$WORK_DIR/OVMF_VARS.neg.fd"
cp "$OVMF_VARS_SRC" "$vars_neg"

serial_neg="$WORK_DIR/console.neg.log"
qemu-system-x86_64 \
    -machine q35 \
    -enable-kvm -cpu host \
    -m 1024 -smp 1 \
    -drive "if=pflash,format=raw,unit=0,file=$OVMF_CODE_SRC,readonly=on" \
    -drive "if=pflash,format=raw,unit=1,file=$vars_neg" \
    -drive "file=$neg_esp,format=raw,if=virtio,readonly=on" \
    -display none -vga none \
    -serial "file:$serial_neg" \
    -monitor none \
    -pidfile "$WORK_DIR/qemu.neg.pid" \
    -daemonize
QEMU_PID="$(cat "$WORK_DIR/qemu.neg.pid")"
echo "Negative-proof VM started (PID $QEMU_PID)"

# No SSH is ever expected to come up; poll briefly for the console to
# report shim's rejection instead of blocking for the full SSH_TIMEOUT.
deadline=$((SECONDS + 30))
neg_console=""
while (( SECONDS < deadline )); do
    neg_console="$(cat "$serial_neg" 2>/dev/null || true)"
    [[ "$neg_console" == *"Security Violation"* ]] && break
    sleep 2
done
assert_contains "shim rejects the Snosi-MOK-signed artifact (Security Violation)" \
    "$neg_console" "Security Violation"
assert_not_contains "negative boot never reaches a shell/SSH-capable userspace" \
    "$neg_console" "systemd-journald"

kill -9 "$QEMU_PID" 2>/dev/null || true
QEMU_PID=""

echo ""
echo "Native-installer ISO boot-chain validation complete"
print_summary
