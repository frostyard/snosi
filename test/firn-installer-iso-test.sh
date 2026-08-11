#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# End-to-end test of the single firn installer ISO (ADR-0010 in firn:
# docs/adr/0010-single-installer-iso-in-snosi.md): boot the ISO in QEMU
# with a PERSISTENT software TPM, run a firn A/B install with
# encryption = tpm2-luks against the guest's blank disk, then reboot
# the SAME virtual machine (same swtpm state, same OVMF varstore) from
# the installed disk and prove /var auto-unlocks via the TPM — the
# full-fidelity encrypted-boot E2E firn's roadmap Phase 7 calls for
# (argv-level unit tests covered enrollment until now; this covers the
# actual unseal on boot).
#
# Same-VM install+boot is what makes the TPM proof real: enrollment
# binds to the installing machine's TPM (signed PCR 11 policy, pubkey
# extracted from the target's own UKI), so only a boot against the SAME
# TPM state can unseal. It is also why this must run in a VM at all
# (firn ADR-0009: A/B images clone a snosi host's discoverable
# partition layout; never attach one to a host kernel).
#
# Flow:
#   1. Reuse (or build) output/firn-installer + the assembled ISO;
#      inject a test SSH key into the rootfs and reassemble the ISO so
#      the installer environment is reachable over SSH
#      (native-installer-iso-test.sh's technique).
#   2. Start swtpm; boot QEMU #1: OVMF (Secure Boot off — the SB chain
#      is native-installer-iso-test.sh's domain), ISO, blank 30G virtio
#      target, vTPM, hostfwd SSH.
#   3. Over SSH: verify the firn kiosk came up on the serial console,
#      then run a headless `firn install` (product cayo-ab,
#      encryption tpm2-luks) against /dev/vda using the medium's own
#      binary, pubring, and tools.
#   4. Power off; boot QEMU #2 from the INSTALLED disk with the same
#      swtpm state + varstore. Assert over SSH (root key seeded via the
#      recipe): /var is a dm-crypt mapper (encrypted), it mounted
#      WITHOUT any passphrase entry (TPM unseal), hostname + user +
#      install-info are right.
#
# Usage: sudo ./test/firn-installer-iso-test.sh
# Env: SKIP_BUILD=1 to reuse output/firn-installer + ISO, SSH_TIMEOUT
# (default 300), INSTALL_TIMEOUT (default 900), KEEP_VM=1 to keep
# artifacts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

: "${SSH_PORT:=2237}"
: "${SSH_TIMEOUT:=300}"
: "${INSTALL_TIMEOUT:=900}"
: "${VM_MEMORY:=4096}"
: "${VM_CPUS:=2}"
: "${SKIP_BUILD:=0}"
: "${KEEP_VM:=0}"
# Default flow installs cayo-ab (server, fast, no flatpaks) and proves
# the encrypted-boot + TPM story. FIRN_ISO_FLATPAK=1 instead installs a
# DESKTOP image with core_flatpaks and proves the OFFLINE medium-copy
# path: firn provisions the ISO-seeded flatpaks with the guest network
# cut after the image download, and they appear on the booted system.
: "${FIRN_ISO_FLATPAK:=0}"
: "${FIRN_ISO_PRODUCT:=}"
if [[ -n $FIRN_ISO_PRODUCT ]]; then product=$FIRN_ISO_PRODUCT
elif [[ $FIRN_ISO_FLATPAK == 1 ]]; then product=snow-ab
else product=cayo-ab; fi

[[ $EUID -eq 0 ]] || { echo "must run as root" >&2; exit 1; }
for cmd in qemu-system-x86_64 swtpm xorriso ssh-keygen; do
  command -v "$cmd" >/dev/null || { echo "missing tool: $cmd" >&2; exit 1; }
done

ROOTFS="$ROOT_DIR/output/firn-installer"
WORK_DIR="$(mktemp -d /var/tmp/firn-iso-e2e.XXXXXX)"
qemu_pid=""; swtpm_pid=""
cleanup() {
  [[ -n $qemu_pid ]] && kill "$qemu_pid" 2>/dev/null || true
  [[ -n $swtpm_pid ]] && kill "$swtpm_pid" 2>/dev/null || true
  [[ $KEEP_VM == 1 ]] || rm -rf "$WORK_DIR"
}
trap cleanup EXIT

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# --- 1. Rootfs + ISO with an injected SSH key ------------------------------
if [[ $SKIP_BUILD != 1 ]]; then
  echo "== building firn-installer rootfs + ISO (SKIP_BUILD=1 to reuse)"
  (cd "$ROOT_DIR" && FIRN_SRC="${FIRN_SRC:-../firn}" just firn-installer)
fi
[[ -d $ROOTFS ]] || fail "rootfs missing at $ROOTFS (run: just firn-installer)"

ssh-keygen -t ed25519 -N "" -f "$WORK_DIR/id_e2e" -C firn-iso-e2e >/dev/null
install -d -m 0700 "$ROOTFS/root/.ssh"
install -m 0600 "$WORK_DIR/id_e2e.pub" "$ROOTFS/root/.ssh/authorized_keys"

version="$(date -u +%Y%m%d%H%M%S)"
echo "== assembling test ISO (version $version, injected SSH key)"
# The flatpak variant embeds the seed (built by `just firn-flatpak-seed`)
# so the offline medium-copy path has something to copy; build-iso.sh
# reads FIRN_FLATPAK_SEED_DIR.
seed_env=()
if [[ $FIRN_ISO_FLATPAK == 1 ]]; then
  seed="${FIRN_FLATPAK_SEED_DIR:-$ROOT_DIR/output/firn-flatpak-seed}"
  [[ -d $seed/repo ]] || fail "FIRN_ISO_FLATPAK=1 but no seed at $seed (run: just firn-flatpak-seed)"
  seed_env=(FIRN_FLATPAK_SEED_DIR="$seed")
  echo "   embedding flatpak seed: $seed ($(du -sh "$seed" | cut -f1))"
fi
env "${seed_env[@]}" "$ROOT_DIR/shared/firn-installer/tools/build-iso.sh" "$ROOTFS" "$WORK_DIR" "$version"
ISO="$(ls "$WORK_DIR"/*.iso | head -1)"
[[ -f $ISO ]] || fail "ISO assembly produced nothing in $WORK_DIR"

# --- 2. Boot the ISO with a persistent vTPM --------------------------------
ovmf_code=""
for c in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd; do
  [[ -f $c ]] && ovmf_code=$c && break
done
[[ -n $ovmf_code ]] || fail "OVMF firmware not found"
cp "${ovmf_code/CODE/VARS}" "$WORK_DIR/vars.fd"
truncate -s 30G "$WORK_DIR/target.raw"

mkdir -p "$WORK_DIR/tpmstate"
swtpm socket --tpm2 --tpmstate dir="$WORK_DIR/tpmstate" \
  --ctrl type=unixio,path="$WORK_DIR/swtpm.sock" --daemon \
  --pid file="$WORK_DIR/swtpm.pid"
swtpm_pid="$(cat "$WORK_DIR/swtpm.pid")"

start_qemu() { # boot-from: iso | disk
  local from=$1 media=()
  if [[ $from == iso ]]; then
    media=(-cdrom "$ISO" -boot d)
  fi
  # swtpm's control socket accepts one connection per QEMU lifetime;
  # restart it for the second boot with the SAME state dir (that
  # persistence is the whole point).
  if ! kill -0 "$swtpm_pid" 2>/dev/null; then
    swtpm socket --tpm2 --tpmstate dir="$WORK_DIR/tpmstate" \
      --ctrl type=unixio,path="$WORK_DIR/swtpm.sock" --daemon \
      --pid file="$WORK_DIR/swtpm.pid"
    swtpm_pid="$(cat "$WORK_DIR/swtpm.pid")"
  fi
  qemu-system-x86_64 \
    -m "$VM_MEMORY" -smp "$VM_CPUS" -enable-kvm -cpu host \
    -drive if=pflash,format=raw,readonly=on,file="$ovmf_code" \
    -drive if=pflash,format=raw,file="$WORK_DIR/vars.fd" \
    -drive file="$WORK_DIR/target.raw",format=raw,if=virtio \
    "${media[@]}" \
    -chardev socket,id=chrtpm,path="$WORK_DIR/swtpm.sock" \
    -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-crb,tpmdev=tpm0 \
    -nic "user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22" \
    -display none -serial file:"$WORK_DIR/console-$from.log" &
  qemu_pid=$!
}

sshq() {
  ssh -i "$WORK_DIR/id_e2e" -p "$SSH_PORT" -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=yes \
    root@127.0.0.1 "$@"
}

wait_ssh() {
  local deadline=$((SECONDS + SSH_TIMEOUT))
  while ((SECONDS < deadline)); do
    sshq true 2>/dev/null && return 0
    kill -0 "$qemu_pid" 2>/dev/null || fail "QEMU exited early ($1)"
    sleep 5
  done
  fail "no SSH within ${SSH_TIMEOUT}s ($1; console: $WORK_DIR/console-$1.log)"
}

echo "== boot 1: ISO (installer environment)"
start_qemu iso
wait_ssh iso
pass "installer environment reachable over SSH"

# The kiosk must be actually running firn on the serial console. Assert
# via systemd, not a serial-log grep: bubbletea drives the alternate
# screen with cursor positioning, so the welcome title never lands as a
# greppable plain-text run in the raw serial byte stream (firn skill
# drive-tui-e2e's "serial is fragile" pitfall).
kiosk_state="$(sshq systemctl is-active firn-kiosk-serial@ttyS0.service 2>/dev/null || true)"
if [[ $kiosk_state != active ]]; then
  echo "-- firn-kiosk-serial@ttyS0 journal --" >&2
  sshq journalctl -u 'firn-kiosk-serial@ttyS0.service' --no-pager 2>&1 | tail -20 >&2
  fail "firn kiosk not active on ttyS0 (state: $kiosk_state)"
fi
# The kiosk ExecStart is /usr/bin/firn; confirm the binary actually
# launched (a crash-looping unit can still read 'activating').
sshq 'test -x /usr/bin/firn' || fail "firn binary missing from the medium"
pass "firn kiosk active on ttyS0 (binary present, unit running)"

# --- 3. Headless encrypted install from the medium -------------------------
# The TUI path is E2E'd in firn (test/e2e-tui.sh); here the medium +
# encrypted+TPM path is the subject, driven headless for determinism.
flatpak_lines=""
if [[ $FIRN_ISO_FLATPAK == 1 ]]; then
  flatpak_lines=$'flatpaks = []\ncore_flatpaks = true'
  # Prove the ISO seed is actually mounted where firn reads it.
  seeded="$(sshq 'flatpak list --system --columns=application 2>/dev/null | wc -l' || echo 0)"
  if [[ ${seeded:-0} -le 0 ]]; then
    echo "-- firn-flatpak-seed diagnostics --" >&2
    sshq 'systemctl status firn-flatpak-seed.service --no-pager -l 2>&1 | head -20
          echo ...journal...; journalctl -u firn-flatpak-seed.service --no-pager 2>&1 | tail -20
          echo ...devices...; ls -l /dev/disk/by-label/ 2>&1; ls -l /dev/sr0 /dev/vd* 2>&1
          echo ...mounts...; findmnt /var/lib/flatpak 2>&1; mountpoint /var/lib/flatpak 2>&1' >&2 || true
    fail "ISO flatpak seed not present at /var/lib/flatpak (got $seeded refs)"
  fi
  pass "ISO flatpak seed mounted at /var/lib/flatpak ($seeded refs)"
  # Deterministic offline proof: black-hole flathub in the installer
  # environment so the signed image download (repository.frostyard.org)
  # still works, but flatpaks can ONLY come from the ISO seed's copy
  # path — never a flathub download. Cleaner than racing a network-cut
  # timer against the image stream.
  sshq 'printf "127.0.0.1 dl.flathub.org\n127.0.0.1 flathub.org\n" >> /etc/hosts'
  pass "flathub black-holed — flatpaks must come from the seed"
fi

sshq "systemctl stop 'firn-kiosk*' 2>/dev/null; cat > /root/recipe.toml" <<EOF
version = 1

[image]
family = "ab"
product = "$product"

[target]
disk = "/dev/vda"

[security]
encryption = "tpm2-luks"

[system]
hostname = "frn-iso-e2e"
timezone = "America/Chicago"
root_ssh_authorized_key_file = "/root/.ssh/authorized_keys"
$flatpak_lines

[system.user]
name = "e2e"
password_hash = "\$6\$firn.e2e\$XjSAJP9d3TXbJ4wIcZarBOUpAo6yLh4uYUniEcpKPGqAe7EfWbrKZOfjfHiZ0KOhSjrqAGdRhrGxU0aTsTfW/1"
groups = ["sudo"]
EOF

echo "== installing $product (tpm2-luks${flatpak_lines:+, core flatpaks offline}) from the medium"
sshq "firn install --confirm /dev/vda --json-progress /root/recipe.toml" \
  >"$WORK_DIR/progress.ndjson" 2>"$WORK_DIR/firn.err" \
  || { tail -8 "$WORK_DIR/firn.err" >&2; fail "firn install failed in the ISO environment"; }
grep -q '"event":"done","ok":true' "$WORK_DIR/progress.ndjson" \
  || fail "no done event in the install progress stream"
grep -q '"event":"recovery_key"' "$WORK_DIR/progress.ndjson" \
  || fail "tpm2-luks install did not disclose a recovery key"
if [[ $FIRN_ISO_FLATPAK == 1 ]]; then
  # No flatpak may be reported unreachable — the seed must satisfy them
  # all with the network down.
  if grep -q '"code":"flatpak_unreachable"' "$WORK_DIR/progress.ndjson"; then
    grep '"code":"flatpak_unreachable"' "$WORK_DIR/progress.ndjson" >&2
    fail "flatpaks were unreachable — the ISO seed did not cover the core set offline"
  fi
  pass "core flatpaks provisioned offline from the ISO seed"
fi
pass "encrypted install completed from the medium"

sshq poweroff 2>/dev/null || true
wait "$qemu_pid" 2>/dev/null || true; qemu_pid=""

# --- 4. Boot the installed disk against the SAME vTPM ----------------------
echo "== boot 2: installed disk (same swtpm state — TPM auto-unlock proof)"
start_qemu disk
wait_ssh disk

fail_count=0
check() { if [[ $3 == *"$2"* ]]; then pass "$1 = $3"; else echo "FAIL: $1 = $3 (want $2)" >&2; fail_count=1; fi; }
check hostname frn-iso-e2e "$(sshq hostname)"
check var-encrypted crypt "$(sshq lsblk -no TYPE "\$(findmnt -n -o SOURCE /var)")"
check var-mounted /var "$(sshq findmnt -n -o TARGET /var)"
check tpm-unlocked-boot "0" "$(sshq 'systemctl show systemd-cryptsetup@* --property=Result 2>/dev/null | grep -c timeout || echo 0')"
check user "uid=1000(e2e)" "$(sshq id e2e)"
check installer firn "$(sshq cat /var/lib/snosi/install-info.json)"
if [[ $FIRN_ISO_FLATPAK == 1 ]]; then
  # The seeded core apps must be present on the INSTALLED system's
  # flatpak installation — provisioned offline from the ISO.
  installed_apps="$(sshq 'flatpak list --system --app --columns=application 2>/dev/null | wc -l' || echo 0)"
  check flatpaks-installed-offline yes "$([[ ${installed_apps:-0} -ge 20 ]] && echo yes || echo "only $installed_apps")"
  check flatpak-calculator org.gnome.Calculator "$(sshq flatpak list --system --app --columns=application 2>/dev/null | tr '\n' ' ')"
fi

sshq poweroff 2>/dev/null || true
wait "$qemu_pid" 2>/dev/null || true; qemu_pid=""

((fail_count == 0)) || fail "assertions failed (artifacts: $WORK_DIR; KEEP_VM=1 to keep)"
echo "ALL PASS: ISO boots to the firn kiosk; encrypted A/B install from the medium; /var TPM-auto-unlocked on reboot of the same VM"
