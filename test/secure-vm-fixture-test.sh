#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Fixture coverage for the fail-closed Secure Boot VM helper.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/test/lib/secure-vm.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if secure_vm_require_files "$work/missing-code.fd" "$work/missing-vars.fd" "$work/missing-cert.crt"; then
    echo "not ok - missing firmware and certificate are rejected" >&2
    exit 1
fi

touch "$work/code.fd" "$work/vars.fd" "$work/mok.crt"
secure_vm_require_files "$work/code.fd" "$work/vars.fd" "$work/mok.crt"
echo "ok - present firmware and certificate are accepted"

sleep 60 &
owned_pid=$!
sleep 60 &
unrelated_pid=$!
if secure_vm_stop_owned_process "$owned_pid"; then
    if ! kill -0 "$owned_pid" 2>/dev/null && kill -0 "$unrelated_pid" 2>/dev/null; then
        echo "ok - owned process stop preserves unrelated process"
    else
        echo "not ok - owned process stop preserves unrelated process" >&2
        exit 1
    fi
else
    echo "not ok - owned process stops cleanly" >&2
    exit 1
fi
kill "$unrelated_pid" 2>/dev/null || true

sleep 60 &
SECURE_VM_SWTPM_PID=$!
if secure_vm_stop_swtpm && [[ -z $SECURE_VM_SWTPM_PID ]]; then
    echo "ok - swtpm stopper clears ownership only after exit"
else
    echo "not ok - swtpm stopper clears ownership only after exit" >&2
    exit 1
fi

native_harness="$ROOT_DIR/test/native-ab-secure-boot-test.sh"
# The literal shell source/call forms are the structural sharing contract.
# shellcheck disable=SC2016
grep -Fq 'source "$SCRIPT_DIR/lib/secure-vm.sh"' "$native_harness"
# shellcheck disable=SC2016
grep -Fq 'secure_vm_prepare_ovmf "$wd"' "$native_harness"
# shellcheck disable=SC2016
grep -Fq 'secure_vm_enroll_mok "$wd/OVMF_VARS.fd" "$cert"' "$native_harness"
# shellcheck disable=SC2016
grep -Fq 'secure_vm_start_swtpm "$wd"' "$native_harness"
echo "ok - native secure-boot harness consumes the shared lifecycle helpers"

grep -Fq 'secure_vm_start_swtpm_paths()' "$ROOT_DIR/test/lib/secure-vm.sh"
# shellcheck disable=SC2016 # Match the literal backwards-compatible delegate.
grep -Fq 'secure_vm_start_swtpm_paths "$workdir/tpm" "$workdir/tpm/swtpm-ctrl.sock" "$workdir/tpm/swtpm.pid"' "$ROOT_DIR/test/lib/secure-vm.sh"
echo "ok - secure VM helper exposes exact-path swtpm startup"

update_harness="$ROOT_DIR/test/bootc-secure-update-test.sh"
if grep -Fq 'openssl x509' "$update_harness"; then
    echo "not ok - update harness has no guest openssl dependency" >&2
    exit 1
fi
# shellcheck disable=SC2016 # Match the literal public-certificate transfer.
grep -Fq 'guest_mok=$(mktemp "$WORK/mok-guest.XXXXXX")' "$update_harness"
# shellcheck disable=SC2016 # Match the literal host/guest public comparison.
grep -Fq 'cmp -s "$mok" "$guest_mok"' "$update_harness"
echo "ok - update harness copies and compares the public guest MOK certificate"

install_harness="$ROOT_DIR/test/bootc-secure-install-test.sh"
# shellcheck disable=SC2016 # Match the capture before the stopper clears globals.
grep -Fq 'tpm_socket=$SECURE_VM_TPM_SOCK' "$install_harness"
# shellcheck disable=SC2016 # The runner must consume the captured socket, not the global.
grep -Fq 'SNOSI_SECURE_TPM_STATE="$WORK/tpm" SNOSI_SECURE_TPM_SOCKET="$tpm_socket"' "$install_harness"
# shellcheck disable=SC2016 # Restart must use the same captured path.
grep -Fq 'secure_vm_start_swtpm_paths "$WORK/tpm" "$tpm_socket" "$WORK/tpm/swtpm.pid"' "$install_harness"
echo "ok - recovery runner reuses captured TPM socket after global clear"
