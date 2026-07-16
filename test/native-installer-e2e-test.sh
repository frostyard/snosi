#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Phase 8 exit: end-to-end proof that a clean VM can boot the (locally
# standing-in-for-R2) network-installer ISO, install a real product from a
# signed local origin, complete MOK enrollment, and reach the installed
# system with Secure Boot enforced and unattended TPM unlock of /var
# (docs/plans/2026-07-14-bootc-native-ab-coexistence-plan.md Phase 8 exit
# criterion; docs/native-ab-contracts.md §7/§8).
#
# Controller scoping (this is a local rehearsal, not a real R2 fetch): a
# local origin (test/lib/range-http-server.py) stands in for
# repository.frostyard.org -- identical URL layout
# (os/native/v1/<product>/x86-64), a real signed index, and the SAME stock
# shipped pubring (shared/native-ab/keys/import-pubring.gpg) every real
# client trusts. No keyring is ever injected into a built image or the ISO;
# every gpgv call in this test verifies against exactly what ships. MokManager's
# one-time interactive UI approval is simulated by host-side `virt-fw-vars
# --add-mok` injection into the SAME OVMF varstore the install ran against --
# the mokutil staging itself (mokutil --import, --list-new, --restage-mok) IS
# exercised for real; only the blue-screen keypress is out of scope, matching
# the plan's documented "Automatic MokManager interaction" non-goal.
#
# Own-boot-medium risk retired empirically before writing this test: probing
# a real built ISO via a loop device confirms xorriso's -appended_part_as_gpt
# hybrid layout makes `blkid` report TYPE=iso9660 (and the matching LABEL) on
# the WHOLE-DISK node, not only a child partition -- so attaching the ISO to
# QEMU as a virtio-blk WHOLE DISK (not -cdrom), exactly like a real `dd`'d
# USB installer stick, is what makes disk_is_installer_medium() (snosi-install)
# actually observe an ISO9660-labeled candidate disk. -cdrom (used by
# test/native-installer-iso-test.sh for the Debian-trust boot-chain proof)
# would attach as lsblk TYPE=rom, invisible to snosi-install's disk
# enumeration (`.type == "disk"` only) -- it would never exercise this code
# path. This test always attaches the ISO as a plain virtio-blk disk.
#
# Sequence per product (brief numbering):
#   1. (once, before any VM) build the ISO fresh, build+publish cayo-ab and
#      snow-ab through the real prepare -> candidate -> verify -> promote
#      pipeline (shared/native-ab/publish/*.sh) with the committed DEV
#      signing key, to a local origin.
#   2. Boot the ISO (virgin OVMF_VARS_4M.ms.fd, swtpm, blank target disk of
#      the product's documented minimum size + a fixed margin -- see
#      TARGET_SIZE_MARGIN below for why a margin is needed to prove growth).
#   3. In-ISO negative FIRST: point snosi-install at the ISO's own device;
#      assert the own-boot-medium refusal (cayo-ab only -- product-agnostic
#      logic, proven once; brief step 8).
#   4. In-ISO non-interactive install: a world-readable --mok-password-file
#      is refused (check_secret_file_perms) only after the full destructive
#      write/format/TPM-enrollment pipeline has already run (that check sits
#      near the very end of snosi-install's main()) -- rather than throwing
#      that real, fully-installed-except-MOK disk away and re-downloading a
#      multi-GiB image a second time, this test completes the SAME install
#      with `snosi-install --restage-mok` and a properly-permissioned
#      password file, which is both realistic (this is restage-mok's actual
#      documented purpose: recovering a skipped/failed MOK step without
#      reinstalling) and the efficient path.
#   5. Pre-enrollment negative: reboot the SAME varstore into the TARGET disk
#      alone; shim must reject the MOK-signed systemd-boot ("Security
#      Violation").
#   6. --restage-mok, dedicated: boot the ISO again (a fresh power cycle) and
#      stage one more MOK request with a NEW password file (cayo-ab only;
#      product-agnostic mechanic, brief step 8).
#   7. Host-side MOK injection (virt-fw-vars --add-mok on the SAME varstore)
#      simulates the one-time MokManager approval; boot the target disk
#      alone and assert the fully enforced, fully unattended end state.
#
# Usage: sudo ./test/native-installer-e2e-test.sh [--with-snowfield]
# Env overrides: SKIP_ISO_BUILD=1 (reuse output/snosi-native-installer_*),
# SKIP_CAYO_BUILD=1 / SKIP_SNOW_BUILD=1 with BUILD_CAYO_DIR / BUILD_SNOW_DIR
# pointing at a previously copied-out split-artifact dir (see
# copy_build_artifacts below) to skip a multi-GiB rebuild during iteration,
# VM_MEMORY (4096), VM_CPUS (2), KEEP_VM (0 -- 1 keeps WORK_DIR + running
# state for post-mortem).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PUBLISH_DIR="$ROOT_DIR/shared/native-ab/publish"

: "${SSH_TIMEOUT:=300}"
: "${VM_MEMORY:=4096}"
: "${VM_CPUS:=2}"
: "${KEEP_VM:=0}"
: "${SKIP_ISO_BUILD:=0}"
: "${SKIP_CAYO_BUILD:=0}"
: "${SKIP_SNOW_BUILD:=0}"
: "${BUILD_CAYO_DIR:=}"
: "${BUILD_SNOW_DIR:=}"
: "${SOURCE_PORT:=18700}"

WITH_SNOWFIELD=0
for arg in "$@"; do
    case "$arg" in
        --with-snowfield) WITH_SNOWFIELD=1 ;;
        *) echo "Error: unknown argument: $arg" >&2; exit 2 ;;
    esac
done

SIGNING_KEY="$ROOT_DIR/.snosi-private/os-update-signing.key"
PUBRING="$ROOT_DIR/shared/native-ab/keys/import-pubring.gpg"
MOK_CERT="$ROOT_DIR/mkosi.crt"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/ssh.sh"

# Redefine ssh.sh's vm_ssh (deliberately -- not editing the shared library
# every other harness relies on) to always export a full PATH on the
# remote side first. Root-caused live (2026-07-15, this script's first
# real VM-boot attempt after fixing the snosi-install-not-on-PATH bug):
# OpenSSH's non-interactive `ssh host cmd` sessions do not source /etc/
# profile (no login shell, no PAM environment), so the remote shell starts
# with whatever minimal PATH sshd itself sets -- which on this packed-
# rootfs-as-initramfs ISO lacks /usr/sbin (sfdisk, blockdev, wipefs,
# mkfs.ext4, udevadm, cryptsetup, blkid) and /usr/libexec (snosi-install
# itself). snosi-install's own startup tool-check loop dies immediately on
# the first /usr/sbin-only command (`sfdisk`) it hits. mokutil/lsblk/jq/
# gpgv/curl (all /usr/bin) had already worked, which is what made the
# failure mode confusing at first: it looked like an install-time bug, not
# an SSH-environment one. This wrapper fixes it exactly once, for every
# vm_ssh call in this whole script (including snosi-install's OWN internal
# shellouts, which inherit whatever PATH the remote shell starts with) --
# without touching test/lib/ssh.sh, which other, already-green QEMU
# harnesses depend on unchanged.
vm_ssh() {
    [[ -n "${SSH_KEY:-}" ]] || { echo "Error: SSH_KEY is not set; call ssh_keygen first" >&2; return 1; }
    ssh "${SSH_OPTS[@]}" -p "$SSH_PORT" -i "$SSH_KEY" root@localhost \
        "export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/libexec;" "$@"
}

PASS=0
FAIL=0
pass() { echo "ok - $1"; PASS=$((PASS + 1)); }
fail() { echo "not ok - $1" >&2; [[ $# -lt 2 ]] || echo "  $2" >&2; FAIL=$((FAIL + 1)); }
assert_eq() { # description actual expected
    if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi
}
assert_true() { local desc="$1"; shift; if "$@"; then pass "$desc"; else fail "$desc" "command failed: $*"; fi; }
assert_false() { local desc="$1"; shift; if "$@"; then fail "$desc" "command unexpectedly succeeded: $*"; else pass "$desc"; fi; }
assert_contains() { # description haystack needle
    if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1" "expected to find: $3 -- got: $2"; fi
}
assert_not_contains() { # description haystack needle
    if [[ "$2" != *"$3"* ]]; then pass "$1"; else fail "$1" "expected NOT to find: $3 -- got: $2"; fi
}
print_summary() { echo ""; echo "# Results: $PASS passed, $FAIL failed, $((PASS + FAIL)) total"; exit "$FAIL"; }

[[ $EUID -eq 0 ]] || { echo "Error: must run as root (loop devices, QEMU/KVM, LUKS)" >&2; exit 1; }

for cmd in jq mkfs.vfat mcopy mmd mdir xorriso sbverify sbsign losetup qemu-system-x86_64 \
    cpio zstd ssh-keygen scp openssl mokutil virt-fw-vars swtpm sfdisk cryptsetup gpgv \
    python3 sha256sum git xz curl; do
    command -v "$cmd" >/dev/null || { echo "Error: required command not found: $cmd" >&2; exit 1; }
done
[[ -s "$SIGNING_KEY" ]] || { echo "Error: missing DEV signing key: $SIGNING_KEY" >&2; exit 1; }
[[ -s "$PUBRING" ]] || { echo "Error: missing stock pubring: $PUBRING" >&2; exit 1; }
[[ -s "$MOK_CERT" ]] || { echo "Error: missing MOK certificate: $MOK_CERT (gitignored dev material)" >&2; exit 1; }

MKOSI_VARS_DIR=/usr/share/OVMF
OVMF_CODE_SRC="$MKOSI_VARS_DIR/OVMF_CODE_4M.secboot.fd"
OVMF_VARS_SRC="$MKOSI_VARS_DIR/OVMF_VARS_4M.ms.fd"
[[ -f "$OVMF_CODE_SRC" ]] || { echo "Error: missing $OVMF_CODE_SRC" >&2; exit 1; }
[[ -f "$OVMF_VARS_SRC" ]] || { echo "Error: missing $OVMF_VARS_SRC" >&2; exit 1; }

WORK_DIR="$(mktemp -d /var/tmp/native-installer-e2e-test.XXXXXX)"
QEMU_PID=""
SWTPM_PID=""
HTTP_PID=""
cleanup() {
    [[ -n "$QEMU_PID" ]] && kill -0 "$QEMU_PID" 2>/dev/null && kill -9 "$QEMU_PID" 2>/dev/null
    [[ -n "$SWTPM_PID" ]] && kill -0 "$SWTPM_PID" 2>/dev/null && kill -9 "$SWTPM_PID" 2>/dev/null
    [[ -n "$HTTP_PID" ]] && kill "$HTTP_PID" 2>/dev/null
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

# ===========================================================================
# Step 1: build the ISO fresh, build + publish cayo-ab and snow-ab
# ===========================================================================
echo ""
echo "=== Step 1: build ISO + cayo-ab + snow-ab, publish to a local origin ==="
echo "started $(date -u +%FT%TZ)"

resolve_mkosi

ROOTFS="$ROOT_DIR/output/native-installer"
OUTPUT_DIR="$ROOT_DIR/output"
ISO_VERSION="$(date -u +%Y%m%d%H%M%S)"
ISO="$OUTPUT_DIR/snosi-native-installer_${ISO_VERSION}_x86-64.iso"

ssh_keygen "$WORK_DIR"

if [[ "$SKIP_ISO_BUILD" != 1 ]]; then
    echo "--- building native-installer profile ($(date -u +%FT%TZ)) ---"
    "$MKOSI" clean -ff --profile native-installer
    "$MKOSI" --profile native-installer build
    install -d -m 0700 "$ROOTFS/root/.ssh"
    install -m 0600 "$WORK_DIR/id_ed25519.pub" "$ROOTFS/root/.ssh/authorized_keys"
    echo "--- assembling ISO ($(date -u +%FT%TZ)) ---"
    "$ROOT_DIR/shared/native-installer/tools/build-iso.sh" "$ROOTFS" "$OUTPUT_DIR" "$ISO_VERSION"
else
    latest="$(ls -t "$OUTPUT_DIR"/snosi-native-installer_*_x86-64.iso 2>/dev/null | head -1 || true)"
    [[ -n "$latest" ]] || { echo "Error: SKIP_ISO_BUILD=1 but no existing ISO found" >&2; exit 1; }
    ISO="$latest"
    ISO_VERSION="$(basename "$ISO" | sed -E 's/^snosi-native-installer_([0-9]{14})_x86-64\.iso$/\1/')"
    echo "SKIP_ISO_BUILD=1: reusing $ISO"
    install -d -m 0700 "$ROOTFS/root/.ssh"
    install -m 0600 "$WORK_DIR/id_ed25519.pub" "$ROOTFS/root/.ssh/authorized_keys"
    echo "NOTE: SKIP_ISO_BUILD reuses whatever SSH key is already baked into the reused ISO; if that ISO predates this run's key, ISO SSH access will fail."
fi
[[ -f "$ISO" ]] || { echo "Error: missing built ISO: $ISO" >&2; exit 1; }

# Copy the ISO OUT of mkosi's OutputDirectory immediately, before the
# cayo-ab/snow-ab `mkosi build` invocations below run: empirically observed
# live (2026-07-15, first run of this script) that mkosi's own output-
# directory handling deletes files unrelated to the CURRENT build target
# from $OUTPUT_DIR on every subsequent `mkosi build` (the ISO -- and the
# PRIOR profile's own split artifacts -- vanished the moment the next
# profile finished building, well before this script ever got to a VM
# boot). copy_build_artifacts() below already existed to solve exactly this
# for cayo-ab/snow-ab's own split outputs; the ISO -- a single self-
# contained file -- needs the identical treatment. From here on, every
# reference to $ISO in this script MUST be this copied path, never the
# original $OUTPUT_DIR one.
ISO_STABLE="$WORK_DIR/$(basename "$ISO")"
cp --sparse=always "$ISO" "$ISO_STABLE"
ISO="$ISO_STABLE"
echo "ISO ready (copied out of \$OUTPUT_DIR before it can be wiped by the next mkosi build): $ISO"

# copy_build_artifacts profile image_id dest -- copies mkosi's split outputs
# for one built native profile into a stable dest dir (mkosi's own output/
# gets overwritten by the NEXT profile build), matching
# test/native-ab-publication-test.sh's build_profile().
copy_build_artifacts() { # profile image_id dest
    local profile="$1" image_id="$2" dest="$3"
    mkdir -p "$dest"
    for suffix in manifest raw efi "${image_id}_@v.root.raw.raw" "${image_id}_@v.root-verity.raw.raw"; do
        cp --sparse=always "$OUTPUT_DIR/$profile.$suffix" "$dest/"
    done
}

if [[ "$SKIP_CAYO_BUILD" != 1 ]]; then
    echo "--- building cayo-ab ($(date -u +%FT%TZ)) ---"
    "$MKOSI" --profile cayo-ab --force build
    BUILD_CAYO_DIR="$WORK_DIR/build-cayo-ab"
    copy_build_artifacts cayo-ab cayo "$BUILD_CAYO_DIR"
else
    [[ -d "$BUILD_CAYO_DIR" ]] || { echo "Error: SKIP_CAYO_BUILD=1 but BUILD_CAYO_DIR not set/found" >&2; exit 1; }
    echo "SKIP_CAYO_BUILD=1: reusing $BUILD_CAYO_DIR"
fi

if [[ "$SKIP_SNOW_BUILD" != 1 ]]; then
    echo "--- building snow-ab ($(date -u +%FT%TZ)) ---"
    "$MKOSI" --profile snow-ab --force build
    BUILD_SNOW_DIR="$WORK_DIR/build-snow-ab"
    copy_build_artifacts snow-ab snow "$BUILD_SNOW_DIR"
else
    [[ -d "$BUILD_SNOW_DIR" ]] || { echo "Error: SKIP_SNOW_BUILD=1 but BUILD_SNOW_DIR not set/found" >&2; exit 1; }
    echo "SKIP_SNOW_BUILD=1: reusing $BUILD_SNOW_DIR"
fi
echo "Product builds done ($(date -u +%FT%TZ))"

ORIGIN_DEST="$WORK_DIR/origin"
mkdir -p "$ORIGIN_DEST"

echo "--- prepare-native-publication.sh --xz (cayo-ab, snow-ab) ---"
"$PUBLISH_DIR/prepare-native-publication.sh" --xz "$BUILD_CAYO_DIR" cayo-ab "$ORIGIN_DEST" >&2
"$PUBLISH_DIR/prepare-native-publication.sh" --xz "$BUILD_SNOW_DIR" snow-ab "$ORIGIN_DEST" >&2
PREPARED_CAYO="$ORIGIN_DEST/cayo/x86-64"
PREPARED_SNOW="$ORIGIN_DEST/snow/x86-64"
VERSION_CAYO="$(jq -er '.version' "$PREPARED_CAYO/publication-info.json")"
VERSION_SNOW="$(jq -er '.version' "$PREPARED_SNOW/publication-info.json")"
echo "cayo-ab version: $VERSION_CAYO   snow-ab version: $VERSION_SNOW"

python3 "$ROOT_DIR/test/lib/range-http-server.py" "$SOURCE_PORT" "$ORIGIN_DEST" >"$WORK_DIR/http.log" 2>&1 &
HTTP_PID=$!
sleep 1
kill -0 "$HTTP_PID" 2>/dev/null || { echo "Error: local origin HTTP server failed to start" >&2; cat "$WORK_DIR/http.log" >&2; exit 1; }
CAYO_BASE_URL="http://127.0.0.1:${SOURCE_PORT}/os/native/v1/cayo/x86-64"
SNOW_BASE_URL="http://127.0.0.1:${SOURCE_PORT}/os/native/v1/snow/x86-64"
GUEST_ORIGIN="http://10.0.2.2:${SOURCE_PORT}"

echo "--- publish-candidate.sh / verify-remote.sh / promote.sh (DEV key, stock pubring) ---"
"$PUBLISH_DIR/publish-candidate.sh" "$PREPARED_CAYO" "$ORIGIN_DEST"
assert_true "verify-remote.sh clean pass for cayo-ab candidate" "$PUBLISH_DIR/verify-remote.sh" "$PREPARED_CAYO" "$CAYO_BASE_URL"
"$PUBLISH_DIR/promote.sh" --signing-key "$SIGNING_KEY" --pubring "$PUBRING" "$PREPARED_CAYO" "$CAYO_BASE_URL" "$ORIGIN_DEST"
assert_true "gpgv (stock pubring) accepts the promoted cayo-ab index" \
    gpgv --keyring "$PUBRING" "$ORIGIN_DEST/os/native/v1/cayo/x86-64/SHA256SUMS.gpg" "$ORIGIN_DEST/os/native/v1/cayo/x86-64/SHA256SUMS"

"$PUBLISH_DIR/publish-candidate.sh" "$PREPARED_SNOW" "$ORIGIN_DEST"
assert_true "verify-remote.sh clean pass for snow-ab candidate" "$PUBLISH_DIR/verify-remote.sh" "$PREPARED_SNOW" "$SNOW_BASE_URL"
"$PUBLISH_DIR/promote.sh" --signing-key "$SIGNING_KEY" --pubring "$PUBRING" "$PREPARED_SNOW" "$SNOW_BASE_URL" "$ORIGIN_DEST"
assert_true "gpgv (stock pubring) accepts the promoted snow-ab index" \
    gpgv --keyring "$PUBRING" "$ORIGIN_DEST/os/native/v1/snow/x86-64/SHA256SUMS.gpg" "$ORIGIN_DEST/os/native/v1/snow/x86-64/SHA256SUMS"

echo "Publication complete ($(date -u +%FT%TZ))"

# ===========================================================================
# Shared VM plumbing (adapted from test/native-ab-secure-boot-test.sh; no
# MOK pre-enrollment here -- every product starts from a VIRGIN varstore).
# ===========================================================================

# minimum_disk_bytes product -- mirrors shared/native-installer/tree/usr/
# libexec/snosi-install's own function EXACTLY (docs/native-ab-contracts.md
# §12). Sourced directly from the installer script itself (guarded behind a
# BASH_SOURCE check, so sourcing never runs main()) rather than copied, so
# this test can never silently drift from the real formula -- same technique
# test/lib/snosi-install-test-helpers.sh uses.
# shellcheck disable=SC1091
source "$ROOT_DIR/shared/native-installer/tree/usr/libexec/snosi-install"

# TARGET_SIZE_MARGIN: the documented minimum is computed from the SAME fixed
# repart slot sizes systemd-repart used to build the image (esp + 2*root +
# 2*verity + var's own SizeMinBytes) -- i.e. a disk sized to EXACTLY that
# minimum has zero spare capacity and relocate_and_grow_var()'s "target_size
# > image_size" branch never fires. A 3 GiB margin (real hardware is never
# byte-exact either) is added so the grow-to-end code path is genuinely
# exercised, not just trivially satisfied.
TARGET_SIZE_MARGIN=$((3 * 1024 * 1024 * 1024))

vm_prepare_ovmf_virgin() { # workdir
    local wd="$1"
    cp "$OVMF_CODE_SRC" "$wd/OVMF_CODE.fd"
    cp "$OVMF_VARS_SRC" "$wd/OVMF_VARS.fd"
}

vm_prepare_swtpm() { # workdir
    local wd="$1"
    mkdir -p "$wd/tpm"
    rm -f "$wd/tpm/swtpm-ctrl.sock" "$wd/tpm/swtpm.pid"
    swtpm socket --tpm2 --tpmstate "dir=$wd/tpm" \
        --ctrl "type=unixio,path=$wd/tpm/swtpm-ctrl.sock" \
        --pid "file=$wd/tpm/swtpm.pid" \
        --log "file=$wd/tpm/swtpm.log,level=1" \
        -d
    local i=0
    while [[ ! -S "$wd/tpm/swtpm-ctrl.sock" ]] && (( i++ < 50 )); do sleep 0.2; done
    [[ -S "$wd/tpm/swtpm-ctrl.sock" ]] || { echo "Error: swtpm control socket did not appear" >&2; exit 1; }
    SWTPM_PID="$(cat "$wd/tpm/swtpm.pid")"
    TPM_SOCK="$wd/tpm/swtpm-ctrl.sock"
    echo "swtpm running (PID $SWTPM_PID)"
}

# vm_boot workdir port serial_log attach_iso(0|1) -- (re)starts QEMU. swtpm is
# re-armed if not running (same lifecycle note as native-ab-secure-boot-test.sh:
# swtpm exits when its QEMU client disconnects), against the SAME persistent
# --tpmstate dir so TPM-sealed state (the enrolled LUKS token) survives every
# power-cycle within this product's run.
vm_boot() { # wd port serial_log attach_iso
    local wd="$1" port="$2" serial_log="$3" attach_iso="$4"
    if [[ -z "$SWTPM_PID" ]] || ! kill -0 "$SWTPM_PID" 2>/dev/null; then
        echo "swtpm not running; re-arming on persistent state"
        vm_prepare_swtpm "$wd"
    fi
    local pidfile="$wd/qemu.pid"
    rm -f "$pidfile"
    local -a drives=()
    if [[ "$attach_iso" == 1 ]]; then
        # Whole-disk virtio-blk, NOT -cdrom -- see header comment.
        drives+=(-drive "file=$ISO,format=raw,if=virtio,readonly=on")
    fi
    drives+=(-drive "file=$wd/target.raw,format=raw,if=virtio")
    qemu-system-x86_64 \
        -machine q35 \
        -enable-kvm -cpu host \
        -m "$VM_MEMORY" -smp "$VM_CPUS" \
        -drive "if=pflash,format=raw,unit=0,file=$wd/OVMF_CODE.fd,readonly=on" \
        -drive "if=pflash,format=raw,unit=1,file=$wd/OVMF_VARS.fd" \
        "${drives[@]}" \
        -netdev "user,id=net0,hostfwd=tcp::${port}-:22" \
        -device virtio-net-pci,netdev=net0 \
        -device virtio-gpu-pci \
        -display none -vga none \
        -chardev "socket,id=tpmchr,path=$TPM_SOCK" \
        -tpmdev emulator,id=tpm0,chardev=tpmchr \
        -device tpm-crb,tpmdev=tpm0 \
        -serial "file:$serial_log" \
        -monitor none \
        -pidfile "$pidfile" \
        -daemonize
    local i=0
    while [[ ! -f "$pidfile" ]] && (( i++ < 50 )); do sleep 0.2; done
    QEMU_PID="$(cat "$pidfile" 2>/dev/null || true)"
    [[ -n "$QEMU_PID" ]] || { echo "Error: QEMU failed to start" >&2; exit 1; }
    echo "VM booted (PID $QEMU_PID, port $port, iso_attached=$attach_iso)"
}

# vm_graceful_stop -- poweroff over SSH (target reachable), then hard-kill.
vm_graceful_stop() {
    vm_ssh systemctl poweroff >/dev/null 2>&1 || true
    local i=0
    while [[ -n "$QEMU_PID" ]] && kill -0 "$QEMU_PID" 2>/dev/null && (( i++ < 30 )); do sleep 1; done
    if [[ -n "$QEMU_PID" ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
        kill "$QEMU_PID" 2>/dev/null || true
        i=0
        while kill -0 "$QEMU_PID" 2>/dev/null && (( i++ < 20 )); do sleep 0.5; done
        kill -9 "$QEMU_PID" 2>/dev/null || true
    fi
    QEMU_PID=""
}

vm_hard_stop() {
    [[ -n "$QEMU_PID" ]] && kill -9 "$QEMU_PID" 2>/dev/null || true
    QEMU_PID=""
}

# resolve_devices -- sets ISO_DEV (empty if not attached) and TARGET_DEV by
# probing lsblk inside the guest (device letters are not assumed -- see
# header comment on why this must be probed, not hardcoded).
resolve_devices() {
    local disks iso_name n
    disks="$(vm_ssh "lsblk -rndo NAME,TYPE | awk '\$2==\"disk\"{print \$1}'")"
    iso_name="$(vm_ssh "lsblk -rno NAME,FSTYPE | awk '\$2==\"iso9660\"{print \$1; exit}'" || true)"
    ISO_DEV=""
    TARGET_DEV=""
    while IFS= read -r n; do
        [[ -n "$n" ]] || continue
        if [[ -n "$iso_name" && "$n" == "$iso_name" ]]; then
            ISO_DEV="/dev/$n"
        else
            TARGET_DEV="/dev/$n"
        fi
    done <<<"$disks"
}

guest_scp_up() { # local_path remote_path
    scp "${SSH_OPTS[@]}" -i "$SSH_KEY" -P "$SSH_PORT" "$1" "root@localhost:$2" >/dev/null
}
guest_scp_down() { # remote_path local_path
    scp "${SSH_OPTS[@]}" -i "$SSH_KEY" -P "$SSH_PORT" "root@localhost:$1" "$2" >/dev/null
}
guest_with_input() { # input_file command...
    local input="$1"
    shift
    # shellcheck disable=SC2029
    ssh "${SSH_OPTS[@]}" -p "$SSH_PORT" -i "$SSH_KEY" root@localhost "$@" <"$input"
}

# ===========================================================================
# run_product product channel base_url version full_mode(1|0)
# ===========================================================================
run_product() {
    local product="$1" channel="$2" version="$3" full_mode="$4"
    local wd="$WORK_DIR/$product"
    mkdir -p "$wd"
    echo ""
    echo "############################################################"
    echo "### Product: $channel (full_mode=$full_mode)  started $(date -u +%FT%TZ)"
    echo "############################################################"

    local min_bytes target_size
    min_bytes="$(minimum_disk_bytes "$product")"
    target_size=$((min_bytes + TARGET_SIZE_MARGIN))
    echo "minimum_disk_bytes($product) = $min_bytes; target disk = $target_size ($(human_bytes "$target_size"))"

    truncate -s "$target_size" "$wd/target.raw"
    vm_prepare_ovmf_virgin "$wd"
    vm_prepare_swtpm "$wd"

    case "$product" in
        cayo) SSH_PORT=2260 ;;
        snow) SSH_PORT=2261 ;;
        snowfield) SSH_PORT=2262 ;;
        *) echo "Error: unknown product $product" >&2; exit 1 ;;
    esac
    export SSH_PORT

    # =======================================================================
    # Step 2: boot the ISO (whole-disk virtio-blk) + blank target, virgin
    # varstore. Reach the installer over SSH -- same access mechanism/
    # assertions as test/native-installer-iso-test.sh's positive-boot step.
    # =======================================================================
    echo "=== Step 2: boot ISO (pre-enrollment chain), reach installer ==="
    local boot1_log="$wd/console.1-install.log"
    vm_boot "$wd" "$SSH_PORT" "$boot1_log" 1
    if SSH_TIMEOUT="$SSH_TIMEOUT" wait_for_ssh; then
        pass "$channel: ISO reaches the installer userspace over SSH"
    else
        fail "$channel: ISO reaches the installer userspace over SSH" "SSH never came up within ${SSH_TIMEOUT}s"
        tail -100 "$boot1_log" >&2 || true
        vm_hard_stop
        return
    fi
    local sb_state
    sb_state="$(vm_ssh mokutil --sb-state 2>&1 || true)"
    assert_contains "$channel: mokutil reports Secure Boot enabled (pre-enrollment chain)" "$sb_state" "SecureBoot enabled"

    resolve_devices
    [[ -n "$ISO_DEV" ]] || { fail "$channel: ISO device identified inside the guest" "no iso9660 disk found"; }
    [[ -n "$TARGET_DEV" ]] || { fail "$channel: target device identified inside the guest" "no second disk found"; }
    echo "ISO_DEV=$ISO_DEV  TARGET_DEV=$TARGET_DEV"

    # =======================================================================
    # Step 3 (cayo-ab only): in-ISO negative FIRST -- own-boot-medium refusal
    # in the REAL initramfs environment.
    # =======================================================================
    if [[ "$full_mode" == 1 ]]; then
        echo "=== Step 3: in-ISO negative -- own-boot-medium refusal (real initramfs) ==="
        local neg_out neg_rc=0
        neg_out="$(vm_ssh "/usr/libexec/snosi-install --product $channel --origin $GUEST_ORIGIN --disk $ISO_DEV --confirm $ISO_DEV --encrypt-var --recovery-key-file /root/never-created-recovery.key --acknowledge-recovery-saved --mok-password-file /root/never-created-mokpass --non-interactive" 2>&1)" || neg_rc=$?
        assert_true "$channel: own-boot-medium install attempt exits non-zero" bash -c "[[ $neg_rc -ne 0 ]]"
        assert_contains "$channel: refusal names the installer's own boot medium" "$neg_out" "own boot medium"
        assert_false "$channel: own-boot-medium refusal fired before ever writing to the ISO device (no recovery key file created)" \
            vm_ssh test -e /root/never-created-recovery.key
    fi

    # =======================================================================
    # Step 4: in-ISO non-interactive install. World-readable mok-password-file
    # is refused only after the real destructive pipeline has run; complete
    # via --restage-mok instead of re-downloading (see header comment).
    # =======================================================================
    echo "=== Step 4: in-ISO non-interactive install ==="
    local mokpass_bad_local="$wd/mokpass-bad.local" mokpass_good_local="$wd/mokpass-good.local"
    openssl rand -hex 16 >"$mokpass_bad_local"
    openssl rand -hex 16 >"$mokpass_good_local"
    guest_scp_up "$mokpass_bad_local" /root/mokpass-bad
    guest_scp_up "$mokpass_good_local" /root/mokpass-good
    vm_ssh "chmod 644 /root/mokpass-bad; chmod 600 /root/mokpass-good"

    local install_out install_rc=0
    install_out="$(vm_ssh "/usr/libexec/snosi-install --product $channel --origin $GUEST_ORIGIN --disk $TARGET_DEV --confirm $TARGET_DEV --encrypt-var --recovery-key-file /root/recovery.key --acknowledge-recovery-saved --mok-password-file /root/mokpass-bad --ssh-authorized-key /root/.ssh/authorized_keys --non-interactive" 2>&1)" || install_rc=$?
    echo "$install_out"
    assert_true "$channel: install with a world-readable mok-password-file exits non-zero" bash -c "[[ $install_rc -ne 0 ]]"
    assert_contains "$channel: refused for group/world-readable --mok-password-file" "$install_out" "group- or world-readable"
    assert_contains "$channel: streamed download/verify succeeded before the MOK refusal" "$install_out" "Validating the written disk's partition layout"
    assert_contains "$channel: post-write layout validation ran" "$install_out" "Growing /var partition"
    assert_contains "$channel: TPM enrollment ran before the MOK refusal" "$install_out" "Enrolling TPM unlock"

    local listnew_before
    listnew_before="$(vm_ssh mokutil --list-new 2>&1 || true)"
    assert_not_contains "$channel: no MOK request staged yet (perm check refused before mok_import)" "$listnew_before" "SHA1 Fingerprint"

    guest_scp_down /root/recovery.key "$wd/recovery.key"
    chmod 600 "$wd/recovery.key"

    local var_part
    var_part="$(vm_ssh "lsblk -nrpo NAME,PARTLABEL $TARGET_DEV | awk '\$2==\"var\"{print \$1}'")"
    [[ -n "$var_part" ]] || { fail "$channel: locate the var partition on $TARGET_DEV" "lsblk found none labeled var"; vm_hard_stop; return; }
    local var_bytes
    # -d/--nodeps: without it, lsblk walks INTO var_part's still-open
    # device-mapper child (snosi-install's own LUKS mapper, only closed by
    # its EXIT trap -- which fires after this SSH command already ran) and
    # prints two SIZE lines (the raw partition's and the mapped/decrypted
    # device's, which differ by the LUKS2 header size), breaking the
    # numeric comparison below. Root-caused live
    # (test/native-installer-e2e-test.sh's first fully-successful install,
    # 2026-07-15).
    var_bytes="$(vm_ssh "lsblk -b -no SIZE -d $var_part")"
    assert_true "$channel: var partition grown beyond the stock 4GiB image size (target > minimum)" \
        bash -c "[[ $var_bytes -gt 4294967296 ]]"

    local luks_dump tpm_token_count keyslot_count
    luks_dump="$(vm_ssh "cryptsetup luksDump --dump-json-metadata $var_part")"
    tpm_token_count="$(jq '[.tokens // {} | to_entries[] | select(.value.type == "systemd-tpm2")] | length' <<<"$luks_dump")"
    assert_eq "$channel: exactly one systemd-tpm2 LUKS token after install" "$tpm_token_count" "1"
    keyslot_count="$(jq '.keyslots | length' <<<"$luks_dump")"
    assert_true "$channel: at least one LUKS keyslot exists (recovery passphrase)" bash -c "[[ $keyslot_count -ge 1 ]]"

    # Deliberately test-passphrase only here (a read-only LUKS header check
    # that never creates a mapper), NOT a real `cryptsetup open` of a
    # second mapper on the same device. Root-caused live
    # (test/native-installer-e2e-test.sh's first fully-successful install,
    # 2026-07-15, persisted across a 5-attempt/3s-apart retry -- not a brief
    # race): "var"'s GPT partition type is systemd-repart's `Type=var`
    # alias for the standardized Discoverable-Partitions-Specification
    # "Linux variable data" GUID, which the installer userspace's OWN
    # systemd-gpt-auto-generator recognizes and auto-activates once the
    # freshly TPM-enrolled LUKS2 header appears -- so `/dev/vdb6` is
    # legitimately, persistently busy from a mapper the INSTALLER ITSELF
    # created, not a stray leftover to retry past (see
    # close_var_mapper()'s own bounded-retry fix in snosi-install for the
    # narrower, genuinely-transient race that fix targets instead).
    # --test-passphrase proves the SAME "the recovery key genuinely unlocks
    # this volume" property without contending for the device. Full
    # install-info.json CONTENT verification happens naturally in Step 7,
    # reading the file through the product's own boot-time /var mount
    # instead of a second manually-opened mapper here -- a MORE
    # representative check of the real access path, not a weaker one.
    local testpass_rc=0
    guest_with_input "$wd/recovery.key" "cryptsetup open --test-passphrase --key-file=- '$var_part'" >/dev/null 2>&1 || testpass_rc=$?
    assert_eq "$channel: recovery passphrase opens the just-installed /var (--test-passphrase)" "$testpass_rc" "0"

    echo "--- completing MOK enrollment via --restage-mok (real recovery path, avoids a 2nd multi-GiB download) ---"
    local restage_out restage_rc=0
    restage_out="$(vm_ssh "/usr/libexec/snosi-install --restage-mok --disk $TARGET_DEV --mok-password-file /root/mokpass-good --non-interactive" 2>&1)" || restage_rc=$?
    echo "$restage_out"
    assert_eq "$channel: restage-mok (completing the perm-refused install) succeeds" "$restage_rc" "0"
    assert_contains "$channel: restage-mok stages a fresh request" "$restage_out" "MOK re-enrollment request staged"

    local listnew_after
    listnew_after="$(vm_ssh mokutil --list-new 2>&1 || true)"
    assert_contains "$channel: mokutil --list-new is non-empty after MOK staging" "$listnew_after" "SHA1 Fingerprint"

    vm_graceful_stop

    # =======================================================================
    # Step 5: pre-enrollment negative -- target disk alone, SAME virgin
    # varstore. shim must reject the MOK-signed systemd-boot chain.
    # =======================================================================
    echo "=== Step 5: pre-enrollment negative boot (target disk, virgin varstore) ==="
    local boot2_log="$wd/console.2-preenrollment-negative.log"
    vm_boot "$wd" "$SSH_PORT" "$boot2_log" 0
    local deadline neg_console=""
    deadline=$((SECONDS + 30))
    while (( SECONDS < deadline )); do
        neg_console="$(cat "$boot2_log" 2>/dev/null || true)"
        [[ "$neg_console" == *"Security Violation"* ]] && break
        sleep 2
    done
    assert_contains "$channel: shim rejects the MOK-signed installed system (Security Violation, MOK not yet enrolled)" \
        "$neg_console" "Security Violation"
    assert_not_contains "$channel: pre-enrollment negative boot never reaches a shell/SSH-capable userspace" \
        "$neg_console" "systemd-journald"
    vm_hard_stop

    # =======================================================================
    # Step 6 (cayo-ab only): --restage-mok, dedicated -- a fresh ISO power
    # cycle, a brand new password file.
    # =======================================================================
    if [[ "$full_mode" == 1 ]]; then
        echo "=== Step 6: --restage-mok (dedicated, fresh ISO boot) ==="
        local boot3_log="$wd/console.3-restage.log"
        vm_boot "$wd" "$SSH_PORT" "$boot3_log" 1
        if SSH_TIMEOUT="$SSH_TIMEOUT" wait_for_ssh; then
            pass "$channel: fresh ISO boot for the dedicated restage-mok test reaches SSH"
        else
            fail "$channel: fresh ISO boot for the dedicated restage-mok test reaches SSH" "timed out"
            tail -100 "$boot3_log" >&2 || true
        fi
        resolve_devices
        local mokpass_restage_local="$wd/mokpass-restage.local"
        openssl rand -hex 16 >"$mokpass_restage_local"
        guest_scp_up "$mokpass_restage_local" /root/mokpass-restage
        vm_ssh "chmod 600 /root/mokpass-restage"
        local restage2_out restage2_rc=0
        restage2_out="$(vm_ssh "/usr/libexec/snosi-install --restage-mok --disk $TARGET_DEV --mok-password-file /root/mokpass-restage --non-interactive" 2>&1)" || restage2_rc=$?
        echo "$restage2_out"
        assert_eq "$channel: dedicated --restage-mok (fresh ISO boot) succeeds" "$restage2_rc" "0"
        assert_contains "$channel: dedicated --restage-mok locates the existing install" "$restage2_out" "Found installed disk: $TARGET_DEV"
        assert_contains "$channel: dedicated --restage-mok stages a fresh request" "$restage2_out" "MOK re-enrollment request staged"
        vm_graceful_stop
    fi

    # =======================================================================
    # Step 7: host-side MOK injection simulates MokManager approval; boot
    # the target disk alone, fully enforced and fully unattended.
    # =======================================================================
    echo "=== Step 7: host-side MOK injection + final enforced/unattended boot ==="
    local guid
    guid="$(python3 -c 'import uuid; print(uuid.uuid4())')"
    echo "Injecting Snosi MOK ($MOK_CERT) into the varstore as owner GUID $guid (simulates MokManager one-time approval)"
    virt-fw-vars --inplace "$wd/OVMF_VARS.fd" --add-mok "$guid" "$MOK_CERT"
    local printed
    printed="$(virt-fw-vars -i "$wd/OVMF_VARS.fd" -p 2>&1)"
    assert_contains "$channel: OVMF varstore has a MokList after host-side injection" "$printed" "MokList"

    local boot4_log="$wd/console.4-final.log"
    vm_boot "$wd" "$SSH_PORT" "$boot4_log" 0
    if SSH_TIMEOUT="$SSH_TIMEOUT" wait_for_ssh; then
        pass "$channel: final boot reaches SSH, fully enforced + unattended (no console input given)"
    else
        fail "$channel: final boot reaches SSH, fully enforced + unattended" "timed out"
        tail -150 "$boot4_log" >&2 || true
        vm_hard_stop
        return
    fi

    local final_sb
    final_sb="$(vm_ssh mokutil --sb-state 2>&1 || true)"
    assert_contains "$channel: final boot -- Secure Boot enforced" "$final_sb" "SecureBoot enabled"

    local lockdown
    lockdown="$(vm_ssh 'cat /sys/kernel/security/lockdown' || true)"
    assert_true "$channel: final boot -- kernel lockdown active (integrity or confidentiality)" \
        bash -c "grep -Eq '\[(integrity|confidentiality)\]' <<<'$lockdown'"

    local var_source
    var_source="$(vm_ssh 'findmnt -no SOURCE /var' || true)"
    assert_eq "$channel: final boot -- /var mounted from the LUKS mapper via UNATTENDED TPM unlock (no console input given)" \
        "$var_source" "/dev/mapper/var"

    local etc_fstype
    etc_fstype="$(vm_ssh 'findmnt -no FSTYPE /etc' || true)"
    assert_eq "$channel: final boot -- /etc is the persistent overlay" "$etc_fstype" "overlay"

    local image_id image_version
    image_id="$(vm_ssh ". /usr/lib/os-release; echo \"\$IMAGE_ID\"" || true)"
    image_version="$(vm_ssh ". /usr/lib/os-release; echo \"\$IMAGE_VERSION\"" || true)"
    assert_eq "$channel: final boot -- IMAGE_ID" "$image_id" "$product"
    assert_eq "$channel: final boot -- IMAGE_VERSION" "$image_version" "$version"

    # Full install-info.json field verification (product/channel/version/
    # architecture) lives here, reading it through the product's own
    # normal boot-time /var mount -- deliberately not via a manually
    # opened second LUKS mapper back in Step 4 (see that step's comment
    # for why: the installer's own systemd-gpt-auto-generator legitimately
    # holds the var device busy once it's a valid LUKS2 volume). This is
    # the more representative access path anyway.
    local final_info
    final_info="$(vm_ssh 'cat /var/lib/snosi/install-info.json' || true)"
    assert_eq "$channel: install-info.json product field" "$(jq -r .product <<<"$final_info")" "$product"
    assert_eq "$channel: install-info.json channel field" "$(jq -r .channel <<<"$final_info")" "$channel"
    assert_eq "$channel: install-info.json version field" "$(jq -r .version <<<"$final_info")" "$version"
    assert_eq "$channel: install-info.json architecture field" "$(jq -r .architecture <<<"$final_info")" "x86-64"

    local update_status_out update_status_rc=0
    update_status_out="$(vm_ssh snosi-update-status 2>&1)" || update_status_rc=$?
    echo "$update_status_out"
    assert_eq "$channel: snosi-update-status runs clean (exit 0)" "$update_status_rc" "0"

    local failed_units
    failed_units="$(vm_ssh 'systemctl --failed --no-legend' || true)"
    assert_eq "$channel: no failed systemd units on the final enforced/unattended boot" "$failed_units" ""

    # Derive the LUKS backing partition from the already-mounted mapper, NOT
    # from $TARGET_DEV: that variable was resolved during the ISO-attached
    # boots (target = /dev/vdb, second disk), but this final boot detaches the
    # ISO so the target is the ONLY disk and enumerates as /dev/vda. Reading
    # the backing device straight off the open `var` mapper is naming-agnostic
    # and is exactly the partition /var is mounted from (asserted above).
    local final_var_part
    final_var_part="$(vm_ssh "cryptsetup status var | awk '/device:/{print \$2}'")"
    [[ -n "$final_var_part" ]] || { fail "$channel: locate the LUKS backing device for /var (final boot)" "cryptsetup status var reported no device"; vm_hard_stop; return; }
    local test_pass_rc=0
    guest_with_input "$wd/recovery.key" "cryptsetup open --test-passphrase --key-file=- '$final_var_part'" >/dev/null 2>&1 || test_pass_rc=$?
    assert_eq "$channel: recovery passphrase still opens /var's LUKS volume (--test-passphrase)" "$test_pass_rc" "0"

    vm_graceful_stop
    echo "### Product $channel complete: $(date -u +%FT%TZ)"
}

# ===========================================================================
# Main: cayo-ab full sequence, snow-ab partial (steps 2,4,5,7 -- brief
# section "Do the full sequence for cayo-ab; for snow-ab run steps 2,4,5,7").
# ===========================================================================
run_product cayo cayo-ab "$VERSION_CAYO" 1
run_product snow snow-ab "$VERSION_SNOW" 0

if [[ "$WITH_SNOWFIELD" == 1 ]]; then
    echo ""
    echo "--with-snowfield was passed, but snowfield-ab's own hardware gate"
    echo "(CLAUDE.md PENDING HUMAN GATE: representative Surface hardware)"
    echo "owns real validation of that product -- this QEMU harness cannot"
    echo "substitute for it. Not run. See docs/native-ab-publication.md."
fi

echo ""
echo "Native installer end-to-end proof complete: $(date -u +%FT%TZ)"
print_summary
