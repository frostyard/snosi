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
# shellcheck disable=SC1091
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
        # install -m 0644, not cp: root-created 0640 copies are unreadable
        # by CI's unprivileged upload-artifact step (EACCES, seen live).
        install -m 0644 "$CONSOLE_LOG" "$SMOKE_CONSOLE_COPY" || true
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
