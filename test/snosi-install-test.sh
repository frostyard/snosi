#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Static, non-root-safe regression test for shared/native-installer/tree/
# usr/libexec/snosi-install (Task 8.2, docs/plans/2026-07-14-bootc-native-
# ab-coexistence-plan.md "First-Round CLI Installer"). Covers the pure logic
# via fixtures, per that task's brief:
#
#   - index parsing/verification (good/tampered signed SHA256SUMS)
#   - disk-refusal filters (fixture `lsblk -b -J -O` JSON)
#   - name derivation (minimum_disk_bytes, human_bytes)
#   - argument validation matrix (every --non-interactive flag, missing ->
#     a specific, clear error)
#   - streamed-verify mismatch handling (small fixture "disk image")
#   - restage-mok argument handling
#
# What this does NOT cover: actually writing to a disk, LUKS/TPM enrollment,
# or MOK/mokutil against real EFI variables -- that needs a full product
# build and a real (or QEMU) install target, which is Task 8.3, not this
# fast per-PR check. Internal pure-logic functions are exercised by
# `source`ing the installer inside a throwaway `bash -c` PER CALL (test/lib/
# snosi-install-test-helpers.sh) so a function's `die` (a plain `exit 1`)
# only ends that one subprocess, never this test harness; argument-handling
# and end-to-end-ish behavior is exercised by invoking the real script as a
# subprocess, exactly as a user would.
#
# Usage: ./test/snosi-install-test.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$ROOT_DIR/shared/native-installer/tree/usr/libexec/snosi-install"
HELPERS="$ROOT_DIR/test/lib/snosi-install-test-helpers.sh"

WORK_DIR=""
HTTP_PID=""
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

cleanup() {
    [[ -z "$HTTP_PID" ]] || kill "$HTTP_PID" 2>/dev/null || true
    [[ -z "$WORK_DIR" || ! -d "$WORK_DIR" ]] || rm -rf "$WORK_DIR"
}
trap cleanup EXIT

for command in jq gpg gpgv curl xz openssl python3 sha256sum bash; do
    command -v "$command" >/dev/null || { echo "Error: required command not found: $command" >&2; exit 1; }
done
[[ -x "$INSTALLER" ]] || { echo "Error: installer not found or not executable: $INSTALLER" >&2; exit 1; }

WORK_DIR="$(mktemp -d /var/tmp/snosi-install-test.XXXXXX)"

# call_fn fn_name args... -- runs one internal function of the installer, in
# its own fresh bash process (see header comment for why). stdout is the
# function's own output; a `die` inside it just makes this call exit
# non-zero, exactly like any other subprocess.
call_fn() {
    local fn="$1"
    shift
    bash -c '
        set -euo pipefail
        source "$1"; shift
        source "$1"; shift
        fn="$1"; shift
        "$fn" "$@"
    ' _ "$INSTALLER" "$HELPERS" "$fn" "$@"
}

# ===========================================================================
# 1. --help / usage
# ===========================================================================
echo "=== --help / usage ==="

set +e
help_out="$("$INSTALLER" --help 2>&1)"
help_rc=$?
set -e
assert_eq "--help exits with usage code 2" "$help_rc" "2"
assert_contains "--help mentions --restage-mok" "$help_out" "--restage-mok"
assert_contains "--help mentions --non-interactive" "$help_out" "--non-interactive"

set +e
noargs_out="$("$INSTALLER" --bogus-flag 2>&1)"
noargs_rc=$?
set -e
assert_eq "unknown flag exits with usage code 2" "$noargs_rc" "2"
assert_contains "unknown flag error names it" "$noargs_out" "unknown option"

# ===========================================================================
# 2. Argument validation matrix (--non-interactive), unprivileged: every
#    check below happens before need_root() in main(), so none of this
#    needs root.
# ===========================================================================
echo "=== argument validation matrix ==="

BASE_ARGS=(--non-interactive --product cayo-ab --disk /dev/fake-disk-for-test
    --confirm fake-serial --recovery-key-file "$WORK_DIR/recovery.key"
    --acknowledge-recovery-saved --mok-password-file "$WORK_DIR/mok-password.txt")
echo hunter2 >"$WORK_DIR/mok-password.txt"

run_installer() { # args... -- sets RUN_OUT, RUN_RC
    set +e
    RUN_OUT="$("$INSTALLER" "$@" 2>&1)"
    RUN_RC=$?
    set -e
}

without_flag() { # flag_to_drop [value_follows=1] args...
    local drop="$1" has_value="$2"
    shift 2
    local -a out=()
    local i=0 n=${#BASE_ARGS[@]}
    while [[ $i -lt $n ]]; do
        if [[ "${BASE_ARGS[$i]}" == "$drop" ]]; then
            i=$((i + 1))
            [[ "$has_value" == 1 ]] && i=$((i + 1))
            continue
        fi
        out+=("${BASE_ARGS[$i]}")
        i=$((i + 1))
    done
    printf '%s\n' "${out[@]}"
}

mapfile -t ARGS_NO_PRODUCT < <(without_flag --product 1)
run_installer "${ARGS_NO_PRODUCT[@]}"
assert_true "missing --product: exits non-zero" bash -c "[[ $RUN_RC -ne 0 ]]"
assert_contains "missing --product: clear error" "$RUN_OUT" "requires --product"

mapfile -t ARGS_NO_DISK < <(without_flag --disk 1)
run_installer "${ARGS_NO_DISK[@]}"
assert_true "missing --disk: exits non-zero" bash -c "[[ $RUN_RC -ne 0 ]]"
assert_contains "missing --disk: clear error" "$RUN_OUT" "requires --disk"

mapfile -t ARGS_NO_CONFIRM < <(without_flag --confirm 1)
run_installer "${ARGS_NO_CONFIRM[@]}"
assert_true "missing --confirm: exits non-zero" bash -c "[[ $RUN_RC -ne 0 ]]"
assert_contains "missing --confirm: clear error" "$RUN_OUT" "requires --confirm"

mapfile -t ARGS_NO_RECOVERY_FILE < <(without_flag --recovery-key-file 1)
run_installer "${ARGS_NO_RECOVERY_FILE[@]}"
assert_true "missing --recovery-key-file (encrypt default): exits non-zero" bash -c "[[ $RUN_RC -ne 0 ]]"
assert_contains "missing --recovery-key-file: clear error" "$RUN_OUT" "requires --recovery-key-file"

mapfile -t ARGS_NO_ACK < <(without_flag --acknowledge-recovery-saved 0)
run_installer "${ARGS_NO_ACK[@]}"
assert_true "missing --acknowledge-recovery-saved: exits non-zero" bash -c "[[ $RUN_RC -ne 0 ]]"
assert_contains "missing --acknowledge-recovery-saved: clear error" "$RUN_OUT" "requires --acknowledge-recovery-saved"

mapfile -t ARGS_NO_MOK < <(without_flag --mok-password-file 1)
run_installer "${ARGS_NO_MOK[@]}"
assert_true "missing --mok-password-file (no --skip-mok): exits non-zero" bash -c "[[ $RUN_RC -ne 0 ]]"
assert_contains "missing --mok-password-file: clear error" "$RUN_OUT" "requires --mok-password-file"

# --insecure-raw-var must NOT demand recovery-key-file/ack.
mapfile -t ARGS_RAW_VAR < <(without_flag --recovery-key-file 1)
run_installer "${ARGS_RAW_VAR[@]}" --insecure-raw-var
assert_not_contains "--insecure-raw-var: does not require --recovery-key-file" "$RUN_OUT" "requires --recovery-key-file"
assert_not_contains "--insecure-raw-var: does not require --acknowledge-recovery-saved" "$RUN_OUT" "requires --acknowledge-recovery-saved"
assert_contains "--insecure-raw-var: proceeds past validation to the root check" "$RUN_OUT" "must run as root"

# --skip-mok must NOT demand --mok-password-file.
mapfile -t ARGS_SKIP_MOK < <(without_flag --mok-password-file 1)
run_installer "${ARGS_SKIP_MOK[@]}" --skip-mok
assert_not_contains "--skip-mok: does not require --mok-password-file" "$RUN_OUT" "requires --mok-password-file"
assert_contains "--skip-mok: proceeds past validation to the root check" "$RUN_OUT" "must run as root"

run_installer "${BASE_ARGS[@]}"
assert_contains "fully-specified non-interactive args pass validation (reach root check)" "$RUN_OUT" "must run as root"

run_installer "${BASE_ARGS[@]}" --product bogus-product
assert_contains "invalid --product value is rejected" "$RUN_OUT" "must be one of"

# ===========================================================================
# 3. restage-mok argument handling
# ===========================================================================
echo "=== restage-mok argument handling ==="

run_installer --restage-mok --non-interactive
assert_true "restage-mok non-interactive without --mok-password-file: exits non-zero" bash -c "[[ $RUN_RC -ne 0 ]]"
assert_contains "restage-mok: requires --mok-password-file" "$RUN_OUT" "requires --mok-password-file"

run_installer --restage-mok --non-interactive --mok-password-file "$WORK_DIR/does-not-exist.txt"
assert_true "restage-mok with missing password file: exits non-zero" bash -c "[[ $RUN_RC -ne 0 ]]"
assert_contains "restage-mok: missing password file error" "$RUN_OUT" "not found"

: >"$WORK_DIR/empty-mok-password.txt"
run_installer --restage-mok --non-interactive --mok-password-file "$WORK_DIR/empty-mok-password.txt"
assert_true "restage-mok with empty password file: exits non-zero" bash -c "[[ $RUN_RC -ne 0 ]]"
assert_contains "restage-mok: empty password file error" "$RUN_OUT" "is empty"

run_installer --restage-mok --non-interactive --mok-password-file "$WORK_DIR/mok-password.txt"
assert_contains "restage-mok with a valid password file proceeds to the root check" "$RUN_OUT" "must run as root"

# ===========================================================================
# 4. Name derivation: minimum_disk_bytes, human_bytes
# ===========================================================================
echo "=== name derivation ==="

assert_eq "minimum_disk_bytes cayo" "$(call_fn minimum_disk_bytes cayo)" "16642998272"
assert_eq "minimum_disk_bytes snow" "$(call_fn minimum_disk_bytes snow)" "23085449216"
assert_eq "minimum_disk_bytes snowfield" "$(call_fn minimum_disk_bytes snowfield)" "23085449216"
assert_false "minimum_disk_bytes rejects an unknown product" call_fn minimum_disk_bytes bogus

assert_eq "human_bytes formats GiB" "$(call_fn human_bytes 16642998272)" "15.5 GiB"
assert_eq "human_bytes formats bytes" "$(call_fn human_bytes 512)" "512.0 B"

# ===========================================================================
# 5. confirm_typed_matches
# ===========================================================================
echo "=== confirm_typed_matches ==="

assert_true "typed confirmation matches disk path" call_fn confirm_typed_matches /dev/sdz /dev/sdz SERIAL123
assert_true "typed confirmation matches serial" call_fn confirm_typed_matches SERIAL123 /dev/sdz SERIAL123
assert_false "typed confirmation rejects an unrelated value" call_fn confirm_typed_matches nope /dev/sdz SERIAL123
assert_false "typed confirmation rejects empty serial match against empty typed value" call_fn confirm_typed_matches "" /dev/sdz ""

# ===========================================================================
# 6. Disk-refusal filters (fixture `lsblk -b -J -O` JSON)
# ===========================================================================
echo "=== disk-refusal filters ==="

FIXTURE_LSBLK="$WORK_DIR/lsblk.json"
cat >"$FIXTURE_LSBLK" <<'EOF'
{
  "blockdevices": [
    {
      "name": "sda", "path": "/dev/sda", "type": "disk",
      "model": "SelfBootDisk", "serial": "SELFBOOT01",
      "size": 32000000000, "tran": "nvme", "mountpoint": null, "mountpoints": [null],
      "children": [
        {"name": "sda1", "path": "/dev/sda1", "type": "part", "fstype": "vfat",
         "mountpoint": "/boot", "mountpoints": ["/boot"]}
      ]
    },
    {
      "name": "sdb", "path": "/dev/sdb", "type": "disk",
      "model": "MountedDisk", "serial": "MOUNTED01",
      "size": 32000000000, "tran": "sata", "mountpoint": null, "mountpoints": [null],
      "children": [
        {"name": "sdb1", "path": "/dev/sdb1", "type": "part", "fstype": "ext4",
         "mountpoint": "/mnt/data", "mountpoints": ["/mnt/data"]}
      ]
    },
    {
      "name": "sdc", "path": "/dev/sdc", "type": "disk",
      "model": "RaidMemberDisk", "serial": "RAID01",
      "size": 32000000000, "tran": "sata", "mountpoint": null, "mountpoints": [null],
      "children": [
        {"name": "sdc1", "path": "/dev/sdc1", "type": "part", "fstype": "linux_raid_member",
         "mountpoint": null, "mountpoints": [null]}
      ]
    },
    {
      "name": "sdd", "path": "/dev/sdd", "type": "disk",
      "model": "TinyDisk", "serial": "TINY01",
      "size": 1000000000, "tran": "usb", "mountpoint": null, "mountpoints": [null]
    },
    {
      "name": "sde", "path": "/dev/sde", "type": "disk",
      "model": "GoodDisk", "serial": "GOOD01",
      "size": 32000000000, "tran": "sata", "mountpoint": null, "mountpoints": [null]
    },
    {
      "name": "sdf", "path": "/dev/sdf", "type": "disk",
      "model": "GoodDiskTwo", "serial": "GOOD01",
      "size": 32000000000, "tran": "sata", "mountpoint": null, "mountpoints": [null]
    },
    {
      "name": "loop0", "path": "/dev/loop0", "type": "loop",
      "model": null, "serial": null, "size": 2000000000, "tran": null
    }
  ]
}
EOF

export SNOSI_INSTALL_LSBLK_JSON="$FIXTURE_LSBLK"

resolved="$(call_fn t_resolve_target_disk /dev/sda 16642998272 /dev/sda 0)"
assert_contains "self-boot-medium disk is refused" "$resolved" "installer's own boot medium"

resolved="$(call_fn t_resolve_target_disk /dev/sdb 16642998272 /dev/sda 0)"
assert_contains "mounted disk is refused" "$resolved" "is mounted"

resolved="$(call_fn t_resolve_target_disk /dev/sdc 16642998272 /dev/sda 0)"
assert_contains "RAID-member disk is refused" "$resolved" "RAID array or LVM"

resolved="$(call_fn t_resolve_target_disk /dev/sdd 16642998272 /dev/sda 0)"
assert_contains "undersized disk is refused" "$resolved" "is too small"

resolved="$(call_fn t_resolve_target_disk /dev/sde 16642998272 /dev/sda 0)"
assert_eq "clean disk has no refusal reason" "${resolved##*|}" ""

assert_false "ambiguous serial (two disks share GOOD01) is rejected" \
    call_fn t_resolve_target_disk GOOD01 16642998272 /dev/sda 0
resolved="$(call_fn t_resolve_target_disk GOOD01 16642998272 /dev/sda 0 2>&1 || true)"
assert_contains "ambiguous selector error names the count" "$resolved" "ambiguous disk selector"

assert_false "an unmatched selector is rejected" \
    call_fn t_resolve_target_disk /dev/does-not-exist 16642998272 /dev/sda 0

# loop device (type != disk) is never a candidate.
assert_false "loop device is not resolvable as an install target" \
    call_fn t_resolve_target_disk /dev/loop0 16642998272 /dev/sda 0

# --allow-file: a regular file target bypasses lsblk entirely.
fixture_file="$WORK_DIR/fake-disk.img"
truncate -s 4096 "$fixture_file"
resolved="$(call_fn t_resolve_target_disk "$fixture_file" 0 /dev/sda 1)"
assert_contains "--allow-file target resolves without touching lsblk" "$resolved" "$fixture_file"

unset SNOSI_INSTALL_LSBLK_JSON

# ===========================================================================
# 7. Index parsing/verification (good/tampered signed SHA256SUMS)
# ===========================================================================
echo "=== index parsing/verification ==="

GNUPGHOME_DIR="$WORK_DIR/gnupg"
mkdir -p "$GNUPGHOME_DIR"
chmod 700 "$GNUPGHOME_DIR"
GNUPGHOME="$GNUPGHOME_DIR" gpg --batch --passphrase '' --quick-generate-key \
    'snosi-install-test EPHEMERAL key <ephemeral@invalid>' ed25519 sign 0 >/dev/null 2>&1
TEST_PUBRING="$WORK_DIR/pubring.gpg"
GNUPGHOME="$GNUPGHOME_DIR" gpg --batch --export -o "$TEST_PUBRING"

ORIGIN_ROOT="$WORK_DIR/origin"
PRODUCT_DIR="$ORIGIN_ROOT/os/native/v1/cayo/x86-64"
mkdir -p "$PRODUCT_DIR"
printf 'fake disk payload for index test\n' >"$PRODUCT_DIR/cayo-ab_20260101000000.disk.raw.xz"
printf '{"config":{"architecture":"x86-64"}}\n' >"$PRODUCT_DIR/cayo-ab_20260101000000.manifest.json"
printf 'fake newer disk payload\n' >"$PRODUCT_DIR/cayo-ab_20260201000000.disk.raw.xz"
printf '{"config":{"architecture":"x86-64"}}\n' >"$PRODUCT_DIR/cayo-ab_20260201000000.manifest.json"
(
    cd "$PRODUCT_DIR"
    : >SHA256SUMS
    for f in cayo-ab_20260101000000.disk.raw.xz cayo-ab_20260101000000.manifest.json \
             cayo-ab_20260201000000.disk.raw.xz cayo-ab_20260201000000.manifest.json; do
        sha256sum "$f" >>SHA256SUMS
    done
)
GNUPGHOME="$GNUPGHOME_DIR" gpg --batch --yes --detach-sign \
    -o "$PRODUCT_DIR/SHA256SUMS.gpg" "$PRODUCT_DIR/SHA256SUMS"

PORT=18734
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$ORIGIN_ROOT" >"$WORK_DIR/http.log" 2>&1 &
HTTP_PID=$!
for _ in $(seq 1 50); do
    curl -fsS "http://127.0.0.1:$PORT/" >/dev/null 2>&1 && break
    sleep 0.1
done

FETCH_WORKDIR="$WORK_DIR/fetch1"
mkdir -p "$FETCH_WORKDIR"
export SNOSI_INSTALL_PUBRING="$TEST_PUBRING"
fetch_result="$(call_fn t_fetch_verified_index "http://127.0.0.1:$PORT" cayo-ab "$FETCH_WORKDIR")"
index_file="${fetch_result%%|*}"
index_base_url="${fetch_result#*|}"
assert_true "fetch_verified_index: good signature produces an index file" test -s "$index_file"
assert_eq "fetch_verified_index: base URL is the product's os/native/v1 path" \
    "$index_base_url" "http://127.0.0.1:$PORT/os/native/v1/cayo/x86-64"

latest="$(call_fn latest_channel_version "$index_file" cayo-ab)"
assert_eq "latest_channel_version picks the numeric MAXIMUM, not first-listed" "$latest" "20260201000000"

expected_hash="$(awk '$2=="cayo-ab_20260201000000.disk.raw.xz"{print $1}' "$index_file")"
got_hash="$(call_fn index_object_sha256 "$index_file" cayo-ab_20260201000000.disk.raw.xz)"
assert_eq "index_object_sha256 returns the correct hash" "$got_hash" "$expected_hash"
assert_eq "index_object_sha256 is empty for an unknown name" \
    "$(call_fn index_object_sha256 "$index_file" nonexistent.disk.raw.xz)" ""

# Tampered signature: flip a byte in SHA256SUMS.gpg on the server.
cp "$PRODUCT_DIR/SHA256SUMS.gpg" "$WORK_DIR/sig.bak"
printf 'X' | dd of="$PRODUCT_DIR/SHA256SUMS.gpg" bs=1 seek=0 count=1 conv=notrunc status=none
assert_false "fetch_verified_index rejects a tampered signature" \
    call_fn t_fetch_verified_index "http://127.0.0.1:$PORT" cayo-ab "$WORK_DIR/fetch2"
cp "$WORK_DIR/sig.bak" "$PRODUCT_DIR/SHA256SUMS.gpg"

# Tampered manifest content (signature no longer matches the bytes).
cp "$PRODUCT_DIR/SHA256SUMS" "$WORK_DIR/sums.bak"
printf '\n' >>"$PRODUCT_DIR/SHA256SUMS"
assert_false "fetch_verified_index rejects a tampered SHA256SUMS body" \
    call_fn t_fetch_verified_index "http://127.0.0.1:$PORT" cayo-ab "$WORK_DIR/fetch3"
cp "$WORK_DIR/sums.bak" "$PRODUCT_DIR/SHA256SUMS"

# Wrong pubring (untrusted key) must also fail closed.
OTHER_GNUPGHOME="$WORK_DIR/gnupg-other"
mkdir -p "$OTHER_GNUPGHOME"
chmod 700 "$OTHER_GNUPGHOME"
GNUPGHOME="$OTHER_GNUPGHOME" gpg --batch --passphrase '' --quick-generate-key \
    'snosi-install-test WRONG key <wrong@invalid>' ed25519 sign 0 >/dev/null 2>&1
WRONG_PUBRING="$WORK_DIR/wrong-pubring.gpg"
GNUPGHOME="$OTHER_GNUPGHOME" gpg --batch --export -o "$WRONG_PUBRING"
SNOSI_INSTALL_PUBRING="$WRONG_PUBRING" bash -c '
    set -euo pipefail
    source "$1"; source "$2"
    t_fetch_verified_index "$3" cayo-ab "$4"
' _ "$INSTALLER" "$HELPERS" "http://127.0.0.1:$PORT" "$WORK_DIR/fetch4" >/dev/null 2>&1 \
    && fail "fetch_verified_index rejects a signature from an untrusted key" \
    || pass "fetch_verified_index rejects a signature from an untrusted key"

unset SNOSI_INSTALL_PUBRING

# ===========================================================================
# 8. Streamed-verify mismatch handling (small fixture "disk image")
# ===========================================================================
echo "=== streamed-verify mismatch handling ==="

PLAIN="$WORK_DIR/plain-payload.bin"
head -c 65536 /dev/urandom >"$PLAIN"
COMPRESSED="$PRODUCT_DIR/tiny.raw.xz"
xz -T0 -c "$PLAIN" >"$COMPRESSED"
GOOD_SHA256="$(sha256sum "$COMPRESSED" | cut -d' ' -f1)"

TARGET_OK="$WORK_DIR/target-ok.raw"
: >"$TARGET_OK"
stream_ok_bytes="$(call_fn t_stream_download_verify "http://127.0.0.1:$PORT/os/native/v1/cayo/x86-64/tiny.raw.xz" "$GOOD_SHA256" "$TARGET_OK")"
assert_true "stream_download_verify: matching checksum succeeds" test -n "$stream_ok_bytes"
assert_eq "stream_download_verify: target has the decompressed bytes" \
    "$(sha256sum "$TARGET_OK" | cut -d' ' -f1)" "$(sha256sum "$PLAIN" | cut -d' ' -f1)"
assert_eq "stream_download_verify: reports the true decompressed byte count (not the target's own size)" \
    "$stream_ok_bytes" "$(stat -c %s "$PLAIN")"

TARGET_BAD="$WORK_DIR/target-bad.raw"
printf 'PRE-EXISTING-DATA-THAT-MUST-NOT-SURVIVE-A-MISMATCH' >"$TARGET_BAD"
BAD_SHA256="0000000000000000000000000000000000000000000000000000000000000000"
BAD_SHA256="${BAD_SHA256:0:64}"
assert_false "stream_download_verify: wrong checksum fails" \
    call_fn stream_download_verify "http://127.0.0.1:$PORT/os/native/v1/cayo/x86-64/tiny.raw.xz" "$BAD_SHA256" "$TARGET_BAD"
assert_eq "stream_download_verify: mismatch wipes the target (regular-file mode truncates)" \
    "$(stat -c %s "$TARGET_BAD")" "0"

TARGET_404="$WORK_DIR/target-404.raw"
printf 'PRE-EXISTING-DATA-THAT-MUST-NOT-SURVIVE-A-FAILED-FETCH' >"$TARGET_404"
assert_false "stream_download_verify: a failed fetch (404) fails" \
    call_fn stream_download_verify "http://127.0.0.1:$PORT/os/native/v1/cayo/x86-64/does-not-exist.xz" "$GOOD_SHA256" "$TARGET_404"
assert_eq "stream_download_verify: failed-fetch also wipes the target" \
    "$(stat -c %s "$TARGET_404")" "0"

print_summary
