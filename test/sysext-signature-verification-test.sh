#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Static contract for authenticated systemd-sysupdate sysext metadata.
#
# Usage:
#   sysext-signature-verification-test.sh             static repository checks
#   sysext-signature-verification-test.sh --rootfs D  check a built image tree
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
base_conf="$root/mkosi.images/base/mkosi.conf"
secure_conf="$root/shared/bootc-secure/mkosi.conf"
repo_ring="$root/mkosi.sandbox/etc/apt/keyrings/frostyard.gpg"
pubring_names=(import-pubring.gpg import-pubring.pgp)

# A built rootfs must carry the repository keyring byte-for-byte at both
# vendor names. A later package install (systemd-container/forky) can
# replace the base copy; only the built tree proves the final content.
if [[ ${1:-} == --rootfs ]]; then
    rootfs=${2:?Usage: $0 --rootfs ROOTFS}
    [[ -d $rootfs ]] || {
        echo "missing rootfs: $rootfs" >&2
        exit 1
    }
    for target in "${pubring_names[@]}"; do
        cmp -s "$repo_ring" "$rootfs/usr/lib/systemd/$target" || {
            echo "rootfs /usr/lib/systemd/$target is not the repository keyring" >&2
            exit 1
        }
    done
    echo "ok - rootfs ships the repository keyring at both vendor names"
    exit 0
fi

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

# The base ships the keyring; the secure bootc composition upgrades
# systemd-container to Forky, which overwrites .pgp, so it must restore it.
for conf in "$base_conf" "$secure_conf"; do
    for target in "${pubring_names[@]}"; do
        grep -Fqx "ExtraTrees=%D/mkosi.sandbox/etc/apt/keyrings/frostyard.gpg:/usr/lib/systemd/$target" \
            "$conf" || {
            echo "${conf#"$root"/} does not ship $target from the repository keyring" >&2
            exit 1
        }
    done
done

repo_fingerprints="$(gpg --batch --show-keys --with-colons "$repo_ring" 2>/dev/null \
    | awk -F: '$1 == "fpr" { print $10 }')"
[[ "$repo_fingerprints" == 432C452CD2B7F4FF1B5D23264DE6A2016E622F97 ]] || {
    echo "base repository keyring has an unexpected signer set" >&2
    exit 1
}

echo "ok - ${#transfers[@]} sysext transfers require signed manifests"
echo "ok - base and secure bootc composition ship the repository keyring"
echo "ok - base trusts only the repository signer"
