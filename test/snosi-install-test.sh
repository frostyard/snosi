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

# Root-gated sections (real loop devices: ISO9660 own-boot-medium detection,
# relocate_and_grow_var) run only when root or passwordless sudo is
# available, matching the HAVE_ROOT/SUDO pattern already used by
# test/snosi-etc-diff-test.sh's own root-gated case -- the bulk of this test
# file (header: "non-root-safe") deliberately does NOT run under sudo as a
# whole, since several existing assertions rely on need_root() actually
# firing ("must run as root") when this script itself is not root.
HAVE_ROOT=0
SUDO=()
if [[ $EUID -eq 0 ]]; then
    HAVE_ROOT=1
elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    HAVE_ROOT=1
    SUDO=(sudo -n)
fi
ROOT_LOOP_DEVICES=()

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
    local ld
    for ld in "${ROOT_LOOP_DEVICES[@]}"; do
        [[ -z "$ld" ]] || "${SUDO[@]}" losetup -d "$ld" 2>/dev/null || true
    done
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

# call_fn_root [ENV=val ...] -- fn_name args... -- like call_fn, but runs
# under "${SUDO[@]}" for root-gated cases (real loop devices: blkid on a
# device node, sfdisk/mkfs.ext4/mount against it). Any leading NAME=value
# tokens are passed to `env` INSIDE the sudo'd command line (not exported
# from this already-running, non-root shell), so a fixture env var like
# SNOSI_INSTALL_LSBLK_JSON reaches the elevated subprocess regardless of the
# host's sudoers env_keep/env_reset policy.
call_fn_root() {
    local -a env_args=()
    while [[ "$1" == *=* ]]; do
        env_args+=("$1")
        shift
    done
    local fn="$1"
    shift
    "${SUDO[@]}" env "${env_args[@]}" bash -c '
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
chmod 600 "$WORK_DIR/mok-password.txt"

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

# --- first-user flags ---
echo hunter2 >"$WORK_DIR/user-password.txt"
chmod 600 "$WORK_DIR/user-password.txt"

run_installer "${BASE_ARGS[@]}" --username bjk
assert_true "--username without --user-password-file (non-interactive): exits non-zero" bash -c "[[ $RUN_RC -ne 0 ]]"
assert_contains "--username without password file: clear error" "$RUN_OUT" "requires --user-password-file"

run_installer "${BASE_ARGS[@]}" --user-password-file "$WORK_DIR/user-password.txt"
assert_true "--user-password-file without --username: exits non-zero" bash -c "[[ $RUN_RC -ne 0 ]]"
assert_contains "--user-password-file without --username: clear error" "$RUN_OUT" "requires --username"

run_installer "${BASE_ARGS[@]}" --username bjk --user-password-file "$WORK_DIR/user-password.txt" --no-create-user
assert_true "--username with --no-create-user: exits non-zero" bash -c "[[ $RUN_RC -ne 0 ]]"
assert_contains "--username with --no-create-user: clear error" "$RUN_OUT" "conflicts with --no-create-user"

run_installer "${BASE_ARGS[@]}" --username 'Bad.User' --user-password-file "$WORK_DIR/user-password.txt"
assert_true "invalid username: exits non-zero" bash -c "[[ $RUN_RC -ne 0 ]]"
assert_contains "invalid username: clear error" "$RUN_OUT" "invalid username"

run_installer "${BASE_ARGS[@]}"
assert_contains "non-interactive without --username warns about missing user" "$RUN_OUT" "NO user account"

run_installer "${BASE_ARGS[@]}" --no-create-user
assert_not_contains "--no-create-user silences the missing-user warning" "$RUN_OUT" "NO user account"

chmod 644 "$WORK_DIR/user-password.txt"
run_installer "${BASE_ARGS[@]}" --username bjk --user-password-file "$WORK_DIR/user-password.txt"
assert_true "world-readable --user-password-file: exits non-zero" bash -c "[[ $RUN_RC -ne 0 ]]"
assert_contains "world-readable --user-password-file: refused with chmod hint" "$RUN_OUT" "chmod 600"
chmod 600 "$WORK_DIR/user-password.txt"

run_installer "${BASE_ARGS[@]}" --username bjk --user-password-file "$WORK_DIR/user-password.txt"
assert_contains "valid first-user args pass validation (reach root check)" "$RUN_OUT" "must run as root"

# --- system settings + first-boot seed flags ---
run_installer "${BASE_ARGS[@]}" --hostname 'bad host!'
assert_contains "invalid --hostname rejected" "$RUN_OUT" "invalid --hostname"

run_installer "${BASE_ARGS[@]}" --locale ';rm -rf /'
assert_contains "invalid --locale rejected" "$RUN_OUT" "invalid --locale"

run_installer "${BASE_ARGS[@]}" --timezone 'America/../../etc'
assert_contains "invalid --timezone rejected" "$RUN_OUT" "invalid --timezone"

run_installer "${BASE_ARGS[@]}" --keyboard 'us;evil'
assert_contains "invalid --keyboard rejected" "$RUN_OUT" "invalid --keyboard"

run_installer "${BASE_ARGS[@]}" --enable-feature 'bad/feature'
assert_contains "invalid --enable-feature rejected" "$RUN_OUT" "invalid --enable-feature"

run_installer "${BASE_ARGS[@]}" --core-flatpaks
assert_true "--core-flatpaks on cayo-ab: exits non-zero" bash -c "[[ $RUN_RC -ne 0 ]]"
assert_contains "--core-flatpaks on cayo-ab: clear error" "$RUN_OUT" "cayo-ab has no desktop"

run_installer "${BASE_ARGS[@]}" --hostname myhost --locale en_US.UTF-8 \
    --timezone America/New_York --keyboard 'us:intl' --enable-feature docker \
    --enable-feature tailscale
assert_contains "valid system-settings args pass validation (reach root check)" "$RUN_OUT" "must run as root"

# --- GUI contract query modes ---
run_installer --print-defaults
assert_eq "--print-defaults exits 0" "$RUN_RC" "0"
PD_JSON="$RUN_OUT"
assert_true "--print-defaults emits valid JSON" bash -c 'jq -e . >/dev/null <<<"$1"' _ "$PD_JSON"
assert_eq "--print-defaults proto is 1" "$(jq -r .proto <<<"$PD_JSON")" "1"
assert_eq "--print-defaults lists 3 products" "$(jq '.products | length' <<<"$PD_JSON")" "3"
assert_eq "--print-defaults: cayo core flatpaks not allowed" \
    "$(jq -r '.products[] | select(.name == "cayo-ab") | .core_flatpaks_allowed' <<<"$PD_JSON")" "false"
assert_eq "--print-defaults: snow core flatpaks default on" \
    "$(jq -r '.products[] | select(.name == "snow-ab") | .core_flatpaks_default' <<<"$PD_JSON")" "true"
assert_eq "--print-defaults: snow minimum disk matches minimum_disk_bytes" \
    "$(jq -r '.products[] | select(.name == "snow-ab") | .minimum_disk_bytes' <<<"$PD_JSON")" \
    "$(call_fn minimum_disk_bytes snow)"
assert_true "--print-defaults carries the username regex" \
    bash -c "jq -e '.regexes.username | length > 0' >/dev/null <<<'$PD_JSON'"

run_installer --list-disks-json
assert_true "--list-disks-json without --product: exits non-zero" bash -c "[[ $RUN_RC -ne 0 ]]"
assert_contains "--list-disks-json without --product: clear error" "$RUN_OUT" "requires --product"

run_installer --list-disks-json --product bogus
assert_contains "--list-disks-json bogus product rejected" "$RUN_OUT" "must be one of"

# Minimal lsblk fixture, scoped to this block (the main disk-refusal fixture
# is created later in this file).
cat >"$WORK_DIR/ldj-lsblk.json" <<'LDJEOF'
{"blockdevices": [
  {"name": "sdz", "path": "/dev/sdz", "type": "disk", "model": "TestDisk",
   "serial": "LDJ123", "size": 64000000000, "tran": "sata", "rm": false, "ro": false},
  {"name": "sdy", "path": "/dev/sdy", "type": "disk", "model": "TinyDisk",
   "serial": "LDJ124", "size": 2000000000, "tran": "usb", "rm": true, "ro": false}
]}
LDJEOF
set +e
LDJ_OUT="$(SNOSI_INSTALL_LSBLK_JSON="$WORK_DIR/ldj-lsblk.json" "$INSTALLER" --list-disks-json --product cayo-ab 2>/dev/null)"
LDJ_RC=$?
set -e
assert_eq "--list-disks-json (fixture) exits 0" "$LDJ_RC" "0"
assert_true "--list-disks-json emits a JSON array" bash -c 'jq -e "type == \"array\"" >/dev/null <<<"$1"' _ "$LDJ_OUT"
assert_eq "--list-disks-json lists both fixture disks" "$(jq length <<<"$LDJ_OUT")" "2"
assert_eq "--list-disks-json: big disk installable (refusal null)" \
    "$(jq -r '.[] | select(.path == "/dev/sdz") | .refusal' <<<"$LDJ_OUT")" "null"
assert_true "--list-disks-json: tiny disk carries a refusal reason" \
    bash -c 'jq -e ".[] | select(.path == \"/dev/sdy\") | .refusal | length > 0" >/dev/null <<<"$1"' _ "$LDJ_OUT"

run_installer --json-progress "${BASE_ARGS[@]}" --product bogus-product
assert_contains "--json-progress: die emits an error event" "$RUN_OUT" '{"event":"error"'

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
# 2b. append_group_member preserves the target file's mode + membership
#     (regression: mktemp+mv clobbered /etc/group to 0600, breaking all
#     non-root group-name resolution on a real install, 2026-07-17)
# ===========================================================================
echo "=== append_group_member mode preservation ==="
GRP_FIXTURE="$WORK_DIR/group-fixture"
cat >"$GRP_FIXTURE" <<'GRPEOF'
root:x:0:
sudo:x:27:existing
video:x:44:
GRPEOF
chmod 0644 "$GRP_FIXTURE"
call_fn append_group_member "$GRP_FIXTURE" sudo claude
call_fn append_group_member "$GRP_FIXTURE" sudo claude   # idempotent
call_fn append_group_member "$GRP_FIXTURE" video claude
call_fn append_group_member "$GRP_FIXTURE" nonexistent claude   # no-op
assert_eq "append_group_member preserves 0644 mode (not mktemp's 0600)" \
    "$(stat -c '%a' "$GRP_FIXTURE")" "644"
assert_eq "append_group_member added claude to sudo (kept existing member)" \
    "$(awk -F: '$1=="sudo"{print $NF}' "$GRP_FIXTURE")" "existing,claude"
assert_eq "append_group_member did not duplicate on re-add" \
    "$(grep -c 'claude,claude\|claude.*claude' "$GRP_FIXTURE" || true)" "0"
assert_eq "append_group_member added claude to an empty-member group" \
    "$(awk -F: '$1=="video"{print $NF}' "$GRP_FIXTURE")" "claude"
assert_eq "append_group_member is a no-op for an absent group" \
    "$(grep -c '^nonexistent' "$GRP_FIXTURE" || true)" "0"

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
chmod 600 "$WORK_DIR/empty-mok-password.txt"
run_installer --restage-mok --non-interactive --mok-password-file "$WORK_DIR/empty-mok-password.txt"
assert_true "restage-mok with empty password file: exits non-zero" bash -c "[[ $RUN_RC -ne 0 ]]"
assert_contains "restage-mok: empty password file error" "$RUN_OUT" "is empty"

run_installer --restage-mok --non-interactive --mok-password-file "$WORK_DIR/mok-password.txt"
assert_contains "restage-mok with a valid password file proceeds to the root check" "$RUN_OUT" "must run as root"

# --mok-password-file permission check: refuse group/world-readable secret
# input files (finding 4) -- checked before the file is ever read.
printf 'hunter2\n' >"$WORK_DIR/world-readable-mok-password.txt"
chmod 644 "$WORK_DIR/world-readable-mok-password.txt"
run_installer --restage-mok --non-interactive --mok-password-file "$WORK_DIR/world-readable-mok-password.txt"
assert_true "restage-mok with world-readable password file: exits non-zero" bash -c "[[ $RUN_RC -ne 0 ]]"
assert_contains "restage-mok: world-readable password file is refused" "$RUN_OUT" "group- or world-readable"

printf 'hunter2\n' >"$WORK_DIR/group-readable-mok-password.txt"
chmod 640 "$WORK_DIR/group-readable-mok-password.txt"
run_installer --restage-mok --non-interactive --mok-password-file "$WORK_DIR/group-readable-mok-password.txt"
assert_true "restage-mok with group-readable password file: exits non-zero" bash -c "[[ $RUN_RC -ne 0 ]]"
assert_contains "restage-mok: group-readable password file is refused" "$RUN_OUT" "group- or world-readable"

# check_secret_file_perms() itself, unit-tested directly. (main()'s own call
# site is deep past need_root()/network fetch/disk resolution, so it is not
# reachable from this non-root, no-network unit test the way restage_mok()'s
# call site is -- restage_mok() validates arguments, including this check,
# BEFORE need_root(), by the same design the header comment calls out for
# --mok-password-file existence/emptiness above.)
assert_true "check_secret_file_perms: accepts mode 600" \
    call_fn check_secret_file_perms "$WORK_DIR/mok-password.txt" "--mok-password-file"
assert_false "check_secret_file_perms: rejects mode 644" \
    call_fn check_secret_file_perms "$WORK_DIR/world-readable-mok-password.txt" "--mok-password-file"
assert_false "check_secret_file_perms: rejects mode 640" \
    call_fn check_secret_file_perms "$WORK_DIR/group-readable-mok-password.txt" "--mok-password-file"
assert_false "check_secret_file_perms: a missing file fails closed" \
    call_fn check_secret_file_perms "$WORK_DIR/does-not-exist.txt" "--mok-password-file"

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
# 6b. Own-boot-medium detection on an initramfs/ISO boot (finding 1): on the
#     real network-installer ISO, / is the kernel's own initramfs (no
#     block-device root at all -- see the installer's self_boot_device()
#     comment), so the OLD self_boot_device()-only refusal silently never
#     fired. disk_is_installer_medium() instead probes the CANDIDATE disk's
#     own ISO9660 LABEL against build-iso.sh's volid pattern
#     ("SNOSI_INSTALLER_<14-digit version>") via real blkid against a real
#     loop-mounted ISO9660 fixture -- root-gated (losetup + blkid need
#     device-node access), graceful skip otherwise.
# ===========================================================================
echo "=== own-boot-medium detection: real ISO9660 label (root-gated) ==="

if [[ $HAVE_ROOT -eq 0 ]]; then
    for t in "disk_is_installer_medium: matching ISO9660 label is detected" \
             "disk_is_installer_medium: non-matching ISO9660 label is NOT detected" \
             "disk_is_installer_medium: matching LABEL on a non-ISO9660 filesystem is NOT detected" \
             "disk_refusal_reason integration: real ISO9660-labeled candidate is refused as own boot medium"; do
        echo "ok - $t # SKIP no root/passwordless sudo available"
        PASS=$((PASS + 1))
    done
elif ! command -v xorriso >/dev/null 2>&1 && ! command -v mkisofs >/dev/null 2>&1 && ! command -v genisoimage >/dev/null 2>&1; then
    for t in "disk_is_installer_medium: matching ISO9660 label is detected" \
             "disk_is_installer_medium: non-matching ISO9660 label is NOT detected" \
             "disk_is_installer_medium: matching LABEL on a non-ISO9660 filesystem is NOT detected" \
             "disk_refusal_reason integration: real ISO9660-labeled candidate is refused as own boot medium"; do
        echo "ok - $t # SKIP no ISO9660 filesystem tool (xorriso/mkisofs/genisoimage) available"
        PASS=$((PASS + 1))
    done
else
    make_iso_fixture() { # out_path volid
        local out_path="$1" volid="$2" content_dir
        content_dir="$(mktemp -d /var/tmp/snosi-install-test-isocontent.XXXXXX)"
        printf 'snosi installer content marker\n' >"$content_dir/marker.txt"
        if command -v xorriso >/dev/null 2>&1; then
            xorriso -as mkisofs -quiet -volid "$volid" -o "$out_path" "$content_dir" >/dev/null 2>&1
        elif command -v mkisofs >/dev/null 2>&1; then
            mkisofs -quiet -volid "$volid" -o "$out_path" "$content_dir" >/dev/null 2>&1
        else
            genisoimage -quiet -volid "$volid" -o "$out_path" "$content_dir" >/dev/null 2>&1
        fi
        rm -rf "$content_dir"
    }

    # Matches build-iso.sh's own volid format exactly: "SNOSI_INSTALLER_" (16
    # chars) + a 14-digit version = 30 d-characters (well within the
    # ISO9660 32-char primary volume-identifier limit).
    MATCHING_VOLID="SNOSI_INSTALLER_20260714000000"
    ISO_MATCH="$WORK_DIR/iso-match.iso"
    make_iso_fixture "$ISO_MATCH" "$MATCHING_VOLID"
    ISO_MATCH_LOOP="$("${SUDO[@]}" losetup --find --show "$ISO_MATCH")"
    ROOT_LOOP_DEVICES+=("$ISO_MATCH_LOOP")

    real_label="$("${SUDO[@]}" blkid -o value -s LABEL "$ISO_MATCH_LOOP" 2>/dev/null || true)"
    assert_eq "ISO9660 fixture volid round-trips through blkid as LABEL" "$real_label" "$MATCHING_VOLID"

    assert_true "disk_is_installer_medium: matching ISO9660 label is detected" \
        call_fn_root disk_is_installer_medium "$ISO_MATCH_LOOP"

    # Integration: the same fixture, surfaced through disk_refusal_reason()
    # via resolve_target_disk()/t_resolve_target_disk(), exactly the path
    # main() actually drives (a loop device is lsblk `type: loop`, not
    # `disk`, so a fixture JSON is required to present it as a disk
    # candidate the way a real installer-medium USB/CD would be).
    FIXTURE_LSBLK_ISO="$WORK_DIR/lsblk-iso-medium.json"
    jq -n --arg path "$ISO_MATCH_LOOP" '{
        blockdevices: [{
            name: ($path | ltrimstr("/dev/")), path: $path, type: "disk",
            model: "IsoFixture", serial: "ISOFIX01",
            size: 999999999999, tran: "usb", mountpoint: null, mountpoints: [null]
        }]
    }' >"$FIXTURE_LSBLK_ISO"

    resolved_iso="$(call_fn_root "SNOSI_INSTALL_LSBLK_JSON=$FIXTURE_LSBLK_ISO" \
        t_resolve_target_disk "$ISO_MATCH_LOOP" 1 "" 0)"
    assert_contains "disk_refusal_reason integration: real ISO9660-labeled candidate is refused as own boot medium" \
        "$resolved_iso" "own boot medium"
    assert_contains "disk_refusal_reason integration: refusal names the ISO9660 volume" \
        "$resolved_iso" "ISO9660"

    # Negative: a genuine ISO9660 filesystem, but a label that does NOT
    # match the pattern (e.g. some unrelated live-media volume) must NOT be
    # refused as this installer's own medium.
    ISO_OTHER="$WORK_DIR/iso-other.iso"
    make_iso_fixture "$ISO_OTHER" "SOME_OTHER_LIVE_MEDIA"
    ISO_OTHER_LOOP="$("${SUDO[@]}" losetup --find --show "$ISO_OTHER")"
    ROOT_LOOP_DEVICES+=("$ISO_OTHER_LOOP")
    assert_false "disk_is_installer_medium: non-matching ISO9660 label is NOT detected" \
        call_fn_root disk_is_installer_medium "$ISO_OTHER_LOOP"

    # Negative: a non-ISO9660 filesystem must NOT be detected even if its
    # own label happens to collide -- the TYPE check must be enforced, not
    # just LABEL. (ext4 labels are capped at 16 bytes, so this uses a
    # shorter but still-plausible-looking prefix.)
    EXT4_COLLIDE="$WORK_DIR/ext4-label-collide.img"
    truncate -s 16M "$EXT4_COLLIDE"
    "${SUDO[@]}" mkfs.ext4 -F -L "SNOSI_INST" "$EXT4_COLLIDE" >/dev/null 2>&1
    EXT4_COLLIDE_LOOP="$("${SUDO[@]}" losetup --find --show "$EXT4_COLLIDE")"
    ROOT_LOOP_DEVICES+=("$EXT4_COLLIDE_LOOP")
    assert_false "disk_is_installer_medium: matching LABEL on a non-ISO9660 filesystem is NOT detected" \
        call_fn_root disk_is_installer_medium "$EXT4_COLLIDE_LOOP"
fi

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

# ===========================================================================
# 9. validate_disk_image_layout (finding 2's wiring target): plain-file GPT
#    fixtures (sfdisk script mode, no root/loop device needed -- same
#    technique test/native-publish-test.sh's build_fixture uses) exercising
#    the accept/reject shape this function is now called with as a
#    POST-WRITE check in main(), before relocate_and_grow_var().
# ===========================================================================
echo "=== validate_disk_image_layout ==="

make_gpt_fixture() { # out_path partition-scripts...
    local out_path="$1"
    shift
    truncate -s 8M "$out_path"
    {
        echo "label: gpt"
        echo "unit: sectors"
        echo ""
        printf '%s\n' "$@"
    } | sfdisk "$out_path" >/dev/null
}

VALID_LAYOUT="$WORK_DIR/valid-layout.img"
make_gpt_fixture "$VALID_LAYOUT" \
    'start=2048, size=2048, name="esp"' \
    'start=4096, size=2048, name="_empty"' \
    'start=6144, size=2048, name="_empty"' \
    'start=8192, size=2048, name="var"'
assert_true "validate_disk_image_layout: accepts esp/_empty/_empty/var" \
    call_fn validate_disk_image_layout "$VALID_LAYOUT"

MISSING_VAR="$WORK_DIR/missing-var-layout.img"
make_gpt_fixture "$MISSING_VAR" \
    'start=2048, size=2048, name="esp"' \
    'start=4096, size=2048, name="_empty"' \
    'start=6144, size=2048, name="_empty"'
assert_false "validate_disk_image_layout: rejects a missing var label" \
    call_fn validate_disk_image_layout "$MISSING_VAR"
missing_var_out="$(call_fn validate_disk_image_layout "$MISSING_VAR" 2>&1 || true)"
assert_contains "validate_disk_image_layout: missing-label error names it" "$missing_var_out" "missing required GPT label: var"

ONE_EMPTY="$WORK_DIR/one-empty-layout.img"
make_gpt_fixture "$ONE_EMPTY" \
    'start=2048, size=2048, name="esp"' \
    'start=4096, size=2048, name="_empty"' \
    'start=6144, size=2048, name="var"'
assert_false "validate_disk_image_layout: rejects only one empty A/B slot" \
    call_fn validate_disk_image_layout "$ONE_EMPTY"
one_empty_out="$(call_fn validate_disk_image_layout "$ONE_EMPTY" 2>&1 || true)"
assert_contains "validate_disk_image_layout: single-empty-slot error is specific" "$one_empty_out" "two empty A/B slots"

# ===========================================================================
# 10. relocate_and_grow_var real coverage (finding 3): a real loop-device GPT
#     fixture mirroring what stream_download_verify leaves behind -- a
#     downloaded image's GPT (dummy1/dummy2/var, var pre-formatted ext4,
#     matching a real image's shape) written onto a LARGER target device, so
#     the disk's own backup GPT header is stale (still at the smaller
#     image's end) exactly the way dd-ing a smaller image onto a bigger disk
#     leaves it. Asserts: sfdisk --verify goes from "1 error detected" (the
#     stale backup GPT) to clean, the var partition grows to fill the extra
#     capacity, and the ext4 filesystem is actually resized to match (not
#     just the partition table). Root-gated (losetup/mkfs.ext4/sfdisk
#     against a real block device), graceful skip otherwise.
# ===========================================================================
echo "=== relocate_and_grow_var (root-gated) ==="

if [[ $HAVE_ROOT -eq 0 ]]; then
    echo "ok - relocate_and_grow_var: relocates the backup GPT and grows var+ext4 # SKIP no root/passwordless sudo available"
    PASS=$((PASS + 1))
else
    RELOCATE_IMG="$WORK_DIR/relocate-fixture.img"
    IMAGE_BYTES=$((32 * 1024 * 1024))
    TARGET_BYTES=$((64 * 1024 * 1024))

    truncate -s "${IMAGE_BYTES}" "$RELOCATE_IMG"
    sfdisk "$RELOCATE_IMG" >/dev/null <<'SFDISK_EOF'
label: gpt
unit: sectors

start=2048, size=4096, name="dummy1"
start=6144, size=4096, name="dummy2"
start=10240, size=+, name="var"
SFDISK_EOF

    RELOCATE_LOOP="$("${SUDO[@]}" losetup --find --show --partscan "$RELOCATE_IMG")"
    ROOT_LOOP_DEVICES+=("$RELOCATE_LOOP")
    "${SUDO[@]}" udevadm settle
    RELOCATE_VAR_PART="${RELOCATE_LOOP}p3"
    "${SUDO[@]}" mkfs.ext4 -F -L var "$RELOCATE_VAR_PART" >/dev/null 2>&1

    var_size_before="$("${SUDO[@]}" blockdev --getsize64 "$RELOCATE_VAR_PART")"

    # Grow the backing file + loop device to simulate a smaller image
    # written onto a larger target disk (main()'s own target_size >
    # image_size case).
    truncate -s "${TARGET_BYTES}" "$RELOCATE_IMG"
    "${SUDO[@]}" losetup --set-capacity "$RELOCATE_LOOP"
    "${SUDO[@]}" blockdev --rereadpt "$RELOCATE_LOOP" 2>/dev/null || true
    "${SUDO[@]}" udevadm settle

    verify_before="$("${SUDO[@]}" sfdisk --verify "$RELOCATE_LOOP" 2>&1 || true)"
    assert_contains "relocate_and_grow_var fixture: stale backup GPT is detected before relocation" \
        "$verify_before" "backup GPT table is not on the end"

    # relocate_and_grow_var's own dependencies (sfdisk -N, resize2fs, e2fsck)
    # print their own progress information to stdout, same as they would
    # under main()'s real, interactive "Growing /var partition..." step --
    # the function's own var-partition-path output (its documented contract)
    # is always the LAST line.
    relocate_out="$(call_fn_root relocate_and_grow_var "$RELOCATE_LOOP" "$IMAGE_BYTES" "$TARGET_BYTES" | tail -n1)"
    assert_eq "relocate_and_grow_var: prints the var partition device" "$relocate_out" "$RELOCATE_VAR_PART"

    verify_after="$("${SUDO[@]}" sfdisk --verify "$RELOCATE_LOOP" 2>&1 || true)"
    assert_contains "relocate_and_grow_var: backup GPT is relocated (sfdisk --verify is clean)" \
        "$verify_after" "No errors detected"

    var_size_after="$("${SUDO[@]}" blockdev --getsize64 "$RELOCATE_VAR_PART")"
    assert_true "relocate_and_grow_var: var partition grew" \
        bash -c "[[ $var_size_after -gt $var_size_before ]]"

    fs_block_info="$("${SUDO[@]}" dumpe2fs -h "$RELOCATE_VAR_PART" 2>/dev/null || true)"
    fs_block_count="$(awk -F': *' '/^Block count:/{print $2}' <<<"$fs_block_info")"
    fs_block_size="$(awk -F': *' '/^Block size:/{print $2}' <<<"$fs_block_info")"
    fs_bytes=$(( fs_block_count * fs_block_size ))
    # The resized ext4 filesystem must be substantially larger than the
    # PRE-grow var size (proving resize2fs actually ran, not just the
    # partition table) and no bigger than the grown partition itself, within
    # a generous block-group-alignment tolerance (ext4 rounds the usable
    # filesystem size down to a whole block group; resize2fs does not use
    # every last byte of the new partition) -- i.e. within 4MiB, one typical
    # block-group's worth, not the exact byte count.
    assert_true "relocate_and_grow_var: ext4 filesystem grew past its pre-relocation size" \
        bash -c "(( $fs_bytes > $var_size_before ))"
    assert_true "relocate_and_grow_var: ext4 filesystem itself was resized to match the grown partition" \
        bash -c "(( $var_size_after - $fs_bytes < 4 * 1024 * 1024 && $var_size_after - $fs_bytes >= 0 ))"

    "${SUDO[@]}" losetup -d "$RELOCATE_LOOP" 2>/dev/null || true
fi

print_summary
