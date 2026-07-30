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
for command in buildah jq objcopy objdump openssl podman sbverify; do
    command -v "$command" >/dev/null || { echo "BLOCKED: missing $command" >&2; exit 2; }
done

"$ASSEMBLER" --validate "$ROOTFS" "$IMAGE" "$MOK_CERT" "$PCR_CERT" "$PREVIOUS_PCR_CERT"
echo "bootc secure artifact validation passed"
