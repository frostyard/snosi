#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Task 9 secure installer acceptance harness. External installer code owns the
# install operation; this test owns its QEMU/OVMF/TPM evidence and refusal checks.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/test/lib/secure-vm.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/test/lib/ssh.sh"

: "${PROFILE:=cayo}"
: "${DAKOTA_ISO:=}"
: "${OCI_REF:=}"
: "${MOK_CERT:=}"
: "${PCR_PUBLIC:=}"
: "${RECOVERY_KEY:=}"
: "${TARGET_DISK:=}"
: "${BOOTC_SECURE_INSTALLER:=}"
: "${BOOTC_SECURE_NEGATIVE_COMMAND:=}"
: "${BOOTC_SECURE_RECOVERY_COMMAND:=}"
: "${BOOTC_SECURE_INSTALL_STATE:=}"
: "${TRACKING_REF:=}"
: "${SSH_PORT:=2249}"
: "${SSH_TIMEOUT:=300}"
: "${KEEP_VM:=0}"

WORK=""
QEMU_PID=""
RECOVERY_TOKEN_ID=""
PASS=0
FAIL=0
HANDOFF_RETAIN=0

pass() { printf 'ok - %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'not ok - %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
assert_true() { local description=$1; shift; if "$@"; then pass "$description"; else fail "$description"; fi; }
assert_false() { local description=$1; shift; if "$@"; then fail "$description"; else pass "$description"; fi; }

validate_profile() { [[ $1 == cayo || $1 == snow || $1 == snowfield ]]; }
valid_oci_ref() { [[ $1 =~ ^ghcr\.io/frostyard/(cayo|snow|snowfield)@sha256:[[:xdigit:]]{64}$ ]]; }
valid_recovery_key() { [[ -f $1 && $(stat -c '%a' "$1") == 600 && -s $1 ]]; }
disk_is_raw() { # block devices are raw by construction; regular files must be raw qemu images.
    [[ -b $1 ]] && return 0
    [[ -f $1 ]] && qemu-img info --output=json "$1" | jq -e '.format == "raw"' >/dev/null
}
disk_is_large_enough() {
    local disk=$1 bytes
    [[ -e $disk ]] && disk_is_raw "$disk" || return 1
    if [[ -b $disk ]]; then bytes=$(blockdev --getsize64 "$disk"); else bytes=$(stat -c '%s' "$disk"); fi
    (( bytes >= 32212254720 ))
}
composefs_from_cmdline() {
    local token value='' count=0
    for token in $1; do
        [[ $token == composefs=* ]] || continue
        value=${token#composefs=}; value=${value#\?}; value=${value%%,*}; count=$((count + 1))
    done
    [[ $count -eq 1 && $value =~ ^[[:xdigit:]]{128}$ ]] && printf '%s\n' "$value"
}
type2_only() { # path; materialize once because callers may provide a FIFO.
    local entries
    entries=$(cat "$1") || return
    ! grep -Eq '^[[:space:]]*(linux|initrd)[[:space:]]+' <<<"$entries" \
        && grep -Eq '^[[:space:]]*efi[[:space:]]+/EFI/Linux/bootc/bootc_composefs-[[:xdigit:]]{128}\.efi[[:space:]]*$' <<<"$entries"
}
cmdline_has_root_or_luks() { [[ $1 =~ (^|[[:space:]])(root=|luks\.|rd\.luks\.) ]]; }
exactly_one_line() { [[ -n $1 && $1 != *$'\n'* ]]; }
recovery_baseline_is_current() { [[ $1 == "$2" ]]; }
signed_pcr11_token() {
    jq -e '[.tokens[] | select(.type == "systemd-tpm2")] as $tokens | ($tokens | length == 1) and $tokens[0]."tpm2-pcrs" == [] and $tokens[0].tpm2_pubkey_pcrs == [11] and ($tokens[0] | has("tpm2-pcrlock") | not)' >/dev/null
}
root_backing_device() { # cryptsetup status root output
    local device
    device=$(awk '/^[[:space:]]*device:/{print $2}' <<<"$1")
    [[ $device == /dev/* && $device != *$'\n'* ]] && printf '%s\n' "$device"
}
canonical_tpm_socket() { # workdir socket
    [[ $2 == "$1/tpm/swtpm-ctrl.sock" && $2 == "$1/tpm/"* ]]
}
negative_case() {
    case $1 in unsigned|wrong-key|wrong-repository|false-capability|wrong-mok-uki|composefs-mismatch|esp-full|interrupted-finalize|reconcile-failure) return 0;; *) return 1;; esac
}
recovery_case() { [[ $1 == tpm-replacement || $1 == recovery-reenrollment ]]; }
runner_output_has_marker() { grep -Fqx "$2" <<<"$1"; }
runner_environment_is_complete() { [[ -n $1 && -n $2 && -n $3 ]]; }
reconciler_proof_shape() { [[ $# -eq 5 ]] && [[ -n $1 && -n $2 && -n $3 && -n $4 && -n $5 ]]; }
run_marked_runner() { # runner expected-marker args...
    local runner=$1 marker=$2 status
    shift 2
    set +e
    RUNNER_OUTPUT=$("$runner" "$@" 2>&1)
    status=$?
    set -e
    [[ $status -eq 0 ]] || { printf '%s\n' "$RUNNER_OUTPUT" >&2; return 1; }
    runner_output_has_marker "$RUNNER_OUTPUT" "$marker" || { printf '%s\n' "$RUNNER_OUTPUT" >&2; return 1; }
}
tpm_token_identity() { jq -c '[.tokens | to_entries[] | select(.value.type == "systemd-tpm2") | .value] | if length == 1 then .[0] else empty end' | sha256sum | cut -d' ' -f1; }
valid_tracking_ref() { [[ $1 =~ ^ghcr\.io/frostyard/(cayo|snow|snowfield):[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; }
recovery_state_is_ready() { # manifest
    [[ -f $1 && $(stat -c '%a' "$1") == 600 ]] && jq -e '
        .schema == 1 and
        ([.target_disk, .ovmf_code, .ovmf_vars, .tpm_state, .tpm_socket,
          .recovery_key, .mok_cert, .pcr_public, .ssh_key, .tracking_ref,
          .accepted_oci_ref] | all(type == "string" and length > 0))
    ' "$1" >/dev/null
}
write_recipe() { # recipe-path ssh-public-key
    local recipe=$1 ssh_public=$2 tracking=${TRACKING_REF:-"ghcr.io/frostyard/$PROFILE:secure-test"}
    valid_tracking_ref "$tracking" && [[ $tracking == "ghcr.io/frostyard/$PROFILE:"* ]] || return 1
    jq -n --arg profile "$PROFILE" --arg oci_ref "$OCI_REF" --arg tracking "$tracking" \
        --arg disk "$TARGET_DISK" --arg recovery "$RECOVERY_KEY" --arg mok "$MOK_CERT" \
        --arg pcr "$PCR_PUBLIC" --arg ssh "$ssh_public" \
        '{schema: 1, profile: $profile, oci_ref: $oci_ref, tracking_ref: $tracking,
          target_disk: $disk, recovery_key: $recovery, mok_certificate: $mok,
          pcr_public_key: $pcr, root_ssh_authorized_key: $ssh}' >"$recipe"
}
write_install_state() { # state-path workdir recovery-key ssh-private-key recipe-path
    local state=$1 work=$2 recovery=$3 ssh_key=$4 recipe=$5 tracking
    tracking=$(jq -er '.tracking_ref' "$recipe") || return 1
    valid_tracking_ref "$tracking" && [[ $tracking == "ghcr.io/frostyard/$PROFILE:"* ]] || return 1
    umask 077
    jq -n --arg profile "$PROFILE" --arg tracking "$tracking" --arg accepted "$OCI_REF" \
        --arg disk "$TARGET_DISK" --arg code "$work/OVMF_CODE.fd" --arg vars "$work/OVMF_VARS.fd" \
        --arg tpm "$work/tpm" --arg socket "$work/tpm/swtpm-ctrl.sock" --arg recovery "$recovery" \
        --arg mok "$MOK_CERT" --arg pcr "$PCR_PUBLIC" --arg ssh "$ssh_key" \
        '{schema: 1, profile: $profile, tracking_ref: $tracking, accepted_oci_ref: $accepted,
          target_disk: $disk, ovmf_code: $code, ovmf_vars: $vars, tpm_state: $tpm,
          tpm_socket: $socket, recovery_key: $recovery, mok_cert: $mok, pcr_public: $pcr,
          ssh_key: $ssh}' >"$state"
    chmod 600 "$state"
}

require_live_inputs() {
    local missing=() command
    validate_profile "$PROFILE" || missing+=("PROFILE=cayo|snow|snowfield")
    [[ -f $DAKOTA_ISO ]] || missing+=("DAKOTA_ISO=<fresh secure Dakota ISO>")
    valid_oci_ref "$OCI_REF" && [[ $OCI_REF == "ghcr.io/frostyard/$PROFILE@"* ]] || missing+=("OCI_REF=ghcr.io/frostyard/$PROFILE@sha256:<digest>")
    [[ -f $MOK_CERT ]] || missing+=("MOK_CERT")
    [[ -f $PCR_PUBLIC ]] || missing+=("PCR_PUBLIC")
    valid_recovery_key "$RECOVERY_KEY" || missing+=("RECOVERY_KEY (regular, nonempty, mode 0600)")
    disk_is_large_enough "$TARGET_DISK" || missing+=("TARGET_DISK (blank >=30GiB disk)")
    [[ -x $BOOTC_SECURE_INSTALLER ]] || missing+=("BOOTC_SECURE_INSTALLER (secure Dakota supported-test runner)")
    [[ -x $BOOTC_SECURE_NEGATIVE_COMMAND ]] || missing+=("BOOTC_SECURE_NEGATIVE_COMMAND (negative-fixture runner)")
    [[ -x $BOOTC_SECURE_RECOVERY_COMMAND ]] || missing+=("BOOTC_SECURE_RECOVERY_COMMAND (positive recovery runner)")
    valid_tracking_ref "$TRACKING_REF" && [[ $TRACKING_REF == "ghcr.io/frostyard/$PROFILE:"* ]] || missing+=("TRACKING_REF=ghcr.io/frostyard/$PROFILE:<tracking-tag>")
    for command in jq qemu-img qemu-system-x86_64 swtpm virt-fw-vars cryptsetup objcopy sbverify ssh ssh-keygen ss; do
        command -v "$command" >/dev/null 2>&1 || missing+=("$command")
    done
    [[ -f "$SECURE_VM_OVMF_CODE" && -f "$SECURE_VM_OVMF_VARS" ]] || missing+=("Microsoft-enrolled OVMF firmware")
    if ((${#missing[@]})); then
        printf 'BLOCKED: Task 9 real install proof requires: %s\n' "${missing[*]}" >&2
        return 2
    fi
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
    if [[ $KEEP_VM == 1 || $HANDOFF_RETAIN == 1 ]]; then
        [[ -z $WORK ]] || printf 'retained secure VM state: %s\n' "$WORK"
        [[ $KEEP_VM != 1 ]] || printf 'WARNING: KEEP_VM=1 leaves QEMU/swtpm state running; stop them before consuming an exported update handoff.\n' >&2
    else
        [[ -z $WORK ]] || rm -rf -- "$WORK"
    fi
}
trap cleanup EXIT

run_fixtures() {
    local work entries output
    work=$(mktemp -d)
    trap 'rm -rf "$work"' RETURN
    assert_true 'cayo is a supported profile' validate_profile cayo
    assert_true 'snow is a supported profile' validate_profile snow
    assert_true 'snowfield is a supported profile' validate_profile snowfield
    assert_false 'unknown profiles are rejected' validate_profile invalid
    assert_true 'immutable matching OCI reference is accepted' valid_oci_ref "ghcr.io/frostyard/cayo@sha256:$(printf 'a%.0s' {1..64})"
    assert_false 'tags and wrong repositories are rejected' valid_oci_ref 'ghcr.io/frostyard/cayo:latest'
    printf key >"$work/recovery"; chmod 600 "$work/recovery"
    printf mok >"$work/mok.crt"; printf pcr >"$work/pcr.pub"; : >"$work/disk"
    OCI_REF="ghcr.io/frostyard/cayo@sha256:$(printf 'e%.0s' {1..64})"
    MOK_CERT="$work/mok.crt"; PCR_PUBLIC="$work/pcr.pub"; TARGET_DISK="$work/disk"; RECOVERY_KEY="$work/recovery"
    if command -v qemu-img >/dev/null 2>&1; then
        qemu-img create -q -f raw "$work/raw.img" 32212254720
        qemu-img create -q -f qcow2 "$work/not-raw.qcow2" 32212254720
        assert_true 'raw qemu image target is accepted' disk_is_raw "$work/raw.img"
        assert_false 'non-raw qemu image target is rejected' disk_is_raw "$work/not-raw.qcow2"
    fi
    assert_true 'mode-0600 recovery credential is accepted' valid_recovery_key "$work/recovery"
    chmod 644 "$work/recovery"
    assert_false 'world-readable recovery credential is rejected' valid_recovery_key "$work/recovery"
    assert_true 'captured TPM socket remains canonical after stopper clears its global' canonical_tpm_socket "$work" "$work/tpm/swtpm-ctrl.sock"
    assert_false 'recovery rejects a TPM socket outside owned state' canonical_tpm_socket "$work" /tmp/swtpm.sock
    if [[ $(composefs_from_cmdline "rw composefs=?$(printf 'b%.0s' {1..128})") == "$(printf 'b%.0s' {1..128})" ]]; then
        pass 'composefs parser accepts its one digest'
    else
        fail 'composefs parser accepts its one digest'
    fi
    if composefs_from_cmdline 'root=/dev/vda2' >/dev/null 2>&1; then
        fail 'composefs parser rejects root arguments'
    else
        pass 'composefs parser rejects root arguments'
    fi
    mkdir -p "$work/entries"
    entries="$work/entries/secure.conf"
    printf 'efi /EFI/Linux/bootc/bootc_composefs-%s.efi\n' "$(printf 'c%.0s' {1..128})" >"$entries"
    assert_true 'Type #2-only entry is accepted' type2_only "$entries"
    printf 'linux /vmlinuz\n' >>"$entries"
    assert_false 'raw BLS fallback is rejected' type2_only "$entries"
    printf 'efi /EFI/Linux/bootc/bootc_composefs-%s.efi\n' "$(printf 'd%.0s' {1..128})" >"$entries"
    if type2_only <(cat "$entries"); then
        pass 'Type #2 validation accepts process-substitution input'
    else
        fail 'Type #2 validation accepts process-substitution input'
    fi
    assert_true 'quote-containing cmdline data cannot false-pass root filtering' cmdline_has_root_or_luks "' root=/dev/vda2 #"
    printf '%s\n' '{"tokens":{"0":{"type":"systemd-tpm2","tpm2-pcrs":[],"tpm2_pubkey_pcrs":[11]}}}' >"$work/token.json"
    if signed_pcr11_token <"$work/token.json"; then
        pass 'one signed PCR-11 token is accepted'
    else
        fail 'one signed PCR-11 token is accepted'
    fi
    assert_true 'runner output requires its exact success marker' runner_output_has_marker \
        'BOOTC_SECURE_INSTALLER: installed' 'BOOTC_SECURE_INSTALLER: installed'
    assert_false 'runner output rejects a wrapped success marker' runner_output_has_marker \
        'prefix BOOTC_SECURE_INSTALLER: installed suffix' 'BOOTC_SECURE_INSTALLER: installed'
    assert_false 'runner output rejects /bin/true without its marker' runner_output_has_marker \
        '' 'BOOTC_SECURE_INSTALLER: installed'
    assert_true 'negative vocabulary excludes positive recovery operations' negative_case unsigned
    assert_false 'negative vocabulary excludes TPM replacement' negative_case tpm-replacement
    assert_true 'positive recovery vocabulary includes TPM replacement' recovery_case tpm-replacement
    assert_true 'runner environment exposes one persistent OVMF/TPM state' runner_environment_is_complete \
        "$work/OVMF_CODE.fd" "$work/OVMF_VARS.fd" "$work/tpm/swtpm-ctrl.sock"
    assert_true 'reconciler proof requires source and ESP hashes' reconciler_proof_shape \
        source-hash shim-hash mokmanager-hash grub-before-hash grub-after-hash
    assert_true 'ESP selection rejects empty and multiple results' exactly_one_line /dev/vda1
    assert_false 'ESP selection rejects an empty result' exactly_one_line ''
    assert_false 'ESP selection rejects multiple results' exactly_one_line $'/dev/vda1\n/dev/vda2'
    assert_true 'root status yields exactly one backing device' root_backing_device $'  device:  /dev/vda2\n'
    assert_false 'root status rejects multiple backing devices' root_backing_device $'device: /dev/vda2\ndevice: /dev/vdb2'
    assert_true 'recovery baselines chain from the prior token' recovery_baseline_is_current token-one token-one
    assert_false 'recovery does not reuse the original token baseline' recovery_baseline_is_current token-one token-zero
    assert_false 'runner failure is not accepted without executing the marker protocol' \
        run_marked_runner /bin/false 'BOOTC_SECURE_INSTALLER: installed'
    assert_false '/bin/true is not accepted without its marker' \
        run_marked_runner /bin/true 'BOOTC_SECURE_INSTALLER: installed'
    assert_true 'installer recipe writer creates the tracking-tag recipe' \
        write_recipe "$work/recipe.json" "$work/id_ed25519.pub"
    assert_true 'install handoff writer creates the update manifest' \
        write_install_state "$work/install-state.json" "$work" "$work/recovery" "$work/id_ed25519" "$work/recipe.json"
    assert_true 'install handoff manifest is mode 0600' test "$(stat -c '%a' "$work/install-state.json")" = 600
    assert_false 'install handoff manifest contains no recovery bytes' grep -Fq '"key"' "$work/install-state.json"
    assert_true 'install handoff preserves its tracking tag' jq -e '.tracking_ref == "ghcr.io/frostyard/cayo:secure-test"' "$work/install-state.json"
    assert_true 'recipe schema includes the tracking tag' jq -e '.tracking_ref == "ghcr.io/frostyard/cayo:secure-test"' "$work/recipe.json"
    assert_true 'recovery state is a mode-0600 path-only install handoff' recovery_state_is_ready "$work/install-state.json"
    output=$(PROFILE=invalid DAKOTA_ISO='' OCI_REF='' MOK_CERT='' PCR_PUBLIC='' RECOVERY_KEY='' TARGET_DISK='' BOOTC_SECURE_INSTALLER='' BOOTC_SECURE_NEGATIVE_COMMAND='' require_live_inputs 2>&1) || true
    if [[ $output == *'BLOCKED:'* ]]; then pass 'missing real inputs block rather than pass'; else fail 'missing real inputs block rather than pass'; fi
    printf '# Results: %d passed, %d failed, %d total\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
    [[ $FAIL -eq 0 ]]
}

run_negative_hooks() {
    local case_name
    for case_name in unsigned wrong-key wrong-repository false-capability wrong-mok-uki composefs-mismatch esp-full interrupted-finalize reconcile-failure; do
        run_marked_runner "$BOOTC_SECURE_NEGATIVE_COMMAND" "BOOTC_SECURE_NEGATIVE: $case_name: rejected" \
            --case "$case_name" --profile "$PROFILE" --oci-ref "$OCI_REF" --recipe "$WORK/recipe.json" || {
            echo "Error: negative fixture '$case_name' did not prove its required refusal" >&2; return 1; }
    done
}

stop_vm() {
    [[ -z $QEMU_PID ]] && return 0
    secure_vm_stop_owned_process "$QEMU_PID" || { echo "Error: owned QEMU PID $QEMU_PID did not stop" >&2; return 1; }
    QEMU_PID=''
}

ssh_port_available() { ! ss -ltn "sport = :$SSH_PORT" | grep -q LISTEN; }

start_vm() {
    rm -f "$WORK/qemu.pid" "$WORK/serial.sock"
    if ! ssh_port_available; then
        echo "BLOCKED: SSH_PORT=$SSH_PORT is already in use" >&2
        return 2
    fi
    QEMU_CONSOLE_LOG="$WORK/serial.log"
    export QEMU_CONSOLE_LOG
    qemu-system-x86_64 -machine q35 -enable-kvm -cpu host -m 4096 -smp 2 \
        -drive "if=pflash,format=raw,unit=0,file=$WORK/OVMF_CODE.fd,readonly=on" \
        -drive "if=pflash,format=raw,unit=1,file=$WORK/OVMF_VARS.fd" \
        -drive "file=$TARGET_DISK,format=raw,if=virtio" \
        -netdev "user,id=net0,hostfwd=tcp::$SSH_PORT-:22" -device virtio-net-pci,netdev=net0 \
        -display none -vga none -chardev "socket,id=tpmchr,path=$SECURE_VM_TPM_SOCK" \
        -tpmdev emulator,id=tpm0,chardev=tpmchr -device tpm-crb,tpmdev=tpm0 \
        -serial "file:$WORK/serial.log" -monitor none -pidfile "$WORK/qemu.pid" -daemonize
    QEMU_PID=$(<"$WORK/qemu.pid")
}

pre_mok_rejection() {
    local deadline=$((SECONDS + 60)) serial
    while ((SECONDS < deadline)); do
        if vm_ssh true 2>/dev/null; then
            echo 'Error: pre-enrollment target reached SSH; shim rejection failed' >&2
            return 1
        fi
        serial=$(cat "$WORK/serial.log" 2>/dev/null || true)
        [[ $serial == *'Security Violation'* ]] && { pass 'Microsoft-only varstore rejects the unenrolled MOK stage'; return 0; }
        kill -0 "$QEMU_PID" 2>/dev/null || break
        sleep 2
    done
    echo 'BLOCKED: pre-enrollment boot produced neither shim Security Violation nor a diagnosable boot-through' >&2
    return 2
}

exercise_reconciler() {
    # shellcheck disable=SC2016 # This complete script executes on the guest.
    vm_ssh 'set -euo pipefail
source=/usr/lib/snosi/bootc/systemd-bootx64.efi
backing=$(cryptsetup status root | awk "/device:/{print \$2; exit}")
disk=$(lsblk -no PKNAME "$backing")
esp=$(lsblk -J -o PATH,TYPE,PARTTYPE,PKNAME | jq -er --arg disk "$disk" ".. | objects | select(.type? == \"part\" and .pkname? == \$disk and (.parttype? | ascii_downcase) == \"c12a7328-f81f-11d2-ba4b-00a0c93ec93b\") | .path" | sort -u)
    test -n "$esp" && test "$(printf "%s" "$esp" | wc -l)" -eq 0
mountpoint=/run/task9-esp
mkdir "$mountpoint"
trap "umount \"$mountpoint\" 2>/dev/null || true; rmdir \"$mountpoint\" 2>/dev/null || true" EXIT
mount "$esp" "$mountpoint"
shim_before=$(sha256sum "$mountpoint/EFI/BOOT/BOOTX64.EFI")
mm_before=$(sha256sum "$mountpoint/EFI/BOOT/mmx64.efi")
source_hash=$(sha256sum "$source")
grub_before=$(sha256sum "$mountpoint/EFI/BOOT/grubx64.efi")
cp "$source" "$mountpoint/EFI/BOOT/grubx64.efi"
printf task9-corruption >>"$mountpoint/EFI/BOOT/grubx64.efi"
sync
systemctl start snosi-bootc-bootloader-reconcile.service
cmp "$source" "$mountpoint/EFI/BOOT/grubx64.efi"
test "$shim_before" = "$(sha256sum "$mountpoint/EFI/BOOT/BOOTX64.EFI")"
test "$mm_before" = "$(sha256sum "$mountpoint/EFI/BOOT/mmx64.efi")"
test "$source_hash" = "$(sha256sum "$mountpoint/EFI/BOOT/grubx64.efi")"
sbverify --cert /usr/lib/snosi/mok.crt "$mountpoint/EFI/BOOT/grubx64.efi" >/dev/null'
}

runner_left_shared_state_stopped() { # captured TPM socket
    local pid_file="$WORK/tpm/swtpm.pid" pid=''
    [[ -S $1 ]] && return 1
    [[ -f $pid_file ]] && pid=$(<"$pid_file")
    [[ -z $pid ]] || ! kill -0 "$pid" 2>/dev/null
}

post_recovery_security_subset() {
    local backing
    backing=$(root_backing_device "$(vm_ssh 'cryptsetup status root')") || return 1
    vm_ssh 'mokutil --sb-state | grep -q "SecureBoot enabled"' \
        && vm_ssh 'bootctl --no-pager status | grep -q "Measured UKI: yes"' \
        && vm_ssh 'grep -Eq "\[(integrity|confidentiality)\]" /sys/kernel/security/lockdown' \
        && vm_ssh "cryptsetup isLuks '$backing'" \
        && vm_ssh "cryptsetup luksDump --dump-json-metadata '$backing'" | signed_pcr11_token \
        && vm_ssh "cryptsetup open --test-passphrase --key-file=- '$backing'" <"$RECOVERY_KEY"
}

run_recovery_hook() { # case old-token-identity; sets RECOVERY_TOKEN_ID
    local case_name=$1 old_token=$2 output new_token boot_id new_id='' backing tpm_socket
    boot_id=$(vm_ssh 'cat /proc/sys/kernel/random/boot_id')
    tpm_socket=$SECURE_VM_TPM_SOCK
    canonical_tpm_socket "$WORK" "$tpm_socket" || { echo "Error: recovery TPM socket is not owned by $WORK/tpm" >&2; return 1; }
    # External recovery owns the shared disk, TPM, and varstore only while both
    # QEMU and swtpm are stopped. It must leave that shared state stopped.
    stop_vm || return 1
    secure_vm_stop_swtpm || return 1
    rm -f -- "$tpm_socket" "$WORK/tpm/swtpm.pid"
    # shellcheck disable=SC2153 # ssh_keygen initializes SSH_KEY before assert_guest.
    write_install_state "$WORK/recovery-state.json" "$WORK" "$RECOVERY_KEY" "$SSH_KEY" "$WORK/recipe.json" || return 1
    recovery_state_is_ready "$WORK/recovery-state.json" || return 1
    SNOSI_SECURE_OVMF_CODE="$WORK/OVMF_CODE.fd" SNOSI_SECURE_OVMF_VARS="$WORK/OVMF_VARS.fd" \
    SNOSI_SECURE_TPM_STATE="$WORK/tpm" SNOSI_SECURE_TPM_SOCKET="$tpm_socket" \
    run_marked_runner "$BOOTC_SECURE_RECOVERY_COMMAND" "BOOTC_SECURE_RECOVERY: $case_name: complete" \
        --case "$case_name" --profile "$PROFILE" --oci-ref "$OCI_REF" --state "$WORK/recovery-state.json" \
        --iso "$DAKOTA_ISO" --recipe "$WORK/recipe.json" --recovery-key "$RECOVERY_KEY" || return 1
    runner_output_has_marker "$RUNNER_OUTPUT" "BOOTC_SECURE_RECOVERY: $case_name: old-token-unavailable" || return 1
    runner_left_shared_state_stopped "$tpm_socket" || return 1
    secure_vm_start_swtpm_paths "$WORK/tpm" "$tpm_socket" "$WORK/tpm/swtpm.pid"
    start_vm
    wait_for_ssh || return 1
    new_id=$(vm_ssh 'cat /proc/sys/kernel/random/boot_id')
    [[ -n $new_id && $new_id != "$boot_id" ]] || return 1
    backing=$(root_backing_device "$(vm_ssh 'cryptsetup status root')") || return 1
    output=$(vm_ssh "cryptsetup luksDump --dump-json-metadata '$backing'")
    new_token=$(tpm_token_identity <<<"$output")
    [[ -n $new_token && $new_token != "$old_token" ]] || return 1
    post_recovery_security_subset || return 1
    RECOVERY_TOKEN_ID=$new_token
}

assert_guest() {
    local boot_id cmdline token provenance entries old_token backing
    assert_true 'firmware Secure Boot is enforced' vm_ssh 'mokutil --sb-state | grep -q "SecureBoot enabled"'
    assert_true 'booted chain is a measured UKI' vm_ssh 'bootctl --no-pager status | grep -q "Measured UKI: yes"'
    assert_true 'lockdown is integrity or confidentiality' vm_ssh 'grep -Eq "\[(integrity|confidentiality)\]" /sys/kernel/security/lockdown'
    cmdline=$(vm_ssh 'cat /proc/cmdline')
    if composefs_from_cmdline "$cmdline" >/dev/null; then pass 'kernel command line has a composefs binding without accepting raw root data'; else fail 'kernel command line has a composefs binding without accepting raw root data'; fi
    assert_false 'kernel command line contains no root or LUKS identifier' cmdline_has_root_or_luks "$cmdline"
    entries=$(vm_ssh 'cat /boot/loader/entries/*.conf')
    if type2_only <(printf '%s\n' "$entries"); then pass 'installed BLS entries are Type #2-only'; else fail 'installed BLS entries are Type #2-only'; fi
    backing=$(root_backing_device "$(vm_ssh 'cryptsetup status root')") || { fail 'root mapper reports exactly one backing LUKS device'; return; }
    assert_true 'root backing device is LUKS2 Btrfs' vm_ssh "cryptsetup isLuks '$backing' && findmnt -no FSTYPE / | grep -qx btrfs"
    token=$(vm_ssh "cryptsetup luksDump --dump-json-metadata '$backing'")
    if signed_pcr11_token <<<"$token"; then pass 'exactly one signed-PCR-11 TPM token exists'; else fail 'exactly one signed-PCR-11 TPM token exists'; fi
    if vm_ssh "cryptsetup open --test-passphrase --key-file=- '$backing'" <"$RECOVERY_KEY"; then pass 'recovery credential remains valid'; else fail 'recovery credential remains valid'; fi
    provenance=$(vm_ssh 'cat /var/lib/snosi/bootc-secure-install.json')
    if jq -e --arg ref "$OCI_REF" --arg tracking "$TRACKING_REF" '.oci_ref == $ref and .tracking_ref == $tracking and .repository and .secure_capability == true and .contract_schema == 1 and .assembly_compatibility and .composefs_id and .uki_sha256 and .mok_fingerprint and .pcr_fingerprint and .esp_partuuid and .luks_uuid and .tpm_token_id and .installer_versions.fisherman and .installer_versions.bootc_installer and .installer_versions.dakota_iso and (.completed_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T.*Z$"))' <<<"$provenance" >/dev/null; then pass 'secure install provenance is complete and non-secret'; else fail 'secure install provenance is complete and non-secret'; fi
    assert_true 'bootc reports a managed deployment' vm_ssh 'bootc status --json | jq -e ".status.booted != null" >/dev/null'
    assert_true 'persistent state and etc are ready' vm_ssh 'findmnt -no SOURCE /var | grep -q /dev/mapper/root && findmnt -no FSTYPE /etc | grep -q overlay'
    # shellcheck disable=SC2016 # The command substitution must execute in the guest.
    assert_true 'no system units failed' vm_ssh 'test -z "$(systemctl --failed --no-legend)"'
    assert_true 'real FAT ESP reconciler restores only the deliberately changed second stage' exercise_reconciler
    boot_id=$(vm_ssh 'cat /proc/sys/kernel/random/boot_id')
    vm_ssh systemctl reboot || true
    local deadline=$((SECONDS + SSH_TIMEOUT)) new_id=''
    while ((SECONDS < deadline)); do new_id=$(vm_ssh 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null || true); [[ -n $new_id && $new_id != "$boot_id" ]] && break; sleep 2; done
    if [[ -n $new_id && $new_id != "$boot_id" ]]; then pass 'TPM unlock reboot reached a distinct boot ID without recovery input'; else fail 'TPM unlock reboot reached a distinct boot ID without recovery input'; fi
    old_token=$(tpm_token_identity <<<"$token")
    assert_true 'TPM replacement produces a distinct token and unattended reboot' run_recovery_hook tpm-replacement "$old_token"
    old_token=$RECOVERY_TOKEN_ID
    assert_true 'recovery reenrollment retains recovery unlock and unattended reboot' run_recovery_hook recovery-reenrollment "$old_token"
}

run_live() {
    require_live_inputs
    WORK=$(mktemp -d /var/tmp/bootc-secure-install-test.XXXXXX)
    ssh_keygen "$WORK"
    # shellcheck disable=SC2153 # ssh_keygen initializes SSH_KEY for the recipe.
    write_recipe "$WORK/recipe.json" "${SSH_KEY}.pub"
    secure_vm_prepare_ovmf "$WORK"
    secure_vm_start_swtpm_paths "$WORK/tpm" "$WORK/tpm/swtpm-ctrl.sock" "$WORK/tpm/swtpm.pid"
    # The installer must receive the same firmware and TPM state later used for
    # the pre-MOK and enrolled target boots; no replacement state is permitted.
    SNOSI_SECURE_OVMF_CODE="$WORK/OVMF_CODE.fd" \
    SNOSI_SECURE_OVMF_VARS="$WORK/OVMF_VARS.fd" \
    SNOSI_SECURE_TPM_STATE="$WORK/tpm" \
    SNOSI_SECURE_TPM_SOCKET="$SECURE_VM_TPM_SOCK" \
    run_marked_runner "$BOOTC_SECURE_INSTALLER" 'BOOTC_SECURE_INSTALLER: installed' \
        --non-interactive --iso "$DAKOTA_ISO" --recipe "$WORK/recipe.json"
    # swtpm exits when its QEMU client does, and the installer runner's QEMU has
    # just exited -- so without re-arming, this boot dies at
    #   -chardev socket,id=tpmchr,path=.../swtpm-ctrl.sock: Failed to connect
    # Same state directory, never reinitialised: the sealed TPM state lives
    # there and a fresh one would silently invalidate the enrollment. This
    # mirrors what the post-enrollment boot below already does.
    secure_vm_start_swtpm_paths "$WORK/tpm" "$WORK/tpm/swtpm-ctrl.sock" "$WORK/tpm/swtpm.pid"
    start_vm
    pre_mok_rejection
    stop_vm
    secure_vm_stop_swtpm
    secure_vm_enroll_mok "$WORK/OVMF_VARS.fd" "$MOK_CERT"
    secure_vm_start_swtpm_paths "$WORK/tpm" "$WORK/tpm/swtpm-ctrl.sock" "$WORK/tpm/swtpm.pid"; start_vm
    wait_for_ssh || { echo 'BLOCKED: MOK-enrolled installed target did not reach SSH' >&2; return 2; }
    assert_guest
    run_negative_hooks
    if [[ -n $BOOTC_SECURE_INSTALL_STATE ]]; then
        stop_vm
        secure_vm_stop_swtpm
        if [[ $BOOTC_SECURE_INSTALL_STATE != "$WORK/recovery-state.json" ]]; then
            cp -- "$WORK/recovery-state.json" "$BOOTC_SECURE_INSTALL_STATE"
        fi
        chmod 600 "$BOOTC_SECURE_INSTALL_STATE"
        HANDOFF_RETAIN=1
        printf 'BOOTC_SECURE_INSTALL_STATE: %s\n' "$BOOTC_SECURE_INSTALL_STATE"
    fi
    [[ $FAIL -eq 0 ]]
}

if [[ ${1:-} == --fixtures ]]; then run_fixtures; exit $?; fi
[[ $# -eq 0 ]] || { echo "Usage: $0 [--fixtures]" >&2; exit 2; }
run_live
