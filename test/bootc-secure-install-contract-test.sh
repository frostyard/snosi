#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Static contract consumed by Fisherman, bootc-installer, and Dakota media.
# shellcheck disable=SC2016 # Matches the literal documented recovery variable.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
contract="$root/shared/bootc-secure/tree/usr/lib/snosi/bootc-secure.json"
documentation="$root/docs/bootc-secure-install-contract.md"

python3 - "$contract" <<'PY'
import json
import sys

with open(sys.argv[1]) as f:
    contract = json.load(f)

assert contract["schema"] == 1
assert contract["encrypted_root_mapper"] == "root"
assert contract["installer"] == {
    "minimum_versions": {
        "bootc": "1.16.3",
        "cosign": "2.6.1",
        "systemd": "261.1-3",
    },
    "minimum_capacities": {
        "esp_bytes": 1073741824,
        "target_disk_bytes": 32212254720,
    },
    "oci": {
        "capability_label": "io.snosi.bootc.secureboot-capable",
        "capability_value": "true",
        "policy": "/etc/containers/policy.json",
        "signed_identity": "matchRepository",
    },
    "storage": {
        "esp_partition_type": "c12a7328-f81f-11d2-ba4b-00a0c93ec93b",
        "root_partition_type": "4f68bce3-e8cd-4db1-96e7-fbcaf984b709",
        "root_filesystem": "btrfs",
    },
    "bootc_install": {
        "composefs_backend": True,
        "bootloader": "systemd",
        "root_mount_spec": "",
        "type": "uki-type-2",
        "forbid_kargs": True,
    },
    "secure_boot": {
        "shim": "debian",
        "second_stage": "mok-signed-systemd-boot",
        "mok_manager": "MokManager",
    },
    "tpm": {
        "pcr_public_key": "/usr/lib/snosi/pcr-signing.pub",
        "pcr_public_key_source": "installed-uki-pcrpkey",
        "pcrs": "",
        "public_key_pcrs": "11",
        "pcrlock": "",
        "device": "auto",
        "unlock_key_file_required": True,
        "recovery_passphrase_required": True,
    },
}
PY

[[ -f "$documentation" ]]
python3 - "$contract" "$documentation" <<'PY'
import json
import sys

with open(sys.argv[1]) as f:
    installer = json.load(f)["installer"]
with open(sys.argv[2]) as f:
    documentation = f.read()

for version in installer["minimum_versions"].values():
    assert version in documentation
for capacity in installer["minimum_capacities"].values():
    assert str(capacity) in documentation
PY
grep -Fqx '# Bootc Secure Installation Contract' "$documentation"
grep -Fqx '```text' "$documentation"
grep -Fqx 'bootc install to-filesystem --composefs-backend --bootloader systemd --root-mount-spec ""' "$documentation"
grep -Fqx 'Fisherman must not pass `--karg`.' "$documentation"
grep -Fq 'io.snosi.bootc.secureboot-capable=true' "$documentation"
grep -Fq 'Type #2 UKI' "$documentation"
grep -Fq '.pcrpkey' "$documentation"
grep -Fq -- '--unlock-key-file="$RECOVERY_KEY"' "$documentation"
grep -Fq -- '--tpm2-device=auto' "$documentation"
grep -Fq 'restage' "$documentation"
grep -Fq 'repair' "$documentation"
grep -Fq 'BOOTC_SECURE_INSTALLER --non-interactive --iso "$DAKOTA_ISO" --recipe "$RECIPE"' "$documentation"
grep -Fq 'SNOSI_SECURE_OVMF_CODE' "$documentation"
grep -Fq 'SNOSI_SECURE_TPM_SOCKET' "$documentation"
grep -Fq 'BOOTC_SECURE_INSTALLER: installed' "$documentation"
grep -Fq '`tracking_ref` must be a tag in the same' "$documentation"
grep -Fq 'BOOTC_SECURE_NEGATIVE: unsigned: rejected' "$documentation"
grep -Fq 'tpm-replacement is not a negative case' "$documentation"
grep -Fq 'BOOTC_SECURE_RECOVERY: tpm-replacement: complete' "$documentation"
grep -Fq 'BOOTC_SECURE_RECOVERY_COMMAND --case <case> --profile "$PROFILE" --oci-ref "$OCI_REF" --state "$STATE" --iso "$DAKOTA_ISO" --recipe "$RECIPE" --recovery-key "$RECOVERY_KEY"' "$documentation"
grep -Fq '`oci_ref`' "$documentation"
grep -Fq '`tracking_ref`' "$documentation"
grep -Fq '`completed_at`' "$documentation"
grep -Fq 'representative Surface hardware' "$documentation"
grep -Fq 'qemu-img` raw image' "$documentation"
grep -Fq 'leave them stopped' "$documentation"
grep -Fq 'Live Task 9 execution remains BLOCKED' "$documentation"
grep -Fq 'UPDATE_N1_VERSION' "$documentation"
grep -Fq -- '--slot N+1|N+2' "$documentation"
grep -Fq '^[0-9]{14}$' "$documentation"
grep -Fq 'outcome=failed' "$documentation"
grep -Fq 'only the registry and SSH' "$documentation"
grep -Fq 'use only the registry and SSH to exercise the installed updater. It must never' "$documentation"
grep -Fq 'open or mutate the target disk, TPM state directory/socket, or OVMF vars' "$documentation"

echo "Bootc secure installer contract validation passed"
