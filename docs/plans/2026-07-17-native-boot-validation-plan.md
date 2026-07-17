# Native A/B Boot Validation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Gate native A/B promotion on a QEMU boot smoke test of the published bytes, and add a nightly deep secure-boot validation workflow.

**Architecture:** Two new root+KVM harness scripts (`test/native-boot-smoke-test.sh`, `test/native-iso-boot-smoke-test.sh`) reuse `test/lib/vm.sh`/`ssh.sh` and consume the same prepared-dir + base-url interface as `verify-remote.sh`. They are wired into `build-native-images.yml`'s `test-public-origin`/`test-public-origin-iso` jobs so the `native-verified-*` marker (the existing promotion gate) also requires a successful boot. A new `native-nightly.yml` runs the existing `test/native-ab-secure-boot-test.sh` on a schedule with ephemeral keys and zero repository secrets.

**Tech Stack:** bash, QEMU/KVM, OVMF, xz, jq, losetup; GitHub Actions (hosted ubuntu-latest); swtpm + virt-firmware (nightly only).

**Spec:** `docs/plans/2026-07-17-native-boot-validation-design.md`

## Global Constraints

- All scripts: `set -euo pipefail`, shellcheck-clean (`validate.yml` runs shellcheck over `test/`).
- The workflow stays a thin caller: NO validation logic in YAML; everything testable lives in `test/*.sh`.
- Scratch space is `/var/tmp` (repo convention; CI bind-mounts it to `/mnt`).
- Published root/verity bytes are booted pristine; only the var partition (user data) may be modified before boot.
- Artifact names/paths are derived from `publication-info.json` / `SHA256SUMS`, never hardcoded.
- Candidate objects live at `<base-url>/.candidate/<version>/<name>` (the convention in `shared/native-ab/publish/publish-lib.sh` `candidate_subpath()`).
- The nightly workflow must reference NO GitHub environments and NO repository secrets; all key material is generated per-run (PCR key MUST be RSA-2048, default exponent — docs/native-ab-contracts.md §7).
- Work on branch `feat/boot-validation-tiers` (already created, design doc committed).

## Established facts (verified against the tree — do not re-litigate)

- `verify-remote.sh` downloads reference blobs to `mktemp /var/tmp/verify-remote-ref.XXXXXX` and deletes them via cleanup — the smoke scripts must fetch the blob themselves.
- In CI, the prepared dir contains ONLY `publication-info.json` + `SHA256SUMS` (blobs never travel as artifacts).
- Product `publication-info.json` fields: `.product`, `.channel`, `.version`, `.xz` (bool), `.artifacts.disk.name` (e.g. `cayo-ab_20260717120000.disk.raw.xz`). ISO variant: `.artifacts.iso.name`, `.version`, product/channel are `snosi-native-installer`.
- `SHA256SUMS` lines are `<sha256>  <name>` (two spaces).
- Native disk partition order (`shared/native-ab/channels/<p>/mkosi.repart/`): 00-esp, 10-root-verity, 11-root, 20-root-verity-empty, 21-root-empty, 30-var — var is partition 6, `Format=ext4` (formatted at build; direct boot works). Locate it by `PARTLABEL=var`, not by index.
- On native images `/root` is on the read-only dm-verity root. Root SSH works via the sshd drop-in `shared/outformat/ab-root/tree/etc/ssh/sshd_config.d/10-snosi-authorized-keys.conf` (`AuthorizedKeysFile /etc/ssh/authorized_keys.d/%u .ssh/authorized_keys`). The correct injection point is the /etc overlay upperdir on var: `lib/snosi/etc-overlay/upper/ssh/authorized_keys.d/root` — the exact path `snosi-install`'s `seed_var()` uses (`shared/native-installer/tree/usr/libexec/snosi-install:920`).
- `test/lib/vm.sh`: `vm_start <disk>` (plain OVMF via `find_ovmf`, KVM, serial → `${disk%.raw}-console.log`, SSH forward on `$SSH_PORT`, `-daemonize`, sets `QEMU_PID`/`QEMU_CONSOLE_LOG`), `vm_stop`. `test/lib/ssh.sh`: `ssh_keygen <dir>` (sets `SSH_KEY`), `wait_for_ssh` (honors `SSH_TIMEOUT`), `vm_ssh`.
- The KVM-on-hosted-runner recipe is proven in `test-install.yml:38` (udev rule + `qemu-system-x86 qemu-utils ovmf`).
- `test/native-ab-secure-boot-test.sh` requires: root, KVM, `mkosi.key`/`mkosi.crt`, `.snosi-private/pcr-signing.pub` (and `.key`/`.crt` for the builds), `.snosi-private/history/` existing, swtpm(+tools), `virt-fw-vars`; it generates its own ephemeral update-signing GPG key. Its `WORK_DIR` is `mktemp -d /var/tmp/native-ab-secure-boot-test.XXXXXX`.
- ISO smoke: SSH is impossible on published ISO bytes (the local ISO test injects a key into the rootfs BEFORE assembly, `test/native-installer-iso-test.sh:137`); the serial console is `console=ttyS0` only, so a getty login prompt appears on the serial log. The QEMU invocation template for `-cdrom` boots is `test/native-installer-iso-test.sh:321`.

---

### Task 1: `test/native-boot-smoke-test.sh` (product disk smoke)

**Files:**
- Create: `test/native-boot-smoke-test.sh`

**Interfaces:**
- Consumes: `test/lib/vm.sh` (`vm_start`, `vm_stop`, `QEMU_PID`), `test/lib/ssh.sh` (`ssh_keygen`, `wait_for_ssh`, `vm_ssh`, `SSH_KEY`).
- Produces: CLI `sudo test/native-boot-smoke-test.sh <prepared-dir> [base-url]`; env `SMOKE_CONSOLE_COPY` (path the serial log is copied to, pass or fail), `SSH_TIMEOUT` (default 600). Exit 0 = booted + all assertions; non-zero otherwise. Tasks 2 and 4 rely on exactly this interface.

- [ ] **Step 1: Write the script**

```bash
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
# shellcheck source=test/lib/vm.sh
source "$SCRIPT_DIR/lib/vm.sh"
# shellcheck source=test/lib/ssh.sh
source "$SCRIPT_DIR/lib/ssh.sh"

PRODUCT="$(jq -r .product "$PREPARED_DIR/publication-info.json")"
VERSION="$(jq -r .version "$PREPARED_DIR/publication-info.json")"
DISK_NAME="$(jq -r .artifacts.disk.name "$PREPARED_DIR/publication-info.json")"
[[ "$VERSION" =~ ^[0-9]{14}$ ]] || { echo "Error: bad version '$VERSION'" >&2; exit 1; }
[[ -n "$DISK_NAME" && "$DISK_NAME" != "null" ]] || { echo "Error: no .artifacts.disk.name in publication-info.json" >&2; exit 1; }

WORK_DIR="$(mktemp -d /var/tmp/native-boot-smoke.XXXXXX)"
LOOP_DEV=""
MOUNTED=""
FAILED_MSG=""

die() {
    FAILED_MSG="$1"
    echo "FAIL: $1" >&2
    if [[ -n "${QEMU_CONSOLE_LOG:-}" && -f "$QEMU_CONSOLE_LOG" ]]; then
        echo "--- last 60 serial console lines ---" >&2
        tail -60 "$QEMU_CONSOLE_LOG" >&2 || true
        echo "--- end console ---" >&2
    fi
    exit 1
}

cleanup() {
    local rc=$?
    vm_stop >/dev/null 2>&1 || true
    [[ -n "$MOUNTED" ]] && umount "$MOUNTED" 2>/dev/null || true
    [[ -n "$LOOP_DEV" ]] && losetup -d "$LOOP_DEV" 2>/dev/null || true
    if [[ -n "${SMOKE_CONSOLE_COPY:-}" && -n "${QEMU_CONSOLE_LOG:-}" && -f "$QEMU_CONSOLE_LOG" ]]; then
        cp "$QEMU_CONSOLE_LOG" "$SMOKE_CONSOLE_COPY" || true
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
    die "system state is '$state', expected 'running' (startup incomplete or failed units)"
fi
echo "PASS: system state is 'running' (startup complete, no failed units)"

mu="$(vm_ssh "systemctl is-active multi-user.target" || true)"
[[ "$mu" == "active" ]] || die "multi-user.target is '$mu', expected 'active'"
echo "PASS: multi-user.target active"

img_id="$(vm_ssh 'source /etc/os-release && echo "$IMAGE_ID"')"
[[ "$img_id" == "$PRODUCT" ]] || die "IMAGE_ID '$img_id' != expected product '$PRODUCT'"
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
```

- [ ] **Step 2: Make executable and shellcheck**

Run: `chmod +x test/native-boot-smoke-test.sh && shellcheck test/native-boot-smoke-test.sh`
Expected: no output (exit 0). Fix any findings (the `source=` directives above keep shellcheck following the libs).

- [ ] **Step 3: Argument/precondition negative checks (no root, no KVM needed)**

```bash
test/native-boot-smoke-test.sh 2>&1 | grep -q 'Usage' && echo ok-usage
test/native-boot-smoke-test.sh /nonexistent 2>&1 | grep -q 'must run as root' && echo ok-root
sudo test/native-boot-smoke-test.sh /nonexistent 2>&1 | grep -q 'publication-info.json not found' && echo ok-missing
mkdir -p /var/tmp/smoke-argtest && echo '{"product":"cayo","version":"bogus","artifacts":{"disk":{"name":"x"}}}' > /var/tmp/smoke-argtest/publication-info.json && touch /var/tmp/smoke-argtest/SHA256SUMS
sudo test/native-boot-smoke-test.sh /var/tmp/smoke-argtest 2>&1 | grep -q "bad version" && echo ok-version
rm -rf /var/tmp/smoke-argtest
```
Expected: `ok-usage`, `ok-root`, `ok-missing`, `ok-version` each printed.

- [ ] **Step 4: Commit**

```bash
git add test/native-boot-smoke-test.sh
git commit -m "feat: add native A/B disk boot smoke test harness"
```

---

### Task 2: Local end-to-end proof of the disk smoke test (positive + deliberate negative)

Requires: a dev machine with root + KVM. Uses a real `cayo-ab` build (smallest product). If `output/cayo-ab.raw` and its split artifacts already exist from a recent build, reuse them; otherwise build first.

**Files:** none created (verification only; fixes to Task 1's script as needed).

- [ ] **Step 1: Ensure a built cayo-ab exists**

Run: `ls output/cayo-ab.raw output/cayo-ab.manifest 2>/dev/null || sudo SNOSI_NATIVE_AUTOSTAGE=1 just cayo-ab`
Expected: the artifacts exist (build takes ~20-40 min if needed; dev keys `mkosi.key`/`mkosi.crt` + `.snosi-private/pcr-signing.*` must exist per the normal local secure-build setup).

- [ ] **Step 2: Prepare a candidate dir (fast path, no xz — the script supports both)**

Run: `./shared/native-ab/publish/prepare-native-publication.sh output cayo-ab /var/tmp/smoke-e2e`
Expected: `/var/tmp/smoke-e2e/cayo/x86-64/` contains `publication-info.json`, `SHA256SUMS`, and the blobs (local-blob path exercised; the download path is exercised in Step 5).

- [ ] **Step 3: Positive run (local blob)**

Run: `sudo SMOKE_CONSOLE_COPY=/var/tmp/smoke-console.log ./test/native-boot-smoke-test.sh /var/tmp/smoke-e2e/cayo/x86-64`
Expected: ends with `OK: cayo <version> boot smoke test passed`, exit 0, and `/var/tmp/smoke-console.log` exists. If sshd rejects the key, debug via the console log — do NOT weaken assertions to pass.

- [ ] **Step 4: Deliberate negative — corrupted root partition must fail with a preserved console log**

```bash
neg=/var/tmp/smoke-neg; rm -rf "$neg"; mkdir -p "$neg"
disk_name="$(jq -r .artifacts.disk.name /var/tmp/smoke-e2e/cayo/x86-64/publication-info.json)"
cp --sparse=always "/var/tmp/smoke-e2e/cayo/x86-64/$disk_name" "$neg/$disk_name"
# Zero 64 MiB starting at 2 GiB -- inside the root partition (ESP 1G + verity 256M precede it)
dd if=/dev/zero of="$neg/$disk_name" bs=1M count=64 seek=2048 conv=notrunc
jq '.' /var/tmp/smoke-e2e/cayo/x86-64/publication-info.json > "$neg/publication-info.json"
(cd "$neg" && sha256sum "$disk_name" > SHA256SUMS)
sudo SSH_TIMEOUT=120 SMOKE_CONSOLE_COPY=/var/tmp/smoke-neg-console.log ./test/native-boot-smoke-test.sh "$neg"
echo "exit=$?"
test -s /var/tmp/smoke-neg-console.log && echo console-preserved
```
Expected: `FAIL: SSH not reachable within 120s...` (dm-verity refuses the corrupted root), `exit=1`, `console-preserved`. The gate is proven capable of failing.

- [ ] **Step 5: Download-path run (metadata-only prepared dir + local HTTP origin)**

```bash
srv=/var/tmp/smoke-origin; rm -rf "$srv"
ver="$(jq -r .version /var/tmp/smoke-e2e/cayo/x86-64/publication-info.json)"
mkdir -p "$srv/.candidate/$ver"
disk_name="$(jq -r .artifacts.disk.name /var/tmp/smoke-e2e/cayo/x86-64/publication-info.json)"
cp --sparse=always "/var/tmp/smoke-e2e/cayo/x86-64/$disk_name" "$srv/.candidate/$ver/"
meta=/var/tmp/smoke-meta; rm -rf "$meta"; mkdir -p "$meta"
cp /var/tmp/smoke-e2e/cayo/x86-64/publication-info.json /var/tmp/smoke-e2e/cayo/x86-64/SHA256SUMS "$meta/"
python3 test/lib/range-http-server.py 8931 --directory "$srv" & srv_pid=$!
sudo ./test/native-boot-smoke-test.sh "$meta" http://127.0.0.1:8931
rc=$?; kill $srv_pid; echo "exit=$rc"
```
(Adjust the range-http-server invocation to its actual argument syntax — check `head test/lib/range-http-server.py`.)
Expected: `OK: ... passed`, `exit=0` — this is exactly the CI code path (metadata-only dir, blob fetched from `.candidate/`).

- [ ] **Step 6: Clean up and commit any script fixes**

```bash
sudo rm -rf /var/tmp/smoke-e2e /var/tmp/smoke-neg /var/tmp/smoke-origin /var/tmp/smoke-meta /var/tmp/smoke-*console.log
git add -u test/ && git commit -m "fix: smoke test issues found in local end-to-end proof" || echo "nothing to fix"
```

---

### Task 3: `test/native-iso-boot-smoke-test.sh` (ISO serial smoke) + local proof

**Files:**
- Create: `test/native-iso-boot-smoke-test.sh`

**Interfaces:**
- Consumes: `test/lib/vm.sh` (`find_ovmf` only — the QEMU invocation is custom `-cdrom`, modeled on `test/native-installer-iso-test.sh:321`).
- Produces: CLI `sudo test/native-iso-boot-smoke-test.sh <prepared-dir> [base-url]`; env `SMOKE_CONSOLE_COPY`, `ISO_BOOT_TIMEOUT` (default 420). Exit 0 = login prompt seen on serial. Task 4 relies on exactly this interface.

- [ ] **Step 1: Write the script**

```bash
#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Boot smoke test for the published network-installer ISO: proves the exact
# candidate bytes boot (kernel + packed initramfs + systemd userspace) to a
# getty login prompt on the serial console. SSH assertions are impossible on
# published bytes -- the local ISO harness injects its key into the rootfs
# BEFORE assembly (test/native-installer-iso-test.sh Step 1), which would
# defeat "boot what users download". Plain (non-Secure-Boot) OVMF; SB
# enforcement of the ISO chain is test/native-installer-iso-test.sh's job.
#
# Usage: sudo native-iso-boot-smoke-test.sh <prepared-dir> [base-url]
#
#   prepared-dir  prepare-iso-publication.sh output dir (publication-info.json
#                 + SHA256SUMS; the ISO blob optional, fetched from the
#                 .candidate/<version>/ subpath when absent)
#   base-url      HTTP(S) URL of the isos/native/v1 directory
#
# Environment:
#   SMOKE_CONSOLE_COPY  copy the serial log here (pass and fail alike)
#   ISO_BOOT_TIMEOUT    seconds to wait for the login prompt (default 420)
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
: "${ISO_BOOT_TIMEOUT:=420}"
: "${VM_MEMORY:=4096}"
: "${VM_CPUS:=2}"

[[ $EUID -eq 0 ]] || { echo "Error: must run as root (KVM)" >&2; exit 1; }
for cmd in qemu-system-x86_64 jq curl sha256sum; do
    command -v "$cmd" >/dev/null || { echo "Error: required command not found: $cmd" >&2; exit 1; }
done
[[ -f "$PREPARED_DIR/publication-info.json" ]] || { echo "Error: $PREPARED_DIR/publication-info.json not found" >&2; exit 1; }
[[ -f "$PREPARED_DIR/SHA256SUMS" ]] || { echo "Error: $PREPARED_DIR/SHA256SUMS not found" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test/lib/vm.sh
source "$SCRIPT_DIR/lib/vm.sh"

VERSION="$(jq -r .version "$PREPARED_DIR/publication-info.json")"
ISO_NAME="$(jq -r .artifacts.iso.name "$PREPARED_DIR/publication-info.json")"
[[ "$VERSION" =~ ^[0-9]{14}$ ]] || { echo "Error: bad version '$VERSION'" >&2; exit 1; }
[[ -n "$ISO_NAME" && "$ISO_NAME" != "null" ]] || { echo "Error: no .artifacts.iso.name in publication-info.json" >&2; exit 1; }

WORK_DIR="$(mktemp -d /var/tmp/native-iso-smoke.XXXXXX)"
QEMU_PID=""
CONSOLE_LOG="$WORK_DIR/console.log"

die() {
    echo "FAIL: $1" >&2
    if [[ -f "$CONSOLE_LOG" ]]; then
        echo "--- last 60 serial console lines ---" >&2
        tail -60 "$CONSOLE_LOG" >&2 || true
        echo "--- end console ---" >&2
    fi
    exit 1
}

cleanup() {
    local rc=$?
    if [[ -n "$QEMU_PID" ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
        kill "$QEMU_PID" 2>/dev/null || true
    fi
    if [[ -n "${SMOKE_CONSOLE_COPY:-}" && -f "$CONSOLE_LOG" ]]; then
        cp "$CONSOLE_LOG" "$SMOKE_CONSOLE_COPY" || true
    fi
    rm -rf "$WORK_DIR"
    exit "$rc"
}
trap cleanup EXIT

expected_sha="$(awk -v n="$ISO_NAME" '$2 == n {print $1}' "$PREPARED_DIR/SHA256SUMS")"
[[ -n "$expected_sha" ]] || die "no SHA256SUMS entry for $ISO_NAME"

iso="$WORK_DIR/$ISO_NAME"
if [[ -f "$PREPARED_DIR/$ISO_NAME" ]]; then
    echo "Using local ISO $PREPARED_DIR/$ISO_NAME"
    cp "$PREPARED_DIR/$ISO_NAME" "$iso"
else
    [[ -n "$BASE_URL" ]] || die "ISO not in $PREPARED_DIR and no base-url given"
    url="$BASE_URL/.candidate/$VERSION/$ISO_NAME"
    echo "Downloading $url"
    curl -fsSL --retry 3 -o "$iso" "$url" || die "download failed: $url"
fi
actual_sha="$(sha256sum "$iso" | cut -d' ' -f1)"
[[ "$actual_sha" == "$expected_sha" ]] || die "sha256 mismatch for $ISO_NAME: got $actual_sha want $expected_sha"

ovmf_pair="$(find_ovmf)"
ovmf_code="${ovmf_pair%% *}"
ovmf_vars_src="${ovmf_pair##* }"
cp "$ovmf_vars_src" "$WORK_DIR/OVMF_VARS.fd"

echo "Booting installer ISO $VERSION (waiting up to ${ISO_BOOT_TIMEOUT}s for a serial login prompt)"
qemu-system-x86_64 \
    -machine q35 \
    -enable-kvm -cpu host \
    -m "$VM_MEMORY" -smp "$VM_CPUS" \
    -drive "if=pflash,format=raw,unit=0,file=$ovmf_code,readonly=on" \
    -drive "if=pflash,format=raw,unit=1,file=$WORK_DIR/OVMF_VARS.fd" \
    -cdrom "$iso" \
    -display none -vga none \
    -serial "file:$CONSOLE_LOG" \
    -monitor none \
    -pidfile "$WORK_DIR/qemu.pid" \
    -daemonize
QEMU_PID="$(cat "$WORK_DIR/qemu.pid")"

deadline=$((SECONDS + ISO_BOOT_TIMEOUT))
while (( SECONDS < deadline )); do
    if grep -aq "login:" "$CONSOLE_LOG" 2>/dev/null; then
        echo "PASS: serial login prompt reached"
        echo ""
        echo "OK: installer ISO $VERSION boot smoke test passed"
        exit 0
    fi
    kill -0 "$QEMU_PID" 2>/dev/null || die "QEMU exited before a login prompt appeared"
    sleep 5
done
die "no login prompt on serial console within ${ISO_BOOT_TIMEOUT}s"
```

- [ ] **Step 2: Make executable and shellcheck**

Run: `chmod +x test/native-iso-boot-smoke-test.sh && shellcheck test/native-iso-boot-smoke-test.sh`
Expected: no output.

- [ ] **Step 3: Local proof (positive)**

Requires a built installer ISO. Build if absent:
```bash
ls output/snosi-native-installer_*_x86-64.iso 2>/dev/null || {
  sudo .mkosi/bin/mkosi --profile native-installer build
  sudo ./shared/native-installer/tools/build-iso.sh output/native-installer output "$(date -u +%Y%m%d%H%M%S)"
}
iso="$(ls output/snosi-native-installer_*_x86-64.iso | head -1)"
ver="$(basename "$iso" | sed 's/^snosi-native-installer_\([0-9]\{14\}\)_x86-64.iso$/\1/')"
./shared/native-ab/publish/prepare-iso-publication.sh "$iso" "$ver" /var/tmp/iso-smoke-e2e
sudo SMOKE_CONSOLE_COPY=/var/tmp/iso-smoke-console.log ./test/native-iso-boot-smoke-test.sh /var/tmp/iso-smoke-e2e
```
Expected: `OK: installer ISO <version> boot smoke test passed`, exit 0. Confirm the console log shows the ISO's actual getty prompt; if the prompt string differs from `login:` (e.g. localized or absent), fix the match pattern in the script now — this step exists to validate that exact assumption.

- [ ] **Step 4: Local negative (truncated ISO must fail cleanly)**

```bash
neg=/var/tmp/iso-smoke-neg; rm -rf "$neg"; mkdir -p "$neg"
iso_name="$(jq -r .artifacts.iso.name /var/tmp/iso-smoke-e2e/publication-info.json)"
head -c 10M "/var/tmp/iso-smoke-e2e/$iso_name" > "$neg/$iso_name"
jq '.' /var/tmp/iso-smoke-e2e/publication-info.json > "$neg/publication-info.json"
(cd "$neg" && sha256sum "$iso_name" > SHA256SUMS)
sudo ISO_BOOT_TIMEOUT=120 ./test/native-iso-boot-smoke-test.sh "$neg"; echo "exit=$?"
```
Expected: `FAIL: ...` (QEMU exits or no prompt), `exit=1`.

- [ ] **Step 5: Clean up and commit**

```bash
sudo rm -rf /var/tmp/iso-smoke-e2e /var/tmp/iso-smoke-neg /var/tmp/iso-smoke-console.log
git add test/native-iso-boot-smoke-test.sh
git commit -m "feat: add installer ISO boot smoke test harness"
```

---

### Task 4: Wire both smoke tests into `build-native-images.yml`

**Files:**
- Modify: `.github/workflows/build-native-images.yml` — the `test-public-origin` job (currently around lines 584-643) and `test-public-origin-iso` job (around lines 1125-1181).

**Interfaces:**
- Consumes: Task 1's and Task 3's CLIs exactly as specified (`<prepared-dir> [base-url]`, `SMOKE_CONSOLE_COPY`).
- Produces: the `native-verified-<product>` / `native-verified-iso` markers now additionally require the smoke step's success. Promote jobs are untouched.

- [ ] **Step 1: Add KVM/QEMU setup and the smoke step to `test-public-origin`**

Insert after the "Verify candidate objects against the public origin" step and before "Record verified marker":

```yaml
      - name: Enable KVM and install QEMU
        if: steps.download.outcome == 'success'
        run: |
          echo 'KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"' | \
            sudo tee /etc/udev/rules.d/99-kvm4all.rules
          sudo udevadm control --reload-rules
          sudo udevadm trigger --name-match=kvm
          sudo apt-get update
          sudo apt-get install -y --no-install-recommends qemu-system-x86 ovmf xz-utils jq

      - name: Boot smoke test (must reach multi-user.target)
        # The published bytes must BOOT before the verified marker (the
        # promotion gate) is earned -- design doc
        # docs/plans/2026-07-17-native-boot-validation-design.md Tier 1.
        if: steps.verify.outcome == 'success'
        id: smoke
        run: |
          sudo SMOKE_CONSOLE_COPY=/var/tmp/smoke-console.log \
            ./test/native-boot-smoke-test.sh \
            "/var/tmp/native-publish/${{ matrix.product }}/x86-64" \
            "https://repository.frostyard.org/os/native/v1/${{ matrix.product }}/x86-64"

      - name: Upload smoke console log
        if: always() && steps.smoke.outcome == 'failure'
        uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1
        with:
          name: native-smoke-console-${{ matrix.product }}
          path: /var/tmp/smoke-console.log
          retention-days: 7
          if-no-files-found: ignore
```

- [ ] **Step 2: Gate the marker on the smoke step**

Change the two marker steps' conditions from `if: steps.verify.outcome == 'success'` to:

```yaml
        if: steps.verify.outcome == 'success' && steps.smoke.outcome == 'success'
```

(Applies to both "Record verified marker" and "Upload verified marker". Redundant with job failure today, but explicit — it survives someone later adding `continue-on-error` to the smoke step.)

- [ ] **Step 3: Same wiring for `test-public-origin-iso`**

Insert after its "Verify candidate objects against the public origin" step (KVM setup identical minus `xz-utils`), smoke step:

```yaml
      - name: Boot smoke test (ISO must reach a serial login prompt)
        if: steps.verify.outcome == 'success'
        id: smoke
        run: |
          sudo SMOKE_CONSOLE_COPY=/var/tmp/smoke-console.log \
            ./test/native-iso-boot-smoke-test.sh \
            /var/tmp/native-publish/iso \
            https://repository.frostyard.org/isos/native/v1

      - name: Upload smoke console log
        if: always() && steps.smoke.outcome == 'failure'
        uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1
        with:
          name: native-smoke-console-iso
          path: /var/tmp/smoke-console.log
          retention-days: 7
          if-no-files-found: ignore
```

and the same `&& steps.smoke.outcome == 'success'` addition to its "Record verified marker" / "Upload verified marker" conditions.

- [ ] **Step 4: Update the workflow header comment**

In the top-of-file comment block (the "THIS WORKFLOW IS A THIN CALLER" section), add one line noting that `test-public-origin`/`test-public-origin-iso` also boot the candidate bytes via `test/native-boot-smoke-test.sh` / `test/native-iso-boot-smoke-test.sh` before the verified marker is earned.

- [ ] **Step 5: Lint**

Run: `actionlint .github/workflows/build-native-images.yml`
(If actionlint is not installed: `curl -sL https://github.com/rhysd/actionlint/releases/latest/download/actionlint_$(uname -s | tr A-Z a-z)_amd64.tar.gz | tar xz -C /tmp/claude-1000 actionlint 2>/dev/null` or skip with a note — `validate.yml` does not run actionlint, but the repo's convention per MEMORY is actionlint-clean workflows.)
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/build-native-images.yml
git commit -m "feat: gate native promotion on boot smoke tests of the candidate bytes"
```

---

### Task 5: `native-nightly.yml` — scheduled deep secure-boot validation

**Files:**
- Create: `.github/workflows/native-nightly.yml`

**Interfaces:**
- Consumes: `test/native-ab-secure-boot-test.sh` (default mode, `PROFILE` env), `shared/native-ab/ci/bootstrap-mkosi.sh` + `check-mkosi-pin.sh`.
- Produces: a standalone scheduled workflow; nothing else depends on it.

- [ ] **Step 1: Write the workflow**

```yaml
name: Native Nightly Boot Validation

# Tier 2 of docs/plans/2026-07-17-native-boot-validation-design.md: runs the
# existing deep secure-chain harness (test/native-ab-secure-boot-test.sh,
# default mode: install -> enforced Secure Boot -> TPM enroll -> boot ->
# signed N->N+1 update hop) nightly on a hosted runner, rotating profiles by
# day of week. NON-BLOCKING: nothing in the release pipeline depends on this
# workflow; the promotion gate is the Tier 1 smoke test in
# build-native-images.yml.
#
# SECURITY PROPERTY: this workflow references NO GitHub environment and NO
# repository secrets. The harness builds its own images, so all key material
# is ephemeral and generated per-run below (the PCR signing key MUST be
# RSA-2048 with the default exponent -- the only algorithm the full TPM
# unlock chain accepts, docs/native-ab-contracts.md §7). The harness
# generates its own ephemeral update-signing GPG key internally.
on:
  schedule:
    - cron: "0 6 * * *"
  workflow_dispatch:
    inputs:
      profile:
        description: "Profile to validate"
        required: false
        default: rotate
        type: choice
        options: [rotate, cayo-ab, snow-ab, snowfield-ab]

permissions: {}

concurrency:
  group: native-nightly
  cancel-in-progress: false

jobs:
  deep-validate:
    runs-on: ubuntu-latest
    timeout-minutes: 350
    permissions:
      contents: read
    steps:
      - name: Free Disk Space (Ubuntu)
        uses: jlumbroso/free-disk-space@54081f138730dfa15788a46383842cd2f914a1be # v1.3.1
        with:
          tool-cache: true

      - name: Redirect temp to /mnt
        run: |
          sudo mkdir -p /mnt/tmp /mnt/var-tmp
          sudo chmod 1777 /mnt/tmp /mnt/var-tmp
          sudo mount --bind /mnt/var-tmp /var/tmp
          echo "TMPDIR=/mnt/tmp" >> "$GITHUB_ENV"

      - name: Checkout repository
        uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4
        with:
          persist-credentials: false

      - name: Bootstrap pinned mkosi
        run: ./shared/native-ab/ci/bootstrap-mkosi.sh .mkosi

      - name: Assert mkosi pin matches build.yml
        run: ./shared/native-ab/ci/check-mkosi-pin.sh .mkosi

      - name: Prepare mkosi build host
        # Same recipe as build-native-images.yml's build jobs, PLUS the
        # QEMU/swtpm/virt-firmware stack the harness needs.
        run: |
          sudo sysctl --ignore --write kernel.apparmor_restrict_unprivileged_unconfined=0
          sudo sysctl --ignore --write kernel.apparmor_restrict_unprivileged_userns=0
          sudo aa-teardown || true
          sudo apt-get remove -y apparmor || true
          sudo mkdir -p /var/lib/ca-certificates
          sudo apt-get update
          sudo apt-get install -y --no-install-recommends debian-archive-keyring \
            dracut-core binutils file python3-cryptography \
            qemu-system-x86 qemu-utils ovmf swtpm swtpm-tools
          pip3 install --user virt-firmware

      - name: Enable KVM
        run: |
          echo 'KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"' | \
            sudo tee /etc/udev/rules.d/99-kvm4all.rules
          sudo udevadm control --reload-rules
          sudo udevadm trigger --name-match=kvm

      - name: Select profile
        id: profile
        env:
          PROFILE_INPUT: ${{ inputs.profile }}
        run: |
          if [[ -n "$PROFILE_INPUT" && "$PROFILE_INPUT" != "rotate" ]]; then
            profile="$PROFILE_INPUT"
          else
            # Mon/Wed/Fri snow-ab, Tue/Thu/Sat cayo-ab, Sun snowfield-ab
            case "$(date -u +%u)" in
              7) profile=snowfield-ab ;;
              2|4|6) profile=cayo-ab ;;
              *) profile=snow-ab ;;
            esac
          fi
          echo "Selected profile: $profile"
          echo "profile=$profile" >> "$GITHUB_OUTPUT"

      - name: Generate ephemeral key material
        run: |
          set -euo pipefail
          umask 077
          mkdir -p .snosi-private/history
          openssl req -x509 -newkey rsa:4096 -nodes -days 7 \
            -keyout mkosi.key -out mkosi.crt \
            -subj "/CN=snosi nightly ephemeral Secure Boot"
          # RSA-2048, default exponent 65537 -- MANDATORY, see header comment.
          openssl req -x509 -newkey rsa:2048 -nodes -days 7 \
            -keyout .snosi-private/pcr-signing.key -out .snosi-private/pcr-signing.crt \
            -subj "/CN=snosi nightly ephemeral PCR"
          openssl x509 -in .snosi-private/pcr-signing.crt -pubkey -noout \
            > .snosi-private/pcr-signing.pub

      - name: Run deep secure-boot harness
        env:
          PROFILE: ${{ steps.profile.outputs.profile }}
        run: |
          sudo PROFILE="$PROFILE" TMPDIR="$TMPDIR" \
            ./test/native-ab-secure-boot-test.sh |& tee /var/tmp/nightly-harness.log

      - name: Upload harness logs
        if: failure()
        uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1
        with:
          name: nightly-harness-logs-${{ steps.profile.outputs.profile }}
          path: |
            /var/tmp/nightly-harness.log
            /var/tmp/native-ab-secure-boot-test.*/*.log
          retention-days: 14
          if-no-files-found: ignore
```

- [ ] **Step 2: Check harness workdir survival on failure**

Run: `grep -n 'trap\|rm -rf "\$WORK_DIR"' test/native-ab-secure-boot-test.sh | head`
If the harness deletes `$WORK_DIR` on failure (so the `*.log` glob above would find nothing), add `KEEP_VM=1` to the harness invocation ONLY IF `grep -n KEEP_VM test/native-ab-secure-boot-test.sh` confirms it preserves the workdir without blocking script exit; otherwise rely on the tee'd `nightly-harness.log` alone and delete the glob line. Record which way it went in the commit message.

- [ ] **Step 3: Lint**

Run: `actionlint .github/workflows/native-nightly.yml`
Expected: no output.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/native-nightly.yml
git commit -m "feat: nightly deep secure-boot validation workflow (ephemeral keys, no secrets)"
```

- [ ] **Step 5: Post-merge verification note**

The nightly cannot be fully proven pre-merge (scheduled workflows run from the default branch). After merge, trigger it once via `gh workflow run native-nightly.yml -f profile=cayo-ab` and watch it complete. Record this as a follow-up in the PR description, not a blocker for this task.

---

### Task 6: Documentation

**Files:**
- Modify: `CLAUDE.md` (CI/CD section)
- Modify: `yeti/ci-cd.md`
- Modify: `yeti/testing.md`

- [ ] **Step 1: CLAUDE.md CI/CD section**

In the `## CI/CD` list, extend the `build-native-images.yml` bullet with (adapt to surrounding prose style):

> `test-public-origin`/`test-public-origin-iso` additionally BOOT the candidate bytes in QEMU/KVM before the verified marker is earned (`test/native-boot-smoke-test.sh`: multi-user.target reached, `systemctl is-system-running` = running, os-release identity match, clean poweroff; `test/native-iso-boot-smoke-test.sh`: serial login prompt). An unbootable image can no longer be promoted. SSH access is seeded via the /etc-overlay upperdir on var (the `snosi-install` `seed_var()` path) — root/verity bytes boot pristine; Secure Boot is NOT enforced in this tier (MOK never enrolled in the throwaway varstore) — SB/TPM fidelity belongs to the nightly.

Add a new bullet:

> `native-nightly.yml` - Nightly (cron + dispatch) deep secure-chain validation: runs `test/native-ab-secure-boot-test.sh` default mode on a hosted runner with KVM+swtpm+virt-firmware, rotating profiles by day of week (Sun snowfield-ab, Tue/Thu/Sat cayo-ab, else snow-ab). Uses NO secrets/environments — all key material is ephemeral per-run (PCR key RSA-2048 per contract §7). Non-blocking: promotion gating stays with the Tier 1 smoke test. Design: `docs/plans/2026-07-17-native-boot-validation-design.md`.

- [ ] **Step 2: yeti/ci-cd.md and yeti/testing.md**

Read both files first; add matching sections in each file's existing style: ci-cd.md gets the pipeline-shape change (smoke gate position between verify-remote and the marker, the nightly workflow's zero-secret property); testing.md gets entries for the two new scripts (usage, what they assert, the local-proof invocations from Tasks 2-3, and the var-partition SSH-seeding mechanism with the /root-is-sealed rationale).

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md yeti/ci-cd.md yeti/testing.md
git commit -m "docs: record boot smoke gate and nightly deep validation"
```

---

### Task 7: Final verification pass and PR

- [ ] **Step 1: Full lint sweep**

Run: `shellcheck test/native-boot-smoke-test.sh test/native-iso-boot-smoke-test.sh && actionlint .github/workflows/build-native-images.yml .github/workflows/native-nightly.yml`
Expected: no output.

- [ ] **Step 2: Repo static gates that could plausibly notice these changes**

Run: `./test/native-ab-contracts-test.sh && ./check-native-publication-guard.sh && ./check-runtime-etc-guard.sh`
(Use the exact invocations `validate.yml` uses — read it first if these paths differ.)
Expected: all pass — the changes touch no contracts, but proving it is cheap.

- [ ] **Step 3: Review the diff for accidental damage**

Run: `git diff main --stat`
Expected: only the two new test scripts, the two workflow files, the design doc, the plan doc, CLAUDE.md, and the two yeti files.

- [ ] **Step 4: Create PR**

Confirm target branch with the user (repo default is `main`), then:

```bash
git push -u origin feat/boot-validation-tiers
gh pr create --base main --title "Boot validation for native A/B images: smoke gate + nightly deep harness" --body "$(cat <<'EOF'
Implements docs/plans/2026-07-17-native-boot-validation-design.md.

- test/native-boot-smoke-test.sh: boots the published candidate disk bytes in QEMU/KVM, asserts multi-user.target / no failed units / os-release identity / clean poweroff. Proven locally positive + negative (corrupted root fails with preserved console log).
- test/native-iso-boot-smoke-test.sh: boots the published installer ISO to a serial login prompt.
- build-native-images.yml: test-public-origin(-iso) now run the smoke tests; the verified marker (promotion gate) requires a successful boot. Promote jobs untouched.
- native-nightly.yml: scheduled deep secure-chain validation via test/native-ab-secure-boot-test.sh with per-run ephemeral keys and zero secrets.

Follow-up after merge: dispatch native-nightly.yml once to prove it end to end.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Self-review notes (already applied)

- Spec coverage: Tier 1 product smoke (Tasks 1-2, 4), Tier 1b ISO smoke (Tasks 3-4), Tier 2 nightly (Task 5), Tier 3 is deferred-by-design (no task; documented in the spec), "testing the tests" negative proof (Task 2 Step 4, Task 3 Step 4), docs requirement (Task 6).
- The spec's open question (verify-remote.sh cleanup) is resolved: it deletes its downloads, so both scripts fetch the blob themselves — reflected in the script code and CI wiring.
- The spec's `roothome/.ssh` injection idea was corrected during research: on production native images /root is on the sealed root; injection goes through the /etc overlay upperdir (`snosi-install` `seed_var()` parity). The design doc's Tier 1 step 2 is superseded on this one point by this plan.
