#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Phase 5 QEMU validation: fully automated Secure Boot + TPM + desktop
# validation for a native A/B product (default snow-ab; also accepts
# cayo-ab). No MokManager interaction: the Snosi MOK is pre-enrolled into an
# OVMF varstore with `virt-fw-vars --add-mok`, starting from
# OVMF_VARS_4M.ms.fd (Microsoft keys already enrolled -> Secure Boot
# enforced), paired with OVMF_CODE_4M.secboot.fd and an attached swtpm TPM2
# socket device.
#
# Sequence (docs/native-ab-contracts.md is the frozen naming/policy
# reference; CLAUDE.md "Native A/B Prototype" / "Native Security Contract"
# document the secure-chain invariants this test proves at runtime):
#
#   1. Build two real versions (N, N+1) of $PROFILE via the pinned .mkosi
#      checkout, mirroring test/native-ab-updateux-test.sh's build_profile.
#   2. Install N to a raw disk FILE (test-only) via
#      test/cayo-ab-install-spike.sh --allow-file --yes --encrypt-var
#      --recovery-key-file <fresh>. Deliberately does NOT pass
#      --mok-certificate: that flag drives `mokutil --import`, which talks
#      to the HOST's live EFI variable store -- wrong (and refused by the
#      spike script itself for --allow-file targets) for a loopback install
#      on a dev machine. MOK enrollment instead targets the GUEST's OVMF
#      varstore directly via virt-fw-vars (see vm_prepare_ovmf below) --
#      exactly the mechanism this test's own header describes, and the spike
#      script needed no changes for it.
#   3. First boot under enforced Secure Boot + swtpm: /var has no TPM token
#      yet, so the initrd's crypt dracut module prompts for the recovery
#      passphrase on the serial console (console=ttyS0 is already in the
#      generic KernelCommandLine). A Python console pump (no expect/socat on
#      this host; see below) types it once, automatically, the first time an
#      ask-password-shaped prompt appears. Asserts: Secure Boot enabled,
#      shim -> MOK-signed systemd-boot -> MOK-signed UKI chain actually
#      loaded (bootctl status "Measured UKI: yes"), kernel lockdown active,
#      /var is LUKS2, /etc overlay mounted, no failed units, first-boot
#      preset parity (reuses test/tests/05-firstboot-presets.sh verbatim,
#      the same TEST_LIB_DIR/helpers.sh remote-execution pattern
#      test/bootc-install-test.sh already uses), no NvPCR consumer failures.
#   4. In-guest TPM enrollment mirroring test/native-ab-secure-rotation-test.sh's
#      enroll_token EXACTLY: --tpm2-pcrs= (empty raw-PCR set) +
#      --tpm2-public-key=<pcr-signing.pub> --tpm2-public-key-pcrs=11 (signed
#      PCR 11 policy). Reboots; the ONLY assertion of success is that SSH
#      comes back inside the normal timeout with ZERO serial input fed --
#      if the initrd needed a passphrase, the boot would hang at the prompt
#      and wait_for_ssh would time out.
#   5. Desktop assertions on the TPM-unlocked boot (this is Snow):
#      graphical.target, gdm.service, a logind seat, notify-send, the
#      fresh-/var tmpfiles targets, dpkg-query, and a minimal ad hoc sysext
#      (plain-directory form, not a raw disk image -- systemd-sysext(8)
#      merges directories under /var/lib/extensions/ identically to raw
#      images; this avoids building and loop-mounting an erofs/squashfs
#      just to prove the icon-cache contract) exercising the CLAUDE.md
#      hicolor icon-cache rule. Also asserts snow-linux-live-setup.service's
#      corrected live-media gate (see the "real bug found and fixed" note
#      in the report/CLAUDE.md): on a native install with no
#      snow-linux.live=1 on the command line, the unit must be
#      ConditionResult=no / inactive, never active and never failed.
#   6. Secure update hop: publish N+1 through the real publication pipeline
#      to a local HTTP origin signed with an ephemeral GPG key (the guest
#      trusts it via the documented /etc/systemd/import-pubring.gpg
#      override, same mechanism as test/native-ab-updateux-test.sh), run
#      /usr/libexec/snosi-sysupdate-stage, reboot with zero serial input
#      (proving the signed PCR 11 policy survives a real UKI change -- the
#      entire point of signed-vs-raw PCR policy), and assert N+1 booted
#      under enforced Secure Boot with TPM auto-unlock intact, /etc upper +
#      /var persistence markers survived, and the N rollback entry is still
#      present (InstancesMax=2).
#   7. Recovery unlock check (non-destructive): the recovery keyslot still
#      opens the volume via `cryptsetup open --test-passphrase`.
#
# Usage: sudo ./test/native-ab-secure-boot-test.sh
# Env overrides: PROFILE (default snow-ab; also accepts cayo-ab),
# IMAGE_ID/CHANNEL (derived from PROFILE by default), SSH_PORT (2225),
# SOURCE_PORT (18095), SSH_TIMEOUT/BOOT_TIMEOUT (300s), VM_MEMORY (4096),
# VM_CPUS (4), KEEP_VM (0), SKIP_BUILD/BUILD_N_DIR/BUILD_N1_DIR (reuse
# prebuilt artifacts, same contract as test/native-ab-updateux-test.sh).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
: "${KEEP_VM:=0}"
: "${SOURCE_PORT:=18095}"
: "${SSH_PORT:=2225}"
: "${SSH_TIMEOUT:=300}"
: "${BOOT_TIMEOUT:=420}"
: "${VM_MEMORY:=4096}"
: "${VM_CPUS:=4}"
: "${SKIP_BUILD:=0}"
: "${BUILD_N_DIR:=}"
: "${BUILD_N1_DIR:=}"

: "${PROFILE:=snow-ab}"
if [[ -z "${IMAGE_ID:-}" ]]; then
    IMAGE_ID="${PROFILE%-ab}"
fi
: "${CHANNEL:=${IMAGE_ID}-ab}"

# This dev host is itself an immutable snosi image (read-only /usr sysext
# overlay); swtpm and virt-firmware cannot be `apt-get install`ed here (see
# the report). They live under linuxbrew (fixed system path) and the
# invoking user's pip --user site -- resolved via $SUDO_USER's home, not
# plain $HOME, since this script requires root (below) and a plain `sudo`
# invocation (the documented Usage:) resets $HOME to /root, which does not
# have the pip --user install.
real_home="$HOME"
if [[ -n "${SUDO_USER:-}" ]]; then
    real_home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
fi
export PATH="$real_home/.local/bin:/home/linuxbrew/.linuxbrew/bin:$PATH"
# virt-fw-vars is a `pip install --user` console-script wrapper: the
# interpreter resolves its OWN user site-packages directory from $HOME at
# import time (not from PATH), so a plain `sudo` invocation (which resets
# $HOME to /root) finds the wrapper via PATH above but then fails with
# "ModuleNotFoundError: No module named 'virt'" -- confirmed live. Exporting
# HOME here (not just PATH) fixes site-packages resolution; nothing else in
# this script depends on root's real $HOME for anything security-sensitive.
export HOME="$real_home"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/ssh.sh"

WORK_DIR=""
HTTP_PID=""
QEMU_PID=""
CONSOLE_PUMP_PID=""
SWTPM_PID=""
loop=""
var_mapper=""
PASS=0
FAIL=0

pass() { # description
    echo "ok - $1"
    PASS=$((PASS + 1))
}

fail() { # description [detail]
    echo "not ok - $1" >&2
    [[ $# -lt 2 ]] || echo "  $2" >&2
    FAIL=$((FAIL + 1))
}

assert_eq() { # description actual expected
    if [[ "$2" == "$3" ]]; then
        pass "$1"
    else
        fail "$1" "expected '$3', got '$2'"
    fi
}

assert_true() { # description command...
    local desc="$1"
    shift
    if "$@"; then
        pass "$desc"
    else
        fail "$desc" "command failed: $*"
    fi
}

assert_false() { # description command...
    local desc="$1"
    shift
    if "$@"; then
        fail "$desc" "command unexpectedly succeeded: $*"
    else
        pass "$desc"
    fi
}

assert_contains() { # description haystack needle
    if [[ "$2" == *"$3"* ]]; then
        pass "$1"
    else
        fail "$1" "expected to find: $3 -- got: $2"
    fi
}

print_summary() {
    echo ""
    echo "# Results: $PASS passed, $FAIL failed, $((PASS + FAIL)) total"
    exit "$FAIL"
}

cleanup() {
    [[ -z "$var_mapper" ]] || cryptsetup close "$var_mapper" 2>/dev/null || true
    [[ -z "$loop" ]] || losetup -d "$loop" 2>/dev/null || true
    [[ -z "$HTTP_PID" ]] || kill "$HTTP_PID" 2>/dev/null || true
    [[ -z "$CONSOLE_PUMP_PID" ]] || kill "$CONSOLE_PUMP_PID" 2>/dev/null || true
    if [[ -n "$QEMU_PID" ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
        kill "$QEMU_PID" 2>/dev/null || true
        local i=0
        while kill -0 "$QEMU_PID" 2>/dev/null && (( i++ < 20 )); do sleep 0.5; done
        kill -9 "$QEMU_PID" 2>/dev/null || true
    fi
    [[ -z "$SWTPM_PID" ]] || kill "$SWTPM_PID" 2>/dev/null || true
    if [[ "$KEEP_VM" == 1 ]]; then
        echo "KEEP_VM=1: leaving $WORK_DIR in place"
        return
    fi
    [[ -z "$WORK_DIR" || ! -d "$WORK_DIR" ]] || rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# mkosi build helpers (mirrors test/native-ab-updateux-test.sh)
# ---------------------------------------------------------------------------
resolve_mkosi() {
    local commit dir
    commit="$(grep -m1 -oE 'systemd/mkosi@[0-9a-f]+' "$ROOT_DIR/.github/workflows/build.yml" | cut -d@ -f2)"
    dir="$ROOT_DIR/.mkosi"
    MKOSI="$dir/bin/mkosi"
    if [[ -x "$MKOSI" && "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" == "$commit" ]]; then
        echo "Using pinned mkosi @ $commit ($dir)"
        return
    fi
    command -v python3 >/dev/null || { echo "Error: python3 is required to run mkosi" >&2; exit 1; }
    echo "Installing mkosi @ $commit into $dir"
    rm -rf "$dir"
    git init -q "$dir"
    git -C "$dir" fetch -q --depth=1 https://github.com/systemd/mkosi.git "$commit"
    git -C "$dir" checkout -q --detach FETCH_HEAD
}

build_profile() { # dest_dir
    local dest="$1"
    mkdir -p "$dest"
    echo "Building $PROFILE -> $dest (started $(date -u +%FT%TZ))"
    "$MKOSI" clean -ff
    "$MKOSI" --profile "$PROFILE" build
    cp --sparse=always "$ROOT_DIR/output/$PROFILE.manifest" "$dest/"
    cp --sparse=always "$ROOT_DIR/output/$PROFILE.raw" "$dest/"
    cp --sparse=always "$ROOT_DIR/output/$PROFILE.efi" "$dest/"
    cp --sparse=always "$ROOT_DIR/output/$PROFILE.${IMAGE_ID}_@v.root.raw.raw" "$dest/"
    cp --sparse=always "$ROOT_DIR/output/$PROFILE.${IMAGE_ID}_@v.root-verity.raw.raw" "$dest/"
    echo "Build done -> $dest (finished $(date -u +%FT%TZ))"
}

sign_sums() { # dir
    gpg --homedir "$WORK_DIR/gnupg" --batch --yes --detach-sign \
        -o "$1/SHA256SUMS.gpg" "$1/SHA256SUMS"
}

publish_version() { # build_dir -> sets publish_dest
    local build_dir="$1" stage
    stage="$(mktemp -d "$WORK_DIR/publish-src.XXXXXX")"
    for suffix in manifest raw efi "${IMAGE_ID}_@v.root.raw.raw" "${IMAGE_ID}_@v.root-verity.raw.raw"; do
        ln -s "$build_dir/$PROFILE.$suffix" "$stage/$CHANNEL.$suffix"
    done
    "$ROOT_DIR/shared/native-ab/publish/prepare-native-publication.sh" --xz \
        "$stage" "$CHANNEL" "$WORK_DIR/publish-out"
    publish_dest="$WORK_DIR/publish-out/$IMAGE_ID/x86-64"
    sign_sums "$publish_dest"
}

guest_version() {
    vm_ssh ". /usr/lib/os-release; echo \"\$IMAGE_VERSION\""
}

# ---------------------------------------------------------------------------
# OVMF + MOK pre-enrollment + swtpm + QEMU (custom -- NOT test/lib/vm.sh:
# that library has no TPM/Secure-Boot/interactive-serial support)
# ---------------------------------------------------------------------------
OVMF_CODE_SRC=/usr/share/OVMF/OVMF_CODE_4M.secboot.fd
OVMF_VARS_SRC=/usr/share/OVMF/OVMF_VARS_4M.ms.fd

vm_prepare_ovmf() { # workdir mok_cert -> writes workdir/OVMF_CODE.fd, workdir/OVMF_VARS.fd
    local wd="$1" cert="$2" guid
    [[ -f "$OVMF_CODE_SRC" ]] || { echo "Error: missing $OVMF_CODE_SRC" >&2; exit 1; }
    [[ -f "$OVMF_VARS_SRC" ]] || { echo "Error: missing $OVMF_VARS_SRC" >&2; exit 1; }
    cp "$OVMF_CODE_SRC" "$wd/OVMF_CODE.fd"
    cp "$OVMF_VARS_SRC" "$wd/OVMF_VARS.fd"
    guid="$(python3 -c 'import uuid; print(uuid.uuid4())')"
    echo "Pre-enrolling Snosi MOK ($cert) into OVMF varstore as owner GUID $guid"
    virt-fw-vars --inplace "$wd/OVMF_VARS.fd" --add-mok "$guid" "$cert"
    # Confirm MokList and Secure Boot enablement landed before we ever boot.
    local printed
    printed="$(virt-fw-vars -i "$wd/OVMF_VARS.fd" -p 2>&1)"
    assert_contains "OVMF varstore has a MokList after pre-enrollment" "$printed" "MokList"
    assert_contains "OVMF varstore has SecureBootEnable ON (Microsoft PK present)" "$printed" "SecureBootEnable"
}

vm_prepare_swtpm() { # workdir -> sets TPM_SOCK, starts swtpm in background
    local wd="$1"
    mkdir -p "$wd/tpm"
    # QEMU's "-tpmdev emulator,chardev=..." integration expects the chardev
    # to point at swtpm's CONTROL channel (--ctrl): swtpm negotiates the
    # actual TPM command channel over that connection itself (an fd handoff
    # under the hood). A separate --server socket is for exposing the raw
    # TPM command channel directly (e.g. over TCP to an unrelated
    # consumer) -- pointing QEMU at that instead of --ctrl was tried first
    # and reproducibly hung QEMU at startup (2 threads, 0% CPU, state S,
    # zero vCPU threads ever created) since QEMU never got the handshake it
    # expects; --ctrl only, confirmed working end-to-end.
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
    echo "swtpm running (PID $SWTPM_PID, control socket $TPM_SOCK)"
}

# vm_start_secure disk workdir mok_cert -- boots $disk under enforced Secure
# Boot with the pre-enrolled MOK, an attached swtpm, and a virtio-gpu device
# (GDM needs a GPU node to bind to even with -display none). The serial
# console is a bidirectional UNIX socket (not test/lib/vm.sh's file-backed
# chardev) so console_pump (below) can both log and type into it.
vm_start_secure() { # disk workdir mok_cert
    local disk="$1" wd="$2" cert="$3"
    vm_prepare_ovmf "$wd" "$cert"
    vm_prepare_swtpm "$wd"
    SERIAL_SOCK="$wd/serial.sock"
    local pidfile="$wd/qemu.pid"
    # NOTE (netdev below): no hostfwd for $SOURCE_PORT -- QEMU user-mode/
    # slirp networking already lets the guest reach the host's 10.0.2.2
    # gateway on ANY port the host is listening on for GUEST-initiated
    # connections (the local publish HTTP server in Step 6); hostfwd= only
    # matters for HOST-initiated connections into the guest (SSH, below).
    # Adding a self-referential hostfwd=tcp::$SOURCE_PORT-:$SOURCE_PORT was
    # tried first and broke Step 6 (curl: (52) Empty reply from server): it
    # made QEMU itself bind and listen on the HOST's $SOURCE_PORT (to
    # forward into the unused guest port of the same number), which raced/
    # shadowed the real Python http.server trying to bind that same host
    # port for the publish origin.
    qemu-system-x86_64 \
        -machine q35 \
        -enable-kvm -cpu host \
        -m "$VM_MEMORY" -smp "$VM_CPUS" \
        -drive "if=pflash,format=raw,unit=0,file=$wd/OVMF_CODE.fd,readonly=on" \
        -drive "if=pflash,format=raw,unit=1,file=$wd/OVMF_VARS.fd" \
        -drive "file=$disk,format=raw,if=virtio" \
        -netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22" \
        -device virtio-net-pci,netdev=net0 \
        -device virtio-gpu-pci \
        -display none \
        -vga none \
        -chardev "socket,id=tpmchr,path=$TPM_SOCK" \
        -tpmdev emulator,id=tpm0,chardev=tpmchr \
        -device tpm-crb,tpmdev=tpm0 \
        -chardev "socket,id=serial0,path=$SERIAL_SOCK,server=on,wait=off" \
        -serial chardev:serial0 \
        -monitor none \
        -pidfile "$pidfile" \
        -daemonize
    local i=0
    while [[ ! -S "$SERIAL_SOCK" ]] && (( i++ < 50 )); do sleep 0.2; done
    [[ -S "$SERIAL_SOCK" ]] || { echo "Error: QEMU serial socket did not appear" >&2; exit 1; }
    QEMU_PID="$(cat "$pidfile")"
    echo "VM started under enforced Secure Boot + swtpm (QEMU PID $QEMU_PID, SSH port $SSH_PORT)"
}

# start_console_pump workdir recovery_key -- launches a Python process that
# connects to the serial UNIX socket, tees everything to $workdir/console.log,
# and -- the ONE interactive step this whole harness needs, since neither
# expect nor socat exist on this host -- types $recovery_key + Enter the
# FIRST time (and only the first time) a systemd-ask-password-shaped
# "...passphrase...:" prompt appears on the console. Runs for the lifetime
# of the QEMU process (guest `systemctl reboot` does not restart QEMU, so
# one pump covers every boot in this test); later boots never see a prompt
# (TPM auto-unlock), so the guard never fires again -- confirmed by grepping
# console.log for the prompt string after each subsequent boot.
start_console_pump() { # workdir recovery_key
    local wd="$1" key="$2"
    python3 - "$SERIAL_SOCK" "$wd/console.log" "$key" > "$wd/console-pump.log" 2>&1 <<'PYEOF' &
import re, socket, sys, time

sock_path, log_path, key = sys.argv[1], sys.argv[2], sys.argv[3]

for attempt in range(50):
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(sock_path)
        break
    except OSError:
        time.sleep(0.2)
else:
    print("ERROR: could not connect to serial socket", file=sys.stderr)
    sys.exit(1)

s.settimeout(1.0)
prompt_re = re.compile(rb'[Ee]nter[^\n]*pass ?(phrase|word)[^\n]*:\s*$')
buf = bytearray()
sent = False
last_rx = time.time()
with open(log_path, "ab", buffering=0) as log:
    while True:
        try:
            chunk = s.recv(4096)
        except socket.timeout:
            chunk = None  # no data within 1s; distinct from a real EOF below
        if chunk == b"":
            # Peer closed the connection (QEMU exited) -- stop spinning.
            break
        if chunk:
            log.write(chunk)
            buf.extend(chunk)
            if len(buf) > 8192:
                del buf[:-8192]
            last_rx = time.time()
        if not sent and (time.time() - last_rx) > 0.6 and prompt_re.search(bytes(buf)):
            time.sleep(0.3)  # let the prompt line fully settle
            s.sendall(key.encode() + b"\r\n")
            log.write(b"\n[console_pump: typed recovery passphrase]\n")
            sent = True
PYEOF
    CONSOLE_PUMP_PID=$!
    echo "Console pump started (PID $CONSOLE_PUMP_PID), logging to $wd/console.log"
}

reboot_guest() { # -- reboot with ZERO serial input; a hang here means the
                  # initrd needed a passphrase it did not get (TPM failed).
    vm_ssh systemctl reboot || true
    sleep 5
    wait_for_ssh
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
for command in jq losetup mount xz python3 qemu-system-x86_64 gpg git sfdisk curl \
    cryptsetup openssl virt-fw-vars swtpm objcopy objdump dpkg lsinitrd wipefs; do
    command -v "$command" >/dev/null || { echo "Error: required command not found: $command" >&2; exit 1; }
done
[[ $EUID -eq 0 ]] || { echo "Error: must run as root" >&2; exit 1; }
[[ -f "$ROOT_DIR/mkosi.key" && -f "$ROOT_DIR/mkosi.crt" ]] || {
    echo "Error: missing $ROOT_DIR/mkosi.key / mkosi.crt (dev Secure Boot signing keys)" >&2
    exit 1
}
[[ -f "$ROOT_DIR/.snosi-private/pcr-signing.pub" ]] || {
    echo "Error: missing $ROOT_DIR/.snosi-private/pcr-signing.pub (dev PCR signing public key)" >&2
    exit 1
}

trap cleanup EXIT
WORK_DIR="$(mktemp -d /var/tmp/native-ab-secure-boot-test.XXXXXX)"
mkdir -p "$WORK_DIR/mnt" "$WORK_DIR/gnupg" "$WORK_DIR/publish-out" "$WORK_DIR/overrides" "$WORK_DIR/tests"
chmod 700 "$WORK_DIR/gnupg"

echo "=== Step 0: build N and N+1 (this takes tens of minutes) ==="
if [[ "$SKIP_BUILD" == 1 ]]; then
    [[ -n "$BUILD_N_DIR" && -n "$BUILD_N1_DIR" ]] || {
        echo "Error: SKIP_BUILD=1 requires BUILD_N_DIR and BUILD_N1_DIR" >&2
        exit 1
    }
    echo "SKIP_BUILD=1: reusing prebuilt artifacts at $BUILD_N_DIR and $BUILD_N1_DIR"
else
    resolve_mkosi
    BUILD_N_DIR="$WORK_DIR/build-n"
    BUILD_N1_DIR="$WORK_DIR/build-n1"
    build_profile "$BUILD_N_DIR"
    build_profile "$BUILD_N1_DIR"
fi

for f in manifest raw efi "${IMAGE_ID}_@v.root.raw.raw" "${IMAGE_ID}_@v.root-verity.raw.raw"; do
    [[ -f "$BUILD_N_DIR/$PROFILE.$f" ]] || { echo "Error: missing N artifact: $f" >&2; exit 1; }
    [[ -f "$BUILD_N1_DIR/$PROFILE.$f" ]] || { echo "Error: missing N+1 artifact: $f" >&2; exit 1; }
done

n_version="$(jq -er '.config.version' "$BUILD_N_DIR/$PROFILE.manifest")"
n1_version="$(jq -er '.config.version' "$BUILD_N1_DIR/$PROFILE.manifest")"
echo "N=$n_version  N+1=$n1_version"
[[ "$n_version" != "$n1_version" ]] || { echo "Error: N and N+1 builds produced the same version" >&2; exit 1; }
[[ "$n1_version" > "$n_version" ]] || { echo "Error: N+1 version is not newer than N" >&2; exit 1; }

echo ""
echo "=== Static artifact validation (reuses test/native-ab-secure-artifact-test.sh) ==="
OUTPUT_NAME="$PROFILE" "$SCRIPT_DIR/native-ab-secure-artifact-test.sh" \
    "$BUILD_N_DIR/$PROFILE.manifest" "$BUILD_N_DIR/$PROFILE.efi" "" \
    "$ROOT_DIR/.snosi-private/pcr-signing.pub" single
pass "N artifact passes the secure-artifact single-signature contract"

# ===========================================================================
# Step 1-2: install N to a raw disk FILE with an encrypted /var, no
# --mok-certificate (see the header comment on why)
# ===========================================================================
echo ""
echo "=== Step 1-2: install N to a raw disk file (--encrypt-var, no TPM at install time) ==="

DISK_IMAGE="$WORK_DIR/disk.raw"
image_size="$(stat -c %s "$BUILD_N_DIR/$PROFILE.raw")"
image_sha256="$(sha256sum "$BUILD_N_DIR/$PROFILE.raw" | cut -d' ' -f1)"
truncate -s "$image_size" "$DISK_IMAGE"
recovery_key_file="$WORK_DIR/recovery.key"

"$SCRIPT_DIR/cayo-ab-install-spike.sh" --allow-file --yes \
    --encrypt-var --recovery-key-file "$recovery_key_file" \
    "$BUILD_N_DIR/$PROFILE.raw" "$image_sha256" "$DISK_IMAGE"
pass "installer completed against a same-size raw disk file"
[[ -s "$recovery_key_file" ]] || { echo "Error: installer did not write a recovery key" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Inject the test SSH key into the freshly installed /var/roothome/.ssh
# (root.mount bind-mounts /root -> /var/roothome, mkosi.images/base) before
# first boot -- opening the just-created LUKS /var with the installer's own
# recovery key file, entirely offline, no serial interaction needed for
# this part.
# ---------------------------------------------------------------------------
ssh_keygen "$WORK_DIR"
loop="$(losetup --find --show --partscan "$DISK_IMAGE")"
udevadm settle
var_part="$(lsblk -nrpo NAME,PARTLABEL "$loop" | awk '$2 == "var" { print $1 }')"
[[ -n "$var_part" ]] || { echo "Error: could not locate the var partition on $loop" >&2; exit 1; }
var_mapper="snosi-secure-boot-test-var-$$"
cryptsetup open --key-file "$recovery_key_file" "$var_part" "$var_mapper"
mount "/dev/mapper/$var_mapper" "$WORK_DIR/mnt"
mkdir -p "$WORK_DIR/mnt/roothome/.ssh"
cp "${SSH_KEY}.pub" "$WORK_DIR/mnt/roothome/.ssh/authorized_keys"
chmod 700 "$WORK_DIR/mnt/roothome/.ssh"
chmod 600 "$WORK_DIR/mnt/roothome/.ssh/authorized_keys"
umount "$WORK_DIR/mnt"
cryptsetup close "$var_mapper"
var_mapper=""
losetup -d "$loop"
loop=""

# ===========================================================================
# Step 3: first boot under enforced Secure Boot + swtpm; automate the
# recovery-passphrase prompt on the serial console
# ===========================================================================
echo ""
echo "=== Step 3: first boot (Secure Boot + swtpm, no TPM token yet) ==="

recovery_key="$(cat "$recovery_key_file")"
vm_start_secure "$DISK_IMAGE" "$WORK_DIR" "$ROOT_DIR/mkosi.crt"
start_console_pump "$WORK_DIR" "$recovery_key"

if ! SSH_TIMEOUT="$BOOT_TIMEOUT" wait_for_ssh; then
    echo "=== console.log (first boot did not reach SSH) ===" >&2
    tail -200 "$WORK_DIR/console.log" >&2 || true
    echo "BLOCKED: first boot never reached SSH -- see console.log above for the actual prompt text/failure" >&2
    exit 1
fi
assert_true "console pump typed the recovery passphrase during first boot" \
    grep -q 'typed recovery passphrase' "$WORK_DIR/console.log"

booted_version="$(guest_version)"
assert_eq "booted version is N" "$booted_version" "$n_version"
vm_ssh 'systemctl is-system-running --wait' >/dev/null || true

sb_state="$(vm_ssh 'mokutil --sb-state' || true)"
assert_contains "mokutil reports Secure Boot enabled" "$sb_state" "SecureBoot enabled"

bootctl_status="$(vm_ssh 'bootctl --no-pager status' || true)"
assert_contains "bootctl status: Secure Boot enabled" "$bootctl_status" "Secure Boot: enabled"
assert_contains "bootctl status: measured UKI (MOK-signed chain actually loaded)" "$bootctl_status" "Measured UKI: yes"

lockdown="$(vm_ssh 'cat /sys/kernel/security/lockdown' || true)"
echo "lockdown: $lockdown"
assert_true "kernel lockdown is in integrity or confidentiality mode" \
    bash -c "grep -Eq '\[(integrity|confidentiality)\]' <<<'$lockdown'"

var_source="$(vm_ssh 'findmnt -no SOURCE /var' || true)"
assert_eq "/var is mounted from the LUKS mapper device" "$var_source" "/dev/mapper/var"
assert_true "cryptsetup status var reports LUKS2" \
    vm_ssh 'cryptsetup status var | grep -Eq "type:[[:space:]]*LUKS2"'

etc_source="$(vm_ssh 'findmnt -no FSTYPE /etc' || true)"
assert_eq "/etc is an overlay mount" "$etc_source" "overlay"

failed_units="$(vm_ssh 'systemctl --failed --no-legend' || true)"
assert_eq "no failed systemd units on first boot" "$failed_units" ""

nvpcr_journal="$(vm_ssh "journalctl -b -p err --grep=nvpcr --no-pager" 2>/dev/null || true)"
# journalctl itself prints a literal "-- No entries --" banner (not empty
# stdout) when --grep finds nothing (confirmed live) -- assert the absence
# of the substring, not an exact-empty match against journalctl's own
# human-readable "nothing found" banner.
assert_false "no NvPCR-related journal errors on first boot" \
    bash -c "grep -qi nvpcr <<<'$nvpcr_journal'"
assert_eq "systemd-pcrproduct.service is masked" \
    "$(vm_ssh 'systemctl is-enabled systemd-pcrproduct.service' || true)" "masked"

# --- snow-linux-live-setup.service: corrected live-media gate ---
if [[ "$IMAGE_ID" == snow ]]; then
    live_active="$(vm_ssh 'systemctl show -P ActiveState snow-linux-live-setup.service' || true)"
    live_result="$(vm_ssh 'systemctl show -P Result snow-linux-live-setup.service' || true)"
    live_cond="$(vm_ssh 'systemctl show -P ConditionResult snow-linux-live-setup.service' || true)"
    assert_eq "snow-linux-live-setup.service did not run on a native install (ActiveState)" "$live_active" "inactive"
    assert_eq "snow-linux-live-setup.service ConditionResult is no (no snow-linux.live=1 on cmdline)" "$live_cond" "no"
    assert_true "snow-linux-live-setup.service Result is not failed" \
        bash -c "[[ '$live_result' != failed ]]"
    assert_false "no passwordless 'snow' user was created on this native install" \
        vm_ssh 'id -u snow'
fi

# --- first-boot preset parity: reuse test/tests/05-firstboot-presets.sh verbatim ---
echo ""
echo "=== Step 3b: first-boot preset parity (test/tests/05-firstboot-presets.sh) ==="
vm_ssh 'mkdir -p /tmp/test-lib'
scp "${SSH_OPTS[@]}" -i "$SSH_KEY" -P "$SSH_PORT" "$SCRIPT_DIR/lib/helpers.sh" root@localhost:/tmp/test-lib/helpers.sh
scp "${SSH_OPTS[@]}" -i "$SSH_KEY" -P "$SSH_PORT" "$SCRIPT_DIR/tests/05-firstboot-presets.sh" root@localhost:/tmp/05-firstboot-presets.sh
set +e
presets_out="$(vm_ssh 'TEST_LIB_DIR=/tmp/test-lib bash /tmp/05-firstboot-presets.sh' 2>&1)"
set -e
echo "$presets_out"
# test/tests/05-firstboot-presets.sh was written for the bootc profiles and
# requires EVERY manifest-recorded enablement symlink to be recreated by
# presets. Reusing it verbatim against a native secure profile surfaces
# three EXPECTED misses, confirmed live and root-caused (not weakened away,
# not assumed):
#   - timers.target.wants/bootc-update-stage.timer,
#     timers.target.wants/nbc-update-download.timer: permanently MASKED on
#     every native profile (docs/native-ab-contracts.md, native updater
#     isolation; confirmed elsewhere in this suite by
#     test/native-ab-components-test.sh's check_masked_timer) -- a masked
#     unit's .wants/ symlink can never be recreated by a preset pass, by
#     design, regardless of what the manifest (captured generically for
#     every profile) expects.
#   - local-fs.target.wants/run-lock.mount: this profile's Forky systemd
#     261 (shared/native-ab-secure/mkosi.conf) no longer ships a
#     run-lock.mount unit at all -- confirmed live (`dpkg -L systemd` on
#     the booted image has no run-lock.mount, and /run/lock is already a
#     plain directory under the API-mounted /run tmpfs, no separate mount
#     needed). The shared enablement-manifest.txt was captured against
#     whatever systemd version was in the tree at that finalize step; a
#     unit newer systemd no longer ships can never be recreated either.
# Assert the missing set is EXACTLY these three (not merely a subset, and
# not "any failure is fine") and that they are the ONLY failure the shared
# script reported -- any other regression still fails this test.
expected_missing=$'/etc/systemd/system/local-fs.target.wants/run-lock.mount\n/etc/systemd/system/timers.target.wants/bootc-update-stage.timer\n/etc/systemd/system/timers.target.wants/nbc-update-download.timer'
actual_missing="$(grep '^# MISSING: ' <<<"$presets_out" | sed 's/^# MISSING: //' | LC_ALL=C sort)"
assert_eq "05-firstboot-presets.sh's missing set is exactly the three known native/Forky exceptions" \
    "$actual_missing" "$expected_missing"
assert_eq "05-firstboot-presets.sh reports exactly 1 failure (only the known exceptions)" \
    "$(grep -oE '[0-9]+ failed' <<<"$presets_out" | grep -oE '^[0-9]+')" "1"

# ===========================================================================
# Step 4: in-guest TPM enrollment mirroring native-ab-secure-rotation-test.sh
# ===========================================================================
echo ""
echo "=== Step 4: in-guest TPM enrollment (signed PCR 11, empty raw-PCR set) ==="

var_device="$(vm_ssh "lsblk -J -o PATH,PARTLABEL | jq -er '.. | objects | select(.partlabel? == \"var\") | .path'")"
scp "${SSH_OPTS[@]}" -i "$SSH_KEY" -P "$SSH_PORT" \
    "$ROOT_DIR/.snosi-private/pcr-signing.pub" root@localhost:/run/pcr-signing.pub
vm_ssh "install -m 0600 /dev/null /run/native-ab-secure-boot-test-recovery.key"
guest_with_input() { # input_file command...
    local input="$1"
    shift
    # shellcheck disable=SC2029
    ssh "${SSH_OPTS[@]}" -p "$SSH_PORT" -i "$SSH_KEY" root@localhost "$@" < "$input"
}
guest_with_input "$recovery_key_file" "cat > /run/native-ab-secure-boot-test-recovery.key"

enroll_out=""
enroll_rc=0
enroll_out="$(vm_ssh "systemd-cryptenroll --unlock-key-file=/run/native-ab-secure-boot-test-recovery.key --tpm2-device=auto --tpm2-pcrs= --tpm2-pcrlock= --tpm2-public-key=/run/pcr-signing.pub --tpm2-public-key-pcrs=11 '$var_device'" 2>&1)" || enroll_rc=$?
echo "$enroll_out"
assert_eq "systemd-cryptenroll (signed PCR 11, empty raw-PCR set) succeeds" "$enroll_rc" "0"
vm_ssh "shred -u /run/native-ab-secure-boot-test-recovery.key /run/pcr-signing.pub" || true

luks_dump="$(vm_ssh "cryptsetup luksDump --dump-json-metadata '$var_device'")"
tpm_token_count="$(jq '[.tokens[] | select(.type == "systemd-tpm2")] | length' <<<"$luks_dump")"
assert_eq "exactly one systemd-tpm2 LUKS token after enrollment" "$tpm_token_count" "1"
token_policy_ok="$(jq -r '
    [.tokens[] | select(.type == "systemd-tpm2")][0]
    | (."tpm2-pcrs" == []) and (.tpm2_pubkey_pcrs == [11]) and (has("tpm2-pcrlock") | not)
' <<<"$luks_dump")"
assert_eq "TPM token uses signed PCR 11-only policy (empty raw-PCR set)" "$token_policy_ok" "true"

echo ""
echo "=== Step 4b: reboot with ZERO serial input -- TPM must auto-unlock /var ==="
reboot_guest
booted_version="$(guest_version)"
assert_eq "still booted version N after the TPM-enrolled reboot" "$booted_version" "$n_version"
prompt_count_after_enroll="$(grep -c 'typed recovery passphrase' "$WORK_DIR/console.log" || true)"
assert_eq "console pump never had to type a passphrase again after TPM enrollment" "$prompt_count_after_enroll" "1"
var_source="$(vm_ssh 'findmnt -no SOURCE /var' || true)"
assert_eq "/var is still mounted from the LUKS mapper after unattended TPM unlock" "$var_source" "/dev/mapper/var"

# ===========================================================================
# Step 5: desktop assertions (Snow)
# ===========================================================================
echo ""
echo "=== Step 5: desktop assertions ==="

# wait_for_ssh only proves the SSH port is open, not that the graphical
# session has finished starting (GNOME/GDM take longer than sshd on a
# desktop image) -- settle on system-running (or a bounded wait) before
# asserting graphical.target, or this races and flakes (observed live: SSH
# reachable while graphical.target was still activating).
vm_ssh 'systemctl is-system-running --wait' >/dev/null || true

graphical_state="$(vm_ssh 'systemctl show -P ActiveState graphical.target' || true)"
assert_eq "graphical.target is active" "$graphical_state" "active"
gdm_state="$(vm_ssh 'systemctl show -P ActiveState gdm.service' || true)"
assert_eq "gdm.service is active" "$gdm_state" "active"
seat_listing="$(vm_ssh 'loginctl list-seats --no-legend' || true)"
assert_contains "a logind seat exists" "$seat_listing" "seat0"
assert_true "notify-send is present (libnotify-bin, graphical package set)" \
    vm_ssh 'command -v notify-send'

var_home_owner="$(vm_ssh "stat -c '%U:%G %a' /var/home" || true)"
assert_eq "/var/home exists with expected fresh-tmpfiles ownership/mode" "$var_home_owner" "root:root 755"
var_roothome_owner="$(vm_ssh "stat -c '%U:%G %a' /var/roothome" || true)"
assert_eq "/var/roothome exists with expected fresh-tmpfiles ownership/mode" "$var_roothome_owner" "root:root 700"
var_opt_owner="$(vm_ssh "stat -c '%U:%G %a' /var/opt" || true)"
assert_eq "/var/opt exists with expected fresh-tmpfiles ownership/mode" "$var_opt_owner" "root:root 755"

dpkg_link_target="$(vm_ssh 'readlink /var/lib/dpkg' || true)"
assert_eq "/var/lib/dpkg is the factory dpkg relocation symlink" "$dpkg_link_target" "../../usr/lib/sysimage/dpkg"
dpkg_query_out="$(vm_ssh "dpkg-query -W -f='\${Package} \${Version}\n' systemd" || true)"
assert_true "dpkg-query works against the relocated /var/lib/dpkg on snow" \
    bash -c "[[ -n '$dpkg_query_out' ]]"
echo "dpkg-query systemd: $dpkg_query_out"

# --- minimal ad hoc sysext fixture: plain-directory form (systemd-sysext(8)
# merges directories exactly like raw images; no erofs/squashfs build or
# guest-side loop mount needed to prove the icon-cache contract). ---
echo ""
echo "=== Step 5b: ad hoc sysext fixture (hicolor icon-cache contract) ==="
guest_os_id="$(vm_ssh '. /etc/os-release; echo "$ID"')"
[[ -n "$guest_os_id" ]] || { echo "Error: could not read guest ID= from os-release" >&2; exit 1; }
# The image also sets SYSEXT_LEVEL (confirmed live: "SYSEXT_LEVEL=1.0" on
# this build). Per os-release(5)/extension-release semantics, when the host
# declares SYSEXT_LEVEL, systemd-sysext requires the extension to declare a
# matching one too -- ID= alone is not sufficient and the merge silently
# reports "No suitable extensions found (1 ignored due to incompatible
# image(s))" (observed live). Real snosi sysexts already set this; mirror
# it here instead of hardcoding "1.0".
guest_sysext_level="$(vm_ssh '. /etc/os-release; echo "$SYSEXT_LEVEL"')"
fixture="$WORK_DIR/sysext-fixture"
mkdir -p "$fixture/usr/lib/extension-release.d" \
    "$fixture/usr/share/applications" \
    "$fixture/usr/share/icons/hicolor/48x48/apps"
{
    echo "ID=$guest_os_id"
    [[ -z "$guest_sysext_level" ]] || echo "SYSEXT_LEVEL=$guest_sysext_level"
} > "$fixture/usr/lib/extension-release.d/extension-release.native-ab-secure-boot-test"
cat > "$fixture/usr/share/applications/native-ab-secure-boot-test.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=native-ab-secure-boot-test fixture
Exec=/bin/true
Icon=native-ab-secure-boot-test
NoDisplay=true
EOF
# A minimal but syntactically valid 1x1 PNG (hicolor only cares that a file
# with the right name/path exists to be indexed).
python3 -c "
import base64, pathlib
png = base64.b64decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII='
)
pathlib.Path('$fixture/usr/share/icons/hicolor/48x48/apps/native-ab-secure-boot-test.png').write_bytes(png)
"
vm_ssh 'mkdir -p /var/lib/extensions/native-ab-secure-boot-test'
scp "${SSH_OPTS[@]}" -i "$SSH_KEY" -P "$SSH_PORT" -r "$fixture/." \
    root@localhost:/var/lib/extensions/native-ab-secure-boot-test/

merge_out=""
merge_rc=0
merge_out="$(vm_ssh 'systemd-sysext merge' 2>&1)" || merge_rc=$?
echo "$merge_out"
assert_eq "systemd-sysext merge succeeds with the fixture present" "$merge_rc" "0"
# `systemd-sysext status` lists, per hierarchy, either "none" (nothing
# merged) or the merged extension name(s) + a SINCE timestamp -- there is
# no literal "active" column in its output (confirmed live); the extension
# name appearing in the /usr row IS the "merged and active" signal.
sysext_status="$(vm_ssh 'systemd-sysext status --no-pager' || true)"
assert_contains "systemd-sysext status shows the fixture merged into /usr" "$sysext_status" "native-ab-secure-boot-test"
assert_false "the /usr hierarchy no longer reports 'none' once merged" \
    bash -c "grep -qE '^/usr[[:space:]]+none[[:space:]]' <<<'$sysext_status'"
desktop_listing="$(vm_ssh 'ls /usr/share/applications' || true)"
assert_contains "fixture .desktop entry visible in merged /usr/share/applications" \
    "$desktop_listing" "native-ab-secure-boot-test.desktop"
assert_false "no hicolor icon-theme.cache exists after merge (CLAUDE.md icon-cache rule)" \
    vm_ssh 'test -e /usr/share/icons/hicolor/icon-theme.cache'
vm_ssh 'systemd-sysext unmerge'

# ===========================================================================
# Step 6: secure update hop N -> N+1 under enforced Secure Boot
# ===========================================================================
echo ""
echo "=== Step 6: secure update hop (publish N+1, stage, reboot) ==="

# Persistence marker written now (in /var, survives reboots+updates) and in
# the /etc overlay upper (survives reboots+updates, NOT the image's lower).
vm_ssh 'echo native-ab-secure-boot-test-var-marker > /var/lib/native-ab-secure-boot-test.marker'
vm_ssh "printf '\nnative-ab-secure-boot-test etc marker\n' >> /etc/issue"

# The ephemeral signing key MUST exist before publish_version's sign_sums
# call below (it gpg-signs SHA256SUMS with whatever default secret key is
# in this gnupg homedir) -- generate it first (observed live: publishing
# before generating the key fails "no default secret key").
gpg --homedir "$WORK_DIR/gnupg" --batch --passphrase '' --quick-generate-key \
    'snosi native A/B secure-boot test <native-ab-secure-boot-test@invalid>' ed25519 sign 0
gpg --homedir "$WORK_DIR/gnupg" --batch --export > "$WORK_DIR/import-pubring.gpg"

publish_version "$BUILD_N1_DIR"

cat > "$WORK_DIR/overrides/10-root-verity.transfer" <<EOF
[Transfer]
ProtectVersion=%A
Verify=yes

[Source]
Type=url-file
Path=http://10.0.2.2:${SOURCE_PORT}/os/
MatchPattern=${CHANNEL}_@v_@u.root-verity.raw.xz

[Target]
Type=partition
Path=auto
MatchPattern=${IMAGE_ID}_@v_v
MatchPartitionType=root-verity
PartitionFlags=0
ReadOnly=yes
InstancesMax=2
EOF
cat > "$WORK_DIR/overrides/20-root.transfer" <<EOF
[Transfer]
ProtectVersion=%A
Verify=yes

[Source]
Type=url-file
Path=http://10.0.2.2:${SOURCE_PORT}/os/
MatchPattern=${CHANNEL}_@v_@u.root.raw.xz

[Target]
Type=partition
Path=auto
MatchPattern=${IMAGE_ID}_@v_r
MatchPartitionType=root
PartitionFlags=0
ReadOnly=yes
InstancesMax=2
EOF
cat > "$WORK_DIR/overrides/90-uki.transfer" <<EOF
[Transfer]
ProtectVersion=%A
Verify=yes

[Source]
Type=url-file
Path=http://10.0.2.2:${SOURCE_PORT}/os/
MatchPattern=${CHANNEL}_@v.efi

[Target]
Type=regular-file
Path=/EFI/Linux
PathRelativeTo=boot
MatchPattern=${CHANNEL}_@v+@l-@d.efi
MatchPattern=${CHANNEL}_@v+@l.efi
MatchPattern=${CHANNEL}_@v.efi
Mode=0444
TriesLeft=3
TriesDone=0
InstancesMax=2
EOF

vm_ssh 'mkdir -p /etc/sysupdate.d /etc/systemd'
scp "${SSH_OPTS[@]}" -i "$SSH_KEY" -P "$SSH_PORT" \
    "$WORK_DIR/overrides/10-root-verity.transfer" \
    "$WORK_DIR/overrides/20-root.transfer" \
    "$WORK_DIR/overrides/90-uki.transfer" \
    root@localhost:/etc/sysupdate.d/
scp "${SSH_OPTS[@]}" -i "$SSH_KEY" -P "$SSH_PORT" \
    "$WORK_DIR/import-pubring.gpg" root@localhost:/etc/systemd/import-pubring.gpg

# Serve publish_dest itself (.../$IMAGE_ID/x86-64) as the HTTP root under
# an "os" symlink so it matches the transfer files' Path=.../os/ exactly
# (same indirection test/native-ab-updateux-test.sh uses) -- serving
# publish-out/$IMAGE_ID directly would put the real files one level deeper,
# at /x86-64/..., not /os/... (caught live: first attempt 404/empty-replied
# against the wrong path).
mkdir -p "$WORK_DIR/http-root"
ln -s "$publish_dest" "$WORK_DIR/http-root/os"
python3 -m http.server "$SOURCE_PORT" --bind 0.0.0.0 --directory "$WORK_DIR/http-root" \
    >"$WORK_DIR/http.log" 2>&1 &
HTTP_PID=$!
vm_ssh "curl --fail --silent --show-error 'http://10.0.2.2:${SOURCE_PORT}/os/SHA256SUMS' >/dev/null"

stager_out=""
stager_rc=0
stager_out="$(vm_ssh '/usr/libexec/snosi-sysupdate-stage' 2>&1)" || stager_rc=$?
echo "$stager_out"
assert_eq "snosi-sysupdate-stage stages N+1" "$stager_rc" "0"

echo ""
echo "=== Step 6b: reboot into N+1 with ZERO serial input -- signed PCR 11 must survive the new UKI ==="
reboot_guest
rebooted_version="$(guest_version)"
assert_eq "booted version is N+1 after the secure update hop" "$rebooted_version" "$n1_version"
prompt_count_after_update="$(grep -c 'typed recovery passphrase' "$WORK_DIR/console.log" || true)"
assert_eq "still no passphrase prompt after the N+1 reboot (PCR 11 signed policy survived the new UKI)" \
    "$prompt_count_after_update" "1"

sb_state="$(vm_ssh 'mokutil --sb-state' || true)"
assert_contains "N+1: Secure Boot still enabled" "$sb_state" "SecureBoot enabled"
bootctl_status="$(vm_ssh 'bootctl --no-pager status' || true)"
assert_contains "N+1: Measured UKI: yes (new MOK-signed UKI actually loaded)" "$bootctl_status" "Measured UKI: yes"
var_source="$(vm_ssh 'findmnt -no SOURCE /var' || true)"
assert_eq "N+1: /var still auto-unlocked via the TPM mapper" "$var_source" "/dev/mapper/var"

luks_dump="$(vm_ssh "cryptsetup luksDump --dump-json-metadata '$var_device'")"
tpm_token_count="$(jq '[.tokens[] | select(.type == "systemd-tpm2")] | length' <<<"$luks_dump")"
assert_eq "N+1: still exactly one systemd-tpm2 LUKS token (no re-enrollment happened)" "$tpm_token_count" "1"

marker_value="$(vm_ssh 'cat /var/lib/native-ab-secure-boot-test.marker' || true)"
assert_eq "/var persistence marker survived the update" "$marker_value" "native-ab-secure-boot-test-var-marker"
etc_marker="$(vm_ssh 'tail -1 /etc/issue' || true)"
assert_eq "/etc overlay upper marker survived the update" "$etc_marker" "native-ab-secure-boot-test etc marker"

esp_listing="$(vm_ssh 'ls /boot/EFI/Linux' || true)"
echo "ESP listing after update: $esp_listing"
assert_contains "N's UKI is still present in the ESP (InstancesMax=2 rollback entry)" "$esp_listing" "${CHANNEL}_${n_version}"
assert_contains "N+1's UKI is present in the ESP" "$esp_listing" "${CHANNEL}_${n1_version}"
layout_after_update="$(vm_ssh 'lsblk -J -o PARTLABEL' || echo "{}")"
n_root_still_present="$(jq --arg l "${IMAGE_ID}_${n_version}_r" \
    '[.. | objects | select(.partlabel? == $l)] | length' <<<"$layout_after_update")"
assert_eq "N's root partition slot (rollback target) is still present" "$n_root_still_present" "1"

health="$(vm_ssh 'systemctl is-system-running --wait' || true)"
assert_true "system health is running or degraded after the secure update" \
    bash -c "[[ '$health' == running || '$health' == degraded ]]"

# ===========================================================================
# Step 7: recovery unlock check (non-destructive)
# ===========================================================================
echo ""
echo "=== Step 7: recovery keyslot still opens the volume (non-destructive) ==="
guest_with_input "$recovery_key_file" "cryptsetup open --test-passphrase --key-file=- '$var_device'"
pass "recovery keyslot still opens /var (cryptsetup open --test-passphrase)"

echo ""
echo "Native A/B secure-boot/TPM/desktop validation: N=$n_version -> N+1=$n1_version ($PROFILE)"
print_summary
