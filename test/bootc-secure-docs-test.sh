#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Static contract for the normative bootc secure operations runbook (Task 11).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runbook="$root/docs/bootc-secure-operations.md"

[[ -f "$runbook" ]]

required_headings=(
    '## Support Status'
    '## Trust Boundaries'
    '## Build Modes And Publication'
    '## Fresh Installation'
    '## Recovery Credential Custody'
    '## MOK Restage'
    '## TPM Replacement And Recovery Reenrollment'
    '## ESP Repair'
    '## PCR Signing-Key Rotation'
    '## MOK Rotation'
    '## CI Evidence Tiers'
    '## Existing Installations'
    '## Incident Response'
    '## Evidence Retention'
)

required_strings=(
    'io.snosi.bootc.secureboot-capable=true'
    'io.snosi.bootc.secureboot-assembly=bootc-1.16.3-storage-digest-v1'
    '/dev/mapper/root'
    "ROOT_BACKING_DEVICE=\$(cryptsetup status root | awk '/^[[:space:]]*device:/{print \$2; exit}')"
    "ROOT_BACKING_DEVICE_COUNT=\$(cryptsetup status root | awk '/^[[:space:]]*device:/{print \$2}' | grep -Ec '^/dev/')"
    '[[ "$ROOT_BACKING_DEVICE_COUNT" -eq 1 ]]'
    "[[ \"\$ROOT_BACKING_DEVICE\" == /dev/* && \"\$ROOT_BACKING_DEVICE\" != *\$'\\n'* ]]"
    'cryptsetup isLuks "$ROOT_BACKING_DEVICE"'
    'systemd-cryptenroll --unlock-key-file="$RECOVERY_KEY" --tpm2-device=auto --tpm2-pcrs= --tpm2-public-key="$INSTALLED_PCR_PUBLIC_KEY" --tpm2-public-key-pcrs=11 --tpm2-pcrlock= "$ROOT_BACKING_DEVICE"'
    'cryptsetup open --test-passphrase'
    'BLOCKED:'
    'docs/bootc-secure-install-contract.md'
    'docs/bootc-secure-assembly-compatibility.md'
    'shared/bootc-secure/tree/usr/lib/snosi/bootc-secure.json'
    'Existing bootc and nbc installations cannot be converted in place to this secure layout.'
    'Private MOK and PCR keys never enter OCI images or installed systems.'
    'Dual-PCR transition policy is not fallback across independent TPM tokens.'
    'Remove the old MOK only after every old-signed rollback deployment is retired.'
    'Loss of both TPM authorization and the external recovery passphrase is unrecoverable.'
)

for heading in "${required_headings[@]}"; do
    grep -Fqx "$heading" "$runbook"
done

for required in "${required_strings[@]}"; do
    grep -Fq "$required" "$runbook"
done

unsupported_claims=(
    'production bootc Secure Boot is supported'
    'all three profiles have passed live validation'
    'Snowfield hardware validation passed'
    'bcvk validates Secure Boot'
)

for claim in "${unsupported_claims[@]}"; do
    if grep -Fq "$claim" "$runbook"; then
        echo "Unsupported claim in secure operations runbook: $claim" >&2
        exit 1
    fi
done

echo "Bootc secure operations documentation validation passed"
