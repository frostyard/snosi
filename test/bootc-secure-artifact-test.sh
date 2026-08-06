#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Structural and live artifact validation for Task 5 bootc secure assembly.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSEMBLER="$ROOT_DIR/shared/bootc-secure/assemble-uki.sh"

if [[ ${1:-} == --fixtures ]]; then
    "$ASSEMBLER" --self-test
    "$ASSEMBLER" --credential-self-test
    echo "bootc secure artifact fixtures passed"
    exit 0
fi

ROOTFS=${1:?Usage: $0 ROOTFS OCI_IMAGE_REF MOK_CERT PCR_CERT [PREVIOUS_PCR_CERT]}
IMAGE=${2:?Usage: $0 ROOTFS OCI_IMAGE_REF MOK_CERT PCR_CERT [PREVIOUS_PCR_CERT]}
MOK_CERT=${3:?Usage: $0 ROOTFS OCI_IMAGE_REF MOK_CERT PCR_CERT [PREVIOUS_PCR_CERT]}
PCR_CERT=${4:?Usage: $0 ROOTFS OCI_IMAGE_REF MOK_CERT PCR_CERT [PREVIOUS_PCR_CERT]}
PREVIOUS_PCR_CERT=${5:-}

[[ -d "$ROOTFS" ]] || { echo "Error: missing rootfs: $ROOTFS" >&2; exit 1; }
for command in buildah chroot jq lsinitrd objcopy objdump openssl podman sbverify; do
    command -v "$command" >/dev/null || { echo "BLOCKED: missing $command" >&2; exit 2; }
done

if (( EUID != 0 )); then
    echo "BLOCKED: bootc secure artifact validation must run as root" >&2
    exit 2
fi

validate_gpt_auto_cryptsetup() {
    local uki initrd initrd_root generator_root generator unit
    uki=$(find "$ROOTFS/boot/EFI/Linux" -maxdepth 1 -type f -name '*.efi' -print -quit)
    [[ -n $uki ]] || { echo "Error: assembled UKI is missing" >&2; return 1; }

    initrd=$(mktemp)
    initrd_root=$(mktemp -d)
    trap 'rm -f "$initrd"; rm -rf "$initrd_root"' RETURN
    objcopy --dump-section ".initrd=$initrd" "$uki"
    (
        cd "$initrd_root"
        lsinitrd --unpack "$initrd"
    )

    generator=/usr/lib/systemd/system-generators/systemd-gpt-auto-generator
    [[ -x "$initrd_root$generator" ]] || {
        echo "Error: initramfs is missing $generator" >&2
        return 1
    }

    generator_root=/run/snosi-gpt-auto-generator-test
    mkdir -p \
        "$initrd_root$generator_root/normal" \
        "$initrd_root$generator_root/early" \
        "$initrd_root$generator_root/late"
    SYSTEMD_IN_INITRD=1 \
    SYSTEMD_IN_CHROOT=0 \
    SYSTEMD_PROC_CMDLINE='root=gpt-auto-force' \
    SYSTEMD_VIRTUALIZATION=none \
        chroot "$initrd_root" "$generator" \
            "$generator_root/normal" \
            "$generator_root/early" \
            "$generator_root/late"

    unit="$initrd_root$generator_root/late/systemd-cryptsetup@root.service"
    [[ -f $unit ]] || {
        echo "Error: initramfs gpt-auto-generator did not emit systemd-cryptsetup@root.service" >&2
        return 1
    }
    grep -Fq "ExecStart=/usr/lib/systemd/systemd-cryptsetup attach 'root' '/dev/gpt-auto-root-luks'" "$unit"
    grep -Fq 'BindsTo=dev-gpt\x2dauto\x2droot\x2dluks.device' "$unit"
    find "$initrd_root$generator_root/late" -type l \
        -lname '../systemd-cryptsetup@root.service' -print -quit | grep -q . || {
        echo "Error: generated root cryptsetup unit has no LUKS device dependency" >&2
        return 1
    }
}

"$ASSEMBLER" --validate "$ROOTFS" "$IMAGE" "$MOK_CERT" "$PCR_CERT" "$PREVIOUS_PCR_CERT"
validate_gpt_auto_cryptsetup
echo "bootc secure artifact validation passed"
