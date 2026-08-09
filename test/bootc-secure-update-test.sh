#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Task 9 secure bootc update harness. Live mode consumes an install handoff;
# fixtures define its fail-closed contract without privileged artifacts.
set -euo pipefail

PASS=0
FAIL=0

pass() { printf 'ok - %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'not ok - %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
assert_true() { local description=$1; shift; if "$@"; then pass "$description"; else fail "$description"; fi; }
assert_false() { local description=$1; shift; if "$@"; then fail "$description"; else pass "$description"; fi; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/test/lib/secure-vm.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/test/lib/ssh.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/test/lib/bootc-secure-assertions.sh"

: "${BOOTC_SECURE_INSTALL_STATE:=}"
: "${BOOTC_SECURE_UPDATE_PUBLISH_COMMAND:=}"
: "${UPDATE_N1_REF:=}"
: "${UPDATE_N2_REF:=}"
: "${UPDATE_N1_VERSION:=}"
: "${UPDATE_N2_VERSION:=}"
: "${SSH_PORT:=2250}"
: "${SSH_TIMEOUT:=300}"
: "${KEEP_VM:=0}"

WORK=""
QEMU_PID=""

valid_profile() { [[ $1 == cayo || $1 == snow || $1 == snowfield ]]; }
valid_digest_ref() { [[ $1 =~ ^ghcr\.io/frostyard/(cayo|snow|snowfield)@sha256:[[:xdigit:]]{64}$ ]]; }
valid_tracking_ref() { [[ $1 =~ ^ghcr\.io/frostyard/(cayo|snow|snowfield):[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; }
valid_image_version() { [[ $1 =~ ^[0-9]{14}$ ]]; }
valid_publish_slot() { [[ $1 == N+1 || $1 == N+2 ]]; }
mode_0600() { [[ -f $1 && $(stat -c '%a' "$1") == 600 ]]; }
disk_is_raw() {
    [[ -b $1 ]] && return 0
    [[ -f $1 ]] && qemu-img info --output=json "$1" | jq -e '.format == "raw"' >/dev/null
}
marker_is_exact() { [[ $1 == "$2" ]]; }

install_state_is_safe() { # manifest
    local state=$1 expected
    mode_0600 "$state" || return 1
    expected='["accepted_oci_ref","mok_cert","ovmf_code","ovmf_vars","pcr_public","profile","recovery_key","schema","ssh_key","target_disk","tpm_socket","tpm_state","tracking_ref"]'
    jq -e --argjson expected "$expected" '
        (keys | sort) == $expected and .schema == 1 and
        ([.profile, .tracking_ref, .accepted_oci_ref, .target_disk, .ovmf_code,
          .ovmf_vars, .tpm_state, .tpm_socket, .recovery_key, .mok_cert,
          .pcr_public, .ssh_key] | all(type == "string" and length > 0)) and
        ([.recovery_key, .mok_cert, .pcr_public, .ssh_key] | all(startswith("/"))) and
        ([.. | strings | select(test("(passphrase|private[ _-]?key|secret)"; "i"))] | length == 0)
    ' "$state" >/dev/null
}

state_value() { jq -er --arg key "$2" '.[$key]' "$1"; }
state_matches_profile() {
    local state=$1 profile=$2
    [[ $(state_value "$state" profile) == "$profile" ]] || return 1
    [[ $(state_value "$state" tracking_ref) == "ghcr.io/frostyard/$profile:"* ]] || return 1
    [[ $(state_value "$state" accepted_oci_ref) == "ghcr.io/frostyard/$profile@"* ]]
}
reconciler_succeeded() { [[ $1 == *$'Result=success'* && $1 != *$'ActiveState=failed'* ]]; }

run_marked() { # runner marker args...
    local runner=$1 marker=$2 output status
    shift 2
    set +e
    output=$("$runner" "$@" 2>&1)
    status=$?
    set -e
    if [[ $status -ne 0 ]] || ! grep -Fqx "$marker" <<<"$output"; then
        printf '%s\n' "$output" >&2
        return 1
    fi
    [[ $output != *'NOOP'* && $output != *'no-op'* ]] || return 1
}

stop_vm() {
    [[ -z $QEMU_PID ]] && return 0
    secure_vm_stop_owned_process "$QEMU_PID" || { echo "Error: owned QEMU PID $QEMU_PID did not stop" >&2; return 1; }
    QEMU_PID=""
}

cleanup() {
    local failed=0
    set +e
    stop_vm || failed=1
    secure_vm_stop_swtpm || failed=1
    if ((failed)); then
        printf 'Error: retaining %s because an owned process did not stop\n' "$WORK" >&2
        return 1
    fi
    if [[ $KEEP_VM != 1 && -n $WORK ]]; then rm -rf -- "$WORK"; fi
}
trap cleanup EXIT

ssh_port_available() { ! ss -ltn "sport = :$SSH_PORT" | grep -q LISTEN; }
start_vm() { # disk firmware-code firmware-vars TPM-socket workdir
    local disk=$1 code=$2 vars=$3 socket=$4 work=$5
    ssh_port_available || { echo "BLOCKED: SSH_PORT=$SSH_PORT is already in use" >&2; return 2; }
    QEMU_CONSOLE_LOG="$work/serial.log"; export QEMU_CONSOLE_LOG
    qemu-system-x86_64 -machine q35 -enable-kvm -cpu host -m 4096 -smp 2 \
        -drive "if=pflash,format=raw,unit=0,file=$code,readonly=on" \
        -drive "if=pflash,format=raw,unit=1,file=$vars" \
        -drive "file=$disk,format=raw,if=virtio" \
        -netdev "user,id=net0,hostfwd=tcp::$SSH_PORT-:22" -device virtio-net-pci,netdev=net0 \
        -display none -vga none -chardev "socket,id=tpmchr,path=$socket" \
        -tpmdev emulator,id=tpm0,chardev=tpmchr -device tpm-crb,tpmdev=tpm0 \
        -serial "file:$work/serial.log" -monitor none -pidfile "$work/qemu.pid" -daemonize
    QEMU_PID=$(<"$work/qemu.pid")
}


# Every check names itself on failure. This used to be one unbroken && chain
# reported as a bare "FATAL: installed target failed secure runtime
# assertions", which says which FUNCTION failed and nothing about which of its
# twelve checks did -- the same diagnostic gap that cost the recovery runner
# several whole lane runs before it was closed.
subset_fail() { echo "  secure_runtime_subset: FAILED -- $1" >&2; return 1; }

secure_runtime_subset() { # recovery MOK certificate
    local recovery=$1 mok=$2 cmdline entries token reconciler backing guest_mok
    vm_ssh 'mokutil --sb-state | grep -q "SecureBoot enabled"'                     || subset_fail "Secure Boot is not enabled" || return 1
    vm_ssh 'bootctl --no-pager status | grep -q "Measured UKI: yes"'                || subset_fail "booted chain is not a measured UKI" || return 1
    vm_ssh 'grep -Eq "\[(integrity|confidentiality)\]" /sys/kernel/security/lockdown' || subset_fail "kernel lockdown is not integrity/confidentiality" || return 1
    # Print WHICH units, not just that some did. "system units have failed" is
    # a fact nobody can act on, and this check runs after the recovery legs --
    # the install harness asserts the same thing BEFORE them and passes, so
    # anything failing here was left behind by TPM replacement or recovery
    # re-enrolment, and the unit name is the entire finding.
    local failed
    failed=$(vm_ssh 'systemctl --failed --no-legend --plain' 2>/dev/null || true)
    [[ -z $failed ]] || {
        subset_fail "system units have failed:"
        printf '%s\n' "$failed" | sed 's/^/      /' >&2
        printf '    --- status of each ---\n' >&2
        while read -r unit _; do
            [[ -n $unit ]] || continue
            vm_ssh "systemctl status --no-pager --lines=15 '$unit'" 2>&1 | sed 's/^/      /' >&2
        done <<<"$failed"
        return 1
    }

    reconciler=$(vm_ssh 'systemctl show --property=ActiveState --property=Result snosi-bootc-bootloader-reconcile.service')
    reconciler_succeeded "$reconciler" || subset_fail "ESP reconciler did not succeed: $reconciler" || return 1

    backing=$(root_backing_device "$(vm_ssh 'cryptsetup status root')") || subset_fail "could not derive the root backing device" || return 1
    vm_ssh "cryptsetup isLuks '$backing'" || subset_fail "$backing is not LUKS" || return 1

    # Probe the MAPPER, not `/`. On a composefs deployment `/` is an overlay,
    # so `findmnt -no FSTYPE /` reports `overlay` and never `btrfs`. This
    # function asserted exactly that impossible thing, so it could not pass on
    # any composefs install -- the install harness had already measured the
    # real shape (fstype(/)=overlay, fstype(/dev/mapper/root)=btrfs) and been
    # fixed; this sibling was not. Observed live: run 31232569446 completed the
    # entire install leg, then failed here on the first update assertion.
    # And probe the DECRYPTED mapper, not $backing: $backing is the LUKS
    # container, which reports crypto_LUKS. The filesystem lives behind it.
    vm_ssh "blkid -o value -s TYPE /dev/mapper/root | grep -qx btrfs" \
        || subset_fail "/dev/mapper/root is not btrfs (backing=$backing)" || return 1

    cmdline=$(vm_ssh 'cat /proc/cmdline')
    composefs_from_cmdline "$cmdline" >/dev/null || subset_fail "no composefs= in the kernel command line: $cmdline" || return 1
    cmdline_has_lockdown_integrity "$cmdline" \
        || subset_fail "kernel command line does not contain exactly one lockdown=integrity: $cmdline" || return 1
    [[ $cmdline != *root=* && $cmdline != *luks.* && $cmdline != *rd.luks.* ]] \
        || subset_fail "kernel command line carries a root/LUKS identifier: $cmdline" || return 1

    # Off the ESP, not /boot. bootc leaves /boot unmounted unless it is using
    # it, so `cat /boot/loader/entries/*.conf` fails on a HEALTHY system --
    # which is exactly what this reported as "BLS entries are not Type #2-only"
    # on run 31292423836, eleven seconds after the install harness asserted the
    # same property and passed. It was fixed there (snosi#524) and not here.
    entries=$(esp_cat 'loader/entries/*.conf')
    type2_only <(printf '%s\n' "$entries") || subset_fail "BLS entries are not Type #2-only" || return 1

    token=$(vm_ssh "cryptsetup luksDump --dump-json-metadata '$backing'")
    signed_pcr11_token <<<"$token" || subset_fail "not exactly one signed-PCR-11 TPM token" || return 1

    vm_ssh "cryptsetup open --test-passphrase --key-file=- '$backing'" <"$recovery" \
        || subset_fail "the recovery credential no longer opens $backing" || return 1
    vm_ssh "source=/usr/lib/snosi/bootc/systemd-bootx64.efi; test -s \"\$source\"; sbverify --cert /usr/lib/snosi/mok.crt \"\$source\" >/dev/null" \
        || subset_fail "the immutable second-stage source is missing or not MOK-signed" || return 1
    # The UKI is read off the ESP, for the same reason the BLS entries are:
    # bootc leaves /boot unmounted unless it is using it, so `test -e
    # /boot/EFI/Linux/...` reports absent on a perfectly healthy system. That is
    # exactly what it did on run 31293274112 -- "no UKI at the composefs path"
    # for a UKI that was present the whole time.
    #
    # Fixing only the BLS read last time and not sweeping the rest of this
    # function for the same mistake is what produced that run. Every remaining
    # guest path here is now ESP-relative or /usr.
    #
    # Signature verification runs HOST-side against the MOK identity the caller
    # supplied, rather than in-guest against the guest's own copy: the guest
    # certificate is separately compared to the supplied one below, so verifying
    # against the supplied identity is the stronger check and needs no second
    # in-guest tool.
    local composefs_id uki_local
    composefs_id=$(composefs_from_cmdline "$cmdline")
    uki_local="$WORK/uki-installed.efi"
    esp_cat "EFI/Linux/bootc/bootc_composefs-${composefs_id}.efi" >"$uki_local" 2>/dev/null \
        || subset_fail "no UKI on the ESP at EFI/Linux/bootc/bootc_composefs-${composefs_id}.efi" || return 1
    [[ -s $uki_local ]] \
        || subset_fail "the UKI on the ESP for ${composefs_id} is empty" || return 1
    sbverify --cert "$mok" "$uki_local" >/dev/null 2>&1 \
        || subset_fail "the installed UKI is not signed by the supplied MOK identity" || return 1

    guest_mok=$(mktemp "$WORK/mok-guest.XXXXXX") || return 1
    rm -f -- "$guest_mok"
    scp "${SSH_OPTS[@]}" -i "$SSH_KEY" -P "$SSH_PORT" root@localhost:/usr/lib/snosi/mok.crt "$guest_mok" \
        || subset_fail "could not fetch the guest MOK certificate" || return 1
    cmp -s "$mok" "$guest_mok" || subset_fail "guest MOK certificate differs from the supplied one" || return 1
}

copy_and_run_persistence() { # write|verify
    # Four steps behind one caller-side FATAL. Name them: "could not write
    # persistence markers" does not distinguish a missing script, a failed
    # copy, and the guest script itself failing -- and the guest script is the
    # interesting case, since its output is the finding.
    local action=$1
    local script="$ROOT_DIR/test/update-tests/persistence-$action.sh"
    [[ -f $script ]] || { echo "  persistence: no such script: $script" >&2; return 1; }
    vm_ssh 'mkdir -p /tmp/task9-lib' \
        || { echo "  persistence: could not create /tmp/task9-lib in the guest" >&2; return 1; }
    scp "${SSH_OPTS[@]}" -i "$SSH_KEY" -P "$SSH_PORT" "$ROOT_DIR/test/lib/helpers.sh" root@localhost:/tmp/task9-lib/helpers.sh \
        || { echo "  persistence: could not copy helpers.sh to the guest" >&2; return 1; }
    scp "${SSH_OPTS[@]}" -i "$SSH_KEY" -P "$SSH_PORT" "$script" root@localhost:/tmp/task9-persistence.sh \
        || { echo "  persistence: could not copy ${script##*/} to the guest" >&2; return 1; }
    vm_ssh 'TEST_LIB_DIR=/tmp/task9-lib bash /tmp/task9-persistence.sh' \
        || { echo "  persistence: ${script##*/} failed IN THE GUEST (its output is above)" >&2; return 1; }
}

guest_digest() { vm_ssh 'bootc status --format json' | jq -r ".status.$1.image.imageDigest // empty"; }
guest_image_version() { vm_ssh ". /usr/lib/os-release; printf \"%s\\n\" \"\$IMAGE_VERSION\""; }
reboot_and_assert() { # old boot id recovery mok expected-version
    local old=$1 recovery=$2 mok=$3 expected=$4 new=''
    vm_ssh systemctl reboot || true
    local deadline=$((SECONDS + SSH_TIMEOUT))
    while ((SECONDS < deadline)); do new=$(vm_ssh 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null || true); [[ -n $new && $new != "$old" ]] && break; sleep 2; done
    [[ -n $new && $new != "$old" ]] || return 1
    secure_runtime_subset "$recovery" "$mok" || { echo 'Error: secure runtime assertion failed after reboot' >&2; return 1; }
    copy_and_run_persistence verify || { echo 'Error: persistence assertion failed after reboot' >&2; return 1; }
    [[ $(guest_image_version) == "$expected" ]] || { echo "Error: booted IMAGE_VERSION does not match $expected" >&2; return 1; }
}

run_fixtures() {
    local work state digest n1 n2
    work=$(mktemp -d)
    trap 'rm -rf "$work"' RETURN
    state="$work/install-state.json"
    digest="sha256:$(printf 'a%.0s' {1..64})"
    n1="ghcr.io/frostyard/cayo@${digest}"
    n2="ghcr.io/frostyard/cayo@sha256:$(printf 'b%.0s' {1..64})"
    if command -v qemu-img >/dev/null 2>&1; then
        qemu-img create -q -f raw "$work/raw.img" 1048576
        qemu-img create -q -f qcow2 "$work/not-raw.qcow2" 1048576
        assert_true 'raw handoff disk is accepted' disk_is_raw "$work/raw.img"
        assert_false 'non-raw handoff disk is rejected' disk_is_raw "$work/not-raw.qcow2"
    fi
    printf '%s\n' "{\"schema\":1,\"profile\":\"cayo\",\"tracking_ref\":\"ghcr.io/frostyard/cayo:secure-test\",\"accepted_oci_ref\":\"$n1\",\"target_disk\":\"/tmp/disk\",\"ovmf_code\":\"/tmp/code\",\"ovmf_vars\":\"/tmp/vars\",\"tpm_state\":\"/tmp/tpm\",\"tpm_socket\":\"/tmp/tpm/socket\",\"recovery_key\":\"/tmp/recovery\",\"mok_cert\":\"/tmp/mok.crt\",\"pcr_public\":\"/tmp/pcr.pub\",\"ssh_key\":\"/tmp/id\"}" >"$state"
    chmod 600 "$state"
    assert_true 'mode-0600 install state accepts only non-secret handoff fields' install_state_is_safe "$state"
    assert_true 'handoff profile, tracking tag, and accepted digest agree' state_matches_profile "$state" cayo
    assert_true 'immutable N+1 digest is accepted' valid_digest_ref "$n1"
    assert_true 'immutable N+2 digest is accepted' valid_digest_ref "$n2"
    assert_true 'tracking tag is accepted separately from immutable deployment refs' valid_tracking_ref ghcr.io/frostyard/cayo:secure-test
    assert_true 'publisher accepts the N+1 slot' valid_publish_slot N+1
    assert_true 'publisher accepts the N+2 slot' valid_publish_slot N+2
    assert_false 'publisher rejects an unrecognized slot' valid_publish_slot N+3
    assert_true 'timestamp image versions use the repository grammar' valid_image_version 20260729123456
    assert_false 'non-timestamp image versions are rejected' valid_image_version 20260729
    assert_true 'successful oneshot reconciler may be inactive' reconciler_succeeded $'ActiveState=inactive\nResult=success'
    assert_false 'failed reconciler result is rejected' reconciler_succeeded $'ActiveState=inactive\nResult=exit-code'
    assert_true 'root status yields exactly one backing device' root_backing_device $'  device:  /dev/vda2\n'
    assert_false 'root status rejects no backing device' root_backing_device 'type: LUKS2'
    assert_false 'root status rejects multiple backing devices' root_backing_device $'device: /dev/vda2\ndevice: /dev/vdb2'
    assert_true 'publisher marker is exact' marker_is_exact 'BOOTC_SECURE_UPDATE_PUBLISH: N+1: published' 'BOOTC_SECURE_UPDATE_PUBLISH: N+1: published'
    printf '%s\n' "{\"schema\":1,\"profile\":\"cayo\",\"tracking_ref\":\"ghcr.io/frostyard/cayo:secure-test\",\"accepted_oci_ref\":\"$n1\",\"target_disk\":\"/tmp/disk\",\"ovmf_code\":\"/tmp/code\",\"ovmf_vars\":\"/tmp/vars\",\"tpm_state\":\"/tmp/tpm\",\"tpm_socket\":\"/tmp/tpm/socket\",\"recovery_key\":\"/tmp/passphrase-secret-private-key\",\"mok_cert\":\"/tmp/mok.crt\",\"pcr_public\":\"/tmp/pcr.pub\",\"ssh_key\":\"/tmp/id\"}" >"$work/unsafe.json"; chmod 600 "$work/unsafe.json"
    if install_state_is_safe "$work/unsafe.json"; then fail 'manifest rejects secret-bearing fields'; else pass 'manifest rejects secret-bearing fields'; fi
    printf '%s\n' '#!/bin/bash' 'printf "%s\\n" "BOOTC_SECURE_UPDATE_PUBLISH: N+1: published NOOP"' >"$work/noop-publisher"
    chmod +x "$work/noop-publisher"
    if run_marked "$work/noop-publisher" 'BOOTC_SECURE_UPDATE_PUBLISH: N+1: published'; then fail 'no-op publisher is rejected despite a marker'; else pass 'no-op publisher is rejected despite a marker'; fi
    printf '%s\n' '#!/bin/bash' 'printf "%s\\n" "BOOTC_SECURE_UPDATE_PUBLISH: N+1: published"' >"$work/publisher"
    chmod +x "$work/publisher"
    assert_true 'marked publisher succeeds only with its exact marker' run_marked "$work/publisher" 'BOOTC_SECURE_UPDATE_PUBLISH: N+1: published'
    assert_false 'failed publisher is rejected even with no marker check bypass' run_marked /bin/false 'BOOTC_SECURE_UPDATE_PUBLISH: N+1: published'
    printf '# Results: %d passed, %d failed, %d total\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
    [[ $FAIL -eq 0 ]]
}

require_live_inputs() {
    local missing=() state=$BOOTC_SECURE_INSTALL_STATE profile
    install_state_is_safe "$state" || missing+=("BOOTC_SECURE_INSTALL_STATE (mode-0600 non-secret handoff manifest)")
    if [[ -z ${missing[*]} ]]; then
        profile=$(state_value "$state" profile)
        valid_profile "$profile" && state_matches_profile "$state" "$profile" || missing+=("consistent profile/tracking_ref/accepted_oci_ref")
        valid_digest_ref "$UPDATE_N1_REF" && [[ $UPDATE_N1_REF == "ghcr.io/frostyard/$profile@"* ]] || missing+=("UPDATE_N1_REF immutable matching digest")
        valid_digest_ref "$UPDATE_N2_REF" && [[ $UPDATE_N2_REF == "ghcr.io/frostyard/$profile@"* ]] || missing+=("UPDATE_N2_REF immutable matching digest")
        [[ $UPDATE_N1_REF != "$UPDATE_N2_REF" && $UPDATE_N1_REF != "$(state_value "$state" accepted_oci_ref)" && $UPDATE_N2_REF != "$(state_value "$state" accepted_oci_ref)" ]] || missing+=("distinct accepted-N/N+1/N+2 digests")
        valid_image_version "$UPDATE_N1_VERSION" || missing+=("UPDATE_N1_VERSION=<14-digit image version>")
        valid_image_version "$UPDATE_N2_VERSION" || missing+=("UPDATE_N2_VERSION=<14-digit image version>")
        [[ $UPDATE_N1_VERSION != "$UPDATE_N2_VERSION" ]] || missing+=("distinct N+1/N+2 image versions")
        disk_is_raw "$(state_value "$state" target_disk)" || missing+=("target_disk from install state (raw qemu image or block device)")
        for key in ovmf_code ovmf_vars recovery_key mok_cert pcr_public ssh_key; do [[ -e $(state_value "$state" "$key") ]] || missing+=("$key from install state"); done
        [[ -d $(state_value "$state" tpm_state) ]] || missing+=("tpm_state from install state")
    fi
    [[ -x $BOOTC_SECURE_UPDATE_PUBLISH_COMMAND ]] || missing+=("BOOTC_SECURE_UPDATE_PUBLISH_COMMAND")
    for tool in jq qemu-img qemu-system-x86_64 swtpm cryptsetup objcopy sbverify ssh scp ss; do command -v "$tool" >/dev/null 2>&1 || missing+=("$tool"); done
    ((${#missing[@]})) || return 0
    printf 'BLOCKED: Task 9 secure update proof requires: %s\n' "${missing[*]}" >&2
    return 2
}

publish() { # slot digest-ref
    local slot=$1 ref=$2 state=$BOOTC_SECURE_INSTALL_STATE tracking profile
    valid_publish_slot "$slot" || return 1
    tracking=$(state_value "$state" tracking_ref); profile=$(state_value "$state" profile)
    run_marked "$BOOTC_SECURE_UPDATE_PUBLISH_COMMAND" "BOOTC_SECURE_UPDATE_PUBLISH: $slot: published" --profile "$profile" --tracking-ref "$tracking" --slot "$slot" --digest-ref "$ref"
}

assert_tracking_and_provenance() {
    local state=$BOOTC_SECURE_INSTALL_STATE tracking accepted spec provenance
    tracking=$(state_value "$state" tracking_ref); accepted=$(state_value "$state" accepted_oci_ref)
    spec=$(vm_ssh 'bootc status --format json' | jq -r '.spec.image.image // empty')
    provenance=$(vm_ssh 'jq -r .oci_ref /var/lib/snosi/bootc-secure-install.json')
    [[ $spec == "$tracking" && $provenance == "$accepted" ]]
}

run_live() {
    local state=$BOOTC_SECURE_INSTALL_STATE disk code vars tpm socket recovery mok old staged booted rollback
    require_live_inputs
    WORK=$(mktemp -d /var/tmp/bootc-secure-update-test.XXXXXX)
    disk=$(state_value "$state" target_disk); code=$(state_value "$state" ovmf_code); vars=$(state_value "$state" ovmf_vars); tpm=$(state_value "$state" tpm_state); socket=$(state_value "$state" tpm_socket); recovery=$(state_value "$state" recovery_key); mok=$(state_value "$state" mok_cert); SSH_KEY=$(state_value "$state" ssh_key)
    secure_vm_start_swtpm_paths "$tpm" "$socket" "$tpm/swtpm.pid"
    start_vm "$disk" "$code" "$vars" "$SECURE_VM_TPM_SOCK" "$WORK"
    wait_for_ssh || { echo 'BLOCKED: retained installed target did not reach SSH' >&2; return 2; }
    assert_tracking_and_provenance || { echo 'FATAL: installer does not retain accepted N provenance while following the tracking tag' >&2; return 1; }
    secure_runtime_subset "$recovery" "$mok" || { echo 'FATAL: installed target failed secure runtime assertions' >&2; return 1; }
    copy_and_run_persistence write || { echo 'FATAL: could not write persistence markers' >&2; return 1; }
    publish N+1 "$UPDATE_N1_REF" || { echo 'FATAL: N+1 publisher did not advance its marked slot' >&2; return 1; }
    old=$(vm_ssh 'cat /proc/sys/kernel/random/boot_id') || { echo 'FATAL: could not read N boot ID' >&2; return 1; }
    vm_ssh /usr/libexec/bootc-update-stage || { echo 'FATAL: N+1 production stager failed' >&2; return 1; }
    staged=$(guest_digest staged); [[ -n $staged && $(vm_ssh 'bootc status --format json' | jq -r '.spec.image.transport') == containers-storage ]] || { echo 'FATAL: N+1 switch did not stage containers-storage deployment' >&2; return 1; }
    reboot_and_assert "$old" "$recovery" "$mok" "$UPDATE_N1_VERSION" || { echo 'FATAL: N+1 reboot/runtime/persistence validation failed' >&2; return 1; }
    booted=$(guest_digest booted); rollback=$(guest_digest rollback); [[ $booted == "$staged" && -n $rollback ]] || { echo 'FATAL: N+1 booted/rollback relationship is invalid' >&2; return 1; }
    publish N+2 "$UPDATE_N2_REF" || { echo 'FATAL: N+2 publisher did not advance its marked slot' >&2; return 1; }
    old=$(vm_ssh 'cat /proc/sys/kernel/random/boot_id') || { echo 'FATAL: could not read N+1 boot ID' >&2; return 1; }
    vm_ssh /usr/libexec/bootc-update-stage || { echo 'FATAL: N+2 production stager failed' >&2; return 1; }
    staged=$(guest_digest staged); [[ -n $staged ]] || { echo 'FATAL: N+2 upgrade did not stage a deployment' >&2; return 1; }
    reboot_and_assert "$old" "$recovery" "$mok" "$UPDATE_N2_VERSION" || { echo 'FATAL: N+2 reboot/runtime/persistence validation failed' >&2; return 1; }
    booted=$(guest_digest booted); rollback=$(guest_digest rollback); [[ $booted == "$staged" && -n $rollback ]] || { echo 'FATAL: N+2 booted/rollback relationship is invalid' >&2; return 1; }
    old=$(vm_ssh 'cat /proc/sys/kernel/random/boot_id') || { echo 'FATAL: could not read N+2 boot ID before rollback' >&2; return 1; }
    vm_ssh bootc rollback || { echo 'FATAL: first rollback command failed' >&2; return 1; }
    reboot_and_assert "$old" "$recovery" "$mok" "$UPDATE_N1_VERSION" || { echo 'FATAL: rollback to N+1 validation failed' >&2; return 1; }
    [[ $(guest_digest booted) == "$rollback" ]] || { echo 'FATAL: rollback did not boot the retained N+1 deployment' >&2; return 1; }
    old=$(vm_ssh 'cat /proc/sys/kernel/random/boot_id') || { echo 'FATAL: could not read N+1 boot ID before return' >&2; return 1; }
    vm_ssh bootc rollback || { echo 'FATAL: return rollback command failed' >&2; return 1; }
    reboot_and_assert "$old" "$recovery" "$mok" "$UPDATE_N2_VERSION" || { echo 'FATAL: return to N+2 validation failed' >&2; return 1; }
    [[ $(guest_digest booted) == "$booted" ]] || { echo 'FATAL: return did not boot the retained N+2 deployment' >&2; return 1; }
}

if [[ ${1:-} == --fixtures ]]; then run_fixtures; exit $?; fi
[[ $# -eq 0 ]] || { echo "Usage: $0 [--fixtures]" >&2; exit 2; }
run_live
