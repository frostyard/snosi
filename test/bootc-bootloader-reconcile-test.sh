#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Fixture coverage for the bootc shim second-stage reconciler.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RECONCILER="$ROOT_DIR/shared/bootc-secure/tree/usr/libexec/snosi-bootc-bootloader-reconcile"
ESP_LIBRARY="$ROOT_DIR/mkosi.images/base/mkosi.extra/usr/lib/snosi/esp.sh"

PASS=0
FAIL=0
WORK=""

pass() { printf 'ok - %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'not ok - %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

cleanup() { [[ -z "$WORK" ]] || rm -rf -- "$WORK"; }
trap cleanup EXIT

write_layout() { # path ESP-path [second-ESP-path]
    local path=$1 esp=$2 second=${3:-}
    jq -n --arg esp "$esp" --arg second "$second" '
        {blockdevices: [
            {path: "/dev/vda", type: "disk", children: [
                {path: "/dev/vda1", type: "part", pkname: "vda", parttype: "ca7d7ccb-63ed-4c53-861c-1742536059cc"},
                {path: "/dev/vda2", type: "part", parttype: "c12a7328-f81f-11d2-ba4b-00a0c93ec93b"},
                {path: $esp, type: "part", pkname: "vda", parttype: "c12a7328-f81f-11d2-ba4b-00a0c93ec93b"}
            ]}
        ]} | if $second != "" then .blockdevices[0].children += [{path: $second, type: "part", pkname: "vda", parttype: "c12a7328-f81f-11d2-ba4b-00a0c93ec93b"}] else . end' >"$path"
}

setup_fixture() {
    WORK=$(mktemp -d)
    mkdir -p "$WORK/bin" "$WORK/root/usr/lib/snosi/bootc" "$WORK/esp/EFI/BOOT" "$WORK/run"
    printf 'certificate\n' >"$WORK/root/usr/lib/snosi/mok.crt"
    printf 'good-new\n' >"$WORK/root/usr/lib/snosi/bootc/systemd-bootx64.efi"
    printf 'good-old\n' >"$WORK/esp/EFI/BOOT/grubx64.efi"
    printf 'shim\n' >"$WORK/esp/EFI/BOOT/BOOTX64.EFI"
    printf 'mokmanager\n' >"$WORK/esp/EFI/BOOT/mmx64.efi"
    write_layout "$WORK/layout.json" /dev/vda3

    cat >"$WORK/bin/cryptsetup" <<'EOF'
#!/bin/bash
printf '  device:  /dev/vda1\n'
EOF
    cat >"$WORK/bin/bootctl" <<'EOF'
#!/bin/bash
exit 1
EOF
    cat >"$WORK/bin/lsblk" <<'EOF'
#!/bin/bash
cat "$SNOSI_TEST_LAYOUT"
EOF
cat >"$WORK/bin/findmnt" <<'EOF'
#!/bin/bash
[[ ${SNOSI_TEST_MOUNTED_ESP:-0} == 1 ]] || exit 0
case "${!#}" in
    TARGET) printf '%s\n' "$SNOSI_TEST_ESP_ROOT" ;;
    TARGET,OPTIONS) printf '%s %s\n' "$SNOSI_TEST_ESP_ROOT" "${SNOSI_TEST_MOUNT_OPTIONS:-rw,relatime}" ;;
esac
EOF
cat >"$WORK/bin/mount" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$SNOSI_TEST_LOG"
rmdir "$4"
ln -s "$SNOSI_TEST_ESP_ROOT" "$4"
EOF
    cat >"$WORK/bin/umount" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$SNOSI_TEST_LOG"
rm -f -- "$1"
EOF
    cat >"$WORK/bin/sbverify" <<'EOF'
#!/bin/bash
[[ $1 == --cert && $2 == "$SNOSI_TEST_CERT" ]] || exit 1
case "$(cat "$3")" in good-*) exit 0 ;; *) exit 1 ;; esac
EOF
cat >"$WORK/bin/sync" <<'EOF'
#!/bin/bash
count=0
[[ ! -f "$SNOSI_TEST_SYNC_COUNT_FILE" ]] || count=$(<"$SNOSI_TEST_SYNC_COUNT_FILE")
count=$((count + 1))
printf '%s' "$count" >"$SNOSI_TEST_SYNC_COUNT_FILE"
printf '%s\n' "$*" >>"$SNOSI_TEST_LOG"
[[ ${SNOSI_TEST_SYNC_FAIL_ON:-0} != "$count" ]]
EOF
    chmod +x "$WORK/bin/"*
}

run_reconciler() {
    PATH="$WORK/bin:$PATH" \
    SNOSI_BOOTC_RECONCILE_SOURCE="$WORK/root/usr/lib/snosi/bootc/systemd-bootx64.efi" \
    SNOSI_BOOTC_RECONCILE_CERT="$WORK/root/usr/lib/snosi/mok.crt" \
    SNOSI_BOOTC_RECONCILE_RUN_DIR="$WORK/run" \
    SNOSI_ESP_LIBRARY="$ESP_LIBRARY" \
    SNOSI_TEST_LAYOUT="$WORK/layout.json" \
    SNOSI_TEST_CERT="$WORK/root/usr/lib/snosi/mok.crt" \
    SNOSI_TEST_ESP=/dev/vda3 \
    SNOSI_TEST_ESP_ROOT="$WORK/esp" \
    SNOSI_TEST_LOG="$WORK/log" \
    SNOSI_TEST_SYNC_COUNT_FILE="$WORK/sync-count" \
    "$RECONCILER"
}

assert_same() { # description left right
    if cmp -s "$2" "$3"; then pass "$1"; else fail "$1"; fi
}

assert_failure_keeps_stage() { # description
    local before="$WORK/prior-stage"
    cp "$WORK/esp/EFI/BOOT/grubx64.efi" "$before"
    if run_reconciler >/dev/null 2>&1; then
        fail "$1 rejects the invalid state"
    else
        pass "$1 rejects the invalid state"
    fi
    assert_same "$1 keeps the prior second stage" "$before" "$WORK/esp/EFI/BOOT/grubx64.efi"
}

test_noop() {
    setup_fixture
    cp "$WORK/root/usr/lib/snosi/bootc/systemd-bootx64.efi" "$WORK/esp/EFI/BOOT/grubx64.efi"
    if SNOSI_TEST_MOUNTED_ESP=1 run_reconciler; then pass "no-op accepts matching signed stage"; else fail "no-op accepts matching signed stage"; fi
    if [[ ! -s "$WORK/log" ]]; then pass "no-op does not mount or sync"; else fail "no-op does not mount or sync"; fi
    cleanup; WORK=""
}

test_valid_update() {
    setup_fixture
    cp "$WORK/esp/EFI/BOOT/BOOTX64.EFI" "$WORK/shim-before"
    cp "$WORK/esp/EFI/BOOT/mmx64.efi" "$WORK/mm-before"
    if SNOSI_TEST_MOUNTED_ESP=1 run_reconciler; then pass "valid signed update succeeds"; else fail "valid signed update succeeds"; fi
    assert_same "valid update installs immutable source" "$WORK/root/usr/lib/snosi/bootc/systemd-bootx64.efi" "$WORK/esp/EFI/BOOT/grubx64.efi"
    assert_same "valid update preserves shim" "$WORK/shim-before" "$WORK/esp/EFI/BOOT/BOOTX64.EFI"
    assert_same "valid update preserves MokManager" "$WORK/mm-before" "$WORK/esp/EFI/BOOT/mmx64.efi"
    if grep -q -- '-f' "$WORK/log"; then pass "valid update syncs durable writes"; else fail "valid update syncs durable writes"; fi
    cleanup; WORK=""
}

test_existing_read_only_mount() {
    local before output
    setup_fixture
    cp "$WORK/esp/EFI/BOOT/grubx64.efi" "$WORK/prior-stage"
    if output=$(SNOSI_TEST_MOUNTED_ESP=1 SNOSI_TEST_MOUNT_OPTIONS=ro,relatime run_reconciler 2>&1); then
        fail "existing read-only ESP mount is rejected"
    elif [[ $output == *'already mounted read-only'* ]]; then
        pass "existing read-only ESP mount is rejected clearly"
    else
        fail "existing read-only ESP mount reports a clear reason"
    fi
    assert_same "existing read-only ESP mount keeps the prior second stage" "$WORK/prior-stage" "$WORK/esp/EFI/BOOT/grubx64.efi"
    if [[ ! -s "$WORK/log" ]]; then pass "existing read-only ESP mount does not remount or write"; else fail "existing read-only ESP mount does not remount or write"; fi
    cleanup; WORK=""
}

test_wrong_source_signer() {
    setup_fixture
    printf 'wrong-signer\n' >"$WORK/root/usr/lib/snosi/bootc/systemd-bootx64.efi"
    SNOSI_TEST_MOUNTED_ESP=1 assert_failure_keeps_stage "wrong source signer"
    cleanup; WORK=""
}

test_wrong_temporary_copy() {
    setup_fixture
cat >"$WORK/bin/cp" <<'EOF'
#!/bin/bash
if [[ $1 == "$SNOSI_BOOTC_RECONCILE_SOURCE" ]]; then printf 'wrong-temporary\n' >"$2"; else /bin/cp "$@"; fi
EOF
    chmod +x "$WORK/bin/cp"
    SNOSI_TEST_MOUNTED_ESP=1 assert_failure_keeps_stage "wrong temporary destination verification"
    cleanup; WORK=""
}

test_interrupted_write() {
    setup_fixture
cat >"$WORK/bin/cp" <<'EOF'
#!/bin/bash
if [[ $1 == "$SNOSI_BOOTC_RECONCILE_SOURCE" ]]; then printf 'partial\n' >"$2"; exit 1; else /bin/cp "$@"; fi
EOF
    chmod +x "$WORK/bin/cp"
    SNOSI_TEST_MOUNTED_ESP=1 assert_failure_keeps_stage "interrupted write"
    cleanup; WORK=""
}

test_failed_durability_sync() {
    setup_fixture
    SNOSI_TEST_MOUNTED_ESP=1 SNOSI_TEST_SYNC_FAIL_ON=3 assert_failure_keeps_stage "post-replacement sync failure"
    cleanup; WORK=""
}

test_rollback() {
    setup_fixture
    printf 'good-rollback\n' >"$WORK/root/usr/lib/snosi/bootc/systemd-bootx64.efi"
    printf 'good-newer\n' >"$WORK/esp/EFI/BOOT/grubx64.efi"
    if SNOSI_TEST_MOUNTED_ESP=1 run_reconciler; then pass "rollback-compatible signed replacement succeeds"; else fail "rollback-compatible signed replacement succeeds"; fi
    assert_same "rollback installs the booted deployment stage" "$WORK/root/usr/lib/snosi/bootc/systemd-bootx64.efi" "$WORK/esp/EFI/BOOT/grubx64.efi"
    cleanup; WORK=""
}

test_missing_or_ambiguous_esp() {
    setup_fixture
    jq '.blockdevices[0].children |= map(select(.path != "/dev/vda3"))' "$WORK/layout.json" >"$WORK/missing.json"
    mv "$WORK/missing.json" "$WORK/layout.json"
    SNOSI_TEST_MOUNTED_ESP=1 assert_failure_keeps_stage "missing colocated ESP"
    cleanup; WORK=""

    setup_fixture
    write_layout "$WORK/layout.json" /dev/vda3 /dev/vda4
    SNOSI_TEST_MOUNTED_ESP=1 assert_failure_keeps_stage "ambiguous colocated ESP"
    cleanup; WORK=""
}

test_temporary_mount() {
    setup_fixture
    if run_reconciler; then pass "unmounted ESP is reconciled through a temporary mount"; else fail "unmounted ESP is reconciled through a temporary mount"; fi
    if grep -q -- '-o rw /dev/vda3' "$WORK/log" && [[ ! -e "$WORK/run/esp" ]]; then pass "temporary ESP mount is removed"; else fail "temporary ESP mount is removed"; fi
    cleanup; WORK=""
}

[[ -x "$RECONCILER" ]] || { echo "not ok - reconciler is not implemented yet" >&2; exit 1; }
test_noop
test_valid_update
test_existing_read_only_mount
test_wrong_source_signer
test_wrong_temporary_copy
test_interrupted_write
test_failed_durability_sync
test_rollback
test_missing_or_ambiguous_esp
test_temporary_mount

[[ $FAIL -eq 0 ]] || exit 1
printf 'bootloader reconciliation fixtures passed (%d assertions)\n' "$PASS"
