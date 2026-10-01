#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Static contract for authenticated systemd-sysupdate sysext metadata.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
base_conf="$root/mkosi.images/base/mkosi.conf"
repo_ring="$root/mkosi.sandbox/etc/apt/keyrings/frostyard.gpg"

mapfile -t transfers < <(find "$root/mkosi.images/base/mkosi.extra/usr/lib" \
    -path '*/sysupdate.*.d/*.transfer' -type f | sort)
((${#transfers[@]} > 0)) || {
    echo "no sysext transfer files found" >&2
    exit 1
}

for transfer in "${transfers[@]}"; do
    grep -qx 'Verify=true' "$transfer" || {
        echo "sysext transfer does not require signed metadata: ${transfer#"$root"/}" >&2
        exit 1
    }
done

for target in import-pubring.gpg import-pubring.pgp; do
    grep -Fqx "ExtraTrees=%D/mkosi.sandbox/etc/apt/keyrings/frostyard.gpg:/usr/lib/systemd/$target" \
        "$base_conf" || {
        echo "base image does not ship $target from the repository keyring" >&2
        exit 1
    }
done

repo_fingerprints="$(gpg --batch --show-keys --with-colons "$repo_ring" 2>/dev/null \
    | awk -F: '$1 == "fpr" { print $10 }')"
[[ "$repo_fingerprints" == 432C452CD2B7F4FF1B5D23264DE6A2016E622F97 ]] || {
    echo "base repository keyring has an unexpected signer set" >&2
    exit 1
}

echo "ok - ${#transfers[@]} sysext transfers require signed manifests"
echo "ok - base trusts only the repository signer"
